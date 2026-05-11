-- ============================================================================
-- HIGHLINE FREIGHT INTELLIGENCE — Enriched View
-- File   : 03_create_views.sql
-- Phase  : 3 of 9  (data model layer)
-- Author : Rishi Kumar Kota
--
-- What this script does
-- ---------------------------------------------------------------------------
-- Creates V_FREIGHT_FLOWS_ENRICHED — a single view that LEFT-JOINs the
-- FREIGHT_FLOWS fact table to all 6 lookup tables, exposing BOTH the raw
-- codes (for filtering / debugging) AND human-readable labels (for the
-- semantic model + agent answers).
--
-- This view is the target of:
--   * Cortex Analyst semantic model (Phase 4)
--   * Custom tools that need geographic / commodity / mode context (Phase 7)
--   * Ad-hoc analysis by anyone in FREIGHT_ANALYST_ROLE
--
-- Why a VIEW (not a materialized view, not a denormalized table):
--   * No storage cost — computed at query time
--   * Always fresh — no refresh logic to manage
--   * Snowflake's optimizer handles 6-table joins on 7.8M rows efficiently
--   * We can iterate on the view definition without rebuilding data
--
-- Pre-requisite : Phase 2 (02_load_data.sql) must already be run.
-- Safety        : CREATE OR REPLACE — safe to re-run; replaces the view in place.
-- Required role : ACCOUNTADMIN (or FREIGHT_ANALYST_ROLE with USAGE on schema)
-- ============================================================================


USE ROLE      ACCOUNTADMIN;
USE WAREHOUSE HIGHLINE_FREIGHT_WH;
USE DATABASE  HIGHLINE_FREIGHT;
USE SCHEMA    DATA;


-- ---------------------------------------------------------------------------
-- 1. THE ENRICHED VIEW
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_FREIGHT_FLOWS_ENRICHED
  COMMENT = 'FAF5 freight flows joined to all 6 lookups — exposes human-readable labels alongside raw codes. Target of the Cortex Analyst semantic model.'
AS
SELECT
    -- Raw codes (kept for filtering, debugging, and exact joins)
    ff.fr_orig,
    ff.dms_origst,
    ff.dms_destst,
    ff.fr_dest,
    ff.fr_inmode,
    ff.dms_mode,
    ff.fr_outmode,
    ff.sctg2,
    ff.trade_type,
    ff.dist_band,

    -- Time + measures
    ff.year,
    ff.tons,
    ff.value,
    ff.current_value,
    ff.tmiles,

    -- Human-readable labels (LEFT-joined so NULLs propagate cleanly)
    s_orig.state_name           AS origin_state_name,
    s_dest.state_name           AS destination_state_name,
    fr_o.region_name            AS foreign_origin_name,
    fr_d.region_name            AS foreign_destination_name,
    c.commodity_name            AS commodity_name,
    m_dom.mode_name             AS domestic_mode_name,
    m_in.mode_name              AS in_mode_name,
    m_out.mode_name             AS out_mode_name,
    tt.trade_type_name          AS trade_type_name,
    db.band_label               AS distance_band_label

FROM         FREIGHT_FLOWS          ff
LEFT JOIN    LOOKUP_STATES          s_orig  ON ff.dms_origst = s_orig.state_code
LEFT JOIN    LOOKUP_STATES          s_dest  ON ff.dms_destst = s_dest.state_code
LEFT JOIN    LOOKUP_FOREIGN_REGIONS fr_o    ON ff.fr_orig    = fr_o.region_code
LEFT JOIN    LOOKUP_FOREIGN_REGIONS fr_d    ON ff.fr_dest    = fr_d.region_code
LEFT JOIN    LOOKUP_SCTG            c       ON ff.sctg2      = c.sctg_code
LEFT JOIN    LOOKUP_MODES           m_dom   ON ff.dms_mode   = m_dom.mode_code
LEFT JOIN    LOOKUP_MODES           m_in    ON ff.fr_inmode  = m_in.mode_code
LEFT JOIN    LOOKUP_MODES           m_out   ON ff.fr_outmode = m_out.mode_code
LEFT JOIN    LOOKUP_TRADE_TYPES     tt      ON ff.trade_type = tt.trade_code
LEFT JOIN    LOOKUP_DIST_BANDS      db      ON ff.dist_band  = db.band_code;


-- ---------------------------------------------------------------------------
-- 2. ROW-COUNT VALIDATION (the joins must not multiply or drop rows)
-- ---------------------------------------------------------------------------
SELECT 'V_FREIGHT_FLOWS_ENRICHED' AS view_name,
       COUNT(*)                   AS actual_rows,
       7791945                    AS expected_rows,
       CASE WHEN COUNT(*) = 7791945 THEN '✓' ELSE '✗' END AS match
FROM   V_FREIGHT_FLOWS_ENRICHED;


-- ---------------------------------------------------------------------------
-- 3. DATA QUALITY: any raw codes in the fact table that DIDN'T match a lookup?
--    All counters should be 0.  If any are > 0, there's a lookup we need to fix.
-- ---------------------------------------------------------------------------
SELECT
  SUM(CASE WHEN dms_origst IS NOT NULL AND origin_state_name      IS NULL THEN 1 ELSE 0 END) AS unmatched_origin_state,
  SUM(CASE WHEN dms_destst IS NOT NULL AND destination_state_name IS NULL THEN 1 ELSE 0 END) AS unmatched_dest_state,
  SUM(CASE WHEN fr_orig    IS NOT NULL AND foreign_origin_name    IS NULL THEN 1 ELSE 0 END) AS unmatched_foreign_origin,
  SUM(CASE WHEN fr_dest    IS NOT NULL AND foreign_destination_name IS NULL THEN 1 ELSE 0 END) AS unmatched_foreign_dest,
  SUM(CASE WHEN sctg2      IS NOT NULL AND commodity_name         IS NULL THEN 1 ELSE 0 END) AS unmatched_sctg,
  SUM(CASE WHEN dms_mode   IS NOT NULL AND domestic_mode_name     IS NULL THEN 1 ELSE 0 END) AS unmatched_dms_mode,
  SUM(CASE WHEN fr_inmode  IS NOT NULL AND in_mode_name           IS NULL THEN 1 ELSE 0 END) AS unmatched_in_mode,
  SUM(CASE WHEN fr_outmode IS NOT NULL AND out_mode_name          IS NULL THEN 1 ELSE 0 END) AS unmatched_out_mode,
  SUM(CASE WHEN trade_type IS NOT NULL AND trade_type_name        IS NULL THEN 1 ELSE 0 END) AS unmatched_trade_type,
  SUM(CASE WHEN dist_band  IS NOT NULL AND distance_band_label    IS NULL THEN 1 ELSE 0 END) AS unmatched_dist_band
FROM V_FREIGHT_FLOWS_ENRICHED;


-- ---------------------------------------------------------------------------
-- 4. SANITY CHECK: trade-type distribution by year
--    Expect 3 rows per year (Domestic, Import, Export) × 7 years = 21 rows.
-- ---------------------------------------------------------------------------
SELECT trade_type_name, year, COUNT(*) AS row_count
FROM V_FREIGHT_FLOWS_ENRICHED
GROUP BY trade_type_name, year
ORDER BY year, trade_type_name;


-- ---------------------------------------------------------------------------
-- 5. INTERESTING QUERY: top 10 commodities by total value in 2024
--    Smoke test that the enriched labels work and aggregations are correct.
-- ---------------------------------------------------------------------------
SELECT
    commodity_name,
    ROUND(SUM(value), 0)         AS total_value_million_usd_2017,
    ROUND(SUM(current_value), 0) AS total_value_million_usd_current,
    ROUND(SUM(tons), 0)          AS total_thousand_tons
FROM V_FREIGHT_FLOWS_ENRICHED
WHERE year = 2024
GROUP BY commodity_name
ORDER BY total_value_million_usd_2017 DESC
LIMIT 10;


-- ---------------------------------------------------------------------------
-- 6. FINAL STATUS
-- ---------------------------------------------------------------------------
SELECT 'Enriched view created. Verify ✓ row count, all unmatched=0, and the spot-check rows above.' AS status;
