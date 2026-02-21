//
//  TerminologyStore.swift
//  DrsMainApp
//
//  Local SNOMED terminology DB access (read-only runtime).
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class TerminologyStore: ObservableObject {

    private let log = AppLog.feature("terminology")

    // MARK: - Version contract
    // Bump this only when the SQLite schema layout changes (tables/columns/indexes).
    private let expectedSchemaVersion = "1.1"

    // Meta keys we expect in the terminology DB.
    private enum MetaKey {
        static let schemaVersion = "schema_version"
        static let rf2Release    = "rf2_release"
        static let subsetName    = "subset_name"
        static let subsetVersion = "subset_version"
        static let dbBuild       = "db_build"
        static let contentHash   = "content_hash"
    }

    // MARK: - IS-A hierarchy (subset graph)

    /// Loaded from the local terminology DB table `isa_edge`.
    ///
    /// We keep a simple parent adjacency list in memory because the subset is small
    /// and we need fast subsumption checks during guideline evaluation.
    private var isaLoaded = false
    private var isaParents: [Int64: [Int64]] = [:]

    /// Load `isa_edge` into memory (child -> [parents]). Safe to call multiple times.
    private func loadISAIfNeeded() {
        if isaLoaded { return }
        isaLoaded = true

        guard let db = openDBReadOnly() else {
            log.info("TerminologyStore: cannot load isa_edge (DB not available)")
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT child_concept_id, parent_concept_id
        FROM isa_edge;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("TerminologyStore: loadISAIfNeeded prepare failed: \(msg, privacy: .public)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        var parents: [Int64: [Int64]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let child = sqlite3_column_int64(stmt, 0)
            let parent = sqlite3_column_int64(stmt, 1)
            parents[child, default: []].append(parent)
        }

        self.isaParents = parents
        log.info("TerminologyStore: loaded isa_edge rows=\(parents.values.reduce(0) { $0 + $1.count }, privacy: .public)")
    }

    /// Direct parents of a concept (within the subset).
    func parents(of conceptID: Int64) -> [Int64] {
        loadISAIfNeeded()
        return isaParents[conceptID] ?? []
    }

    /// Returns true if `child` is equal to `ancestor` or is a descendant via repeated IS-A.
    ///
    /// Notes:
    /// - This only reasons over the subset we ship (not the full SNOMED graph).
    /// - Works well as long as your subset includes the relevant ancestor chain.
    func isDescendant(_ child: Int64, of ancestor: Int64) -> Bool {
        if child == ancestor { return true }
        loadISAIfNeeded()

        var visited = Set<Int64>()
        var stack: [Int64] = [child]

        while let cur = stack.popLast() {
            if !visited.insert(cur).inserted { continue }
            for p in isaParents[cur] ?? [] {
                if p == ancestor { return true }
                stack.append(p)
            }
        }
        return false
    }

    /// Returns a de-duplicated list of ancestors (parents, grandparents, ...) within the subset.
    ///
    /// - maxDepth: safety guard against cycles in unexpected data.
    func ancestors(of conceptID: Int64, maxDepth: Int = 64) -> [Int64] {
        loadISAIfNeeded()

        var out: [Int64] = []
        var visited = Set<Int64>()
        var frontier: [Int64] = [conceptID]
        var depth = 0

        while !frontier.isEmpty, depth < maxDepth {
            depth += 1
            var next: [Int64] = []
            for cur in frontier {
                for p in isaParents[cur] ?? [] {
                    if visited.insert(p).inserted {
                        out.append(p)
                        next.append(p)
                    }
                }
            }
            frontier = next
        }
        return out
    }

    // MARK: - Basic term search (dev / first integration)

    struct TermHit: Identifiable, Hashable {
        let id: Int64            // description_id
        let conceptID: Int64
        let term: String
    }

    /// Simple LIKE search in description.term (active rows only).
    ///
    /// Notes:
    /// - This is intentionally minimal for first wiring.
    /// - Later we’ll upgrade to preferred terms via langrefset and add locale/language handling.
    func searchTerms(_ query: String, limit: Int = 25) -> [TermHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        guard let db = openDBReadOnly() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT description_id, concept_id, term
        FROM description
        WHERE active = 1
          AND term LIKE ?
        ORDER BY LENGTH(term) ASC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("TerminologyStore: searchTerms prepare failed: \(msg, privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let like = "%\(q)%"
        _ = like.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 2, Int32(max(1, min(limit, 200))))

        var out: [TermHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let descID = sqlite3_column_int64(stmt, 0)
            let conceptID = sqlite3_column_int64(stmt, 1)
            guard let cStr = sqlite3_column_text(stmt, 2) else { continue }
            let term = String(cString: cStr)
            out.append(TermHit(id: descID, conceptID: conceptID, term: term))
        }
        return out
    }
    
    /// Very small “normalization” helper:
    /// - input: free text (any UI language for now, but works best with English mock DB)
    /// - output: best-matching conceptID (if any)
    ///
    /// Later upgrades:
    /// - restrict by language_code
    /// - prefer synonyms via langrefset acceptability
    /// - better ranking (token match, prefix boost, etc.)
    func bestConceptMatch(_ query: String) -> TermHit? {
        // Reuse current minimal search and pick the best hit.
        // For now: shortest term first (already ORDER BY LENGTH(term)).
        return searchTerms(query, limit: 1).first
    }

    /// Map a stable app feature key (e.g. "sick_episode_form.choice.wheeze") to a SNOMED concept_id.
    ///
    /// This uses the app-local terminology DB table `feature_snomed_map`.
    ///
    /// Returns: concept_id (SCTID) if mapped and active.
    func conceptIDForFeatureKey(_ featureKey: String) -> Int64? {
        let k = featureKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }

        guard let db = openDBReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT concept_id
        FROM feature_snomed_map
        WHERE active = 1
          AND feature_key = ?
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("TerminologyStore: conceptIDForFeatureKey prepare failed: \(msg, privacy: .public)")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        _ = k.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Batch map stable app feature keys (e.g. "sick_episode_form.choice.wheeze") to SNOMED concept_ids.
    ///
    /// - Uses a single SQLite open + a single SELECT with an `IN (...)` list.
    /// - Returns a dictionary keyed by feature_key with the mapped concept_id.
    /// - Ignores empty/whitespace-only keys.
    func conceptIDsForFeatureKeys(_ featureKeys: [String]) -> [String: Int64] {
        let keys = featureKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !keys.isEmpty else { return [:] }

        guard let db = openDBReadOnly() else { return [:] }
        defer { sqlite3_close(db) }

        // Build: (?, ?, ?, ...) placeholders
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let sql = """
        SELECT feature_key, concept_id
        FROM feature_snomed_map
        WHERE active = 1
          AND feature_key IN (\(placeholders));
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            log.error("TerminologyStore: conceptIDsForFeatureKeys prepare failed: \(msg, privacy: .public)")
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        // Bind keys 1..N
        for (i, k) in keys.enumerated() {
            _ = k.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, SQLITE_TRANSIENT) }
        }

        var out: [String: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kStr = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: kStr)
            let conceptID = sqlite3_column_int64(stmt, 1)
            out[key] = conceptID
        }
        return out
    }

    // MARK: - DB location (local app space, NOT patient bundle)
    /// ~/Library/Application Support/DrsMainApp/Terminology/snomed.sqlite
    private var dbURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))!
            .appendingPathComponent("DrsMainApp", isDirectory: true)
            .appendingPathComponent("Terminology", isDirectory: true)

        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }

        return base.appendingPathComponent("snomed.sqlite", isDirectory: false)
    }

    /// Name of the bundled DB file in app resources.
    /// You will add "snomed.sqlite" to the Xcode target's Copy Bundle Resources.
    private let bundledDBResourceName = "snomed"
    private let bundledDBResourceExt  = "sqlite"

    // MARK: - Lifecycle
    init() {
        installBundledDBIfNeeded()
        healthCheck()

        #if DEBUG
        // Dev smoke test: proves the DB opens and basic search returns rows.
        // Remove or gate behind a UI debug panel later.
        let hits = searchTerms("fever", limit: 5)
        if hits.isEmpty {
            log.info("TerminologyStore: DEBUG smoke search 'fever' -> 0 hits")
        } else {
            let sample = hits.map { $0.term }.joined(separator: " | ")
            log.info("TerminologyStore: DEBUG smoke search 'fever' -> \(hits.count, privacy: .public) hits: \(sample, privacy: .public)")
        }
        
        let hits2 = searchTerms("sibilants", limit: 5)
        if hits2.isEmpty {
            log.info("TerminologyStore: DEBUG smoke search 'sibilants' -> 0 hits")
        } else {
            let sample2 = hits2.map { "\($0.term) [\($0.conceptID)]" }.joined(separator: " | ")
            log.info("TerminologyStore: DEBUG smoke search 'sibilants' -> \(hits2.count, privacy: .public) hits: \(sample2, privacy: .public)")
        }

        let hits3 = searchTerms("wheezing", limit: 5)
        if hits3.isEmpty {
            log.info("TerminologyStore: DEBUG smoke search 'wheezing' -> 0 hits")
        } else {
            let sample3 = hits3.map { "\($0.term) [\($0.conceptID)]" }.joined(separator: " | ")
            log.info("TerminologyStore: DEBUG smoke search 'wheezing' -> \(hits3.count, privacy: .public) hits: \(sample3, privacy: .public)")
        }
        #endif
    }

    // MARK: - Install/copy bundled DB
    private func installBundledDBIfNeeded() {
        let fm = FileManager.default

        // If DB already exists locally, do nothing.
        if fm.fileExists(atPath: dbURL.path) { return }

        guard let src = Bundle.main.url(forResource: bundledDBResourceName, withExtension: bundledDBResourceExt) else {
            log.info("TerminologyStore: no bundled snomed.sqlite found in app resources (ok during dev)")
            return
        }

        do {
            try fm.copyItem(at: src, to: dbURL)
            log.info("TerminologyStore: installed bundled DB -> \(self.dbURL.lastPathComponent, privacy: .public)")
        } catch {
            log.error("TerminologyStore: copy bundled DB failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - SQLite open (READONLY)
    private func openDBReadOnly() -> OpaquePointer? {
        // If the DB file doesn't exist yet (common during dev), don't even attempt sqlite open.
        if !FileManager.default.fileExists(atPath: dbURL.path) {
            log.info("TerminologyStore: snomed.sqlite not present at expected path (ok during dev)")
            return nil
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY

        let rc = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            // Avoid calling sqlite APIs on a potentially-invalid pointer.
            if let db { sqlite3_close(db) }
            let msg = String(cString: sqlite3_errstr(rc))
            log.info("TerminologyStore: failed to open snomed.sqlite readonly rc=\(rc, privacy: .public) err=\(msg, privacy: .public)")
            return nil
        }

        return opened
    }

    // MARK: - Health check (cheap smoke test)
    private func healthCheck() {
        guard let db = openDBReadOnly() else { return }
        defer { sqlite3_close(db) }

        // Once the real schema is in place, we expect these core tables to exist.
        // (We keep the check lightweight and only log failures.)
        let expectedTables = [
            "meta",              // schema/version stamp
            "concept",           // SNOMED concepts (subset)
            "description",       // FSN + synonyms (subset)
            "langrefset",        // language refset preferences (subset)
            "isa_edge",          // hierarchy graph (subset)
            "feature_snomed_map" // app feature_key -> concept_id bridge
        ]

        func tableExists(_ name: String) -> Bool {
            let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            _ = name.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            return sqlite3_step(stmt) == SQLITE_ROW
        }

        var missing: [String] = []
        for t in expectedTables {
            if !tableExists(t) { missing.append(t) }
        }

        if !missing.isEmpty {
            log.info("TerminologyStore: snomed.sqlite opened, but missing tables: \(missing.joined(separator: ", "), privacy: .public)")
            return
        }

        // Read meta (schema + content) and enforce schema compatibility.
        func readMeta(_ key: String) -> String? {
            let sql = "SELECT value FROM meta WHERE key=? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
            let v = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }

        let schemaV = readMeta(MetaKey.schemaVersion) ?? "<missing>"
        let rf2Rel  = readMeta(MetaKey.rf2Release) ?? "<missing>"
        let subset  = readMeta(MetaKey.subsetName) ?? "<missing>"
        let subsetV = readMeta(MetaKey.subsetVersion) ?? "<missing>"

        // Optional meta keys: during early development/testing we may ship a mock DB
        // that intentionally omits build/hash stamps. Treat as informational only.
        let dbBuildRaw = readMeta(MetaKey.dbBuild)
        let hashRaw    = readMeta(MetaKey.contentHash)

        let dbBuildInfo: String = {
            guard let v = dbBuildRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return "" }
            return " build=\(v)"
        }()

        let hashInfo: String = {
            guard let v = hashRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return "" }
            return " hash=\(v)"
        }()

        if schemaV != expectedSchemaVersion {
            // Hard fail (we keep the DB unopened beyond this check, but signal loudly).
            log.info(
                "TerminologyStore: incompatible snomed.sqlite schema_version=\(schemaV, privacy: .public) expected=\(self.expectedSchemaVersion, privacy: .public) rf2=\(rf2Rel, privacy: .public) subset=\(subset, privacy: .public)"
            )
            return
        }

        log.info(
            "TerminologyStore: snomed.sqlite OK schema=\(schemaV, privacy: .public) rf2=\(rf2Rel, privacy: .public) subset=\(subset, privacy: .public) subsetV=\(subsetV, privacy: .public)\(dbBuildInfo)\(hashInfo)"
        )
    }
}
