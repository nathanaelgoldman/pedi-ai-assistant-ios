-- SNOMED subset SQLite schema (tools/snomed_builder/snomed_schema.sql)
-- Schema version: 1.0

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- -------------------------
-- META
-- -------------------------
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- -------------------------
-- CONCEPT
-- -------------------------
CREATE TABLE IF NOT EXISTS concept (
  concept_id            INTEGER PRIMARY KEY,
  active                INTEGER NOT NULL,
  effective_time        TEXT    NOT NULL,
  module_id             INTEGER NOT NULL,
  definition_status_id  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_concept_active ON concept(active);

-- -------------------------
-- DESCRIPTION
-- -------------------------
CREATE TABLE IF NOT EXISTS description (
  description_id        INTEGER PRIMARY KEY,
  concept_id            INTEGER NOT NULL,
  active                INTEGER NOT NULL,
  effective_time        TEXT    NOT NULL,
  module_id             INTEGER NOT NULL,
  language_code         TEXT    NOT NULL,
  type_id               INTEGER NOT NULL,
  term                  TEXT    NOT NULL,
  case_significance_id  INTEGER NOT NULL,
  FOREIGN KEY(concept_id) REFERENCES concept(concept_id)
);

CREATE INDEX IF NOT EXISTS idx_description_concept ON description(concept_id);
CREATE INDEX IF NOT EXISTS idx_description_active  ON description(active);
CREATE INDEX IF NOT EXISTS idx_description_term    ON description(term);

-- -------------------------
-- LANG REFSET
-- -------------------------
CREATE TABLE IF NOT EXISTS langrefset (
  langrefset_id            INTEGER PRIMARY KEY,
  active                   INTEGER NOT NULL,
  effective_time           TEXT    NOT NULL,
  module_id                INTEGER NOT NULL,
  refset_id                INTEGER NOT NULL,
  referenced_component_id  INTEGER NOT NULL,
  acceptability_id         INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_langrefset_refcomp ON langrefset(referenced_component_id);
CREATE INDEX IF NOT EXISTS idx_langrefset_refset  ON langrefset(refset_id);
CREATE INDEX IF NOT EXISTS idx_langrefset_active  ON langrefset(active);

-- -------------------------
-- IS-A EDGES (concept hierarchy)
-- -------------------------
-- Relationship typeId = 116680003 (Is a)
-- parent_concept_id = destinationId
-- child_concept_id  = sourceId
--
-- NOTE:
-- The runtime needs only the hierarchy graph for subsumption queries.
-- We store a minimal edge list (active-only edges are filtered by the builder).
CREATE TABLE IF NOT EXISTS isa_edge (
  child_concept_id  INTEGER NOT NULL,
  parent_concept_id INTEGER NOT NULL,
  PRIMARY KEY(child_concept_id, parent_concept_id)
);

CREATE INDEX IF NOT EXISTS idx_isa_edge_parent ON isa_edge(parent_concept_id);
CREATE INDEX IF NOT EXISTS idx_isa_edge_child  ON isa_edge(child_concept_id);

-- -------------------------
-- Token/feature key → SNOMED concept mapping (app-side bridge)
-- -------------------------
CREATE TABLE IF NOT EXISTS feature_snomed_map (
  feature_key TEXT PRIMARY KEY,
  concept_id  INTEGER NOT NULL,
  active      INTEGER NOT NULL DEFAULT 1,
  note        TEXT,
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_feature_snomed_map_concept
  ON feature_snomed_map(concept_id);
