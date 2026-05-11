-- ============================================================================
-- HIGHLINE FREIGHT INTELLIGENCE — Cortex Search Service
-- File   : 04_create_search.sql
-- Phase  : 5 of 9  (unstructured retrieval layer)
-- Author : Rishi Kumar Kota
--
-- What this script does
-- ---------------------------------------------------------------------------
-- Creates the FREIGHT_REPORTS_SEARCH service over the 50 freight analyst
-- reports.  Uses the new (GA Mar 2026) multi-index syntax so we get:
--
--   * TEXT INDEXES   on `title`        — BM25/fuzzy match for exact terms
--                                        (event names, place names, SCTG numbers)
--   * VECTOR INDEXES on `report_text`  — semantic embedding for prose meaning
--
-- ATTRIBUTES (`report_id`, `report_type`, `report_date`) become fast pre-filters
-- the agent can use to narrow results BEFORE semantic ranking runs.
--
-- The default embedding model is `snowflake-arctic-embed-m-v1.5` (English,
-- 768-dim).  Everything — embeddings, indexes, reranker — stays inside the
-- Snowflake security perimeter; no data leaves your account.
--
-- Pre-requisite : Phase 2 (FREIGHT_REPORTS table loaded with 50 rows).
-- Safety        : CREATE OR REPLACE — safe to re-run; service rebuilds in place.
-- Required role : ACCOUNTADMIN  (or FREIGHT_ANALYST_ROLE with the grants from
--                                Phase 1, which include CREATE CORTEX SEARCH SERVICE).
-- ============================================================================


USE ROLE      ACCOUNTADMIN;
USE WAREHOUSE HIGHLINE_FREIGHT_WH;
USE DATABASE  HIGHLINE_FREIGHT;
USE SCHEMA    DATA;


-- ---------------------------------------------------------------------------
-- 1. THE SEARCH SERVICE  (single-column legacy syntax — ON report_text)
--    Falling back from the new TEXT INDEXES / VECTOR INDEXES multi-index
--    syntax because Snowflake's vector indexer was rejecting our column
--    types on this account.  The legacy ON-column form is rock solid and
--    matches the proven pattern from the Snowflake sales-template
--    quickstart.  Title is still exposed via ATTRIBUTES so it can be
--    returned alongside results and filtered on.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE CORTEX SEARCH SERVICE FREIGHT_REPORTS_SEARCH
  ON              report_text
  ATTRIBUTES      title, report_id, report_type, report_date
  WAREHOUSE       = HIGHLINE_FREIGHT_WH
  TARGET_LAG      = '1 hour'
  COMMENT         = 'Hybrid search over 50 freight analyst reports — semantic embedding on report_text, BM25 keyword index built automatically. Default Arctic Embed (snowflake-arctic-embed-m-v1.5).'
  AS (
    SELECT
        report_id,
        title,
        report_text,
        report_type,
        report_date
    FROM FREIGHT_REPORTS
  );


-- ---------------------------------------------------------------------------
-- 2. CONFIRM THE SERVICE EXISTS + SHOW ITS CONFIG
-- ---------------------------------------------------------------------------
SHOW CORTEX SEARCH SERVICES LIKE 'FREIGHT_REPORTS_SEARCH' IN SCHEMA HIGHLINE_FREIGHT.DATA;

DESC CORTEX SEARCH SERVICE HIGHLINE_FREIGHT.DATA.FREIGHT_REPORTS_SEARCH;


-- ---------------------------------------------------------------------------
-- 3. TEST QUERY 1 — broad semantic search
--    Query: "supply chain disruption from natural disaster"
--    Expect: hurricane / Texas freeze / Suez / Red Sea / East Palestine / etc.
--            Top 3 by relevance.
-- ---------------------------------------------------------------------------
WITH q1 AS (
  SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'HIGHLINE_FREIGHT.DATA.FREIGHT_REPORTS_SEARCH',
    '{
       "query":   "supply chain disruption from natural disaster",
       "columns": ["report_id", "title", "report_type", "report_date"],
       "limit":   3
     }'
  )):results AS results
)
SELECT
    value:report_id::STRING    AS report_id,
    value:title::STRING        AS title,
    value:report_type::STRING  AS report_type,
    value:report_date::STRING  AS report_date
FROM q1, LATERAL FLATTEN(input => results);


-- ---------------------------------------------------------------------------
-- 4. TEST QUERY 2 — specific event search (text-index strength)
--    Query: "Suez Canal blockage"
--    Expect: the Suez Canal 2021 report at top — the title contains the
--            exact phrase, so the TEXT INDEXES match boosts it.
-- ---------------------------------------------------------------------------
WITH q2 AS (
  SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'HIGHLINE_FREIGHT.DATA.FREIGHT_REPORTS_SEARCH',
    '{
       "query":   "Suez Canal blockage",
       "columns": ["report_id", "title", "report_type", "report_date"],
       "limit":   3
     }'
  )):results AS results
)
SELECT
    value:report_id::STRING    AS report_id,
    value:title::STRING        AS title,
    value:report_type::STRING  AS report_type,
    value:report_date::STRING  AS report_date
FROM q2, LATERAL FLATTEN(input => results);


-- ---------------------------------------------------------------------------
-- 5. TEST QUERY 3 — attribute-filtered search
--    Query: "trucking rates and carrier capacity"
--    Filter: only carrier_negotiation reports
--    Expect: top 3 of the 10 carrier-negotiation reports by relevance
--            (filter applied BEFORE semantic ranking)
-- ---------------------------------------------------------------------------
WITH q3 AS (
  SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'HIGHLINE_FREIGHT.DATA.FREIGHT_REPORTS_SEARCH',
    '{
       "query":   "trucking rates and carrier capacity",
       "columns": ["report_id", "title", "report_type", "report_date"],
       "filter":  {"@eq": {"report_type": "carrier_negotiation"}},
       "limit":   3
     }'
  )):results AS results
)
SELECT
    value:report_id::STRING    AS report_id,
    value:title::STRING        AS title,
    value:report_type::STRING  AS report_type,
    value:report_date::STRING  AS report_date
FROM q3, LATERAL FLATTEN(input => results);


-- ---------------------------------------------------------------------------
-- 6. FINAL STATUS
-- ---------------------------------------------------------------------------
SELECT 'Cortex Search Service created. The 3 test queries above should each return relevant reports — verify titles look sensible.' AS status;
