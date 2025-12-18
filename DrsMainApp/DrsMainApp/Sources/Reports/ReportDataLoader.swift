


//  ReportDataLoader.swift
//  DrsMainApp
//

// REPORT CONTRACT (Well visits)
// - Age gating lives in WellVisitReportRules + ReportDataLoader ONLY.
// - Age gating controls ONLY which fields appear INSIDE the current visit sections.
// - Growth charts, perinatal summary, and previous well visits are NEVER age-gated.
// - ReportBuilder is a dumb renderer: it prints whatever WellReportData gives it.
//- We don't make RTF (that is legacy from previous failed attempts)
//- we don't touch GrowthCharts
//- we work with PDF and Docx.
//- the contract is to filter the age appropriate current visit field to include in the report. Everything else is left unchanged.


import Foundation
import SQLite3

// MARK: - Localization helpers (file-scope)
private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: .current, arguments: args)
}

// Ensure ordinal suffixes appear in lowercase (e.g., 1st, 2nd, 3rd, 4th)
private func prettifyOrdinals(_ s: String) -> String {
    do {
        let regex = try NSRegularExpression(
            pattern: "\\b(\\d+)([Ss][Tt]|[Nn][Dd]|[Rr][Dd]|[Tt][Hh])\\b"
        )
        let ns = s as NSString
        var result = ""
        var lastIndex = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            result += ns.substring(with: NSRange(location: lastIndex, length: range.location - lastIndex))
            let num = ns.substring(with: match.range(at: 1))
            let suf = ns.substring(with: match.range(at: 2)).lowercased()
            result += num + suf
            lastIndex = range.location + range.length
        }
        result += ns.substring(from: lastIndex)
        return result
    } catch {
        return s
    }
}

// MARK: - Visit type mapping (file-scope)
private let VISIT_TITLES: [String:String] = [
    "one_month": L("visit.type.one_month"),
    "two_month": L("visit.type.two_month"),
    "four_month": L("visit.type.four_month"),
    "six_month": L("visit.type.six_month"),
    "nine_month": L("visit.type.nine_month"),
    "twelve_month": L("visit.type.twelve_month"),
    "fifteen_month": L("visit.type.fifteen_month"),
    "eighteen_month": L("visit.type.eighteen_month"),
    "twentyfour_month": L("visit.type.twentyfour_month"),
    "thirty_month": L("visit.type.thirty_month"),
    "thirtysix_month": L("visit.type.thirtysix_month"),
    "newborn_1st_after_maternity": L("visit.type.newborn_1st_after_maternity"),
    "episode": L("visit.type.episode")
]

private func readableVisitType(_ raw: String?) -> String? {
    guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
    if let mapped = VISIT_TITLES[r] { return mapped }
    // Fallback: prettify snake_case → Title Case with nice ordinals
    let pretty = r.replacingOccurrences(of: "_", with: " ").capitalized
    return prettifyOrdinals(pretty)
}

@MainActor
final class ReportDataLoader {
    private let appState: AppState
    private let clinicianStore: ClinicianStore

    init(appState: AppState, clinicianStore: ClinicianStore) {
        self.appState = appState
        self.clinicianStore = clinicianStore
    }

    // MARK: - Public entry points

    func loadWell(visitID: Int) throws -> WellReportData {
        let meta = try buildMetaForWell(visitID: visitID)

        // STEP 1: Perinatal Summary (historical; NOT date-gated)
        // Per spec: perinatal_history is considered fixed historical info and should not be cutoff by visit date.
        var perinatalSummary: String? = nil
        if let pid = patientIDForWellVisit(visitID) {
            perinatalSummary = buildPerinatalSummary(patientID: pid, cutoffISO: nil)
        }

        // STEP 2: Findings from previous well visits (aggregated)
        let prevFindings = buildPreviousWellVisitFindings(currentVisitID: visitID, dobISO: meta.dobISO, cutoffISO: meta.visitDateISO)

        // STEP 3: Compute age in months for age-gated CURRENT VISIT sections
        // Use the same convention as growth logic (days / 30.4375) for consistency.
        var ageMonthsDouble: Double? = nil
        if let dobDate = parseDateFlexible(meta.dobISO),
           let visitDate = parseDateFlexible(meta.visitDateISO) {
            let seconds = visitDate.timeIntervalSince(dobDate)
            let days = seconds / 86400.0
            let months = max(0.0, days / 30.4375)
            ageMonthsDouble = months
        }
        let ageDebug = ageMonthsDouble.map { String(format: "%.2f", $0) } ?? "nil"
        print("[ReportDataLoader] well ageMonths for visitID=\(visitID): dob=\(meta.dobISO) visitDate=\(meta.visitDateISO) ageMonths=\(ageDebug)")
        // STEP 4: Current visit core fields (type subtitle, parents' concerns, feeding, supplementation, sleep)
        let core = loadCurrentWellCoreFields(visitID: visitID)
        let currentVisitTitle = core.visitType ?? (meta.visitTypeReadable ?? L("report.well_visit.default_title"))
        let parentsConcernsRaw = core.parentsConcerns
        let feedingRaw = core.feeding
        let supplementationRaw = core.supplementation
        let stoolRaw = core.stool
        let sleepRaw = core.sleep
        print("[ReportDataLoader] wellCore: type='\(currentVisitTitle)' parents=\(parentsConcernsRaw?.count ?? 0) feed=\(feedingRaw.count) supp=\(supplementationRaw.count) stool=\(stoolRaw.count) sleep=\(sleepRaw.count)")

        // STEP 5: Developmental evaluation (M-CHAT / Dev test / Parents' Concerns) + Milestones (for this visit)
        let devPack = loadDevelopmentForWellVisit(visitID: visitID)
        // STEP 6: Measurements (today’s W/L/HC + weight-gain since discharge)
        let measurementsRaw = loadMeasurementsForWellVisit(visitID: visitID)

        // STEP 7: Physical Exam + problem listing / conclusions / guidance / comments / next visit
        let pePack = loadWellPEAndText(visitID: visitID)

        // STEP 8: Apply age-based visibility for CURRENT VISIT sections ONLY.
        // Per REPORT CONTRACT:
        // - Perinatal summary, growth charts, and previous well visits are NEVER age-gated.
        // - Age gating controls only which fields are populated inside the current visit sections.
        
        let rawVisitTypeID = rawVisitTypeIDForWell(visitID: visitID) ?? core.visitType
        let visibility = WellVisitReportRules.visibility(for: rawVisitTypeID, ageMonths: ageMonthsDouble)
        let rawTypeDebug = rawVisitTypeID ?? core.visitType ?? "nil"
        print("[ReportDataLoader] well visibility lookup for visitID=\(visitID): rawTypeID=\(rawTypeDebug) ageMonths=\(ageDebug) visibility=\(String(describing: visibility))")

        // At this stage, all age/visit-type gating has already been applied upstream
        // (WellVisitReportRules + form logic). ReportDataLoader now only routes
        // the already-filtered fields into the WellReportData sections and
        // prettifies them downstream in ReportBuilder.
        let parentsConcerns = parentsConcernsRaw
        let feeding = feedingRaw
        let supplementation = supplementationRaw
        let stool = stoolRaw
        let sleep = sleepRaw
        let developmental = devPack.dev
        let milestonesAchieved = (devPack.achieved, devPack.total)
        let milestoneFlags = devPack.flags
        let measurements = measurementsRaw
        let physicalExamGroups = pePack.groups
        let problemListing = repairWellProblemListing(visitID: visitID,
                                                      rawProblemListing: pePack.problem,
                                                      ageMonths: ageMonthsDouble) ?? pePack.problem
        let conclusions = pePack.conclusions
        let anticipatoryGuidance = pePack.anticipatory
        let clinicianComments = pePack.comments
        let nextVisitDate = pePack.nextVisitDate

        // Header + perinatal summary stay untouched; ReportDataLoader does
        // no additional gating here, it simply forwards the gated data.
        return WellReportData(
            meta: meta,
            perinatalSummary: perinatalSummary,
            previousVisitFindings: prevFindings,
            currentVisitTitle: currentVisitTitle,
            parentsConcerns: parentsConcerns,
            feeding: feeding,
            supplementation: supplementation,
            stool: stool,
            sleep: sleep,
            developmental: developmental,
            milestonesAchieved: milestonesAchieved,
            milestoneFlags: milestoneFlags,
            measurements: measurements,
            physicalExamGroups: physicalExamGroups,
            problemListing: problemListing,
            conclusions: conclusions,
            anticipatoryGuidance: anticipatoryGuidance,
            clinicianComments: clinicianComments,
            nextVisitDate: nextVisitDate,
            growthCharts: [],
            visibility: visibility
        )
    }

    // MARK: - Well Problem Listing: full recovery (repair stored-key lines)
    //
    // Some older well visits stored localization KEYS (e.g. "well_visit_form.problem_listing.parents_concerns")
    // instead of localized, formatted text. This repairs those lines at report-time by re-reading the
    // underlying DB fields and formatting them with the current language.

    private func repairWellProblemListing(visitID: Int, rawProblemListing: String?, ageMonths: Double?) -> String? {
        guard let raw = rawProblemListing?.replacingOccurrences(of: "\r", with: "\n") else { return nil }
        let trimmedAll = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAll.isEmpty else { return nil }

        // Only do work if the block contains any of our known broken keys
        if !trimmedAll.contains("well_visit_form.problem_listing.") { return rawProblemListing }

        let row = fetchWellVisitRowMap(visitID: visitID)

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }

        func formatKey(_ key: String, value: String?) -> String? {
            let fmt = NSLocalizedString(key, comment: "")
            // If the localized string expects a value, format it; otherwise just return the localized label.
            if let v = nonEmpty(value), (fmt.contains("%@") || fmt.contains("%1$@")) {
                return String(format: fmt, locale: .current, v)
            }
            // If there is no value, return the localized string only if it is not the key itself.
            return (fmt == key) ? nil : fmt
        }

        // Pull values from the DB row (use multiple candidate column names to be robust)
        let parentsConcerns = nonEmpty(stringFromRow(row, keys: ["parents_concerns","parent_concerns"]))
        let feedingIssue    = nonEmpty(stringFromRow(row, keys: ["feeding_issue","feeding_difficulty","feeding_problem"]))
        let foodVariety     = nonEmpty(stringFromRow(row, keys: ["food_variety_quality","food_variety","foodVarietyQuality"]))
        let poopStatus      = nonEmpty(stringFromRow(row, keys: ["poop_status","stool_status","stools_status"]))
        let poopComment     = nonEmpty(stringFromRow(row, keys: ["poop_comment","stool_comment","stools_comment"]))
        let wakesPerNight   = nonEmpty(stringFromRow(row, keys: ["wakes_for_feeds_per_night","wakesForFeedsPerNight","wakes_per_night"]))
        let sleepHoursText  = nonEmpty(stringFromRow(row, keys: ["sleep_hours_text","sleep_hours","sleepHoursText"]))
        let sleepRegular    = nonEmpty(stringFromRow(row, keys: ["sleep_regular","sleep_regularity","sleepRegular"]))
        let sleepIssueText  = nonEmpty(stringFromRow(row, keys: ["sleep"]))
        let solidQuality    = nonEmpty(stringFromRow(row, keys: ["solid_food_quality","solids_quality","solidFoodQuality"]))
        let solidComment    = nonEmpty(stringFromRow(row, keys: ["solid_food_comment","solids_comment","solidFoodComment"]))
        let feedingDiet     = nonEmpty(stringFromRow(row, keys: ["feeding"]))
        let dairyCode       = nonEmpty(stringFromRow(row, keys: ["dairy_amount_code","dairyAmountCode","dairy_amount"]))
        let regurgPresent   = boolFromRow(row, keys: ["regurgitation_present","regurgitationPresent","regurgitation"])
        let solidStarted    = boolFromRow(row, keys: ["solid_food_started","solidFoodStarted","solids_started"])
        let snoring         = boolFromRow(row, keys: ["sleep_snoring","sleepSnoring","snoring"])

        let isPostTwelveMonths = (ageMonths ?? 0.0) >= 12.0

        func shouldFlagSleepDuration(_ raw: String) -> Bool {
            let lower = raw.lowercased()
            if lower.contains("<10") || lower.contains("less than 10") { return true }
            let digits = raw.filter { "0123456789.".contains($0) }
            if let v = Double(digits), v < 10 { return true }
            return false
        }

        func replacementForKey(_ key: String) -> String? {
            switch key {
            case "well_visit_form.problem_listing.parents_concerns":
                return formatKey(key, value: parentsConcerns)

            case "well_visit_form.problem_listing.feeding.regurgitation":
                return regurgPresent ? formatKey(key, value: nil) : nil

            case "well_visit_form.problem_listing.feeding.difficulty":
                return formatKey(key, value: feedingIssue)

            case "well_visit_form.problem_listing.feeding.diet":
                return formatKey(key, value: feedingDiet)

            case "well_visit_form.problem_listing.feeding.solids_started":
                return solidStarted ? formatKey(key, value: nil) : nil

            case "well_visit_form.problem_listing.feeding.solids_quality":
                return formatKey(key, value: solidQuality)

            case "well_visit_form.problem_listing.feeding.solids_comment":
                return formatKey(key, value: solidComment)

            case "well_visit_form.problem_listing.feeding.food_variety":
                if let fv = foodVariety, !fv.isEmpty, fv.lowercased() != "appears good" {
                    return formatKey(key, value: fv)
                }
                return nil

            case "well_visit_form.problem_listing.feeding.dairy_gt_3":
                return (dairyCode == "4") ? formatKey(key, value: nil) : nil

            case "well_visit_form.problem_listing.stools.abnormal":
                return (poopStatus == "abnormal") ? formatKey(key, value: nil) : nil

            case "well_visit_form.problem_listing.stools.hard":
                return (poopStatus == "hard") ? formatKey(key, value: nil) : nil

            case "well_visit_form.problem_listing.stools.comment":
                return formatKey(key, value: poopComment)

            case "well_visit_form.problem_listing.sleep.wakes_per_night":
                return (isPostTwelveMonths ? formatKey(key, value: wakesPerNight) : nil)

            case "well_visit_form.problem_listing.sleep.duration":
                if let sh = sleepHoursText, shouldFlagSleepDuration(sh) {
                    return formatKey(key, value: sh)
                }
                return nil

            case "well_visit_form.problem_listing.sleep.regularity":
                return formatKey(key, value: sleepRegular)

            case "well_visit_form.problem_listing.sleep.snoring":
                return snoring ? formatKey(key, value: nil) : nil

            case "well_visit_form.problem_listing.sleep.issue":
                return formatKey(key, value: sleepIssueText)

            default:
                return nil
            }
        }

        let lines = raw.components(separatedBy: .newlines)
        var out: [String] = []
        out.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                out.append(line)
                continue
            }

            let hasBullet = trimmed.hasPrefix("• ")
            let core = hasBullet ? String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed

            if core.hasPrefix("well_visit_form.problem_listing.") {
                if let repl = replacementForKey(core) {
                    out.append(hasBullet ? "• \(repl)" : repl)
                } else {
                    // If we can't rebuild it, drop the broken key line.
                    continue
                }
            } else {
                out.append(line)
            }
        }

        let repaired = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return repaired.isEmpty ? nil : repaired
    }

    // MARK: - Well choice + milestone localization helpers (used for previous visits recompute)

    private func localizedStringIfExists(_ key: String) -> String? {
        let v = NSLocalizedString(key, comment: "")
        return (v == key) ? nil : v
    }

    private func slugifyToken(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "(", with: "")
        t = t.replacingOccurrences(of: ")", with: "")
        t = t.replacingOccurrences(of: "-", with: " ")
        t = t.replacingOccurrences(of: "/", with: " ")

        let allowed = CharacterSet.alphanumerics
        var out = ""
        var lastUnderscore = false
        for scalar in t.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastUnderscore = false
            } else {
                if !lastUnderscore {
                    out.append("_")
                    lastUnderscore = true
                }
            }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out
    }

    private func reportLocalizedWellChoiceToken(_ rawToken: String) -> String {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return rawToken }

        let slug = slugifyToken(token)

        // Try well-visit specific choice keys first, then fall back to common, then keep raw.
        let candidates: [String] = [
            "well_visit_form.choice.\(slug)",
            "well_visit_form.choice_\(slug)",
            "well_visit_form.choice.feeding.\(slug)",
            "well_visit_form.choice.sleep.\(slug)",
            "well_visit_form.choice.stools.\(slug)",
            "common.choice.\(slug)",
            "common.choice_\(slug)"
        ]

        for k in candidates {
            if let v = localizedStringIfExists(k) { return v }
        }

        // As a last-resort, humanize snake_case codes.
        if token.contains("_") {
            let pretty = token.replacingOccurrences(of: "_", with: " ")
            return pretty.prefix(1).uppercased() + pretty.dropFirst()
        }

        return token
    }

    private func reportLocalizedWellChoiceTokenList(_ rawList: String?) -> String? {
        guard let rawList = rawList else { return nil }
        let trimmed = rawList.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if tokens.count <= 1 {
            return reportLocalizedWellChoiceToken(trimmed)
        }
        return tokens.map { reportLocalizedWellChoiceToken($0) }.joined(separator: ", ")
    }

    private func localizedMilestoneTitle(code: String, label: String) -> String {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty {
            let slug = slugifyToken(c)
            let candidates: [String] = [
                "milestone.\(slug)",
                "milestones.\(slug)",
                "well_visit.milestone.\(slug)",
                "well_visit_form.milestone.\(slug)"
            ]
            for k in candidates {
                if let v = localizedStringIfExists(k) { return v }
            }
        }
        return !l.isEmpty ? l : (!c.isEmpty ? c : L("report.milestone.default_title"))
    }

    private func localizedMilestoneStatus(_ status: String) -> String {
        let s = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        let slug = slugifyToken(s)
        let candidates: [String] = [
            "milestone.status.\(slug)",
            "milestones.status.\(slug)",
            "well_visit.milestone.status.\(slug)",
            "well_visit_form.milestone.status.\(slug)"
        ]
        for k in candidates {
            if let v = localizedStringIfExists(k) { return v }
        }
        return s
    }

    private func computeAgeMonths(dobISO: String, visitISO: String) -> Double? {
        guard let dob = parseDateFlexible(dobISO),
              let v = parseDateFlexible(visitISO),
              v >= dob else { return nil }
        let seconds = v.timeIntervalSince(dob)
        let days = seconds / 86400.0
        return max(0.0, days / 30.4375)
    }

    private func computedWellProblemItemsFromRow(_ row: [String:String], ageMonths: Double?) -> [String] {
        var items: [String] = []

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }

        // --- Parents' concerns ---
        if let pc = nonEmpty(stringFromRow(row, keys: ["parents_concerns","parent_concerns"])) {
            let fmt = L("well_visit_form.problem_listing.parents_concerns")
            items.append(String(format: fmt, locale: .current, pc))
        }

        // --- Feeding / diet ---
        let regurgPresent = boolFromRow(row, keys: ["regurgitation_present","regurgitationPresent","regurgitation"])
        if regurgPresent {
            items.append(L("well_visit_form.problem_listing.feeding.regurgitation"))
        }

        if let feedingIssue = nonEmpty(stringFromRow(row, keys: ["feeding_issue","feeding_difficulty","feeding_problem"])) {
            let fmt = L("well_visit_form.problem_listing.feeding.difficulty")
            items.append(String(format: fmt, locale: .current, feedingIssue))
        }

        if let feedingDiet = nonEmpty(stringFromRow(row, keys: ["feeding"])) {
            // feeding is usually free text; keep as-is
            let fmt = L("well_visit_form.problem_listing.feeding.diet")
            items.append(String(format: fmt, locale: .current, feedingDiet))
        }

        let solidStarted = boolFromRow(row, keys: ["solid_food_started","solidFoodStarted","solids_started"])
        if solidStarted {
            items.append(L("well_visit_form.problem_listing.feeding.solids_started"))
        }

        if let solidQuality = nonEmpty(stringFromRow(row, keys: ["solid_food_quality","solids_quality","solidFoodQuality"])) {
            let fmt = L("well_visit_form.problem_listing.feeding.solids_quality")
            items.append(String(format: fmt, locale: .current, solidQuality))
        }

        if let solidComment = nonEmpty(stringFromRow(row, keys: ["solid_food_comment","solids_comment","solidFoodComment"])) {
            let fmt = L("well_visit_form.problem_listing.feeding.solids_comment")
            items.append(String(format: fmt, locale: .current, solidComment))
        }

        // Food variety: only if NOT "appears good" (also treat "appears_good" as good)
        if let fvRaw = nonEmpty(stringFromRow(row, keys: ["food_variety_quality","food_variety","foodVarietyQuality"])) {
            let fvNorm = fvRaw.lowercased().replacingOccurrences(of: "_", with: " ")
            if fvNorm != "appears good" {
                let fv = reportLocalizedWellChoiceToken(fvRaw)
                let fmt = L("well_visit_form.problem_listing.feeding.food_variety")
                items.append(String(format: fmt, locale: .current, fv))
            }
        }

        // Dairy intake: only if more than 3 cups (code "4")
        if let dairyCode = nonEmpty(stringFromRow(row, keys: ["dairy_amount_code","dairyAmountCode","dairy_amount"])) {
            if dairyCode == "4" {
                items.append(L("well_visit_form.problem_listing.feeding.dairy_gt_3"))
            }
        }

        // --- Stools ---
        if let poopStatus = nonEmpty(stringFromRow(row, keys: ["poop_status","stool_status","stools_status"])) {
            let ps = poopStatus.lowercased()
            if ps == "abnormal" {
                items.append(L("well_visit_form.problem_listing.stools.abnormal"))
            } else if ps == "hard" {
                items.append(L("well_visit_form.problem_listing.stools.hard"))
            }
        }

        if let poopComment = nonEmpty(stringFromRow(row, keys: ["poop_comment","stool_comment","stools_comment"])) {
            let fmt = L("well_visit_form.problem_listing.stools.comment")
            items.append(String(format: fmt, locale: .current, poopComment))
        }

        // --- Sleep ---
        let sleepSnoring = boolFromRow(row, keys: ["sleep_snoring","sleepSnoring","snoring"])
        if sleepSnoring {
            items.append(L("well_visit_form.problem_listing.sleep.snoring"))
        }

        if let wakes = nonEmpty(stringFromRow(row, keys: ["wakes_for_feeds_per_night","wakesForFeedsPerNight","wakes_per_night"])) {
            let isPost12 = (ageMonths ?? 0.0) >= 12.0
            if isPost12 {
                let fmt = L("well_visit_form.problem_listing.sleep.wakes_per_night")
                items.append(String(format: fmt, locale: .current, wakes))
            }
        }

        if let sleepHoursText = nonEmpty(stringFromRow(row, keys: ["sleep_hours_text","sleep_hours","sleepHoursText"])) {
            // only flag if < 10h (same heuristic as the form)
            let lower = sleepHoursText.lowercased()
            var shouldFlag = false
            if lower.contains("<10") || lower.contains("less than 10") {
                shouldFlag = true
            } else {
                let digits = sleepHoursText.filter { "0123456789.".contains($0) }
                if let v = Double(digits), v < 10 { shouldFlag = true }
            }
            if shouldFlag {
                let fmt = L("well_visit_form.problem_listing.sleep.duration")
                items.append(String(format: fmt, locale: .current, sleepHoursText))
            }
        }

        if let sleepRegularRaw = nonEmpty(stringFromRow(row, keys: ["sleep_regular","sleep_regularity","sleepRegular"])) {
            // keep only if NOT "regular" (also treat codes)
            let norm = sleepRegularRaw.lowercased().replacingOccurrences(of: "_", with: " ")
            if norm != "regular" {
                let v = reportLocalizedWellChoiceToken(sleepRegularRaw)
                let fmt = L("well_visit_form.problem_listing.sleep.regularity")
                items.append(String(format: fmt, locale: .current, v))
            }
        }

        if let sleepIssue = nonEmpty(stringFromRow(row, keys: ["sleep"])) {
            let fmt = L("well_visit_form.problem_listing.sleep.issue")
            items.append(String(format: fmt, locale: .current, sleepIssue))
        }

        return items
    }

    private func fetchWellVisitRowMap(visitID: Int) -> [String:String] {
        var row: [String:String] = [:]
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }

                let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT * FROM \(wellTable) WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }
                    }
                }
            }
        } catch {
            // ignore
        }
        return row
    }

    private func stringFromRow(_ row: [String:String], keys: [String]) -> String? {
        for k in keys {
            if let v = row[k] { return v }
        }
        return nil
    }

    private func boolFromRow(_ row: [String:String], keys: [String]) -> Bool {
        guard let raw = stringFromRow(row, keys: keys)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let lower = raw.lowercased()
        if ["1","true","yes","y","oui"].contains(lower) { return true }
        if ["0","false","no","n","non"].contains(lower) { return false }
        // If stored as any non-empty string, treat as true (last-resort)
        return true
    }

    // Resolve patient_id for a WELL visit by introspecting the well table and FK column.
    private func patientIDForWellVisit(_ visitID: Int) -> Int64? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let cName = sqlite3_column_text(s, 1) {
                                cols.insert(String(cString: cName))
                            }
                        }
                    }
                    return cols
                }

                // Decide which table holds well visits
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: table)
                let fkCandidates = ["patient_id","patientId","patientID"]
                guard let fk = fkCandidates.first(where: { cols.contains($0) }) else { return nil }

                let sql = "SELECT \(fk) FROM \(table) WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                var val: Int64 = -1
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL {
                        val = sqlite3_column_int64(st, 0)
                    }
                }
                return val > 0 ? val : nil
            }
        } catch {
            // ignore and fall back
        }
        return nil
    }

    // Build a single-line perinatal summary from perinatal_summary (latest row for the patient, with optional cutoff)
    private func buildPerinatalSummary(patientID: Int64, cutoffISO: String?) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func dbg(_ msg: String) { print("[ReportDataLoader] buildPerinatalSummary(pid:\(patientID)): \(msg)") }

                // 1) List tables
                var tables: [String] = []
                var tStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &tStmt, nil) == SQLITE_OK, let s = tStmt {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 0) { tables.append(String(cString: c)) }
                    }
                }
                dbg("tables: \(tables)")

                // 2) Pick perinatal table
                let candidates = ["perinatal_summary","perinatal","perinatal_summaries","perinatal_info","perinatal_history"]
                guard let table = candidates.first(where: { tables.contains($0) }) else {
                    dbg("no perinatal table found"); return nil
                }
                dbg("using table: \(table)")

                // 3) Columns for the chosen table
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let cName = sqlite3_column_text(s, 1) { cols.insert(String(cString: cName)) }
                    }
                }
                dbg("columns: \(Array(cols).sorted())")
                if cols.isEmpty { return nil }

                // 4) Patient FK
                let patientFK = ["patient_id","patientId","patientID"].first(where: { cols.contains($0) }) ?? "patient_id"
                dbg("patient FK: \(patientFK)")

                // Helper to bind text
                func bindText(_ st: OpaquePointer, _ index: Int32, _ str: String) {
                    _ = str.withCString { cstr in
                        sqlite3_bind_text(st, index, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }

                // 5) Helper to fetch one value (first existing column)
                func val(_ keys: [String]) -> String? {
                    guard let col = keys.first(where: { cols.contains($0) }) else { return nil }
                    let orderField = cols.contains("updated_at") ? "updated_at" : "id"
                    dbg("ordering by \(orderField)")
                    var whereClause = "\(patientFK) = ?"
                    var needsDate = false
                    if let cut = cutoffISO, cols.contains("updated_at") {
                        whereClause += " AND date(updated_at) <= date(?)"
                        needsDate = true
                    }
                    let sql = "SELECT \(col) FROM \(table) WHERE \(whereClause) ORDER BY \(orderField) DESC LIMIT 1;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, patientID)
                        if needsDate, let cut = cutoffISO { bindText(st, 2, cut) }
                        if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL, let c = sqlite3_column_text(st, 0) {
                            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                    }
                    return nil
                }

                // Integer-value helper
                func ival(_ keys: [String]) -> Int? {
                    guard let col = keys.first(where: { cols.contains($0) }) else { return nil }
                    let orderField = cols.contains("updated_at") ? "updated_at" : "id"
                    var whereClause = "\(patientFK) = ?"
                    var needsDate = false
                    if let cut = cutoffISO, cols.contains("updated_at") {
                        whereClause += " AND date(updated_at) <= date(?)"
                        needsDate = true
                    }
                    var stmt: OpaquePointer?
                    let sql = "SELECT \(col) FROM \(table) WHERE \(whereClause) ORDER BY \(orderField) DESC LIMIT 1;"
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, patientID)
                        if needsDate, let cut = cutoffISO { bindText(st, 2, cut) }
                        if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL {
                            return Int(sqlite3_column_int(st, 0))
                        }
                    }
                    return nil
                }

                // 6) Build parts using whatever columns exist
                var parts: [String] = []

                if let v = val(["pregnancy_risk"]) { parts.append(LF("report.perinatal.pregnancy_risk", v)) }
                if let v = val(["birth_mode"]) { parts.append(LF("report.perinatal.birth_mode", v)) }
                if let w = ival(["birth_term_weeks"]) { parts.append(LF("report.perinatal.gestation_age_weeks", w)) }
                if let v = val(["resuscitation"]) { parts.append(LF("report.perinatal.resuscitation", v)) }
                if let n = ival(["nicu_stay"]), n != 0 { parts.append(LF("report.perinatal.nicu", L("common.yes"))) }
                if let v = val(["infection_risk"]) { parts.append(LF("report.perinatal.infection_risk", v)) }

                if let v = val(["birth_weight_g"]) { parts.append(LF("report.perinatal.birth_weight_g", v)) }
                if let v = val(["birth_length_cm"]) { parts.append(LF("report.perinatal.birth_length_cm", v)) }
                if let v = val(["birth_head_circumference_cm"]) { parts.append(LF("report.perinatal.birth_head_circumference_cm", v)) }

                if let v = val(["maternity_stay_events"]) { parts.append(LF("report.perinatal.maternity_stay_events", v)) }
                if let v = val(["maternity_vaccinations"]) { parts.append(LF("report.perinatal.maternity_vaccinations", v)) }
                if let k = ival(["vitamin_k"]) { parts.append(LF("report.perinatal.vitamin_k", (k != 0 ? L("common.yes") : L("common.no")))) }
                if let v = val(["feeding_in_maternity"]) { parts.append(LF("report.perinatal.feeding_in_maternity", v)) }
                if let m = ival(["passed_meconium_24h"]) { parts.append(LF("report.perinatal.meconium_24h", (m != 0 ? L("common.yes") : L("common.no")))) }
                if let u = ival(["urination_24h"]) { parts.append(LF("report.perinatal.urination_24h", (u != 0 ? L("common.yes") : L("common.no")))) }

                if let v = val(["heart_screening"]) { parts.append(LF("report.perinatal.heart_screening", v)) }
                if let v = val(["metabolic_screening"]) { parts.append(LF("report.perinatal.metabolic_screening", v)) }
                if let v = val(["hearing_screening"]) { parts.append(LF("report.perinatal.hearing_screening", v)) }

                if let v = val(["mother_vaccinations"]) { parts.append(LF("report.perinatal.mother_vaccinations", v)) }
                if let v = val(["family_vaccinations"]) { parts.append(LF("report.perinatal.family_vaccinations", v)) }

                if let v = val(["maternity_discharge_date"]) { parts.append(LF("report.perinatal.maternity_discharge_date", v)) }
                if let v = val(["discharge_weight_g"]) { parts.append(LF("report.perinatal.discharge_weight_g", v)) }

                if let v = val(["illnesses_after_birth"]) { parts.append(LF("report.perinatal.illnesses_after_birth", v)) }
                if let v = val(["evolution_since_maternity"]) { parts.append(LF("report.perinatal.evolution_since_maternity", v)) }

                let summary = parts.joined(separator: "; ")
                dbg("summary: \(summary)")
                return summary.isEmpty ? nil : summary
            }
        } catch {
            print("[ReportDataLoader] buildPerinatalSummary error: \(error)")
        }
        return nil
    }

    // Aggregate concise findings from prior well visits for the same patient, up to a cutoff date
    private func buildPreviousWellVisitFindings(currentVisitID: Int, dobISO: String, cutoffISO: String) -> [(title: String, date: String, findings: String?)] {
        var results: [(title: String, date: String, findings: String?)] = []
        guard let patientID = patientIDForWellVisit(currentVisitID) else {
            print("[ReportDataLoader] previousWell: no patient for visit \(currentVisitID)")
            return results
        }
        // Ensure we have a DOB that can be parsed; if not, fetch from patients table
        var effectiveDobISO = dobISO
        if parseDateFlexible(effectiveDobISO) == nil || effectiveDobISO == "—" {
            if let fetchedDOB = fetchDOBFromPatients(patientID: Int64(patientID)) {
                effectiveDobISO = fetchedDOB
            }
        }
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Ensure table exists and discover columns
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(well_visits);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let cName = sqlite3_column_text(s, 1) {
                            cols.insert(String(cString: cName))
                        }
                    }
                }
                if cols.isEmpty {
                    print("[ReportDataLoader] previousWell: no well_visits table")
                    return results
                }

                // Columns we will try to read
                let dateCol = cols.contains("visit_date") ? "visit_date" : (cols.contains("created_at") ? "created_at" : nil)
                let typeCol = cols.contains("visit_type") ? "visit_type" : nil

                let sql = """
                SELECT
                    id,
                    \(dateCol ?? "''") as visit_date,
                    \(typeCol ?? "''") as visit_type,
                    COALESCE(problem_listing,'') as problem_listing,
                    COALESCE(conclusions,'') as conclusions,
                    COALESCE(parents_concerns,'') as parents_concerns,
                    COALESCE(issues_since_last,'') as issues_since_last,
                    COALESCE(comments,'') as comments
                FROM well_visits
                WHERE patient_id = ? AND id <> ?
                \(dateCol != nil ? "AND date(\(dateCol!)) <= date(?)" : "")
                ORDER BY date(\(dateCol ?? "''")) DESC, id DESC
                LIMIT 5;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, patientID)
                    sqlite3_bind_int64(st, 2, Int64(currentVisitID))
                    if dateCol != nil {
                        _ = cutoffISO.withCString { cstr in
                            sqlite3_bind_text(st, 3, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        }
                    }

                    while sqlite3_step(st) == SQLITE_ROW {
                        func col(_ i: Int32) -> String {
                            guard let c = sqlite3_column_text(st, i) else { return "" }
                            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        var idx: Int32 = 0
                        let _ = sqlite3_column_int64(st, idx); idx += 1 // id (unused in title)
                        let visitDateISO = col(idx); idx += 1
                        let visitTypeRaw = col(idx); idx += 1
                        let problems = col(idx); idx += 1
                        let conclusions = col(idx); idx += 1
                        let parents = col(idx); idx += 1
                        let issues = col(idx); idx += 1
                        let comments = col(idx); idx += 1

                        // Title: Date · Visit Type · Age
                        let visitLabel = visitTypeRaw.isEmpty ? L("report.well_visit.default_title") : (readableVisitType(visitTypeRaw) ?? visitTypeRaw)
                        let age = visitDateISO.isEmpty ? "" : ageString(dobISO: effectiveDobISO, onDateISO: visitDateISO)
                        let dateShort = visitDateISO.isEmpty ? "—" : visitDateISO
                        let title = [dateShort, visitLabel, age.isEmpty ? nil : LF("report.previous.age", age)]
                            .compactMap { $0 }
                            .joined(separator: " · ")

                        // Lines (short, prioritized)
                        var lines: [String] = []

                        if !issues.isEmpty {
                            lines.append(LF("report.previous.issues_since_last", issues))
                        }

                        // Localize the previous visit's stored problem_listing lines (legacy EN or legacy keys)
                        let ageMonthsPrev = (!effectiveDobISO.isEmpty && !visitDateISO.isEmpty) ? computeAgeMonths(dobISO: effectiveDobISO, visitISO: visitDateISO) : nil
                        let localizedProblemsLines = localizePreviousWellProblemListingLines(visitID: Int(sqlite3_column_int64(st, 0)), rawProblemListing: problems, ageMonths: ageMonthsPrev)

                        if !localizedProblemsLines.isEmpty {
                            // Add each problem as its own bullet line later in ReportBuilder
                            lines.append(contentsOf: localizedProblemsLines)
                        } else if !problems.isEmpty {
                            // Fallback: keep the raw block
                            lines.append(LF("report.previous.problems", problems))
                        }

                        if !conclusions.isEmpty {
                            lines.append(LF("report.previous.conclusions", conclusions))
                        }
                        if !parents.isEmpty {
                            lines.append(LF("report.previous.parents_concerns", parents))
                        }
                        if !comments.isEmpty {
                            lines.append(LF("report.previous.comments", comments))
                        }

                        // Keep it concise
                        if lines.count > 6 { lines = Array(lines.prefix(6)) }

                        let dateOut = visitDateISO.isEmpty ? "—" : visitDateISO
                        let findingsStr: String? = lines.isEmpty ? nil : lines.joined(separator: " • ")
                        if !title.isEmpty {
                            results.append((title: title, date: dateOut, findings: findingsStr))
                        }
                    }
                }
            }
        } catch {
            print("[ReportDataLoader] previousWell error: \(error)")
        }
        print("[ReportDataLoader] previousWell: \(results.count) items for visit \(currentVisitID)")
        return results
    }

    // Localize a previous visit's stored problem_listing (either legacy keys or legacy EN labels)
    // into a list of clean lines (without leading bullets).
    private func localizePreviousWellProblemListingLines(visitID: Int, rawProblemListing: String, ageMonths: Double?) -> [String] {
        let normalized = rawProblemListing
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedAll = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAll.isEmpty else { return [] }

        // 1) If the block contains legacy localization keys, reuse the existing repair.
        if trimmedAll.contains("well_visit_form.problem_listing.") {
            let repaired = repairWellProblemListing(visitID: visitID, rawProblemListing: trimmedAll, ageMonths: ageMonths) ?? trimmedAll
            return repaired
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line in
                    if line.hasPrefix("• ") { return String(line.dropFirst(2)) }
                    return line
                }
        }

        // 2) Otherwise, attempt to localize common legacy EN labels.
        func stripBullet(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("• ") { return String(t.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
            return t
        }

        func afterColon(_ s: String) -> String {
            guard let idx = s.firstIndex(of: ":") else { return "" }
            return String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var out: [String] = []
        let lines = normalized.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = stripBullet(rawLine)
            guard !line.isEmpty else { continue }

            // Parents' concerns
            if line.lowercased().hasPrefix("parents'") || line.lowercased().hasPrefix("parents concerns") {
                let v = afterColon(line)
                if !v.isEmpty {
                    out.append(LF("well_visit_form.problem_listing.parents_concerns", v))
                }
                continue
            }

            // Food variety
            if line.lowercased().hasPrefix("food variety") {
                let vRaw = afterColon(line)
                if !vRaw.isEmpty {
                    let v = reportLocalizedWellChoiceToken(vRaw)
                    out.append(LF("well_visit_form.problem_listing.feeding.food_variety", v))
                }
                continue
            }

            // Sleep regularity
            if line.lowercased().hasPrefix("sleep regularity") {
                let vRaw = afterColon(line)
                if !vRaw.isEmpty {
                    let v = reportLocalizedWellChoiceToken(vRaw)
                    out.append(LF("well_visit_form.problem_listing.sleep.regularity", v))
                }
                continue
            }

            // Snoring
            if line.lowercased().contains("snoring") {
                // Prefer the canonical localized sentence
                out.append(L("well_visit_form.problem_listing.sleep.snoring"))
                continue
            }

            // Sleep issue
            if line.lowercased().hasPrefix("sleep issue") {
                let v = afterColon(line)
                if !v.isEmpty {
                    out.append(LF("well_visit_form.problem_listing.sleep.issue", v))
                }
                continue
            }

            // Anything else: keep as-is (free text, milestone lines, teeth lines, etc.)
            out.append(line)
        }

        return out
    }

    // Fetch patient's DOB (ISO-like string) from patients table, trying common column names.
    private func fetchDOBFromPatients(patientID: Int64) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover columns in patients
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(patients);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                    }
                }

                // Prefer an existing DOB-like column
                let dobCol = ["dob","date_of_birth","dob_iso","dobISO","birth_date"].first(where: { cols.contains($0) }) ?? "dob"

                let sql = "SELECT \(dobCol) FROM patients WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, patientID)
                    if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                        var s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)

                        // Normalize variants → "yyyy-MM-dd"
                        if s.contains("/") || s.contains(".") {
                            s = s.replacingOccurrences(of: "/", with: "-")
                                 .replacingOccurrences(of: ".", with: "-")
                        }
                        // Strip any time component
                        if let t = s.firstIndex(of: "T") { s = String(s[..<t]) }
                        if let sp = s.firstIndex(of: " ") { s = String(s[..<sp]) }

                        return s.isEmpty ? nil : s
                    }
                }
            }
        } catch { }
        return nil
    }

    // Load Developmental section for a WELL visit:
    // - From well_visits: mchat/dev test + (optionally) parent_concerns
    // - From well_visit_milestones: achieved/total + flags (non-achieved with optional notes)
    private func loadDevelopmentForWellVisit(visitID: Int) -> (dev: [String:String], achieved: Int, total: Int, flags: [String]) {
        var dev: [String:String] = [:]
        var achieved = 0
        var total = 0
        var flags: [String] = []

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }

        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // -------- well_visits row (M-CHAT / Dev Test / Parent Concerns) --------
                // Discover which table is used for well visits
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"

                // Pull entire row
                var stmtWell: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT * FROM \(wellTable) WHERE id = ? LIMIT 1;", -1, &stmtWell, nil) == SQLITE_OK, let st = stmtWell {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }


                        // M-CHAT, strictly CSV-driven (via allowedDBColumnsForWellVisit)
                        let allowedCols = allowedDBColumnsForWellVisit(visitID)
                        let hasGate = !allowedCols.isEmpty
                        let mchatAllowed = !hasGate || allowedCols.contains("mchat_score") || allowedCols.contains("mchat_result")
                        if mchatAllowed {
                            let mScore = nonEmpty(row["mchat_score"])
                            let mRes   = nonEmpty(row["mchat_result"])
                            if let s = mScore, let r = mRes {
                                dev[L("report.dev.mchat")] = "\(s) (\(r))"
                            } else if let s = mScore {
                                dev[L("report.dev.mchat")] = s
                            } else if let r = mRes {
                                dev[L("report.dev.mchat")] = r
                            }
                        }
                        // Developmental test
                        let dScore = nonEmpty(row["devtest_score"])
                        let dRes   = nonEmpty(row["devtest_result"])
                        if let s = dScore, let r = dRes {
                            dev[L("report.dev.devtest")] = "\(s) (\(r))"
                        } else if let s = dScore {
                            dev[L("report.dev.devtest")] = s
                        } else if let r = dRes {
                            dev[L("report.dev.devtest")] = r
                        }

                        // Optional: a separate parent concerns string specifically under Development
                        if let pc = nonEmpty(row["parent_concerns"]) ?? nonEmpty(row["parents_concerns"]) {
                            dev[L("report.dev.parent_concerns")] = pc
                        }
                    }
                }

                // -------- well_visit_milestones (by visit id) --------
                // Ensure table exists
                var milestoneCols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(well_visit_milestones);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) { milestoneCols.insert(String(cString: c)) }
                    }
                }

                if !milestoneCols.isEmpty {
                    // Identify FK column for visit linkage
                    let fk = ["well_visit_id","visit_id","visitId","visitID"].first(where: { milestoneCols.contains($0) }) ?? "visit_id"

                    // Identify text columns (be robust)
                    let codeCol   = milestoneCols.contains("code") ? "code" : (milestoneCols.contains("milestone_code") ? "milestone_code" : nil)
                    let labelCol  = milestoneCols.contains("label") ? "label" : (milestoneCols.contains("milestone_label") ? "milestone_label" : nil)
                    let statusCol = milestoneCols.contains("status") ? "status" : (milestoneCols.contains("result") ? "result" : nil)
                    let noteCol   = milestoneCols.contains("note") ? "note" : (milestoneCols.contains("notes") ? "notes" : nil)

                    var colsList: [String] = []
                    colsList.append(codeCol ?? "'' as code")
                    colsList.append(labelCol ?? "'' as label")
                    colsList.append(statusCol ?? "'' as status")
                    colsList.append(noteCol ?? "'' as note")

                    let sql = """
                    SELECT \(colsList.joined(separator: ",")) FROM well_visit_milestones
                    WHERE \(fk) = ?
                    ORDER BY id ASC;
                    """
                    var st: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let stmt = st {
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_int64(stmt, 1, Int64(visitID))
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            func col(_ i: Int32) -> String {
                                guard let c = sqlite3_column_text(stmt, i) else { return "" }
                                return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            let code   = col(0)
                            let label  = col(1)
                            let status = col(2)
                            let note   = col(3)
                            total += 1

                            let statusL = status.lowercased()
                            let isAchieved = ["achieved","done","passed","ok","normal","complete","completed"].contains(statusL)
                            if isAchieved {
                                achieved += 1
                            } else {
                                let title = !label.isEmpty ? label : (!code.isEmpty ? code : L("report.milestone.default_title"))
                                var line = title
                                if !status.isEmpty { line += " (\(status))" }
                                if !note.isEmpty { line += " — \(note)" }
                                flags.append(line)
                            }
                        }
                    }
                }
            }
        } catch {
            // swallow; leave defaults
        }

        return (dev, achieved, total, flags)
    }

    func loadSick(episodeID: Int) throws -> SickReportData {
        let meta = try buildMetaForSick(episodeID: episodeID)

        // Core fields
        var mainComplaint: String?
        var hpi: String?
        var duration: String?
        var basics: [String: String] = [:] // Feeding / Urination / Breathing / Pain / Context

        // Additional sections
        var pmhText: String?
        var vaccinationText: String?
        var vitalsFlags: [String] = []   // (to be wired later)
        var peGroups: [(group: String, lines: [String])] = []
        var problemListing: String?
        var investigations: [String] = []
        var workingDx: String?
        var icd10Tuple: (code: String, label: String)?
        var meds: [String] = []
        var planGuidance: String?
        var clinicianComments: String?
        var nextVisitDate: String?
        var perinatalSummary: String?

        // Localize DB-stored choice tokens (often stored in EN) into the current UI language.
        // Safe for multi-select strings like "Wheeze, Crackles (L)".
        
        
        // MARK: - Choice localization for report rendering
        // DB stores choice tokens in base language (often EN). Reports must localize at render time.
        func reportLocalizedChoiceToken(_ rawToken: String) -> String {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return rawToken }

            func slugify(_ s: String) -> String {
                var t = s.lowercased()
                t = t.replacingOccurrences(of: "(", with: "")
                t = t.replacingOccurrences(of: ")", with: "")
                t = t.replacingOccurrences(of: "-", with: " ")
                t = t.replacingOccurrences(of: "/", with: " ")

                let allowed = CharacterSet.alphanumerics
                var out = ""
                var lastWasUnderscore = false

                for scalar in t.unicodeScalars {
                    if allowed.contains(scalar) {
                        out.unicodeScalars.append(scalar)
                        lastWasUnderscore = false
                    } else {
                        if !lastWasUnderscore {
                            out.append("_")
                            lastWasUnderscore = true
                        }
                    }
                }

                while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
                out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                return out
            }

            func localizedIfExists(_ key: String) -> String? {
                let v = NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
                return (v == key) ? nil : v
            }

            let slug = slugify(token)

            let candidates: [String] = [
                "sick_episode_form.choice.\(slug)",
                "sick_episode_form.choice_\(slug)",
                "sick_episode_form.choice.main_complaint.\(slug)",
                "sick_episode_form.choice.main_complaint_\(slug)",

                // legacy fallbacks (keep while migrating)
                "sick_episode.choice.\(slug)",
                "sick_episode.choice_\(slug)"
            ]

            for k in candidates {
                if let v = localizedIfExists(k) { return v }
            }

            return token
        }

        func reportLocalizedChoiceTokenList(_ rawList: String?) -> String? {
            guard let rawList = rawList else { return nil }
            let trimmed = rawList.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let tokens = trimmed
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if tokens.count <= 1 {
                return reportLocalizedChoiceToken(trimmed)
            }

            return tokens.map { reportLocalizedChoiceToken($0) }.joined(separator: ", ")
        }

        func reportLocalizedProblemListing(_ raw: String?) -> String? {
            guard let raw = raw else { return nil }
            let normalized = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let trimmedAll = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAll.isEmpty else { return nil }

            func splitLeadingWhitespace(_ s: String) -> (lead: String, rest: String) {
                var idx = s.startIndex
                while idx < s.endIndex {
                    let ch = s[idx]
                    if ch == " " || ch == "\t" {
                        idx = s.index(after: idx)
                    } else {
                        break
                    }
                }
                return (String(s[..<idx]), String(s[idx...]))
            }

            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var out: [String] = []
            out.reserveCapacity(lines.count)

            for line in lines {
                let (lead, rest0) = splitLeadingWhitespace(line)
                let rest = rest0.trimmingCharacters(in: .whitespaces)
                guard !rest.isEmpty else {
                    out.append(line) // preserve blank/spacing lines
                    continue
                }

                // Preserve common bullet prefixes (e.g., "• ")
                var bulletPrefix = ""
                var body = rest
                if body.hasPrefix("• ") {
                    bulletPrefix = "• "
                    body = String(body.dropFirst(2))
                } else if body.hasPrefix("- ") {
                    bulletPrefix = "- "
                    body = String(body.dropFirst(2))
                } else if body.hasPrefix("– ") {
                    bulletPrefix = "– "
                    body = String(body.dropFirst(2))
                } else if body.hasPrefix("— ") {
                    bulletPrefix = "— "
                    body = String(body.dropFirst(2))
                }

                // If the line has a colon, localize only the RHS (often a comma-separated choice list)
                if let cIdx = body.firstIndex(of: ":") {
                    let lhs = String(body[...cIdx])
                    let rhs = String(body[body.index(after: cIdx)...]).trimmingCharacters(in: .whitespaces)
                    let localizedRhs = reportLocalizedChoiceTokenList(rhs) ?? rhs
                    out.append(lead + bulletPrefix + lhs + " " + localizedRhs)
                } else {
                    // Otherwise, if it's a raw comma-separated choice list line, localize the whole thing.
                    let localized = reportLocalizedChoiceTokenList(body) ?? body
                    out.append(lead + bulletPrefix + localized)
                }
            }

            return out.joined(separator: "\n")
        }
        
        /// Localize a previously-saved Problem Listing block (labels + known choice tokens).
        func localizeProblemListingBlock(_ raw: String?) -> String? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }

            let labelKeyMap: [String: String] = [
                "Age": "report.problem.age",
                "Sex": "report.problem.sex",
                "Main complaint": "report.problem.main_complaint",
                "Duration": "report.problem.duration",
                "HPI summary": "report.problem.hpi_summary",
                "Appearance": "report.problem.appearance",
                "Breathing": "report.problem.breathing",
                "Context": "report.problem.context",

                // PE echoes commonly present in Problem Listing
                "General Appearance": "report.problem.pe.general_appearance",
                "Color": "report.problem.pe.color",
                "Skin": "report.problem.pe.skin",
                "Lungs": "report.problem.pe.lungs",
                "Heart": "report.problem.pe.heart"
            ]

            // Only these labels try to localize comma-separated RHS tokens.
            let rhsTokenLabels: Set<String> = [
                "Main complaint", "Appearance", "Breathing", "Context",
                "General Appearance", "Color", "Skin", "Lungs", "Heart"
            ]

            func localizeRHS(label: String, rhs: String) -> String {
                var out = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

                // Fix legacy artifact like: "24h hours"
                if label == "Duration" {
                    out = out.replacingOccurrences(of: " hours", with: "")
                    out = out.replacingOccurrences(of: " hour", with: "")
                }

                if rhsTokenLabels.contains(label) {
                    out = reportLocalizedChoiceTokenList(out) ?? out // your existing token localizer
                }

                return out
            }

            let normalized = raw.replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.components(separatedBy: .newlines)

            let localizedLines = lines.map { line -> String in
                let prefixWhitespace = line.prefix { $0 == " " || $0 == "\t" }
                let core = line.dropFirst(prefixWhitespace.count)

                guard let colon = core.firstIndex(of: ":") else { return line }

                let labelRaw = core[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                let rhsRaw = core[core.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)

                let localizedLabel: String = {
                    if let k = labelKeyMap[String(labelRaw)] {
                        return L(k)
                    }
                    return String(labelRaw)
                }()

                let localizedRhs = localizeRHS(label: String(labelRaw), rhs: String(rhsRaw))
                return "\(prefixWhitespace)\(localizedLabel): \(localizedRhs)"
            }

            return localizedLines.joined(separator: "\n")
        }

        // Vaccination status localization (DB typically stores base-language tokens)
        func reportLocalizedVaccinationStatus(_ raw: String) -> String {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return raw }

            switch t {
            case "Up to date":
                return NSLocalizedString("vax.status.up_to_date", comment: "Vaccination status: up to date")
            case "Delayed":
                return NSLocalizedString("vax.status.delayed", comment: "Vaccination status: delayed")
            case "Not vaccinated":
                return NSLocalizedString("vax.status.not_vaccinated", comment: "Vaccination status: not vaccinated")
            case "Unknown":
                return NSLocalizedString("vax.status.unknown", comment: "Vaccination status: unknown")
            default:
                // If the DB already contains a localized string (or an unexpected code), keep it.
                return t
            }
        }

        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // --- EPISODE ROW ---
                let sqlEp = """
                SELECT
                    patient_id,
                    main_complaint, hpi, duration, feeding, urination, breathing, pain, context,
                    problem_listing, complementary_investigations, diagnosis, icd10, medications,
                    anticipatory_guidance, comments,
                    general_appearance, hydration, color, skin,
                    ent, right_ear, left_ear, right_eye, left_eye,
                    heart, lungs,
                    abdomen, peristalsis,
                    genitalia,
                    neurological, musculoskeletal, lymph_nodes
                FROM episodes
                WHERE id = ?
                LIMIT 1;
                """
                var stmtEp: OpaquePointer?
                var patientID: Int64 = -1
                if sqlite3_prepare_v2(db, sqlEp, -1, &stmtEp, nil) == SQLITE_OK, let stmt = stmtEp {
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(episodeID))
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        func col(_ i: Int32) -> String? {
                            guard let cstr = sqlite3_column_text(stmt, i) else { return nil }
                            let s = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                        var i: Int32 = 0
                        patientID      = sqlite3_column_int64(stmt, i); i += 1
                        mainComplaint  = col(i); i += 1
                        // Localize multi-select complaint tokens for the report
                        mainComplaint = reportLocalizedChoiceTokenList(mainComplaint)
                        hpi            = col(i); i += 1
                        duration       = col(i); i += 1
                        // DEBUG: now-localized mainComplaint
                        print("[ReportDataLoader] loadSick(\(episodeID)) mainComplaint=\(mainComplaint ?? "nil")")
                        print("[ReportDataLoader] loadSick(\(episodeID)) raw duration=\(duration ?? "nil")")
                        if let v = col(i) { basics[L("report.sick.basics.feeding")] = v }; i += 1
                        if let v = col(i) { basics[L("report.sick.basics.urination")] = v }; i += 1
                        if let v = col(i) { basics[L("report.sick.basics.breathing")] = v }; i += 1
                        if let v = col(i) { basics[L("report.sick.basics.pain")] = v }; i += 1
                        if let v = col(i) { basics[L("report.sick.basics.context")] = v }; i += 1

                        problemListing = col(i); i += 1
                        problemListing = localizeProblemListingBlock(problemListing)
                        let investigationsRaw = col(i); i += 1
                        workingDx      = col(i); i += 1
                        let icdRaw     = col(i); i += 1
                        let medsRaw    = col(i); i += 1
                        planGuidance   = col(i); i += 1
                        clinicianComments = col(i); i += 1

                        // PE fields (localized labels)
                        let peGeneralAppearance = L("report.sick.pe.general_appearance")
                        let peHydration         = L("report.sick.pe.hydration")
                        let peColor             = L("report.sick.pe.color")
                        let peSkin              = L("report.sick.pe.skin")
                        let peENT               = L("report.sick.pe.ent")
                        let peRightEar          = L("report.sick.pe.right_ear")
                        let peLeftEar           = L("report.sick.pe.left_ear")
                        let peRightEye          = L("report.sick.pe.right_eye")
                        let peLeftEye           = L("report.sick.pe.left_eye")
                        let peHeart             = L("report.sick.pe.heart")
                        let peLungs             = L("report.sick.pe.lungs")
                        let peAbdomen           = L("report.sick.pe.abdomen")
                        let pePeristalsis       = L("report.sick.pe.peristalsis")
                        let peGenitalia         = L("report.sick.pe.genitalia")
                        let peNeurological      = L("report.sick.pe.neurological")
                        let peMusculoskeletal   = L("report.sick.pe.musculoskeletal")
                        let peLymphNodes        = L("report.sick.pe.lymph_nodes")

                        let peNames = [
                            peGeneralAppearance, peHydration, peColor, peSkin,
                            peENT, peRightEar, peLeftEar, peRightEye, peLeftEye,
                            peHeart, peLungs,
                            peAbdomen, pePeristalsis,
                            peGenitalia,
                            peNeurological, peMusculoskeletal, peLymphNodes
                        ]
                        var valuesByName: [String:String] = [:]
                        for name in peNames {
                            if let v = col(i), !v.isEmpty {
                                valuesByName[name] = reportLocalizedChoiceTokenList(v) ?? v
                            }
                            i += 1
                        }
                        // DEBUG: selected PE values (now localized)
                        print("[ReportDataLoader] loadSick(\(episodeID)) PE lungs=\(valuesByName[peLungs] ?? "nil")")
                        print("[ReportDataLoader] loadSick(\(episodeID)) PE skin=\(valuesByName[peSkin] ?? "nil")")
                        print("[ReportDataLoader] loadSick(\(episodeID)) PE heart=\(valuesByName[peHeart] ?? "nil")")
                        let groupMap: [(String,[String])] = [
                            (L("report.sick.pe.group.general"), [peGeneralAppearance, peHydration, peColor, peSkin]),
                            (L("report.sick.pe.group.ent"), [peENT, peRightEar, peLeftEar, peRightEye, peLeftEye]),
                            (L("report.sick.pe.group.cardiorespiratory"), [peHeart, peLungs]),
                            (L("report.sick.pe.group.abdomen"), [peAbdomen, pePeristalsis]),
                            (L("report.sick.pe.group.genitalia"), [peGenitalia]),
                            (L("report.sick.pe.group.neuro_msk_lymph"), [peNeurological, peMusculoskeletal, peLymphNodes])
                        ]
                        for (group, names) in groupMap {
                            let lines = names.compactMap { n -> String? in
                                guard let v = valuesByName[n] else { return nil }
                                return "\(n): \(v)"
                            }
                            if !lines.isEmpty { peGroups.append((group: group, lines: lines)) }
                        }

                        // split multi-line lists
                        if let raw = investigationsRaw {
                            investigations = raw
                                .replacingOccurrences(of: "\r", with: "\n")
                                .components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                        if let raw = medsRaw {
                            meds = raw
                                .replacingOccurrences(of: "\r", with: "\n")
                                .components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                        if let raw = icdRaw, !raw.isEmpty {
                            let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                            if parts.count == 2 {
                                icd10Tuple = (code: parts[0], label: parts[1])
                            } else {
                                icd10Tuple = (code: parts.first ?? "", label: raw)
                            }
                        }
                    }
                }

                // --- VITALS summary for this sick episode ---
                vitalsFlags = loadVitalsSummaryForEpisode(episodeID)

                // --- PATIENT: vaccination_status ---
                if patientID > 0 {
                    let sqlPt = "SELECT vaccination_status FROM patients WHERE id = ? LIMIT 1;"
                    var stmtPt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sqlPt, -1, &stmtPt, nil) == SQLITE_OK, let stmt = stmtPt {
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_int64(stmt, 1, patientID)
                        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
                            let s = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { vaccinationText = reportLocalizedVaccinationStatus(s) }
                        }
                    }
                }

                // --- PMH from past_medical_history ---
                if patientID > 0 {
                    let sqlPMH = """
                    SELECT asthma, otitis, uti, allergies, other
                    FROM past_medical_history
                    WHERE patient_id = ?
                    LIMIT 1;
                    """
                    var stmtPMH: OpaquePointer?
                    if sqlite3_prepare_v2(db, sqlPMH, -1, &stmtPMH, nil) == SQLITE_OK, let stmt = stmtPMH {
                        defer { sqlite3_finalize(stmt) }
                        sqlite3_bind_int64(stmt, 1, patientID)
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            var items: [String] = []
                            func f(_ idx: Int32, _ label: String) {
                                let isNull = sqlite3_column_type(stmt, idx) == SQLITE_NULL
                                let val = isNull ? 0 : sqlite3_column_int(stmt, idx)
                                if val == 1 { items.append(label) }
                            }
                            let pmhAsthma    = L("report.sick.pmh.asthma")
                            let pmhOtitis    = L("report.sick.pmh.otitis")
                            let pmhUTI       = L("report.sick.pmh.uti")
                            let pmhAllergies = L("report.sick.pmh.allergies")

                            f(0, pmhAsthma)
                            f(1, pmhOtitis)
                            f(2, pmhUTI)
                            f(3, pmhAllergies)
                            if let cstr = sqlite3_column_text(stmt, 4) {
                                let s = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !s.isEmpty { items.append(s) }
                            }
                            if !items.isEmpty { pmhText = items.joined(separator: "; ") }
                        }
                    }
                }
                
                // --- Perinatal summary for sick episode, gated to ≤ 3 months ---
                if let dob = parseDateFlexible(meta.dobISO),
                   let visit = parseDateFlexible(meta.visitDateISO),
                   visit >= dob {

                    let seconds = visit.timeIntervalSince(dob)
                    let days = seconds / 86400.0
                    let months = max(0.0, days / 30.4375)    // same convention as growth logic

                    if months <= 3.0, let pid = patientIDForSickEpisode(episodeID) {
                        // Per spec: perinatal history is historical, no date cutoff here.
                        perinatalSummary = buildPerinatalSummary(patientID: pid, cutoffISO: nil)
                    }
                }
            }
        } catch {
            // leave optionals nil; renderer will print "—"
        }

        return SickReportData(
            meta: meta,
            mainComplaint: mainComplaint,
            hpi: hpi,
            duration: duration,
            basics: basics,
            pmh: pmhText,
            perinatalSummary: perinatalSummary,
            vaccination: vaccinationText,
            vitalsSummary: vitalsFlags,
            physicalExamGroups: peGroups,
            problemListing: problemListing,
            investigations: investigations,
            workingDiagnosis: workingDx,
            icd10: icd10Tuple,
            planGuidance: planGuidance,
            medications: meds,
            clinicianComments: clinicianComments,
            nextVisitDate: nextVisitDate
        )
    }
    
    // Prefer clinician name stored in Golden.db for the specific episode
    private func fetchClinicianNameForEpisode(_ episodeID: Int) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Columns on episodes
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(episodes);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) {
                            cols.insert(String(cString: c))
                        }
                    }
                }

                // Prefer FK → users join (to get first_name + last_name)
                let fkCandidates = [
                    "clinician_user_id","user_id","clinician_id",
                    "physician_user_id","physician_id",
                    "doctor_user_id","doctor_id",
                    "provider_id",
                    "created_by","author_id","entered_by","owner_id"
                ]
                if let fk = fkCandidates.first(where: { cols.contains($0) }) {
                    let sql = """
                    SELECT u.first_name, u.last_name
                    FROM users u
                    JOIN episodes e ON u.id = e.\(fk)
                    WHERE e.id = ? LIMIT 1;
                    """
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, Int64(episodeID))
                        if sqlite3_step(st) == SQLITE_ROW {
                            func col(_ i: Int32) -> String? {
                                guard let c = sqlite3_column_text(st, i) else { return nil }
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                return s.isEmpty ? nil : s
                            }
                            if let f = col(0), let l = col(1) {
                                let full = "\(f) \(l)".trimmingCharacters(in: .whitespaces)
                                if !full.isEmpty { return full }
                            }
                        }
                    }
                }

                // Last-resort: direct text on episodes row
                for direct in ["clinician_name","clinician","doctor","physician"] where cols.contains(direct) {
                    let sql = "SELECT \(direct) FROM episodes WHERE id = ? LIMIT 1;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, Int64(episodeID))
                        if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                            let name = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty { return name }
                        }
                    }
                }
            }
        } catch { /* ignore */ }
        return nil
    }

    // Fetch patient first+last name for a SICK episode from the bundle DB
    private func fetchPatientNameForEpisode(_ episodeID: Int) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover columns on episodes to find the patient FK
                var epCols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(episodes);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let cName = sqlite3_column_text(s, 1) {
                            epCols.insert(String(cString: cName))
                        }
                    }
                }

                let fkCandidates = ["patient_id","patientId","patientID"]
                guard let fk = fkCandidates.first(where: { epCols.contains($0) }) else { return nil }

                let sql = """
                SELECT p.first_name, p.last_name
                FROM patients p
                JOIN episodes e ON p.id = e.\(fk)
                WHERE e.id = ? LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(episodeID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        func col(_ i: Int32) -> String? {
                            guard let c = sqlite3_column_text(st, i) else { return nil }
                            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                        if let first = col(0), let last = col(1) {
                            let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                            if !full.isEmpty { return full }
                        }
                    }
                }
            }
        } catch {
            // ignore and fall back
        }
        return nil
    }

    // Fetch patient first+last name for a WELL visit from the bundle DB
    private func fetchPatientNameForWellVisit(_ visitID: Int) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let cName = sqlite3_column_text(s, 1) {
                                cols.insert(String(cString: cName))
                            }
                        }
                    }
                    return cols
                }

                // Choose well table
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: table)
                let fkCandidates = ["patient_id","patientId","patientID"]
                guard let fk = fkCandidates.first(where: { cols.contains($0) }) else { return nil }

                let sql = """
                SELECT p.first_name, p.last_name
                FROM patients p
                JOIN \(table) w ON p.id = w.\(fk)
                WHERE w.id = ? LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        func col(_ i: Int32) -> String? {
                            guard let c = sqlite3_column_text(st, i) else { return nil }
                            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                        if let first = col(0), let last = col(1) {
                            let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                            if !full.isEmpty { return full }
                        }
                    }
                }
            }
        } catch {
            // ignore and fall back
        }
        return nil
    }

    // Fetch patient MRN for a SICK episode from the bundle DB (patients.mrn)
    private func fetchMRNForEpisode(_ episodeID: Int) -> String? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover patient FK on episodes
                var epCols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(episodes);", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) { epCols.insert(String(cString: c)) }
                    }
                }
                let fk = ["patient_id","patientId","patientID"].first(where: { epCols.contains($0) }) ?? "patient_id"

                let sql = """
                SELECT p.mrn
                FROM patients p
                JOIN episodes e ON p.id = e.\(fk)
                WHERE e.id = ? LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(episodeID))
                    if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                        let val = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty { return val }
                    }
                }
            }
        } catch { }
        return nil
    }

    // Fetch patient MRN for a WELL visit from the bundle DB (patients.mrn)
    private func fetchMRNForWellVisit(_ visitID: Int) -> String? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: wellTable)
                let fk = ["patient_id","patientId","patientID"].first(where: { cols.contains($0) }) ?? "patient_id"

                let sql = """
                SELECT p.mrn
                FROM patients p
                JOIN \(wellTable) w ON p.id = w.\(fk)
                WHERE w.id = ? LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                        let val = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty { return val }
                    }
                }
            }
        } catch { }
        return nil
    }

    // Prefer clinician name stored in Golden.db for the specific WELL visit
    private func fetchClinicianNameForWellVisit(_ visitID: Int) -> String? {
        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) {
                                cols.insert(String(cString: c))
                            }
                        }
                    }
                    return cols
                }

                // Pick table used for well visits
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: table)

                // Prefer FK → users join (to get first_name + last_name)
                let fkCandidates = [
                    "clinician_user_id","user_id","clinician_id",
                    "physician_user_id","physician_id",
                    "doctor_user_id","doctor_id",
                    "provider_id",
                    "created_by","author_id","entered_by","owner_id"
                ]
                if let fk = fkCandidates.first(where: { cols.contains($0) }) {
                    let sql = """
                    SELECT u.first_name, u.last_name
                    FROM users u
                    JOIN \(table) w ON u.id = w.\(fk)
                    WHERE w.id = ? LIMIT 1;
                    """
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, Int64(visitID))
                        if sqlite3_step(st) == SQLITE_ROW {
                            func col(_ i: Int32) -> String? {
                                guard let c = sqlite3_column_text(st, i) else { return nil }
                                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                                return s.isEmpty ? nil : s
                            }
                            if let f = col(0), let l = col(1) {
                                let full = "\(f) \(l)".trimmingCharacters(in: .whitespaces)
                                if !full.isEmpty { return full }
                            }
                        }
                    }
                }

                // Last-resort: direct text on the visit row
                for direct in ["clinician_name","clinician","doctor","physician"] where cols.contains(direct) {
                    let sql = "SELECT \(direct) FROM \(table) WHERE id = ? LIMIT 1;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                        defer { sqlite3_finalize(st) }
                        sqlite3_bind_int64(st, 1, Int64(visitID))
                        if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                            let name = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty { return name }
                        }
                    }
                }
            }
        } catch { /* ignore */ }
        return nil
    }
    
    // Debug helper to ensure we're using the patient's bundle DB (ActiveBundle/db.sqlite)
    @MainActor
    private func bundleDBPathWithDebug() throws -> String {
        let path = try currentBundleDBPath()
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let parent = url.deletingLastPathComponent().lastPathComponent

        print("[ReportDataLoader] Using DB: \(path)")
        print("[ReportDataLoader] Exists: \(exists)  Size: \(size) bytes  File: \(url.lastPathComponent)  Parent: \(parent)")
        if url.lastPathComponent.lowercased() != "db.sqlite" {
            print("[ReportDataLoader][WARN] Expected 'db.sqlite' (patient bundle), but got '\(url.lastPathComponent)'.")
        }
        return path
    }

    // MARK: - Meta builders (WELL)

    // Simple localization helper used throughout this file
    @inline(__always)
    private func L(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    // NOTE: keep this NON-@MainActor to match current call sites and avoid actor churn.
    // We also avoid calling the @MainActor debug helper; we use currentBundleDBPath().
    private func buildMetaForWell(visitID: Int) throws -> ReportMeta {
        let (patientName, alias, mrn, dobISO, sex) = basicPatientStrings()
        let properPatientName = fetchPatientNameForWellVisit(visitID) ?? patientName
        let mrnResolved = fetchMRNForWellVisit(visitID) ?? mrn

        // Defaults (kept exactly as before, then overridden by DB fields if present)
        var visitDateISO: String = appState.visits.first(where: { $0.id == visitID })?.dateISO
            ?? ISO8601DateFormatter().string(from: Date())
        var visitTypeReadable: String? = nil
        var createdISO: String? = nil
        var updatedISO: String? = nil

        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover columns for a table
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }

                // Decide which table holds well visits
                let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                let cols = columns(in: wellTable)

                // Build a resilient SELECT that returns strings (or '') for each field
                let vtype = cols.contains("visit_type") ? "visit_type" : "''"
                let vdate = cols.contains("visit_date") ? "visit_date" : "''"
                let cAt   = cols.contains("created_at") ? "created_at" : "''"
                let uAt   = cols.contains("updated_at") ? "updated_at" : "''"

                let sql = """
                SELECT \(vtype) as visit_type,
                       \(vdate) as visit_date,
                       \(cAt)   as created_at,
                       \(uAt)   as updated_at
                FROM \(wellTable)
                WHERE id = ?
                LIMIT 1;
                """

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))

                    if sqlite3_step(st) == SQLITE_ROW {
                        func col(_ i: Int32) -> String? {
                            guard let c = sqlite3_column_text(st, i) else { return nil }
                            let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return s.isEmpty ? nil : s
                        }
                        // Pull values if present
                        if let vt = col(0) { visitTypeReadable = readableVisitType(vt) ?? vt }
                        let dbVisitDate = col(1)       // visit_date
                        let dbCreated    = col(2)      // created_at
                        let dbUpdated    = col(3)      // updated_at

                        createdISO = dbCreated
                        updatedISO = dbUpdated

                        // Prefer visit_date, else created_at, else keep existing default
                        if let vd = dbVisitDate, !vd.isEmpty {
                            visitDateISO = vd
                        } else if let c = dbCreated, !c.isEmpty {
                            visitDateISO = c
                        }
                    }
                }
            }
        } catch {
            // leave defaults; ReportBuilder will still show "Report Generated"
        }

        let clinicianName = fetchClinicianNameForWellVisit(visitID) ?? activeClinicianName()
        let age = ageString(dobISO: dobISO, onDateISO: visitDateISO)
        let nowISO = ISO8601DateFormatter().string(from: Date())

        return ReportMeta(
            alias: alias,
            mrn: mrnResolved,
            name: properPatientName,
            dobISO: dobISO,
            sex: sex,
            visitDateISO: visitDateISO,
            ageAtVisit: age,
            clinicianName: clinicianName,
            visitTypeReadable: visitTypeReadable,
            createdAtISO: createdISO,     // "Created"
            updatedAtISO: updatedISO,     // "Last Edited"
            generatedAtISO: nowISO        // "Report Generated"
        )
    }

    @MainActor
    private func buildMetaForSick(episodeID: Int) throws -> ReportMeta {
        let (patientName, alias, mrn, dobISO, sex) = basicPatientStrings()
        let properPatientName = fetchPatientNameForEpisode(episodeID) ?? patientName
        let mrnResolved = fetchMRNForEpisode(episodeID) ?? mrn

        // Keep existing visit date behavior (from appState or now)
        var visitDateISO: String = appState.visits.first(where: { $0.id == episodeID })?.dateISO
            ?? ISO8601DateFormatter().string(from: Date())

        let clinicianName = fetchClinicianNameForEpisode(episodeID) ?? activeClinicianName()
        let age = ageString(dobISO: dobISO, onDateISO: visitDateISO)
        let nowISO = ISO8601DateFormatter().string(from: Date())

        // NEW: pull created_at (+ updated_at if present) from episodes
        var createdISO: String? = nil
        var updatedISO: String? = nil
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Try both columns first
                let sqlBoth = "SELECT created_at, updated_at FROM episodes WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlBoth, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(episodeID))
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        if let c0 = sqlite3_column_text(stmt, 0) {
                            let s = String(cString: c0).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { createdISO = s }
                        }
                        if let c1 = sqlite3_column_text(stmt, 1) {
                            let s = String(cString: c1).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { updatedISO = s }
                        }
                    }
                } else {
                    // Fallback if updated_at column doesn't exist
                    let sqlCreatedOnly = "SELECT created_at FROM episodes WHERE id = ? LIMIT 1;"
                    var stmt2: OpaquePointer?
                    if sqlite3_prepare_v2(db, sqlCreatedOnly, -1, &stmt2, nil) == SQLITE_OK, let stmt2 = stmt2 {
                        defer { sqlite3_finalize(stmt2) }
                        sqlite3_bind_int64(stmt2, 1, Int64(episodeID))
                        if sqlite3_step(stmt2) == SQLITE_ROW, let c0 = sqlite3_column_text(stmt2, 0) {
                            let s = String(cString: c0).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { createdISO = s }
                        }
                    }
                }
            }
        } catch {
            // leave createdISO/updatedISO nil
        }

        // Prefer episodes.created_at for Sick visit date when available
        if let created = createdISO, !created.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            visitDateISO = created
        }

        return ReportMeta(
            alias: alias,
            mrn: mrnResolved,
            name: properPatientName,
            dobISO: dobISO,
            sex: sex,
            visitDateISO: visitDateISO,
            ageAtVisit: age,
            clinicianName: clinicianName,
            visitTypeReadable: nil,
            createdAtISO: createdISO,   // "Created"
            updatedAtISO: updatedISO,   // "Last Edited" (may be nil)
            generatedAtISO: nowISO      // "Report Generated" = now
        )
    }
    /// Load the most recent AI assistant entry for a given sick episode, if any.
    /// Reads from the `ai_inputs` table in the current patient bundle DB.
    func loadLatestAIInputForEpisode(_ episodeID: Int) -> LatestAIInput? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Ensure the ai_inputs table exists
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(
                    db,
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='ai_inputs' LIMIT 1;",
                    -1,
                    &checkStmt,
                    nil
                ) == SQLITE_OK, let st = checkStmt {
                    defer { sqlite3_finalize(st) }
                    // If no row, the table is missing
                    if sqlite3_step(st) != SQLITE_ROW {
                        return nil
                    }
                } else {
                    return nil
                }

                // Fetch the most recent row for this episode
                let sql = """
                SELECT model, response, created_at
                FROM ai_inputs
                WHERE episode_id = ?
                ORDER BY datetime(created_at) DESC, id DESC
                LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(episodeID))

                    if sqlite3_step(st) == SQLITE_ROW {
                        func colString(_ idx: Int32) -> String {
                            guard let c = sqlite3_column_text(st, idx) else { return "" }
                            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        let model     = colString(0)
                        let response  = colString(1)
                        let createdAt = colString(2)

                        // Require at least some response text to consider this valid
                        guard !response.isEmpty else { return nil }

                        let finalModel = model.isEmpty ? L("report.ai.model.unknown") : model
                        return LatestAIInput(
                            model: finalModel,
                            createdAt: createdAt,
                            response: response
                        )
                    }
                }
            }
        } catch {
            print("[ReportDataLoader] loadLatestAIInputForEpisode error: \(error)")
        }
        return nil
    }
    
    /// Load the most recent AI assistant entry for a given WELL visit, if any.
    /// Reads from the `well_ai_inputs` table in the current patient bundle DB.
    func loadLatestAIInputForWell(_ wellVisitID: Int) -> LatestAIInput? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Ensure the well_ai_inputs table exists
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(
                    db,
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='well_ai_inputs' LIMIT 1;",
                    -1,
                    &checkStmt,
                    nil
                ) == SQLITE_OK, let st = checkStmt {
                    defer { sqlite3_finalize(st) }
                    // If no row, the table is missing → no AI entries for well visits
                    if sqlite3_step(st) != SQLITE_ROW {
                        return nil
                    }
                } else {
                    return nil
                }

                // Fetch the most recent row for this well visit
                let sql = """
                SELECT model, response, created_at
                FROM well_ai_inputs
                WHERE well_visit_id = ?
                ORDER BY datetime(created_at) DESC, id DESC
                LIMIT 1;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(wellVisitID))

                    if sqlite3_step(st) == SQLITE_ROW {
                        func colString(_ idx: Int32) -> String {
                            guard let c = sqlite3_column_text(st, idx) else { return "" }
                            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        let model     = colString(0)
                        let response  = colString(1)
                        let createdAt = colString(2)

                        // Require some response text
                        guard !response.isEmpty else { return nil }

                        let finalModel = model.isEmpty ? L("report.ai.model.unknown") : model
                        return LatestAIInput(
                            model: finalModel,
                            createdAt: createdAt,
                            response: response
                        )
                    }
                }
            }
        } catch {
            print("[ReportDataLoader] loadLatestAIInputForWell error: \(error)")
        }
        return nil
    }
    
// MARK: - Helpers

    /// Previous-well rows often store multi-line bullet lists (and sometimes legacy EN labels).
    /// For report rendering we want a single-line, bullet-separated string.
    private func flattenBulletsForReport(_ text: String) -> String {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        let parts: [String] = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { line in
                var s = line
                if s.hasPrefix("•") {
                    s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if s.hasPrefix("-") {
                    s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return s
            }
            .filter { !$0.isEmpty }

        return parts.joined(separator: " • ")
    }

    /// Localize legacy EN problem-listing lines that were stored as human text (not keys).
    /// This is used mainly for *previous* well visits, where the DB may contain EN labels.
    private func localizeLegacyWellProblemListingLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Normalize bullet prefixes
        var s = trimmed
        if s.hasPrefix("•") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("-") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty else { return nil }

        // If it looks like "Label: value" try to map the label to an existing localized format string.
        if let colon = s.firstIndex(of: ":") {
            let labelPart = String(s[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valuePart = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = labelPart.lowercased()

            // 1) Parents' concerns
            if label == "parents' concerns" || label == "parents concerns" || label == "parent concerns" {
                if !valuePart.isEmpty {
                    return String(format: L("well_visit_form.problem_listing.parents_concerns"), valuePart)
                }
                return s
            }

            // 2) Food variety (skip if it's the benign code/value)
            if label == "food variety" {
                let v = valuePart.lowercased()
                if v == "appears good" || v == "appears_good" || v == "appears-good" {
                    return nil
                }
                if !valuePart.isEmpty {
                    return String(format: L("well_visit_form.problem_listing.feeding.food_variety"), valuePart)
                }
                return s
            }

            // 3) Sleep regularity
            if label == "sleep regularity" {
                if !valuePart.isEmpty {
                    return String(format: L("well_visit_form.problem_listing.sleep.regularity"), valuePart)
                }
                return s
            }

            // 4) Sleep issue
            if label == "sleep issue" {
                if !valuePart.isEmpty {
                    return String(format: L("well_visit_form.problem_listing.sleep.issue"), valuePart)
                }
                return s
            }

            // 5) Snoring line is often stored as "Sleep: snoring / noisy breathing reported."
            if label == "sleep" {
                if valuePart.lowercased().contains("snoring") {
                    return L("well_visit_form.problem_listing.sleep.snoring")
                }
                return s
            }
        }

        // Default: keep as-is
        return s
    }

    /// Apply lightweight legacy-label localization line-by-line.
    /// Returns a multi-line string (so downstream repair rules can still operate),
    /// and the final renderer will later flatten it.
    private func localizeLegacyWellProblemListingText(_ text: String) -> String {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        let parts: [String] = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var out: [String] = []
        out.reserveCapacity(parts.count)

        for p in parts {
            if let mapped = localizeLegacyWellProblemListingLine(p) {
                let t = mapped.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
            }
        }

        return out.joined(separator: "\n")
    }

    /// Apply the same localization repair used for the *current* well visit problem listing,
    /// then normalize to a single-line bullet-separated string for the Previous Visits section.
    private func localizeAndFlattenPreviousWellText(visitID: Int, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // For previous visits, the DB can contain legacy EN human labels.
        // First, translate the obvious label+value lines.
        let legacyLocalized = localizeLegacyWellProblemListingText(trimmed)

        // Reuse the same repair/localization logic as the current well visit.
        // For previous visits we also pass visitID (for rules) and ageMonths (for age-gating).
        let ageMonths = wellVisitAgeMonths(visitID: visitID) ?? 0.0
        let repaired = repairWellProblemListing(
            visitID: visitID,
            rawProblemListing: legacyLocalized,
            ageMonths: ageMonths
        ) ?? legacyLocalized

        return flattenBulletsForReport(repaired)
    }

    // Returns a list of previous well visits for the same patient (excluding the current visit),
    // with robust date/age handling and patient DOB from DB if available.
    // Returns a list of previous well visits for the same patient (excluding the current visit),
    // with robust date/age handling and patient DOB from DB if available.
    func previousWellVisits(for currentVisitID: Int) -> [(title: String, date: String, findings: String?)] {
        var results: [(title: String, date: String, findings: String?)] = []
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover columns for a table
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) {
                                cols.insert(String(cString: c))
                            }
                        }
                    }
                    return cols
                }

                // Decide which table holds well visits
                let wellTable = ["well_visits", "visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"

                // --- Resolve patient ID and DOB from patients table if possible ---
                var effectiveDobISO = basicPatientStrings().dobISO
                var currentPatientID: Int64 = -1

                do {
                    let wcols = columns(in: wellTable)
                    let patientFK = ["patient_id","patientId","patientID"].first(where: { wcols.contains($0) }) ?? "patient_id"

                    // Fetch patient id for the current visit
                    var stmtPID: OpaquePointer?
                    if sqlite3_prepare_v2(db, "SELECT \(patientFK) FROM \(wellTable) WHERE id = ? LIMIT 1;", -1, &stmtPID, nil) == SQLITE_OK, let stp = stmtPID {
                        defer { sqlite3_finalize(stp) }
                        sqlite3_bind_int64(stp, 1, Int64(currentVisitID))
                        if sqlite3_step(stp) == SQLITE_ROW {
                            currentPatientID = sqlite3_column_int64(stp, 0)
                        }
                    }

                    // If we resolved a patient id, prefer DOB from patients table
                    if currentPatientID > 0, let dobFromDB = fetchDOBFromPatients(patientID: currentPatientID) {
                        effectiveDobISO = dobFromDB
                    }
                }

                // If we still don't have a valid patient ID, there is nothing to list
                guard currentPatientID > 0 else {
                    print("[ReportDataLoader] previousWell: no patient for visit \(currentVisitID)")
                    return results
                }

                // Determine FK column name for patient linkage (for the main query)
                let wcols = columns(in: wellTable)
                let patientFK = ["patient_id","patientId","patientID"].first(where: { wcols.contains($0) }) ?? "patient_id"

                // Build SQL for previous visits, coalescing visit_date and fallbacks,
                // and extracting normalized date for age calculation
                let sqlPrev = """
                SELECT
                    id,
                    COALESCE(visit_date, created_at, updated_at, date) AS visit_date_raw,
                    CASE
                        WHEN visit_date LIKE '____-__-__%' THEN substr(visit_date,1,10)
                        WHEN created_at LIKE '____-__-__%' THEN substr(created_at,1,10)
                        WHEN updated_at LIKE '____-__-__%' THEN substr(updated_at,1,10)
                        WHEN date       LIKE '____-__-__%' THEN substr(date,1,10)
                        ELSE COALESCE(visit_date, created_at, updated_at, date)
                    END AS visit_date_for_age,
                    visit_type,
                    problem_listing,
                    conclusions,
                    parents_concerns,
                    issues_since_last,
                    comments
                FROM \(wellTable)
                WHERE \(patientFK) = ? AND id <> ?
                ORDER BY visit_date_raw DESC;
                """

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlPrev, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, currentPatientID)
                    sqlite3_bind_int64(st, 2, Int64(currentVisitID))

                    while sqlite3_step(st) == SQLITE_ROW {
                        var idx: Int32 = 0
                        func col(_ i: Int32) -> String {
                            guard let c = sqlite3_column_text(st, i) else { return "" }
                            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        let prevVisitID = Int(sqlite3_column_int64(st, idx)); idx += 1 // id
                        let visitDateRaw      = col(idx); idx += 1      // visit_date_raw
                        let visitDateForAge   = col(idx); idx += 1      // visit_date_for_age
                        let visitTypeRaw      = col(idx); idx += 1
                        let problemsRaw       = col(idx); idx += 1
                        let conclusionsRaw    = col(idx); idx += 1
                        let parents           = col(idx); idx += 1
                        let issues            = col(idx); idx += 1
                        let comments          = col(idx); idx += 1

                        // Localize + normalize legacy stored text (often saved in EN) for report display.
                        let problems          = localizeAndFlattenPreviousWellText(visitID: prevVisitID, text: problemsRaw)
                        let conclusions       = localizeAndFlattenPreviousWellText(visitID: prevVisitID, text: conclusionsRaw)

                        // Title: Date · Visit Type · Age
                        let visitLabel = visitTypeRaw.isEmpty ? L("report.previousWell.visitLabel.default") : (readableVisitType(visitTypeRaw) ?? visitTypeRaw)

                        // Compute age using an age-safe ISO-like date (YYYY-MM-DD when available); fallback to raw if needed.
                        let ageCalc = visitDateForAge.isEmpty ? "—" : ageString(dobISO: effectiveDobISO, onDateISO: visitDateForAge)
                        let age = (ageCalc == "—") ? "" : ageCalc

                        // Keep the raw (possibly pretty) date for display; ReportBuilder may reformat if needed.
                        let dateShort = visitDateRaw.isEmpty ? "—" : visitDateRaw

                        let agePart = age.isEmpty ? nil : String(format: L("report.previousWell.title.agePart"), age)
                        let title = [dateShort, visitLabel, agePart]
                            .compactMap { $0 }
                            .joined(separator: " · ")

                        // Lines (short, prioritized)
                        var lines: [String] = []
                        if !issues.isEmpty     { lines.append(String(format: L("report.previousWell.line.issuesSinceLast"), issues)) }
                        if !problems.isEmpty   { lines.append(String(format: L("report.previousWell.line.problems"), problems)) }
                        if !conclusions.isEmpty { lines.append(String(format: L("report.previousWell.line.conclusions"), conclusions)) }
                        if !parents.isEmpty    { lines.append(String(format: L("report.previousWell.line.parentsConcerns"), parents)) }
                        if !comments.isEmpty   { lines.append(String(format: L("report.previousWell.line.comments"), comments)) }

                        // Keep it concise
                        if lines.count > 3 { lines = Array(lines.prefix(3)) }

                        let dateOut = visitDateRaw.isEmpty ? "—" : visitDateRaw
                        let findingsStr: String? = lines.isEmpty ? nil : lines.joined(separator: " • ")
                        if !title.isEmpty {
                            results.append((title: title, date: dateOut, findings: findingsStr))
                        }
                    }
                }
            }
        } catch {
            print("[ReportDataLoader] previousWell error: \(error)")
        }
        print("[ReportDataLoader] previousWell: \(results.count) items for visit \(currentVisitID)")
        return results
    }

    

        struct LatestAIInput {
            let model: String
            let createdAt: String
            let response: String
        }
    // MARK: - Growth data for WELL visit (points only; rendering is done elsewhere)
    

        struct ReportGrowthSeries {
            let wfa: [ReportGrowth.Point]   // kg vs age (months)
            let lhfa: [ReportGrowth.Point]  // cm vs age (months)
            let hcfa: [ReportGrowth.Point]  // cm vs age (months)
            let sex: ReportGrowth.Sex
            let dobISO: String
            let visitDateISO: String
        }

        /// Canonical current-visit block for WELL visit reports.
        /// This is the only payload that ReportBuilder needs for the
        /// "Current Visit — Feeding / Supplementation / Sleep" section.
        struct WellCurrentVisitBlock {
            /// Human-readable visit type subtitle (e.g. "1‑month visit").
            let visitTypeSubtitle: String?

            /// Parents' concerns (ungated: always relevant when present).
            let parentsConcerns: String?

            /// Age-gated, pretty-labelled feeding lines (key = pretty label).
            let feeding: [String:String]

            /// Age-gated, pretty-labelled stool pattern lines.
            let stool: [String:String]

            /// Age-gated, pretty-labelled supplementation lines.
            let supplementation: [String:String]

            /// Age-gated, pretty-labelled sleep lines.
            let sleep: [String:String]
        }
        private func ensureGrowthSchema(_ db: OpaquePointer?) {
                guard let db = db else { return }

                @discardableResult
                func exec(_ sql: String) -> Int32 {
                    var err: UnsafeMutablePointer<Int8>?
                    let rc = sqlite3_exec(db, sql, nil, nil, &err)
                    if rc != SQLITE_OK {
                        let msg = err.flatMap { String(cString: $0) } ?? "unknown"
                        NSLog("Growth schema exec failed: \(msg)")
                        if let e = err { sqlite3_free(e) }
                    }
                    return rc
                }

                // Manual user-entered points (broad columns for compatibility across earlier schemas)
                let createManual = """
                CREATE TABLE IF NOT EXISTS manual_growth (
                  id INTEGER PRIMARY KEY,
                  patient_mrn TEXT,
                  patient_id INTEGER,
                  date TEXT NOT NULL,
                  age_months REAL,
                  weight_kg REAL,
                  length_cm REAL,
                  height_cm REAL,
                  head_circumference_cm REAL,
                  unit TEXT
                );
                """

                // Visit-linked vitals (again, broad superset of common names)
                let createVitals = """
                CREATE TABLE IF NOT EXISTS vitals (
                  id INTEGER PRIMARY KEY,
                  visit_id TEXT,
                  patient_id INTEGER,
                  date TEXT,
                  recorded_at TEXT,
                  measured_at TEXT,
                  created_at TEXT,
                  updated_at TEXT,
                  weight_kg REAL,
                  length_cm REAL,
                  height_cm REAL,
                  head_circ_cm REAL,
                  head_circumference_cm REAL,
                  wt_kg REAL,
                  stature_cm REAL
                );
                """

                _ = exec(createManual)
                _ = exec(createVitals)
            }
        
        
        /// Collect patient growth points up to and including the WELL visit date.
        /// Sources: perinatal_history (birth/discharge), vitals, manual_growth.
        /// Units normalized to kg / cm. Ages expressed in months (days / 30.4375).
    @MainActor
    func loadGrowthSeriesForWell(visitID: Int) -> ReportGrowthSeries? {
        // Resolve db path
        guard let dbPath = try? bundleDBPathWithDebug() else { return nil }

        // Try RW+CREATE so we can create missing tables; fall back to RO if needed.
        var dbHandle: OpaquePointer?
        var openedRW = false
        if sqlite3_open_v2(dbPath, &dbHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, dbHandle != nil {
            openedRW = true
        } else if sqlite3_open_v2(dbPath, &dbHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, dbHandle != nil {
            openedRW = false
        } else {
            return nil
        }
        guard let db = dbHandle else { return nil }
        defer { sqlite3_close(db) }

        // If writable, ensure growth schema exists (idempotent).
        if openedRW { ensureGrowthSchema(db) }

            // Helper: read columns of a table
            func columns(in table: String) -> Set<String> {
                var cols = Set<String>()
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                    }
                }
                return cols
            }

            // Choose well table and FK to patients
            let wellTable = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
            let wcols = columns(in: wellTable)
            let patientFK = ["patient_id","patientId","patientID"].first(where: { wcols.contains($0) }) ?? "patient_id"

            // Resolve patient id, visit date
            var patientID: Int64 = -1
            var visitDateISO: String = ""
            do {
                var st: OpaquePointer?
                // Pull whole row so we can be robust on date columns
                if sqlite3_prepare_v2(db, "SELECT * FROM \(wellTable) WHERE id = ? LIMIT 1;", -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    sqlite3_bind_int64(s, 1, Int64(visitID))
                    if sqlite3_step(s) == SQLITE_ROW {
                        // Map row into dictionary
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(s)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(s, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(s, i) != SQLITE_NULL, let cval = sqlite3_column_text(s, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }
                        if let pidStr = row[patientFK], let pid = Int64(pidStr) {
                            patientID = pid
                        } else if let pid = row[patientFK] { patientID = (pid as NSString).longLongValue }

                        // visit_date precedence: visit_date → created_at → updated_at → date
                        visitDateISO =
                            row["visit_date"] ??
                            row["created_at"] ??
                            row["updated_at"] ??
                            row["date"] ?? ""
                    }
                }
            }

            guard patientID > 0 else { return nil }

            // Resolve DOB & SEX from patients (prefer DB value over appState)
            var dobISO = basicPatientStrings().dobISO
            var sexStr = basicPatientStrings().sex
            do {
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT first_name,last_name,dob,sex FROM patients WHERE id = ? LIMIT 1;", -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    sqlite3_bind_int64(s, 1, patientID)
                    if sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 2) {
                            let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !v.isEmpty { dobISO = v }
                        }
                        if let c = sqlite3_column_text(s, 3) {
                            let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !v.isEmpty { sexStr = v }
                        }
                    }
                }
            }

            // Parse DOB and visit date to bound points (if no visitDate, allow all)
            guard let dobDate = parseDateFlexible(dobISO) else { return nil }
            let visitCut = parseDateFlexible(visitDateISO)

            // Helpers
            func months(from dob: Date, to d: Date) -> Double {
                let seconds = d.timeIntervalSince(dob)
                let days = seconds / 86400.0
                return max(0.0, days / 30.4375)
            }
            func withinVisit(_ d: Date) -> Bool {
                guard let cut = visitCut else { return true }
                return d <= cut
            }

            var wfa: [ReportGrowth.Point] = []
            var lhfa: [ReportGrowth.Point] = []
            var hcfa: [ReportGrowth.Point] = []

            // -------- PERINATAL: birth / discharge --------
            if columns(in: "perinatal_history").isEmpty == false {
                // Single most recent row per patient
                let sqlP = """
                SELECT birth_weight_g, birth_length_cm, birth_head_circumference_cm,
                       maternity_discharge_date, discharge_weight_g, updated_at
                FROM perinatal_history
                WHERE patient_id = ?
                ORDER BY COALESCE(updated_at, id) DESC
                LIMIT 1;
                """
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlP, -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    sqlite3_bind_int64(s, 1, patientID)
                    if sqlite3_step(s) == SQLITE_ROW {
                        func colStr(_ i: Int32) -> String? {
                            guard let c = sqlite3_column_text(s, i) else { return nil }
                            let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                            return v.isEmpty ? nil : v
                        }
                        // Birth (age = 0m)
                        if let g = colStr(0), let gw = Double(g) { wfa.append(.init(ageMonths: 0.0, value: gw / 1000.0)) }
                        if let l = colStr(1), let lc = Double(l) { lhfa.append(.init(ageMonths: 0.0, value: lc)) }
                        if let h = colStr(2), let hc = Double(h) { hcfa.append(.init(ageMonths: 0.0, value: hc)) }

                        // Discharge
                        let discDateStr = colStr(3)
                        let discWtStr   = colStr(4)
                        if let ds = discDateStr, let d = parseDateFlexible(ds), withinVisit(d) {
                            let ageM = months(from: dobDate, to: d)
                            if let s = discWtStr, let g = Double(s) {
                                wfa.append(.init(ageMonths: ageM, value: g / 1000.0))
                            }
                        }
                    }
                }
            }

            // -------- VITALS table --------
            if columns(in: "vitals").isEmpty == false {
                // Try to find linkage and common column names
                let vcols = columns(in: "vitals")
                let pidCol = vcols.contains("patient_id") ? "patient_id" :
                             (vcols.contains("patientId") ? "patientId" :
                             (vcols.contains("patientID") ? "patientID" : nil))
                // Date columns to try
                let dateCols = ["date","recorded_at","measured_at","created_at","updated_at"]

                // Build SELECT dynamically
                let pidWhere = pidCol != nil ? "WHERE \(pidCol!) = ?" : ""
                let sqlV = "SELECT * FROM vitals \(pidWhere);"
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlV, -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    if pidCol != nil { sqlite3_bind_int64(s, 1, patientID) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        // Row dict
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(s)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(s, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(s, i) != SQLITE_NULL, let cval = sqlite3_column_text(s, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }
                        // Date
                        let dateRaw = dateCols.compactMap { row[$0] }.first
                        guard let dateStr = dateRaw, let d = parseDateFlexible(dateStr), withinVisit(d) else { continue }
                        let ageM = months(from: dobDate, to: d)

                        // Weights
                        if let w = row["weight_kg"] ?? row["weight"] ?? row["wt_kg"], let dv = Double(w) {
                            wfa.append(.init(ageMonths: ageM, value: dv))
                        }
                        // Length/Height
                        if let l = row["length_cm"] ?? row["height_cm"] ?? row["length"] ?? row["stature_cm"], let dv = Double(l) {
                            lhfa.append(.init(ageMonths: ageM, value: dv))
                        }
                        // Head circumference
                        if let h = row["head_circumference_cm"] ?? row["hc_cm"] ?? row["head_circ_cm"], let dv = Double(h) {
                            hcfa.append(.init(ageMonths: ageM, value: dv))
                        }
                    }
                }
            }

            // -------- MANUAL_GROWTH table (optional) --------
            if columns(in: "manual_growth").isEmpty == false {
                let gcols = columns(in: "manual_growth")
                let pidCol = gcols.contains("patient_id") ? "patient_id" :
                             (gcols.contains("patientId") ? "patientId" :
                             (gcols.contains("patientID") ? "patientID" : nil))
                let dateCols = ["date","recorded_at","created_at","updated_at"]
                let sqlG = "SELECT * FROM manual_growth \(pidCol != nil ? "WHERE \(pidCol!) = ?" : "");"
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, sqlG, -1, &st, nil) == SQLITE_OK, let s = st {
                    defer { sqlite3_finalize(s) }
                    if pidCol != nil { sqlite3_bind_int64(s, 1, patientID) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(s)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(s, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(s, i) != SQLITE_NULL, let cval = sqlite3_column_text(s, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }
                        // If table stores age_months directly, prefer that; else compute from date
                        let ageM: Double? = {
                            if let a = row["age_months"], let dv = Double(a) { return dv }
                            if let ds = dateCols.compactMap({ row[$0] }).first, let d = parseDateFlexible(ds) {
                                return withinVisit(d) ? months(from: dobDate, to: d) : nil
                            }
                            return nil
                        }()
                        guard let age = ageM else { continue }

                        if let w = row["weight_kg"] ?? row["weight"], let dv = Double(w) {
                            wfa.append(.init(ageMonths: age, value: dv))
                        }
                        if let l = row["length_cm"] ?? row["height_cm"] ?? row["length"], let dv = Double(l) {
                            lhfa.append(.init(ageMonths: age, value: dv))
                        }
                        if let h = row["head_circumference_cm"] ?? row["hc_cm"] ?? row["head_circ_cm"], let dv = Double(h) {
                            hcfa.append(.init(ageMonths: age, value: dv))
                        }
                    }
                }
            }

            // Sort by age and return (no dedup beyond stable sort)
            func sortPts(_ pts: inout [ReportGrowth.Point]) {
                pts.sort { $0.ageMonths < $1.ageMonths }
            }
            sortPts(&wfa); sortPts(&lhfa); sortPts(&hcfa)

            let sex = (sexStr.uppercased().hasPrefix("F")) ? ReportGrowth.Sex.female : .male
            return ReportGrowthSeries(wfa: wfa, lhfa: lhfa, hcfa: hcfa, sex: sex, dobISO: dobISO, visitDateISO: visitDateISO)
        }
    }

extension ReportDataLoader {

    /// Age at the given WELL visit, expressed in months (used for WellVisitReportRules age gating).
    /// Returns nil if DOB or visit date cannot be parsed.
    func wellVisitAgeMonths(visitID: Int) -> Double? {
        do {
            let meta = try buildMetaForWell(visitID: visitID)
            guard let dob = parseDateFlexible(meta.dobISO),
                  let visit = parseDateFlexible(meta.visitDateISO) else {
                return nil
            }
            let seconds = visit.timeIntervalSince(dob)
            let days = seconds / 86400.0
            // Use the same month length convention as growth logic (30.4375 days)
            let months = max(0.0, days / 30.4375)

            #if DEBUG
            let dbgMonths = String(format: "%.2f", months)
            print("[ReportDataLoader] wellVisitAgeMonths visitID=\(visitID) dob=\(meta.dobISO) visitDate=\(meta.visitDateISO) months=\(dbgMonths)")
            #endif

            return months
        } catch {
            return nil
        }
    }

    // MARK: - Date parsing helpers (SQLite & ISO tolerant)
    private static let _posix: Locale = Locale(identifier: "en_US_POSIX")
    private static let _gmt: TimeZone = TimeZone(secondsFromGMT: 0)!

    // Reuse formatters to avoid allocation churn
    private static let _dfYMD_HMS: DateFormatter = {
        let df = DateFormatter()
        df.locale = _posix
        df.timeZone = _gmt
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    private static let _dfYMD_HM: DateFormatter = {
        let df = DateFormatter()
        df.locale = _posix
        df.timeZone = _gmt
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    private static let _dfYMD: DateFormatter = {
        let df = DateFormatter()
        df.locale = _posix
        df.timeZone = _gmt
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static let _dfYMD_T_HMS: DateFormatter = {
        let df = DateFormatter()
        df.locale = _posix
        df.timeZone = _gmt
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df
    }()

    private func parseDateFlexible(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 1) ISO8601 fast path if 'T' or 'Z' present
        if s.contains("T") || s.hasSuffix("Z") {
            if let d = ISO8601DateFormatter().date(from: s) { return d }
            if let d = ReportDataLoader._dfYMD_T_HMS.date(from: s) { return d }
        }

        // 2) Common SQLite / TEXT timestamps
        if let d = ReportDataLoader._dfYMD_HMS.date(from: s) { return d }
        if let d = ReportDataLoader._dfYMD_HM.date(from: s)  { return d }
        if let d = ReportDataLoader._dfYMD.date(from: s)     { return d }

        // 3) If there's a space, try the date-only part
        if let sp = s.firstIndex(of: " ") {
            let dateOnly = String(s[..<sp])
            if let d = ReportDataLoader._dfYMD.date(from: dateOnly) { return d }
        }

        return nil
    }

    private func currentBundleDBPath() throws -> String {
        guard let root = appState.currentBundleURL else {
            throw NSError(domain: "ReportDataLoader", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: L("error.bundle.noActivePatientBundle")])
        }
        return root.appendingPathComponent("db.sqlite").path
    }

    private func activeClinicianName() -> String {
        guard let uid = appState.activeUserID,
              let c = clinicianStore.users.first(where: { $0.id == uid }) else {
            return "—"
        }
        let first = reflectString(c, keys: ["firstName", "first_name"])
        let last  = reflectString(c, keys: ["lastName", "last_name"])
        let name  = [first, last].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? String(format: L("common.user.number"), c.id) : name
    }

    private func basicPatientStrings() -> (name: String, alias: String, mrn: String, dobISO: String, sex: String) {
        var patientName = "—", alias = "—", mrn = "—", dobISO = "—", sex = "—"
        if let p = appState.selectedPatient {
            if let dn = reflectString(p, keys: ["displayName", "name"]) {
                patientName = dn
            } else {
                let first = reflectString(p, keys: ["firstName", "first_name"])
                let last  = reflectString(p, keys: ["lastName", "last_name"])
                let combined = [first, last].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !combined.isEmpty { patientName = combined }
                else if let a = reflectString(p, keys: ["alias", "alias_label"]) { patientName = a }
            }
            alias  = reflectString(p, keys: ["alias", "alias_label"]) ?? alias
            mrn    = reflectString(p, keys: ["mrn"]) ?? mrn
            dobISO = reflectString(p, keys: ["dobISO", "dateOfBirth", "dob"]) ?? dobISO
            sex    = reflectString(p, keys: ["sex", "gender"]) ?? sex
        }
        return (patientName, alias, mrn, dobISO, sex)
    }

    private func reflectString(_ any: Any, keys: [String]) -> String? {
        let m = Mirror(reflecting: any)
        for c in m.children {
            if let label = c.label, keys.contains(label),
               let val = c.value as? String,
               !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
        }
        return nil
    }

    private func ageString(dobISO: String, onDateISO: String) -> String {
        guard let dob = parseDateFlexible(dobISO),
              let ref = parseDateFlexible(onDateISO),
              ref >= dob else { return "—" }

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: dob, to: ref)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        let d = comps.day ?? 0

        // < 1 month: days only
        if y == 0 && m == 0 {
            return String(format: L("report.age.format.days"), max(d, 0))
        }

        // < 6 months: months + days
        if y == 0 && m < 6 {
            return d > 0
            ? String(format: L("report.age.format.monthsDays"), m, d)
            : String(format: L("report.age.format.months"), m)
        }

        // 6–11 months: months only
        if y == 0 {
            return String(format: L("report.age.format.months"), m)
        }

        // ≥ 12 months: years + months
        return m > 0
        ? String(format: L("report.age.format.yearsMonths"), y, m)
        : String(format: L("report.age.format.years"), y)
    }
}

extension ReportDataLoader {
    /// Load Physical Examination (grouped) and trailing text fields for a WELL visit.
    /// Reads from `well_visits` (or fallback `visits`) and returns grouped PE lines and summary strings.
    @MainActor
    fileprivate func loadWellPEAndText(visitID: Int) -> (groups: [(String,[String])],
                                                         problem: String?,
                                                         conclusions: String?,
                                                         anticipatory: String?,
                                                         comments: String?,
                                                         nextVisitDate: String?) {
        var groupsOut: [(String,[String])] = []
        var problem: String?
        var conclusions: String?
        var anticipatory: String?
        var comments: String?
        var nextVisitDate: String?

        // Age/visit-type gating for PE elements, driven by the canonical CSV.
        // Important:
        // - Only the age-dependent items (fontanelle, hips, teeth) are gated by the CSV.
        // - All other PE elements should be considered always-allowed when present in the DB row.
        let allowedCols = allowedDBColumnsForWellVisit(visitID)

        // Columns that *may* be age-gated via the CSV. Everything else in PE
        // is treated as always-on and will be rendered whenever data is present.
        let ageGatedPEColumns: Set<String> = [
            // Fontanelle
            "pe_fontanelle_normal",
            "pe_fontanelle_comment",
            // Hips focus
            "pe_hips_normal",
            "pe_hips_comment",
            // Teeth / dentition
            "pe_teeth_normal",
            "pe_teeth_comment",
            "pe_teeth_present",
            "pe_teeth_count",
            // Primitive neuro / neonatal reflexes
            "pe_moro_normal",
            "pe_moro_comment",
            "pe_primitive_neuro_normal",
            "pe_primitive_neuro_comment",
            // Early neuro / development items (also age‑dependent)
            "pe_hands_fist_normal",
            "pe_hands_fist_comment",
            "pe_symmetry_normal",
            "pe_symmetry_comment",
            "pe_follows_midline_normal",
            "pe_follows_midline_comment"
        ]

        func isAllowedPE(_ keys: [String]) -> Bool {
            // Only care about columns that are explicitly age-gated.
            let gatedKeys = keys.filter { ageGatedPEColumns.contains($0) }

            // If this PE item does not use any age-gated columns,
            // we don't apply CSV gating here.
            if gatedKeys.isEmpty {
                return true
            }

            // For age-gated PE (fontanelle, primitive neuro, Moro, hips, teeth),
            // if the CSV / flags gave us NO allowed columns for this visit type,
            // we FAIL-CLOSED: do not show this block.
            guard !allowedCols.isEmpty else {
                #if DEBUG
                print("[ReportDataLoader] PE gated OFF (no allowedCols) for keys=\(gatedKeys)")
                #endif
                return false
            }

            // Otherwise, show only if at least one of this block's gated columns
            // is actually allowed for this visit type.
            return gatedKeys.contains { allowedCols.contains($0) }
        }

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func yn(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            let l = s.lowercased()
            if ["1","true","yes","y"].contains(l) { return L("common.yes") }
            if ["0","false","no","n"].contains(l) { return L("common.no") }
            return s
        }
        func isYes(_ raw: String?) -> Bool? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            let l = s.lowercased()
            if ["1","true","yes","y"].contains(l) { return true }
            if ["0","false","no","n"].contains(l) { return false }
            return nil
        }

        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"

                // Pull full row as dictionary
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT * FROM \(table) WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }
                        #if DEBUG
                        print("[ReportDataLoader] loadWellPEAndText visitID=\(visitID)")
                        print("  allowedCols: \(Array(allowedCols).sorted())")
                        print("  row keys: \(Array(row.keys).sorted())")
                        #endif

                        // --- Build grouped PE lines ---
                        let gGeneral         = L("report.pe.group.general")
                        let gHeadEyes        = L("report.pe.group.headEyes")
                        let gCardioPulses    = L("report.pe.group.cardioPulses")
                        let gAbdomen         = L("report.pe.group.abdomen")
                        let gGenitalia       = L("report.pe.group.genitalia")
                        let gSpineHips       = L("report.pe.group.spineHips")
                        let gSkin            = L("report.pe.group.skin")
                        let gNeuroDev        = L("report.pe.group.neuroDevelopment")
                        var groups: [String:[String]] = [:]
                        func add(_ group: String, _ line: String) {
                            groups[group, default: []].append(line)
                        }
                        func addNormal(_ group: String, _ label: String, normalKey: String, commentKey: String?) {
                            let keys = [normalKey] + (commentKey != nil ? [commentKey!] : [])
                            // Respect CSV-driven age/visit-type gating *only* for the
                            // explicitly age-gated PE elements (fontanelle, hips, teeth).
                            // All other PE items will bypass this check inside isAllowedPE.
                            if !isAllowedPE(keys) {
                                #if DEBUG
                                print("[ReportDataLoader] PE GATED OUT group=\(group) label=\(label) keys=\(keys)")
                                #endif
                                return
                            }
                            let norm = isYes(row[normalKey])
                            let comment = nonEmpty(row[commentKey ?? ""])
                            if norm != nil || comment != nil {
                                let statusText: String
                                if let n = norm {
                                    statusText = n ? L("common.normal") : L("common.abnormal")
                                } else {
                                    statusText = "—"
                                }

                                var line = String(format: L("report.pe.line.labelStatus"), label, statusText)
                                if let c = comment { line += " — \(c)" }
                                add(group, line)
                            }
                        }

                        // General
                        addNormal(gGeneral, L("report.pe.item.trophic"), normalKey: "pe_trophic_normal", commentKey: "pe_trophic_comment")
                        addNormal(gGeneral, L("report.pe.item.hydration"), normalKey: "pe_hydration_normal", commentKey: "pe_hydration_comment")
                        if isAllowedPE(["pe_color", "pe_color_comment"]),
                           let color = nonEmpty(row["pe_color"]) ?? nonEmpty(row["pe_color_comment"]) {
                            add(gGeneral, String(format: L("report.pe.line.color"), color))
                        }
                        addNormal(gGeneral, L("report.pe.item.tone"), normalKey: "pe_tone_normal", commentKey: "pe_tone_comment")
                        addNormal(gGeneral, L("report.pe.item.breathing"), normalKey: "pe_breathing_normal", commentKey: "pe_breathing_comment")
                        addNormal(gGeneral, L("report.pe.item.wakefulness"), normalKey: "pe_wakefulness_normal", commentKey: "pe_wakefulness_comment")

                        // Head & Eyes
                        addNormal(gHeadEyes, L("report.pe.item.fontanelle"), normalKey: "pe_fontanelle_normal", commentKey: "pe_fontanelle_comment")

                        // Teeth / dentition (age-gated via CSV)
                        addNormal(gHeadEyes, L("report.pe.item.teethDentition"), normalKey: "pe_teeth_normal", commentKey: "pe_teeth_comment")
                        if isAllowedPE(["pe_teeth_present", "pe_teeth_count"]) {
                            if let present = isYes(row["pe_teeth_present"]) {
                                let ynText = present ? L("common.yes") : L("common.no")
                                add(gHeadEyes, String(format: L("report.pe.line.teethPresent"), ynText))
                            }
                            if let countStr = nonEmpty(row["pe_teeth_count"]) {
                                add(gHeadEyes, String(format: L("report.pe.line.teethCount"), countStr))
                            }
                        }

                        addNormal(gHeadEyes, L("report.pe.item.pupilsRR"), normalKey: "pe_pupils_rr_normal", commentKey: "pe_pupils_rr_comment")
                        addNormal(gHeadEyes, L("report.pe.item.ocularMotility"), normalKey: "pe_ocular_motility_normal", commentKey: "pe_ocular_motility_comment")

                        // Cardio / Pulses
                        addNormal(gCardioPulses, L("report.pe.item.heartSounds"), normalKey: "pe_heart_sounds_normal", commentKey: "pe_heart_sounds_comment")
                        addNormal(gCardioPulses, L("report.pe.item.femoralPulses"), normalKey: "pe_femoral_pulses_normal", commentKey: "pe_femoral_pulses_comment")

                        // Abdomen
                        if isAllowedPE(["pe_abd_mass"]),
                           let massYes = isYes(row["pe_abd_mass"]) {
                            if massYes { add(gAbdomen, L("report.pe.line.abdominalMassPresent")) }
                        }
                        addNormal(gAbdomen, L("report.pe.item.liverSpleen"), normalKey: "pe_liver_spleen_normal", commentKey: "pe_liver_spleen_comment")
                        addNormal(gAbdomen, L("report.pe.item.umbilic"), normalKey: "pe_umbilic_normal", commentKey: "pe_umbilic_comment")

                        // Genitalia
                        if isAllowedPE(["pe_genitalia"]),
                           let gen = nonEmpty(row["pe_genitalia"]) {
                            add(gGenitalia, String(format: L("report.pe.line.genitalia"), gen))
                        }
                        if isAllowedPE(["pe_testicles_descended"]),
                           let desc = isYes(row["pe_testicles_descended"]) {
                            let ynText = desc ? L("common.yes") : L("common.no")
                            add(gGenitalia, String(format: L("report.pe.line.testiclesDescended"), ynText))
                        }

                        // Spine & Hips
                        addNormal(gSpineHips, L("report.pe.item.spine"), normalKey: "pe_spine_normal", commentKey: "pe_spine_comment")
                        addNormal(gSpineHips, L("report.pe.item.hips"), normalKey: "pe_hips_normal", commentKey: "pe_hips_comment")

                        // Skin
                        addNormal(gSkin, L("report.pe.item.marks"), normalKey: "pe_skin_marks_normal", commentKey: "pe_skin_marks_comment")
                        addNormal(gSkin, L("report.pe.item.integrity"), normalKey: "pe_skin_integrity_normal", commentKey: "pe_skin_integrity_comment")
                        addNormal(gSkin, L("report.pe.item.rash"), normalKey: "pe_skin_rash_normal", commentKey: "pe_skin_rash_comment")

                        // Neuro / Development
                        // Insert Muscle tone first, using same config as e.g. "Hydration" or "Spine"
                        addNormal(gNeuroDev, L("report.pe.item.muscleTone"), normalKey: "pe_tone_normal", commentKey: "pe_tone_comment")
                        addNormal(gNeuroDev, L("report.pe.item.moro"), normalKey: "pe_moro_normal", commentKey: "pe_moro_comment")
                        addNormal(gNeuroDev, L("report.pe.item.primitiveNeuro"), normalKey: "pe_primitive_neuro_normal", commentKey: "pe_primitive_neuro_comment")
                        addNormal(gNeuroDev, L("report.pe.item.handsInFist"), normalKey: "pe_hands_fist_normal", commentKey: "pe_hands_fist_comment")
                        addNormal(gNeuroDev, L("report.pe.item.symmetry"), normalKey: "pe_symmetry_normal", commentKey: "pe_symmetry_comment")
                        addNormal(gNeuroDev, L("report.pe.item.followsMidline"), normalKey: "pe_follows_midline_normal", commentKey: "pe_follows_midline_comment")

                        // Emit groups in a stable order
                        let order = [gGeneral, gHeadEyes, gCardioPulses, gAbdomen, gGenitalia, gSpineHips, gSkin, gNeuroDev]
                        for g in order {
                            if let lines = groups[g], !lines.isEmpty {
                                groupsOut.append((g, lines))
                            }
                        }

                        // --- Trailing text sections ---
                        problem        = nonEmpty(row["problem_listing"])
                        conclusions    = nonEmpty(row["conclusions"])
                        anticipatory   = nonEmpty(row["anticipatory_guidance"])
                        comments       = nonEmpty(row["comments"])
                        nextVisitDate  = nonEmpty(row["next_visit_date"])

                        // Add stool issues to Problem Listing when deemed abnormal (never age-gated).
                        if let statusRaw = row["poop_status"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !statusRaw.isEmpty,
                           statusRaw != "normal" {
                            var stoolLine: String
                            switch statusRaw {
                            case "abnormal":
                                stoolLine = L("report.well.problem.stools.abnormalPattern")
                            case "hard":
                                stoolLine = L("report.well.problem.stools.hardConstipated")
                            default:
                                stoolLine = String(format: L("report.well.problem.stools.other"), statusRaw)
                            }
                            if let c = nonEmpty(row["poop_comment"]) {
                                stoolLine += " — \(c)"
                            }
                            if let existing = problem, !existing.isEmpty {
                                problem = existing + "\n" + stoolLine
                            } else {
                                problem = stoolLine
                            }
                        }
                    }
                }
            }
        } catch {
            // leave defaults
        }

        return (groupsOut, problem, conclusions, anticipatory, comments, nextVisitDate)
    }
}

extension ReportDataLoader {
    // Read current WELL visit core fields from the bundle DB (robust to column name variants)
    private func loadCurrentWellCoreFields(visitID: Int) -> (visitType: String?, parentsConcerns: String?, feeding: [String:String], stool: [String:String], supplementation: [String:String], sleep: [String:String]) {
        var visitType: String?
        var parents: String?
        var feeding: [String:String] = [:]
        var stool: [String:String] = [:]
        var supplementation: [String:String] = [:]
        var sleep: [String:String] = [:]

        // Age-gated DB columns for this WELL visit (canonical CSV via WellVisitReportRules)
        // Contract: this is the *only* source of truth for which current-visit fields
        // may appear in the report for this visit type + age.
        let allowedCols = allowedDBColumnsForWellVisit(visitID)
        let hasGate = !allowedCols.isEmpty

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }

        enum WellFieldSection {
            case feeding
            case stool
            case supplementation
            case sleep
        }

        enum ValueKind {
            case plain                 // as-is (after trimming)
            case yesNo                 // normalize 1/0, yes/no, true/false → "yes"/"no"
            case numeric(unit: String?)// parse numeric, pretty-print, attach unit
        }

        struct MappedField {
            let section: WellFieldSection
            let prettyKey: String
            let kind: ValueKind
        }

        // Central mapping: DB column -> (section, pretty label, value kind)
        // Gating (age/visit-type) is entirely handled by `allowedCols`.
        let fieldMap: [String: MappedField] = [
            // FEEDING NOTES & QUALITATIVE FIELDS
            "feeding":              .init(section: .feeding, prettyKey: L("report.well.current.label.notes"), kind: .plain),
            "breastfeeding":        .init(section: .feeding, prettyKey: L("report.well.current.label.breastfeeding"), kind: .plain),
            "feeding_breast":       .init(section: .feeding, prettyKey: L("report.well.current.label.breastfeeding"), kind: .plain),
            "breast_milk":          .init(section: .feeding, prettyKey: L("report.well.current.label.breastfeeding"), kind: .plain),
            "nursing":              .init(section: .feeding, prettyKey: L("report.well.current.label.breastfeeding"), kind: .plain),
            "formula":              .init(section: .feeding, prettyKey: L("report.well.current.label.formula"), kind: .plain),
            "feeding_formula":      .init(section: .feeding, prettyKey: L("report.well.current.label.formula"), kind: .plain),
            "solids":               .init(section: .feeding, prettyKey: L("report.well.current.label.solids"), kind: .plain),
            "feeding_solids":       .init(section: .feeding, prettyKey: L("report.well.current.label.solids"), kind: .plain),
            "complementary_feeding":.init(section: .feeding, prettyKey: L("report.well.current.label.solids"), kind: .plain),
            "weaning":              .init(section: .feeding, prettyKey: L("report.well.current.label.solids"), kind: .plain),

            "feeding_comment":      .init(section: .feeding, prettyKey: L("report.well.current.label.feedingComment"), kind: .plain),
            "milk_types":           .init(section: .feeding, prettyKey: L("report.well.current.label.milkTypes"), kind: .plain),
            "food_variety_quality": .init(section: .feeding, prettyKey: L("report.well.current.label.foodVarietyQuantity"), kind: .plain),
            "dairy_amount_text":    .init(section: .feeding, prettyKey: L("report.well.current.label.dairyAmount"), kind: .plain),
            "feeding_issue":        .init(section: .feeding, prettyKey: L("report.well.current.label.feedingIssue"), kind: .plain),

            // FREQUENCY & VOLUMES
            "feed_freq_per_24h":    .init(section: .feeding, prettyKey: L("report.well.current.label.feedsPer24h"), kind: .plain),
            "feeds_per_24h":        .init(section: .feeding, prettyKey: L("report.well.current.label.feedsPer24h"), kind: .plain),
            "feeds_per_day":        .init(section: .feeding, prettyKey: L("report.well.current.label.feedsPer24h"), kind: .plain),
            "feed_volume_ml":       .init(section: .feeding, prettyKey: L("report.well.current.label.feedVolumeML"), kind: .numeric(unit: "ml")),
            "est_total_ml":         .init(section: .feeding, prettyKey: L("report.well.current.label.estimatedTotalML24h"), kind: .numeric(unit: "ml")),
            "est_ml_per_kg_24h":    .init(section: .feeding, prettyKey: L("report.well.current.label.estimatedMLkg24h"), kind: .numeric(unit: "ml/kg/24h")),

            // FEEDING BOOLEANS / FLAGS
            "regurgitation":        .init(section: .feeding, prettyKey: L("report.well.current.label.regurgitation"), kind: .yesNo),
            "wakes_for_feeds":      .init(section: .feeding, prettyKey: L("report.well.current.label.wakesForFeeds"), kind: .yesNo),
            "night_feeds":          .init(section: .feeding, prettyKey: L("report.well.current.label.wakesForFeeds"), kind: .yesNo),
            "wakes_to_feed":        .init(section: .feeding, prettyKey: L("report.well.current.label.wakesForFeeds"), kind: .yesNo),
            "expressed_bm":         .init(section: .feeding, prettyKey: L("report.well.current.label.expressedBM"), kind: .yesNo),

            // SOLID FOODS DETAIL
            "solid_food_started":   .init(section: .feeding, prettyKey: L("report.well.current.label.solidFoodsStarted"), kind: .yesNo),
            "solid_food_start_date":.init(section: .feeding, prettyKey: L("report.well.current.label.solidFoodStart"), kind: .plain),
            "solid_food_quality":   .init(section: .feeding, prettyKey: L("report.well.current.label.solidFoodQuality"), kind: .plain),
            "solid_food_comment":   .init(section: .feeding, prettyKey: L("report.well.current.label.solidFoodNotes"), kind: .plain),

            // STOOL / STOOL PATTERN
            "poop_status":         .init(section: .stool, prettyKey: L("report.well.current.label.stoolPattern"), kind: .plain),
            "poop_comment":        .init(section: .stool, prettyKey: L("report.well.current.label.stoolComment"), kind: .plain),

            // SUPPLEMENTATION
            "supplementation":      .init(section: .supplementation, prettyKey: L("report.well.current.label.notes"), kind: .plain),
            "supplements":          .init(section: .supplementation, prettyKey: L("report.well.current.label.notes"), kind: .plain),
            "vitamin_d":            .init(section: .supplementation, prettyKey: L("report.well.current.label.vitaminD"), kind: .plain),
            "vit_d":                .init(section: .supplementation, prettyKey: L("report.well.current.label.vitaminD"), kind: .plain),
            "vit_d_supplement":     .init(section: .supplementation, prettyKey: L("report.well.current.label.vitaminD"), kind: .plain),
            "vitamin_d_iu":         .init(section: .supplementation, prettyKey: L("report.well.current.label.vitaminD"), kind: .plain),
            "vitamin_d_given":      .init(section: .supplementation, prettyKey: L("report.well.current.label.vitaminDGiven"), kind: .yesNo),
            "iron":                 .init(section: .supplementation, prettyKey: L("report.well.current.label.iron"), kind: .plain),
            "ferrous":              .init(section: .supplementation, prettyKey: L("report.well.current.label.iron"), kind: .plain),
            "others":               .init(section: .supplementation, prettyKey: L("report.well.current.label.other"), kind: .plain),
            "other_supplements":    .init(section: .supplementation, prettyKey: L("report.well.current.label.other"), kind: .plain),

            // SLEEP CORE FIELDS
            "sleep":                .init(section: .sleep, prettyKey: L("report.well.current.label.notes"), kind: .plain),
            "sleep_hours":          .init(section: .sleep, prettyKey: L("report.well.current.label.totalHours"), kind: .plain),
            "sleep_total_hours":    .init(section: .sleep, prettyKey: L("report.well.current.label.totalHours"), kind: .plain),
            "sleep_total":          .init(section: .sleep, prettyKey: L("report.well.current.label.totalHours"), kind: .plain),
            "sleep_hours_text":     .init(section: .sleep, prettyKey: L("report.well.current.label.totalHours"), kind: .plain),
            "naps":                 .init(section: .sleep, prettyKey: L("report.well.current.label.naps"), kind: .plain),
            "daytime_naps":         .init(section: .sleep, prettyKey: L("report.well.current.label.naps"), kind: .plain),
            "night_wakings":        .init(section: .sleep, prettyKey: L("report.well.current.label.nightWakings"), kind: .plain),
            "night_wakes":          .init(section: .sleep, prettyKey: L("report.well.current.label.nightWakings"), kind: .plain),
            "night_awakenings":     .init(section: .sleep, prettyKey: L("report.well.current.label.nightWakings"), kind: .plain),
            "sleep_quality":        .init(section: .sleep, prettyKey: L("report.well.current.label.sleepQuality"), kind: .plain),
            "sleep_regular":        .init(section: .sleep, prettyKey: L("report.well.current.label.sleepRegular"), kind: .plain),
            "sleep_snoring":        .init(section: .sleep, prettyKey: L("report.well.current.label.sleepSnoring"), kind: .yesNo),
            "sleep_issue_reported": .init(section: .sleep, prettyKey: L("report.well.current.label.sleepIssueReported"), kind: .yesNo),
            "sleep_issue_text":     .init(section: .sleep, prettyKey: L("report.well.current.label.sleepIssueNotes"), kind: .plain)
        ]

        func renderValue(_ raw: String, kind: ValueKind) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            switch kind {
            case .plain:
                return trimmed
            case .yesNo:
                let l = trimmed.lowercased()
                if ["1","true","yes","y"].contains(l) { return L("common.yes") }
                if ["0","false","no","n"].contains(l) { return L("common.no") }
                return trimmed
            case .numeric(let unit):
                if let d = Double(trimmed) {
                    let isInt = d.truncatingRemainder(dividingBy: 1) == 0
                    let base = isInt ? String(Int(d)) : String(d)
                    if let u = unit {
                        return "\(base) \(u)"
                    } else {
                        return base
                    }
                } else {
                    // Fallback: keep raw text, optionally with unit appended
                    if let u = unit, !trimmed.contains(u) {
                        return "\(trimmed) \(u)"
                    }
                    return trimmed
                }
            }
        }

        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover well visit table
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }

                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                #if DEBUG
                print("[ReportDataLoader] loadCurrentWellCoreFields: using table=\(table)")
                #endif

                // Pull the entire row so we can map flexible column names
                let sql = "SELECT * FROM \(table) WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }

                        // Visit type subtitle (not age-gated: always relevant for the current visit)
                        let vtRaw = nonEmpty(row["visit_type"])
                            ?? nonEmpty(row["type"])
                            ?? nonEmpty(row["milestone"])
                            ?? nonEmpty(row["title"])
                        visitType = readableVisitType(vtRaw) ?? vtRaw

                        // Parents' concerns (also not age-gated)
                        parents = nonEmpty(row["parents_concerns"])
                            ?? nonEmpty(row["parent_concerns"])
                            ?? nonEmpty(row["concerns"])

                        // Core rule:
                        //   - Only consider (key, value) pairs that:
                        //       * are present in this visit row
                        //       * have a mapping entry in fieldMap
                        //       * respect age-gating for Feeding / Supplementation / Sleep when allowedCols is non-empty
                        //       * Stool fields are explicitly **not** age-gated and are always allowed when present.
                        for (key, rawVal) in row {
                            // Only handle keys we know how to map
                            guard let mapping = fieldMap[key] else {
                                continue
                            }

                            // Apply age/visit-type gating only for selected sections.
                            if hasGate {
                                switch mapping.section {
                                case .stool:
                                    // Stool is not age-gated: always allowed when present.
                                    break
                                case .feeding, .supplementation, .sleep:
                                    // For these sections, only include columns explicitly allowed
                                    // for this visit type / age.
                                    if !allowedCols.contains(key) {
                                        continue
                                    }
                                }
                            }

                            guard let rendered = renderValue(rawVal, kind: mapping.kind) else {
                                continue
                            }

                            switch mapping.section {
                            case .feeding:
                                feeding[mapping.prettyKey] = rendered
                            case .stool:
                                stool[mapping.prettyKey] = rendered
                            case .supplementation:
                                supplementation[mapping.prettyKey] = rendered
                            case .sleep:
                                sleep[mapping.prettyKey] = rendered
                            }
                        }
                    }
                }
            }
        } catch {
            // leave nil/empty dicts, renderer will show "—" or skip lines
        }

        return (visitType, parents, feeding, stool, supplementation, sleep)
    }
}

extension ReportDataLoader {
    // Load Measurements for the current WELL visit from well_visits (or visits) table.
    // Maps:
    //  - weight_today_kg        -> "Weight"              (kg)
    //  - length_today_cm        -> "Length"              (cm)
    //  - head_circ_today_cm     -> "Head Circumference"  (cm)
    //  - delta_weight_g         -> part of "Weight gain since discharge"
    //  - delta_days_since_discharge -> appended as "over N days"
    @MainActor
    private func loadMeasurementsForWellVisit(visitID: Int) -> [String:String] {
        #if DEBUG
        print("[ReportDataLoader] loadMeasurementsForWellVisit visitID=\(visitID)")
        #endif
        var out: [String:String] = [:]

        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func fmtNumber(_ raw: String?, unit: String) -> String? {
            guard let t = nonEmpty(raw) else { return nil }
            if let d = Double(t) {
                let asInt = d.truncatingRemainder(dividingBy: 1) == 0
                return asInt ? "\(Int(d)) \(unit)" : String(format: "%.1f %@", d, unit)
            }
            return "\(t) \(unit)"
        }
        func fmtInt(_ raw: String?) -> Int? {
            guard let t = nonEmpty(raw) else { return nil }
            if let i = Int(t) { return i }
            if let d = Double(t) { return Int(d.rounded()) }
            return nil
        }

        do {
            let dbPath = try bundleDBPathWithDebug()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Determine table that holds well visits
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
                        }
                    }
                    return cols
                }
                let table = ["well_visits","visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"

                // Fetch the row
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT * FROM \(table) WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW {
                        // Build dictionary of all non-null, non-empty stringified values
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL, let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }

                        // Core measurements
                        if let s = fmtNumber(row["weight_today_kg"], unit: "kg") {
                            out[L("report.well.measurement.weight")] = s
                        }
                        if let s = fmtNumber(row["length_today_cm"], unit: "cm") {
                            out[L("report.well.measurement.length")] = s
                        }
                        if let s = fmtNumber(row["head_circ_today_cm"], unit: "cm") {
                            out[L("report.well.measurement.headCircumference")] = s
                        }

                        // Weight gain since discharge
                        let dW = fmtInt(row["delta_weight_g"])
                        let dD = fmtInt(row["delta_days_since_discharge"])
                        if let dw = dW {
                            let sign = dw > 0 ? "+" : ""
                            let label = L("report.well.measurement.weightGainSinceDischarge")
                            if let dd = dD {
                                out[label] = String(format: L("report.well.measurement.weightGain.value.overDays"), sign, dw, dd)
                            } else {
                                out[label] = String(format: L("report.well.measurement.weightGain.value.simple"), sign, dw)
                            }
                        }
                    }
                }
            }
        } catch {
            // leave empty; builder will skip section if empty
        }
        #if DEBUG
        print("[ReportDataLoader] loadMeasurementsForWellVisit out=\(out)")
        #endif
        return out
    }
}


extension ReportDataLoader {

    /// Resolve the raw internal visit_type ID for a WELL visit from the bundle DB.
    /// This should return canonical IDs such as "one_month", "nine_month", etc.
    /// Returns nil if the row or column cannot be found.
    private func rawVisitTypeIDForWell(visitID: Int) -> String? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Discover which table is used for well visits
                func columns(in table: String) -> Set<String> {
                    var cols = Set<String>()
                    var stmtCols: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK, let s = stmtCols {
                        defer { sqlite3_finalize(s) }
                        while sqlite3_step(s) == SQLITE_ROW {
                            if let c = sqlite3_column_text(s, 1) {
                                cols.insert(String(cString: c))
                            }
                        }
                    }
                    return cols
                }

                let table = ["well_visits", "visits"].first { !columns(in: $0).isEmpty } ?? "well_visits"
                #if DEBUG
                print("[ReportDataLoader] rawVisitTypeIDForWell: using table=\(table)")
                #endif
                let cols = columns(in: table)
                #if DEBUG
                print("[ReportDataLoader] rawVisitTypeIDForWell: columns=\(Array(cols).sorted())")
                #endif
                // If there is no visit_type column, we cannot resolve a canonical ID
                guard cols.contains("visit_type") else { return nil }

                let sql = "SELECT visit_type FROM \(table) WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(visitID))
                    if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                        let raw = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        #if DEBUG
                        print("[ReportDataLoader] rawVisitTypeIDForWell visitID=\(visitID) raw='\(raw)'")
                        #endif
                        return raw.isEmpty ? nil : raw
                    }
                }
            }
        } catch {
            // fall through to nil
        }
        return nil
    }

    /// Returns the resolved WellVisitVisibility for a given WELL visit, using the raw
    /// visit_type from the DB plus the computed age in months.
    /// Returns nil if we cannot determine a canonical visit_type.
    func wellVisitVisibility(visitID: Int) -> WellVisitReportRules.WellVisitVisibility? {
        let age = wellVisitAgeMonths(visitID: visitID)
        let rawVisitTypeID = rawVisitTypeIDForWell(visitID: visitID)
        let visibility = WellVisitReportRules.visibility(for: rawVisitTypeID, ageMonths: age)

        #if DEBUG
        if let vis = visibility {
            let ageStr = age.map { String(format: "%.2f", $0) } ?? "nil"
            let typeStr = rawVisitTypeID ?? "nil"
            print("[ReportDataLoader] wellVisibility visitID=\(visitID) typeID='\(typeStr)' ageMonths=\(ageStr) " +
                  "sections: feed=\(vis.showFeeding) supp=\(vis.showSupplementation) sleep=\(vis.showSleep) dev=\(vis.showDevelopment)")
        } else {
            let ageStr = age.map { String(format: "%.2f", $0) } ?? "nil"
            let typeStr = rawVisitTypeID ?? "nil"
            print("[ReportDataLoader] wellVisibility visitID=\(visitID) typeID='\(typeStr)' ageMonths=\(ageStr) -> nil")
        }
        #endif

        return visibility
    }
    
    /// Convenience: allowed DB column names for this WELL visit,
    /// resolved via the canonical CSV (WellVisitReportRules).
    private func allowedDBColumnsForWellVisit(_ visitID: Int) -> Set<String> {
        let age = wellVisitAgeMonths(visitID: visitID)
        let rawType = rawVisitTypeIDForWell(visitID: visitID)
        let allowed = WellVisitReportRules.allowedDBColumns(for: rawType, ageMonths: age)

        #if DEBUG
        let ageStr = age.map { String(format: "%.2f", $0) } ?? "nil"
        let typeStr = rawType ?? "nil"
        print("[ReportDataLoader] allowedDBColumnsForWellVisit visitID=\(visitID) typeID='\(typeStr)' ageMonths=\(ageStr) -> \(Array(allowed).sorted())")
        #endif

        return allowed
    }
}

extension WellVisitReportRules.WellVisitVisibility {
    /// Section-level visibility used by ReportBuilder for the
    /// "Current Visit — …" block. This is the only place where
    /// age/visit-type gating for current-visit sections lives.
    ///
    /// Contract:
    /// - Perinatal summary, previous well visits, and growth charts
    ///   are never gated here (they are handled elsewhere).
    /// - These booleans only control the *current visit* sections.
    /// - Fine-grained, field-level logic remains in WellVisitReportRules
    ///   (e.g. via the flags and any per-field helpers).

    // MARK: - Subjective / global fields (always relevant)

    /// Parents' concerns are relevant at any age.
    var showParentsConcerns: Bool { true }

    /// Problem listing is always useful when present.
    var showProblemListing: Bool { true }

    /// Conclusions / assessment are always shown for the current visit.
    var showConclusions: Bool { true }

    /// Anticipatory guidance is part of every well visit.
    var showAnticipatoryGuidance: Bool { true }

    /// Free-text clinician comments are always allowed.
    var showClinicianComments: Bool { true }

    /// Planned next visit is always allowed when provided.
    var showNextVisit: Bool { true }

    // MARK: - Feeding & supplementation

    /// Feeding block: shown whenever any age-group defines structured
    /// feeding content (milk only, under-12m structure, solids, older feeding).
    var showFeeding: Bool {
        let f = flags
        return f.isEarlyMilkOnlyVisit
            || f.isStructuredFeedingUnder12
            || f.isSolidsVisit
            || f.isOlderFeedingVisit
    }

    /// Supplementation block: mirrors the broader feeding window; in practice
    /// we show this for any visit where structured feeding is part of the layout.
    var showSupplementation: Bool {
        let f = flags
        return f.isStructuredFeedingUnder12
            || f.isSolidsVisit
            || f.isOlderFeedingVisit
    }

    // MARK: - Sleep

    /// Sleep block: we keep this available for all well visits so that
    /// any recorded sleep details (including very early visits such as
    /// the 1‑month visit) are always rendered in the report. Age‑specific
    /// content is handled by the form/rules rather than by hiding the
    /// entire section.
    var showSleep: Bool { true }

    // MARK: - Development / screening

    /// Developmental screening / tests: reserved for visits where we actually
    /// run Dev tests and/or M-CHAT according to the age matrix.
    var showDevelopment: Bool {
        let f = flags
        return f.isDevTestScoreVisit
            || f.isDevTestResultVisit
            || f.isMCHATVisit
    }

    /// Milestones summary: we keep this enabled for all milestone-based visits;
    /// detailed age-filtering is handled by the milestone engine itself.
    var showMilestones: Bool { true }

    // MARK: - Measurements & physical examination

    /// Measurements (weight/length/head circ, weight delta, etc.) are core
    /// to all well visits and are not age-gated at the section level.
    var showMeasurements: Bool { true }

    /// Physical exam is always present; age-specific details (e.g. fontanelle,
    /// primitive reflexes) are governed by the underlying form/rules, not by
    /// hiding the entire PE block.
    var showPhysicalExam: Bool { true }
}

extension ReportDataLoader {

    /// Build the age-gated, section-ready current visit block for a WELL visit.
    ///
    /// Contract:
    /// - Age/visit-type gating is entirely handled by `loadCurrentWellCoreFields`,
    ///   via `allowedDBColumnsForWellVisit` and the canonical CSV.
    /// - Keys in `feeding`, `supplementation`, and `sleep` are already
    ///   pretty labels expected by ReportBuilder (e.g. "Feeds / 24h").
    /// - ReportBuilder should treat these dictionaries as-is and render
    ///   them in the "Current Visit" section without re-implementing
    ///   any age logic.
    @MainActor
    func buildWellCurrentVisitBlock(visitID: Int) -> WellCurrentVisitBlock {
        let core = loadCurrentWellCoreFields(visitID: visitID)

        return WellCurrentVisitBlock(
            visitTypeSubtitle: core.visitType,
            parentsConcerns: core.parentsConcerns,
            feeding: core.feeding,
            stool: core.stool,
            supplementation: core.supplementation,
            sleep: core.sleep
        )
    }
}

extension ReportDataLoader {

    /// Load a concise vitals summary for a sick episode.
    /// Strategy:
    ///  - Look for a `vitals` table in the current bundle DB.
    ///  - Join by a suitable FK (episode_id / visit_id / encounter_id / sick_episode_id).
    ///  - Take the most recent row for this episode.
    ///  - Build a single human-readable line with all available vitals.
    private func loadVitalsSummaryForEpisode(_ episodeID: Int) -> [String] {
        var out: [String] = []

        func nonEmpty(_ value: String?) -> String? {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }

        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Check that a vitals table exists
                var hasVitals = false
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(
                    db,
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='vitals' LIMIT 1;",
                    -1,
                    &checkStmt,
                    nil
                ) == SQLITE_OK, let st = checkStmt {
                    defer { sqlite3_finalize(st) }
                    hasVitals = (sqlite3_step(st) == SQLITE_ROW)
                }
                if !hasVitals { return out }

                // Discover vitals columns
                var vcols = Set<String>()
                var colsStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(vitals);", -1, &colsStmt, nil) == SQLITE_OK, let s = colsStmt {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let cName = sqlite3_column_text(s, 1) {
                            vcols.insert(String(cString: cName))
                        }
                    }
                }

                // Try common FK candidates
                let fkCandidates = ["episode_id","visit_id","encounter_id","sick_episode_id"]
                guard let fk = fkCandidates.first(where: { vcols.contains($0) }) else {
                    return out
                }

                // Pick available date/timestamp columns in priority order
                let datePriorityCandidates = [
                    "recorded_at",
                    "measured_at",
                    "created_at",
                    "updated_at",
                    "date"
                ]
                let dateCols = datePriorityCandidates.filter { vcols.contains($0) }

                let orderClause: String
                if dateCols.isEmpty {
                    // Fallback: no known date columns, just use id
                    orderClause = "ORDER BY id DESC"
                } else {
                    var caseLines: [String] = []
                    for col in dateCols {
                        caseLines.append("WHEN \(col) IS NOT NULL THEN \(col)")
                    }
                    let caseBody = caseLines.joined(separator: "\n            ")
                    orderClause = """
                    ORDER BY
                        CASE
                            \(caseBody)
                            ELSE id
                        END DESC
                    """
                }

                let sql = """
                SELECT *
                FROM vitals
                WHERE \(fk) = ?
                \(orderClause)
                LIMIT 1;
                """

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(episodeID))

                    if sqlite3_step(st) == SQLITE_ROW {
                        // Build a dictionary of the row
                        var row: [String:String] = [:]
                        let n = sqlite3_column_count(st)
                        for i in 0..<n {
                            guard let cname = sqlite3_column_name(st, i) else { continue }
                            let key = String(cString: cname)
                            if sqlite3_column_type(st, i) != SQLITE_NULL,
                               let cval = sqlite3_column_text(st, i) {
                                let val = String(cString: cval).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !val.isEmpty { row[key] = val }
                            }
                        }

                        func val(_ key: String) -> String? {
                            return nonEmpty(row[key])
                        }

                        var parts: [String] = []

                        // Weight
                        if let w = val("weight_kg") ?? val("wt_kg") ?? val("weight") {
                            let v = w.contains("kg") ? w : "\(w) kg"
                            parts.append(String(format: L("report.vitals.part.weight"), v))
                        }

                        // Length / Height
                        if let l = val("length_cm") ?? val("height_cm") ?? val("stature_cm") ?? val("length") {
                            let v = l.contains("cm") ? l : "\(l) cm"
                            parts.append(String(format: L("report.vitals.part.heightLength"), v))
                        }

                        // Temperature (°C)
                        if let t = val("temp_c") ?? val("temperature_c") ?? val("temperature") ?? val("temp") {
                            let v = "\(t)\u{00A0}°C"
                            parts.append(String(format: L("report.vitals.part.temp"), v))
                        }

                        // Heart rate
                        if let hr = val("heart_rate") ?? val("hr") ?? val("pulse") {
                            let v = "\(hr)\u{00A0}bpm"
                            parts.append(String(format: L("report.vitals.part.hr"), v))
                        }

                        // Respiratory rate
                        if let rr = val("resp_rate") ?? val("rr") ?? val("respiratory_rate") {
                            let v = "\(rr)/min"
                            parts.append(String(format: L("report.vitals.part.rr"), v))
                        }

                        // SpO2
                        if let spo2 = val("spo2") ?? val("SpO2") ?? val("spO2") ?? val("oxygen_saturation") {
                            let v = spo2.contains("%") ? spo2 : "\(spo2)%"
                            parts.append(String(format: L("report.vitals.part.spo2"), v))
                        }

                        // Blood pressure  ✅ now includes bp_systolic / bp_diastolic
                        var bpPieces: [String] = []
                        if let sys = val("bp_systolic") ?? val("bp_sys") ?? val("systolic_bp") ?? val("sbp") {
                            bpPieces.append(sys)
                        }
                        if let dia = val("bp_diastolic") ?? val("bp_dia") ?? val("diastolic_bp") ?? val("dbp") {
                            bpPieces.append(dia)
                        }
                        if !bpPieces.isEmpty {
                            let v = "\(bpPieces.joined(separator: "/")) mmHg"
                            parts.append(String(format: L("report.vitals.part.bp"), v))
                        }

                        // When measured
                        if let when = val("measured_at") ?? val("recorded_at") ?? val("date") {
                            parts.append(String(format: L("report.vitals.part.measured"), when))
                        }

                        if !parts.isEmpty {
                            out.append(parts.joined(separator: " · "))
                        }
                    }
                }
            }
        } catch {
            // On error, just return empty and let the renderer show "—"
        }

        return out
    }
    
}

extension ReportDataLoader {

    /// Resolve patient_id for a sick episode from the bundle DB.
    /// Robust to minor schema variants: tries common tables and patient FK names.
    private func patientIDForSickEpisode(_ episodeID: Int) -> Int64? {
        do {
            let dbPath = try currentBundleDBPath()
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
               let db = db {
                defer { sqlite3_close(db) }

                // Discover tables
                var tables: [String] = []
                var tStmt: OpaquePointer?
                if sqlite3_prepare_v2(db,
                                      "SELECT name FROM sqlite_master WHERE type='table';",
                                      -1,
                                      &tStmt,
                                      nil) == SQLITE_OK,
                   let s = tStmt {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let c = sqlite3_column_text(s, 0) {
                            tables.append(String(cString: c))
                        }
                    }
                }

                // Prefer canonical episodes table but allow a couple of variants
                let candidates = ["episodes", "sick_episodes"]
                guard let table = candidates.first(where: { tables.contains($0) }) else {
                    return nil
                }

                // Columns for chosen table
                var cols = Set<String>()
                var stmtCols: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmtCols, nil) == SQLITE_OK,
                   let s = stmtCols {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        if let cName = sqlite3_column_text(s, 1) {
                            cols.insert(String(cString: cName))
                        }
                    }
                }

                // Patient FK candidates
                guard let patientFK = ["patient_id","patientId","patientID"].first(where: { cols.contains($0) }) else {
                    return nil
                }

                let sql = "SELECT \(patientFK) FROM \(table) WHERE id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                   let st = stmt {
                    defer { sqlite3_finalize(st) }
                    sqlite3_bind_int64(st, 1, Int64(episodeID))
                    if sqlite3_step(st) == SQLITE_ROW,
                       sqlite3_column_type(st, 0) != SQLITE_NULL {
                        return sqlite3_column_int64(st, 0)
                    }
                }
            }
        } catch {
            // fall through
        }
        return nil
    }
}
