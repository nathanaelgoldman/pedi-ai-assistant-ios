PRAGMA foreign_keys=ON;
PRAGMA journal_mode=WAL;
PRAGMA user_version=1;

-- ========== TABLES ==========

CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  first_name TEXT NOT NULL,
  last_name  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS patients (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  first_name TEXT NOT NULL,
  last_name  TEXT NOT NULL,
  dob        TEXT NOT NULL,
  sex        TEXT NOT NULL,
  mrn        TEXT UNIQUE NOT NULL,
  vaccination_status TEXT,
  parent_notes       TEXT,
  alias_id    TEXT,
  alias_label TEXT
);

CREATE TABLE IF NOT EXISTS perinatal_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER UNIQUE,
  pregnancy_risk TEXT,
  birth_mode TEXT,
  birth_term_weeks INTEGER,
  resuscitation TEXT,
  nicu_stay INTEGER,
  infection_risk TEXT,
  birth_weight_g INTEGER,
  birth_length_cm REAL,
  birth_head_circumference_cm REAL,
  maternity_stay_events TEXT,
  maternity_vaccinations TEXT,
  vitamin_k INTEGER,
  feeding_in_maternity TEXT,
  passed_meconium_24h INTEGER,
  urination_24h INTEGER,
  heart_screening TEXT,
  metabolic_screening TEXT,
  hearing_screening TEXT,
  mother_vaccinations TEXT,
  family_vaccinations TEXT,
  maternity_discharge_date TEXT,
  discharge_weight_g INTEGER,
  illnesses_after_birth TEXT,
  updated_at TEXT,
  evolution_since_maternity TEXT,
  FOREIGN KEY (patient_id) REFERENCES patients(id)
);

CREATE TABLE IF NOT EXISTS past_medical_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER,
  asthma INTEGER,
  otitis INTEGER,
  uti INTEGER,
  allergies INTEGER,
  other TEXT,
  allergy_details TEXT,
  updated_at TEXT,
  FOREIGN KEY (patient_id) REFERENCES patients(id)
);

CREATE TABLE IF NOT EXISTS vaccinations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER,
  file_name TEXT,
  file_path TEXT,
  uploaded_at TEXT,
  FOREIGN KEY (patient_id) REFERENCES patients(id)
);

CREATE TABLE IF NOT EXISTS episodes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER,
  user_id INTEGER,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,

  -- Episode Core
  main_complaint TEXT,
  hpi TEXT,
  duration TEXT,

  -- Structured HPI
  appearance TEXT,
  feeding TEXT,
  breathing TEXT,
  urination TEXT,
  pain TEXT,
  stools TEXT,
  context TEXT,

  -- Physical Exam
  general_appearance TEXT,
  hydration TEXT,
  color TEXT,
  skin TEXT,
  ent TEXT,
  right_ear TEXT,
  left_ear TEXT,
  right_eye TEXT,
  left_eye TEXT,
  heart TEXT,
  lungs TEXT,
  abdomen TEXT,
  peristalsis TEXT,
  genitalia TEXT,
  neurological TEXT,
  musculoskeletal TEXT,
  lymph_nodes TEXT,

  problem_listing TEXT,
  complementary_investigations TEXT,
  diagnosis TEXT,
  icd10 TEXT,
  medications TEXT,
  anticipatory_guidance TEXT,
  comments TEXT,

  -- AI & Coding (kept as in your schema)
  ai_notes TEXT,
  weight_today_kg TEXT,
  working_diagnosis TEXT,
  tests_results TEXT,
  auto_summary TEXT,
  pe_abd_mass INTEGER,
  pe_breathing_normal INTEGER,
  pe_color TEXT,
  pe_femoral_pulses_comment TEXT,
  pe_femoral_pulses_normal INTEGER,
  pe_follows_midline_comment TEXT,
  pe_follows_midline_normal INTEGER,
  pe_fontanelle_comment TEXT,
  pe_fontanelle_normal INTEGER,
  pe_genitalia TEXT,
  pe_hands_fist_comment TEXT,
  pe_hands_fist_normal INTEGER,
  pe_heart_sounds_comment TEXT,
  pe_heart_sounds_normal INTEGER,
  pe_hips_comment TEXT,
  pe_hips_normal INTEGER,
  pe_hydration_comment TEXT,
  pe_hydration_normal INTEGER,
  pe_liver_spleen_comment TEXT,
  pe_liver_spleen_normal INTEGER,
  pe_moro_comment INTEGER,
  pe_moro_normal INTEGER,
  pe_ocular_motility_comment TEXT,
  pe_ocular_motility_normal INTEGER,
  pe_pupils_rr_comment TEXT,
  pe_pupils_rr_normal INTEGER,
  pe_skin_integrity_comment TEXT,
  pe_skin_integrity_normal INTEGER,
  pe_skin_marks_comment TEXT,
  pe_skin_marks_normal INTEGER,
  pe_skin_rash_comment TEXT,
  pe_skin_rash_normal INTEGER,
  pe_spine_comment TEXT,
  pe_spine_normal INTEGER,
  pe_symmetry_comment TEXT,
  pe_symmetry_normal INTEGER,
  pe_teeth_comment TEXT,
  pe_teeth_count INTEGER,
  pe_teeth_present INTEGER,
  pe_testicles_descended INTEGER,
  pe_tone_normal INTEGER,
  pe_trophic_comment TEXT,
  pe_trophic_normal INTEGER,
  pe_umbilic_comment TEXT,
  pe_umbilic_normal INTEGER,
  pe_wakefulness_normal INTEGER,
  feeding_type TEXT,
  feeding_bottle TEXT,
  feeding_comment TEXT,
  milk_types TEXT,
  feed_freq_per_24h INTEGER,
  regurgitation INTEGER,
  updated_at TEXT,

  FOREIGN KEY (patient_id) REFERENCES patients(id),
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS vitals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER,
  episode_id INTEGER,
  weight_kg REAL,
  height_cm REAL,
  head_circumference_cm REAL,
  temperature_c REAL,
  heart_rate INTEGER,
  respiratory_rate INTEGER,
  spo2 INTEGER,
  recorded_at TEXT DEFAULT CURRENT_TIMESTAMP,
  bp_systolic INTEGER,
  bp_diastolic INTEGER,
  FOREIGN KEY (patient_id) REFERENCES patients(id),
  FOREIGN KEY (episode_id) REFERENCES episodes(id)
);

CREATE TABLE IF NOT EXISTS manual_growth (
  id INTEGER PRIMARY KEY,
  patient_id INTEGER NOT NULL,
  recorded_at TEXT NOT NULL,  -- ISO date or datetime
  weight_kg REAL,
  height_cm REAL,
  head_circumference_cm REAL,
  source TEXT DEFAULT 'manual',
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS well_visits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER,
  user_id INTEGER,
  visit_date TEXT DEFAULT CURRENT_TIMESTAMP,
  visit_type TEXT,
  age_days INTEGER,

  -- Feeding / sleep (first visit subset)
  poop_status TEXT,
  poop_comment TEXT,
  vitamin_d INTEGER,
  milk_types TEXT,
  expressed_bm INTEGER,
  feed_volume_ml REAL,
  feed_freq_per_24h INTEGER,
  est_total_ml REAL,
  est_ml_per_kg_24h REAL,
  regurgitation INTEGER,
  feeding_issue TEXT,
  longer_sleep_night INTEGER,
  wakes_for_feeds INTEGER,
  sleep_issue TEXT,

  -- Early behavior checks
  cries_with_discomfort INTEGER,
  calms_with_voice INTEGER,
  startles_to_loud INTEGER,
  lifts_chin_chest_prone INTEGER,
  other_concerns TEXT,

  -- Physical exam (normal flags + comments)
  pe_trophic_normal INTEGER,
  pe_trophic_comment TEXT,
  pe_hydration_normal INTEGER,
  pe_hydration_comment TEXT,
  pe_color TEXT,
  pe_color_comment TEXT,
  pe_tone_normal INTEGER,
  pe_tone_comment TEXT,
  pe_breathing_normal INTEGER,
  pe_breathing_comment TEXT,
  pe_wakefulness_normal INTEGER,
  pe_wakefulness_comment TEXT,

  pe_fontanelle_normal INTEGER,
  pe_fontanelle_comment TEXT,
  pe_pupils_rr_normal INTEGER,
  pe_pupils_rr_comment TEXT,
  pe_ocular_motility_normal INTEGER,
  pe_ocular_motility_comment TEXT,

  pe_heart_sounds_normal INTEGER,
  pe_heart_sounds_comment TEXT,

  pe_abd_mass INTEGER,
  pe_genitalia TEXT,
  pe_femoral_pulses_normal INTEGER,
  pe_femoral_pulses_comment TEXT,
  pe_liver_spleen_normal INTEGER,
  pe_liver_spleen_comment TEXT,
  pe_umbilic_normal INTEGER,
  pe_umbilic_comment TEXT,

  pe_spine_normal INTEGER,
  pe_spine_comment TEXT,
  pe_hips_normal INTEGER,
  pe_hips_comment TEXT,

  pe_skin_marks_normal INTEGER,
  pe_skin_marks_comment TEXT,
  pe_skin_integrity_normal INTEGER,
  pe_skin_integrity_comment TEXT,
  pe_skin_rash_normal INTEGER,
  pe_skin_rash_comment TEXT,

  pe_moro_normal INTEGER,
  pe_moro_comment TEXT,
  pe_hands_fist_normal INTEGER,
  pe_hands_fist_comment TEXT,
  pe_symmetry_normal INTEGER,
  pe_symmetry_comment TEXT,
  pe_follows_midline_normal INTEGER,
  pe_follows_midline_comment TEXT,

  lab_text TEXT,

  -- Snapshot for history
  problem_listing TEXT,
  problem_listing_tokens TEXT NOT NULL DEFAULT '[]',
  conclusions TEXT,
  anticipatory_guidance TEXT,
  next_visit_date TEXT,
  comments TEXT,

  created_at TEXT,
  updated_at TEXT,
  pe_testicles_descended INTEGER,
  solid_food_started INTEGER DEFAULT 0,
  solid_food_start_date TEXT,
  solid_food_quality TEXT,
  solid_food_comment TEXT,
  pe_teeth_present INTEGER,
  pe_teeth_count INTEGER,
  pe_teeth_comment TEXT,
  weight_today_g INTEGER,
  food_variety_quality TEXT,
  dairy_amount_text TEXT,
  feeding_comment TEXT,
  sleep_hours_text TEXT,
  sleep_regular TEXT,
  sleep_snoring INTEGER,
  mchat_score INTEGER,
  mchat_result TEXT,
  devtest_score INTEGER,
  devtest_result TEXT,
  parent_concerns TEXT,
  sleep_issue_reported INTEGER DEFAULT 0,
  sleep_issue_text TEXT,
  parents_concerns TEXT,
  issues_since_last TEXT,
  weight_today_kg REAL,
  length_today_cm REAL,
  head_circ_today_cm REAL,
  bp_systolic INTEGER,
  bp_diastolic INTEGER,
  episode_id INTEGER,
  vitamin_d_given INTEGER DEFAULT NULL,
  delta_weight_g INTEGER,
  delta_days_since_discharge INTEGER,

  FOREIGN KEY (patient_id) REFERENCES patients(id),
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS well_visit_milestones (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id INTEGER NOT NULL,
  code  TEXT NOT NULL,
  label TEXT NOT NULL,
  status TEXT NOT NULL,  -- 'achieved', 'not yet', 'uncertain'
  note TEXT,
  updated_at TEXT,
  UNIQUE(visit_id, code),
  FOREIGN KEY (visit_id) REFERENCES well_visits(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ai_inputs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  episode_id INTEGER,
  model TEXT,
  prompt TEXT,
  response TEXT,
  created_at TEXT,
  FOREIGN KEY (episode_id) REFERENCES episodes(id)
);


CREATE TABLE IF NOT EXISTS well_ai_inputs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  well_visit_id INTEGER,
  model TEXT,
  prompt TEXT,
  response TEXT,
  created_at TEXT,
  FOREIGN KEY (well_visit_id) REFERENCES well_visits(id)
);

CREATE TABLE IF NOT EXISTS visit_addenda (
  id INTEGER PRIMARY KEY AUTOINCREMENT,

  -- Exactly one of these must be set.
  episode_id INTEGER,
  well_visit_id INTEGER,

  -- Optional author (single-user app can leave NULL)
  user_id INTEGER,

  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT,
  addendum_text TEXT NOT NULL,

  CHECK (
    (episode_id IS NOT NULL AND well_visit_id IS NULL) OR
    (episode_id IS NULL AND well_visit_id IS NOT NULL)
  ),

  FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE CASCADE,
  FOREIGN KEY (well_visit_id) REFERENCES well_visits(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

-- ========== INDEXES (optional but helpful) ==========

CREATE INDEX IF NOT EXISTS idx_patients_mrn ON patients(mrn);
CREATE INDEX IF NOT EXISTS idx_vitals_patient_time ON vitals(patient_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_episodes_patient ON episodes(patient_id);

CREATE INDEX IF NOT EXISTS idx_well_visits_patient ON well_visits(patient_id);
CREATE INDEX IF NOT EXISTS idx_visit_addenda_episode ON visit_addenda(episode_id, created_at);
CREATE INDEX IF NOT EXISTS idx_visit_addenda_well_visit ON visit_addenda(well_visit_id, created_at);

-- ========== TRIGGERS (growth mirroring from vitals) ==========
-- IMPORTANT: Do NOT mirror vitals into manual_growth.
-- Keep DROP statements to remove any legacy triggers in existing DBs.

DROP TRIGGER IF EXISTS vitals_to_manual_growth_ai;
DROP TRIGGER IF EXISTS vitals_to_manual_growth_au;

-- ========== VIEW (unified growth) ==========

CREATE VIEW IF NOT EXISTS growth_unified AS
SELECT
  mg.id                    AS id,
  mg.patient_id            AS patient_id,
  NULL                     AS episode_id,
  mg.recorded_at           AS recorded_at,
  mg.weight_kg             AS weight_kg,
  mg.height_cm             AS height_cm,
  mg.head_circumference_cm AS head_circumference_cm,
  COALESCE(mg.source,'manual') AS source
FROM manual_growth mg

UNION ALL

SELECT
  p.id + 2000000           AS id,
  p.id                     AS patient_id,
  NULL                     AS episode_id,
  COALESCE(p.dob, '')      AS recorded_at,
  per.birth_weight_g/1000.0      AS weight_kg,
  per.birth_length_cm            AS height_cm,
  per.birth_head_circumference_cm AS head_circumference_cm,
  'birth'                  AS source
FROM perinatal_history per
JOIN patients p ON p.id = per.patient_id

UNION ALL

SELECT
  p.id + 3000000           AS id,
  p.id                     AS patient_id,
  NULL                     AS episode_id,
  per.maternity_discharge_date AS recorded_at,
  per.discharge_weight_g/1000.0 AS weight_kg,
  NULL                     AS height_cm,
  NULL                     AS head_circumference_cm,
  'discharge'              AS source
FROM perinatal_history per
JOIN patients p ON p.id = per.patient_id
WHERE per.maternity_discharge_date IS NOT NULL;

-- keep user_version at 1 for now (migrations will bump it)
PRAGMA user_version=1;
