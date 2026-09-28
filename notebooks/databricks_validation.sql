-- ============================================================================
-- Tuva Demo Validation — Databricks version
--
-- Mirrors notebooks/validation.ipynb (which runs against local DuckDB) so the
-- same checks can be run directly against Databricks once the warehouse is
-- responsive. Paste sections into the Databricks SQL editor, or run individual
-- queries via:
--   dbt show --inline "<query>" --target dev --output json
--
-- Catalog is qualified as `workspace.` throughout to match ~/.dbt/profiles.yml.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- STEP 0 — build the DQI layer first. It doesn't exist on Databricks yet;
-- everything else below already does (built earlier this session).
-- Run this from the demo project root, not in the SQL editor:
--
--   source ~/dbt-env/bin/activate
--   dbt build --select data_quality --target dev --vars '{enable_input_layer_testing: true}'
--
-- Confirmed safe earlier via `dbt list --vars` dry-run: compiles cleanly, adds
-- ~1 table. (enable_legacy_data_quality is NOT included here — it hard-fails
-- on a dependency on the disabled chronic_conditions mart.)
-- ----------------------------------------------------------------------------


-- ----------------------------------------------------------------------------
-- SECTION 1 — build & test summary
-- No SQL equivalent: this comes from dbt's own run output / run_results.json
-- after the `dbt build` above. Look for "Done. PASS=x WARN=y ERROR=z SKIP=w"
-- in the console output, and treat any ERROR as a real problem, WARN as
-- (usually) an expected soft check -- e.g. Tuva ships allowed_amount
-- completeness checks at warn severity by design.
-- ----------------------------------------------------------------------------


-- ----------------------------------------------------------------------------
-- SECTION 2 — DQI input-layer data quality summary
-- data_quality__data_quality_for_pbi buckets every checked field into
-- valid / invalid / null per table+field.
-- ----------------------------------------------------------------------------

-- Worst 20 by % valid (sorted ascending -- worth a look, not necessarily a
-- problem; some fields are legitimately sparse in this synthetic dataset)
SELECT
    table_name,
    field_name,
    SUM(CASE WHEN bucket_name = 'valid' THEN frequency ELSE 0 END) AS valid_n,
    SUM(CASE WHEN bucket_name = 'invalid' THEN frequency ELSE 0 END) AS invalid_n,
    SUM(CASE WHEN bucket_name = 'null' THEN frequency ELSE 0 END) AS null_n,
    SUM(frequency) AS total_n,
    ROUND(SUM(CASE WHEN bucket_name = 'valid' THEN frequency ELSE 0 END) * 100.0
        / NULLIF(SUM(frequency), 0), 1) AS pct_valid
FROM workspace.data_quality.data_quality_for_pbi
GROUP BY table_name, field_name
ORDER BY pct_valid ASC
LIMIT 20;

-- Fields that are majority-invalid (not just null) -- the ones actually worth
-- investigating. On DuckDB this flagged MEDICAL_CLAIM.HCPCS_CODE (77.1%
-- invalid), PHARMACY_CLAIM.DISPENSING_DATE/PAID_DATE (45.5%),
-- MEDICAL_CLAIM.CLAIM_START_DATE/CLAIM_END_DATE (21.2%), and a few others --
-- expect the same here since it's the same underlying data.
SELECT
    table_name,
    field_name,
    SUM(CASE WHEN bucket_name = 'invalid' THEN frequency ELSE 0 END) AS invalid_n,
    SUM(frequency) AS total_n,
    ROUND(SUM(CASE WHEN bucket_name = 'invalid' THEN frequency ELSE 0 END) * 100.0
        / NULLIF(SUM(frequency), 0), 1) AS pct_invalid
FROM workspace.data_quality.data_quality_for_pbi
GROUP BY table_name, field_name
HAVING SUM(CASE WHEN bucket_name = 'invalid' THEN frequency ELSE 0 END) * 100.0
    / NULLIF(SUM(frequency), 0) > 5
ORDER BY pct_invalid DESC;


-- ----------------------------------------------------------------------------
-- SECTION 3 — business-logic sanity checks
-- ----------------------------------------------------------------------------

-- Core layer volumes. Expect: patients > 0, encounters > 0, medical_claim =
-- 167,995 (matches the seed exactly on both DuckDB and Databricks so far),
-- and encounters well under medical_claim count (claims compress into fewer
-- encounters).
SELECT
    (SELECT COUNT(*) FROM workspace.core.patient) AS n_patients,
    (SELECT COUNT(*) FROM workspace.core.encounter) AS n_encounters,
    (SELECT COUNT(*) FROM workspace.core.medical_claim) AS n_medical_claims;

-- Readmissions: all-cause 30-day rate. readmission_summary is one row per
-- qualifying index encounter; index_admission_flag marks index stays,
-- readmit_30_flag marks whether that encounter's *next* encounter for the
-- same person was <=30 days later. Expect a rate in a plausible 0-40% band
-- (DuckDB showed 6.8%; Databricks showed 198 summary rows vs DuckDB's 201 --
-- a small known discrepancy, everything else matched exactly).
SELECT
    COUNT(*) AS n_summary_rows,
    SUM(index_admission_flag) AS index_admissions,
    SUM(CASE WHEN index_admission_flag = 1 THEN readmit_30_flag ELSE 0 END) AS readmissions_30d,
    SUM(CASE WHEN index_admission_flag = 1 THEN readmit_30_flag ELSE 0 END) * 100.0
        / NULLIF(SUM(index_admission_flag), 0) AS readmission_rate_pct
FROM workspace.readmissions.readmission_summary;

-- CCSR: every mapped condition should trace back to a real CCSR category.
-- Expect n_rows = 229,634 (matched exactly between DuckDB and Databricks
-- already) and null_categories = 0.
SELECT
    COUNT(*) AS n_rows,
    COUNT(DISTINCT ccsr_category) AS n_categories,
    SUM(CASE WHEN ccsr_category IS NULL THEN 1 ELSE 0 END) AS null_categories
FROM workspace.ccsr.long_condition_category;

-- Provider attribution: what share of patients actually got attributed?
-- Expect > 50% coverage (DuckDB: 974/1000 = 97.4%); low coverage would
-- suggest a join/logic problem rather than being an outright error.
SELECT
    (SELECT COUNT(DISTINCT person_id) FROM workspace.tuva_provider_attribution.assigned_beneficiaries_current) AS attributed_patients,
    (SELECT COUNT(*) FROM workspace.core.patient) AS total_patients,
    (SELECT COUNT(DISTINCT person_id) FROM workspace.tuva_provider_attribution.assigned_beneficiaries_current) * 100.0
        / NULLIF((SELECT COUNT(*) FROM workspace.core.patient), 0) AS coverage_pct;

-- AHRQ PQI: pqi_summary is qualifying-encounter detail (expect n > 0, matched
-- exactly at 32 rows already); pqi_rate has the actual computed rates
-- (expect all non-negative, no zero denominators).
SELECT COUNT(*) AS n FROM workspace.ahrq_measures.pqi_summary;

SELECT
    pqi_number,
    denom_count,
    num_count,
    rate_per_100_thousand
FROM workspace.ahrq_measures.pqi_rate
ORDER BY pqi_number;

-- Sanity flags on pqi_rate (should return zero rows both times)
SELECT * FROM workspace.ahrq_measures.pqi_rate WHERE rate_per_100_thousand < 0;
SELECT * FROM workspace.ahrq_measures.pqi_rate WHERE denom_count <= 0;


-- ----------------------------------------------------------------------------
-- SECTION 4 — one-shot cross-check against the DuckDB reference numbers
-- Run this and compare each row's n to the value in the comment.
-- ----------------------------------------------------------------------------

SELECT 'core.encounter' AS tbl, COUNT(*) AS n FROM workspace.core.encounter                                          -- expect 54080
UNION ALL SELECT 'readmissions.readmission_summary', COUNT(*) FROM workspace.readmissions.readmission_summary        -- expect ~198-201
UNION ALL SELECT 'ccsr.long_condition_category', COUNT(*) FROM workspace.ccsr.long_condition_category                -- expect 229634
UNION ALL SELECT 'tuva_provider_attribution.assigned_beneficiaries_current', COUNT(*) FROM workspace.tuva_provider_attribution.assigned_beneficiaries_current  -- expect 974
UNION ALL SELECT 'ahrq_measures.pqi_summary', COUNT(*) FROM workspace.ahrq_measures.pqi_summary;                     -- expect 32
