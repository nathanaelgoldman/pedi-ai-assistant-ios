-- SNOMED subset SQLite schema (matches tools/snomed_builder/sqlite_writer.py)
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