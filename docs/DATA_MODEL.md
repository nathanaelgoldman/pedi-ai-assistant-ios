# DATA_MODEL

Authoritative reference for the shared SQLite schema and import/export protocol
used by **PatientViewerApp** and **DrsMainApp**.

> Status: Draft (v1). Owner: @you. Update whenever schema or bundle protocol changes.

---

## 1) Goals & Principles

- **Single source of truth:** Patient data lives in a **portable patient bundle** (outside the doctor app).
- **Atomic bundles:** Everything needed travels together (SQLite + docs + manifests).
- **Forward compatibility:** Versioned schema + migrations.
- **Simple & inspectable:** Plain SQLite; JSON manifests for docs; avoid opaque formats.
- **Unified naming:** `lower_snake_case` for tables/columns; plural table names; foreign keys end in `_id`.

---

## 2) Patient Bundle Layout (on device)
/
├── db.sqlite                 # main data store
├── docs/                     # generated reports & artifacts (PDFs, images)
│   ├── manifest.json         # array of document metadata
│   └── <files…>
├── manifest.json             # top-level bundle metadata (schema version, patient id, alias)
└── README.txt                # optional notes
**Top-level `manifest.json` (contract)**
- `schema_version` (string/semver)  
- `exported_at` (ISO-8601)  
- `patient_id` (int)  
- `patient_alias` (string, e.g., `"Teal Robin 🐦"`)  
- `docs_index` (string; path to `docs/manifest.json`)

**`docs/manifest.json` (contract)**
Array of objects:
```json
{ "id": "UUID-or-stable-id", "filename": "WellVisitReport_31.pdf", "title": "12-month Well Visit", "created_at": "2025-09-15T10:01:28Z", "type": "pdf" }

---

## 3) SQLite Settings

- Always enable foreign keys at connection: `PRAGMA foreign_keys = ON;`
- Store timestamps as **TEXT** in ISO-8601 (`YYYY-MM-DDTHH:MM:SS` in UTC or local time consistently).
- Booleans as **INTEGER** (0/1).
- Enumerations via `CHECK (...)` constraints.
- Run `VACUUM` after large deletes or migrations when appropriate.


## 4) Schema (v1)

> The definitions below mirror the current schema & naming used in both apps.  
> Foreign keys assume `PRAGMA foreign_keys = ON`.

### 4.1 `users`

~~~sql
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  first_name TEXT NOT NULL,
  last_name  TEXT NOT NULL
);
~~~

### 4.2 `patients`

~~~sql
CREATE TABLE IF NOT EXISTS patients (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  first_name TEXT NOT NULL,
  last_name  TEXT NOT NULL,
  dob TEXT NOT NULL,                           -- ISO-8601 date (YYYY-MM-DD)
  sex TEXT CHECK (sex IN ('Male','Female')) NOT NULL,
  mrn TEXT UNIQUE,
  vaccination_status TEXT DEFAULT 'unknown',
  parent_notes TEXT DEFAULT '',

  -- Alias fields kept for parity with iOS viewer
  alias_id INTEGER UNIQUE,
  alias_label TEXT UNIQUE
);
~~~

### 4.3 `episodes`  -- sick/problem-oriented encounters

> Includes representative structured fields + free text blocks.

~~~sql
CREATE TABLE IF NOT EXISTS episodes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER,
  user_id INTEGER,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,

  -- Core
  main_complaint TEXT,
  hpi TEXT,
  duration TEXT,

  -- Structured HPI / ROS (representative)
  appearance TEXT,
  feeding TEXT,
  breathing TEXT,
  activity TEXT,
  urine TEXT,
  stool TEXT,
  hydration TEXT,

  -- Physical exam (representative)
  head TEXT,
  right_eye TEXT,
  left_eye TEXT,
  heart TEXT,
  lungs TEXT,
  abdomen TEXT,
  neurological TEXT,
  musculoskeletal TEXT,

  -- Assessment & Plan (representative)
  problem_listing TEXT,
  complementary_investigations TEXT,
  diagnosis TEXT,
  icd10 TEXT,
  medications TEXT,

  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id)    REFERENCES users(id)    ON DELETE SET NULL
);
~~~

### 4.4 `well_visits`

~~~sql
CREATE TABLE IF NOT EXISTS well_visits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER NOT NULL,
  user_id INTEGER,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,

  -- Structured domains (representative)
  perinatal_summary TEXT,
  nutrition TEXT,
  development TEXT,
  guidance TEXT,
  growth_assessment TEXT,
  vaccines_due TEXT,

  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id)    REFERENCES users(id)    ON DELETE SET NULL
);
~~~

### 4.5 `vaccinations`

~~~sql
CREATE TABLE IF NOT EXISTS vaccinations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER NOT NULL,
  vaccine_name TEXT,
  lot_number TEXT,
  batch_number TEXT,
  dose_number INTEGER,
  site TEXT,
  route TEXT,
  date_administered TEXT,
  admin_by TEXT,
  manufacturer TEXT,

  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
);
~~~

### 4.6 `vitals`

~~~sql
CREATE TABLE IF NOT EXISTS vitals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id  INTEGER NOT NULL,
  recorded_at TEXT NOT NULL,

  weight_kg REAL,
  height_cm REAL,
  head_circ_cm REAL,
  temperature_c REAL,
  heart_rate_bpm INTEGER,
  respiratory_rate_bpm INTEGER,
  spo2_percent INTEGER,

  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
);
~~~

### 4.7 `manual_growth`

~~~sql
CREATE TABLE IF NOT EXISTS manual_growth (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id  INTEGER NOT NULL,
  recorded_at TEXT NOT NULL,

  age_months REAL,
  weight_kg  REAL,
  length_cm  REAL,
  head_circ_cm REAL,

  source TEXT DEFAULT 'manual',
  note   TEXT,

  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
);
~~~

### 4.8 `perinatal_history`

~~~sql
CREATE TABLE IF NOT EXISTS perinatal_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER NOT NULL,

  gestational_age_weeks INTEGER,
  delivery_mode TEXT,              -- e.g., vaginal, c-section
  birth_weight_kg REAL,
  apgar_1min INTEGER,
  apgar_5min INTEGER,
  complications TEXT,
  maternal_history TEXT,

  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
);
~~~

### 4.9 `past_medical_history`

~~~sql
CREATE TABLE IF NOT EXISTS past_medical_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER NOT NULL,

  allergies TEXT,                  -- free text list or JSON array
  surgeries TEXT,
  chronic_conditions TEXT,
  family_history TEXT,
  medications TEXT,

  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
);
~~~

### 4.10 `ai_inputs`

~~~sql
CREATE TABLE IF NOT EXISTS ai_inputs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id  INTEGER NOT NULL,
  created_at  TEXT DEFAULT CURRENT_TIMESTAMP,

  -- minimally structured inputs kept for reproducibility
  prompt TEXT NOT NULL,
  model TEXT,
  temperature REAL,
  top_p REAL,

  -- outputs/trace
  response TEXT,
  token_usage_json TEXT,

  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
);
~~~


## 5) Indices

> Add indices for the hottest read paths.

~~~sql
CREATE INDEX IF NOT EXISTS idx_patients_alias_label      ON patients(alias_label);
CREATE INDEX IF NOT EXISTS idx_vitals_patient_time       ON vitals(patient_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_growth_patient_time       ON manual_growth(patient_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_vaccinations_patient      ON vaccinations(patient_id);
CREATE INDEX IF NOT EXISTS idx_episodes_patient_time     ON episodes(patient_id, created_at);
CREATE INDEX IF NOT EXISTS idx_well_visits_patient_time  ON well_visits(patient_id, created_at);
~~~


## 6) Migrations

- Track `schema_version` in the top-level bundle `manifest.json`.
- Keep one SQL file per bump under `migrations/` (e.g., `migrations/v02__add_ai_inputs.sql`).
- Upgrade flow:
  1. Read `schema_version` from `manifest.json`.
  2. Open `db.sqlite`; `PRAGMA foreign_keys=OFF;`
  3. Apply migrations up to current version.
  4. `PRAGMA foreign_keys=ON;` and optionally `VACUUM;`
  5. Update `manifest.json.schema_version`.


## 7) Import / Export Protocol

**Export (Doctor → Parent)**  
1. Flush in-memory state to disk.  
2. Copy the whole patient bundle directory (layout in section 2).  
3. Rebuild `docs/manifest.json` to include new PDFs/images.  
4. Update top-level `manifest.json` (`exported_at`, `schema_version`).  

**Import (PatientViewerApp)**  
1. Validate top-level `manifest.json`.  
2. Enable FKs; migrate if needed.  
3. Don’t duplicate heavy static assets (WHO curves remain app-side).  


## 8) Naming Conventions

- **Tables:** plural (`patients`, `users`, `well_visits`, `episodes`, `vitals`, `manual_growth`, `vaccinations`, `perinatal_history`, `past_medical_history`, `ai_inputs`)
- **Columns:** `lower_snake_case`; FK columns end in `_id`
- **Dates/times:** TEXT, ISO-8601
- **Booleans:** INTEGER 0/1
- **Enums:** TEXT with `CHECK(...)`
- **Large notes:** TEXT blobs (`parent_notes`, `hpi`, `diagnosis`, …)


## 9) Appendix

- The full field sets for `episodes` and `well_visits` are verbose in live code; treat app code as authoritative and update this doc as those stabilize.
- iOS convenience `'M'/'F'` maps to DB `sex` strings `'Male'/'Female'`.
