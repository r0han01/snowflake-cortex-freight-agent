-- ============================================================================
-- HIGHLINE FREIGHT INTELLIGENCE — Data Ingestion
-- File   : 02_load_data.sql
-- Phase  : 2 of 9  (data ingestion)
-- Author : Rishi Kumar Kota
--
-- Pre-requisite: Phase 1 (01_setup_infra.sql) already executed AND 8 files
-- uploaded to the @HIGHLINE_FREIGHT.DATA.DATA_STAGE internal stage:
--
--   1.  FAF5.7.1_State_2018-2024_long.parquet  (181 MB,  7,791,945 rows)
--   2.  freight_analyst_reports.csv             ( 65 KB,        50 rows)
--   3.  lookup_states.csv                       ( ~1 KB,        51 rows)
--   4.  lookup_sctg.csv                         ( ~1 KB,        42 rows)
--   5.  lookup_modes.csv                        ( ~1 KB,         8 rows)
--   6.  lookup_trade_types.csv                  ( ~1 KB,         3 rows)
--   7.  lookup_dist_bands.csv                   ( ~1 KB,         8 rows)
--   8.  lookup_foreign_regions.csv              ( ~1 KB,         8 rows)
--
-- What this script does
-- ---------------------------------------------------------------------------
--   1. Creates 2 reusable file formats (CSV, Parquet)
--   2. Creates 8 tables (1 fact, 1 reports, 6 lookups) with proper schemas
--   3. COPY INTO each table from the stage with strict error handling
--   4. Runs row-count + measure-total validation against expected baselines
--
-- Safety
-- ---------------------------------------------------------------------------
--   * Tables use CREATE OR REPLACE — re-running the script wipes & reloads
--     cleanly (no duplicate rows, no stale data).
--   * ON_ERROR = ABORT_STATEMENT — the very first bad row halts the load
--     so we never end up with a half-loaded table.
--   * Required role: ACCOUNTADMIN (or FREIGHT_ANALYST_ROLE with proper grants).
-- ============================================================================


USE ROLE      ACCOUNTADMIN;
USE WAREHOUSE HIGHLINE_FREIGHT_WH;
USE DATABASE  HIGHLINE_FREIGHT;
USE SCHEMA    DATA;


-- ---------------------------------------------------------------------------
-- 0. SANITY CHECK — list all files in the stage
--    Expect to see 8 files. If not, upload before continuing.
-- ---------------------------------------------------------------------------
LIST @DATA_STAGE;


-- ---------------------------------------------------------------------------
-- 1. FILE FORMATS  (reusable across COPY INTO statements)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT FF_CSV_STANDARD
  TYPE                          = CSV
  PARSE_HEADER                  = TRUE   -- read first row as column names (required for MATCH_BY_COLUMN_NAME)
  FIELD_OPTIONALLY_ENCLOSED_BY  = '"'
  EMPTY_FIELD_AS_NULL           = TRUE
  NULL_IF                       = ('', 'NULL')
  TRIM_SPACE                    = TRUE
  COMMENT = 'Standard CSV: PARSE_HEADER=TRUE so COPY INTO can match by column name';

CREATE OR REPLACE FILE FORMAT FF_PARQUET
  TYPE = PARQUET
  COMMENT = 'Parquet load for the FAF5 long-format fact table';


-- ---------------------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------------------

-- 2a. Fact table — FAF5 freight flows (long format, 2018-2024)
CREATE OR REPLACE TABLE FREIGHT_FLOWS (
    fr_orig          VARCHAR(10),  -- foreign origin region code (NULL for domestic)
    dms_origst       VARCHAR(10),  -- US state FIPS code (origin)
    dms_destst       VARCHAR(10),  -- US state FIPS code (destination)
    fr_dest          VARCHAR(10),  -- foreign destination region code (NULL for domestic)
    fr_inmode        VARCHAR(10),  -- mode foreign region → US entry (NULL for domestic)
    dms_mode         VARCHAR(10),  -- domestic mode (1=Truck, 2=Rail, ...)
    fr_outmode       VARCHAR(10),  -- mode US exit → foreign region (NULL for domestic)
    sctg2            VARCHAR(10),  -- 2-digit commodity code (01..43, no 42)
    trade_type       VARCHAR(10),  -- 1=Domestic, 2=Import, 3=Export
    dist_band        VARCHAR(10),  -- 1..8 distance bucket
    year             INTEGER,      -- 2018..2024
    tons             FLOAT,        -- thousand tons
    value            FLOAT,        -- million USD (2017 constant dollars)
    current_value    FLOAT,        -- million USD (current-year dollars)
    tmiles           FLOAT         -- million ton-miles
)
COMMENT = 'Long-format FAF5 freight flows 2018-2024 (7.8M rows pivoted from 38-col wide CSV)';

-- 2b. Reports table — 50 freight analyst reports for Cortex Search
CREATE OR REPLACE TABLE FREIGHT_REPORTS (
    report_id        VARCHAR(20),
    title            VARCHAR(500),
    report_date      DATE,
    report_type      VARCHAR(50),   -- 5 categories: carrier_negotiation / supply_chain_disruption /
                                    --               commodity_market_update / regional_capacity_report /
                                    --               mode_shift_analysis
    report_text      TEXT           -- ~1.2 KB per report on average
)
COMMENT = '50 freight analyst reports for Cortex Search indexing';

-- 2c. Lookup tables (joined to FREIGHT_FLOWS via the enriched view in Phase 3)
CREATE OR REPLACE TABLE LOOKUP_STATES (
    state_code  VARCHAR(2),
    state_name  VARCHAR(100)
) COMMENT = '51 rows: 50 US states + Washington DC. Codes are FIPS with gaps (03, 07, 14, 43, 52)';

CREATE OR REPLACE TABLE LOOKUP_SCTG (
    sctg_code       VARCHAR(2),
    commodity_name  VARCHAR(100)
) COMMENT = '42 SCTG2 commodity codes (01-41 plus 43; 42 intentionally skipped per FAF5 spec)';

CREATE OR REPLACE TABLE LOOKUP_MODES (
    mode_code  VARCHAR(2),
    mode_name  VARCHAR(100)
) COMMENT = '8 transport modes: Truck, Rail, Water, Air, Multimodal, Pipeline, Other, No domestic mode';

CREATE OR REPLACE TABLE LOOKUP_TRADE_TYPES (
    trade_code       VARCHAR(2),
    trade_type_name  VARCHAR(50)
) COMMENT = '3 trade types: Domestic, Import, Export';

CREATE OR REPLACE TABLE LOOKUP_DIST_BANDS (
    band_code   VARCHAR(2),
    band_label  VARCHAR(50)
) COMMENT = '8 distance buckets from Below 100mi to Over 2,000mi';

CREATE OR REPLACE TABLE LOOKUP_FOREIGN_REGIONS (
    region_code  VARCHAR(5),
    region_name  VARCHAR(100)
) COMMENT = '8 foreign regions: 801=Canada, 802=Mexico, 803=Rest of Americas, 804=Europe, 805=Africa, 806=SW & Central Asia, 807=Eastern Asia, 808=SE Asia & Oceania';


-- ---------------------------------------------------------------------------
-- 3. COPY INTO — load every table from the stage
-- ---------------------------------------------------------------------------

-- 3a. The big one — 7.8M rows from Parquet (column names matched case-insensitively)
COPY INTO FREIGHT_FLOWS
FROM @DATA_STAGE/FAF5.7.1_State_2018-2024_long.parquet
FILE_FORMAT          = (FORMAT_NAME = FF_PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR             = ABORT_STATEMENT;

-- 3b. Reports (CSV with header, double-quoted text)
COPY INTO FREIGHT_REPORTS
FROM @DATA_STAGE/freight_analyst_reports.csv
FILE_FORMAT          = (FORMAT_NAME = FF_CSV_STANDARD)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR             = ABORT_STATEMENT;

-- 3c. Six lookups
COPY INTO LOOKUP_STATES          FROM @DATA_STAGE/lookup_states.csv          FILE_FORMAT = (FORMAT_NAME = FF_CSV_STANDARD) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE ON_ERROR = ABORT_STATEMENT;
COPY INTO LOOKUP_SCTG            FROM @DATA_STAGE/lookup_sctg.csv            FILE_FORMAT = (FORMAT_NAME = FF_CSV_STANDARD) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE ON_ERROR = ABORT_STATEMENT;
COPY INTO LOOKUP_MODES           FROM @DATA_STAGE/lookup_modes.csv           FILE_FORMAT = (FORMAT_NAME = FF_CSV_STANDARD) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE ON_ERROR = ABORT_STATEMENT;
COPY INTO LOOKUP_TRADE_TYPES     FROM @DATA_STAGE/lookup_trade_types.csv     FILE_FORMAT = (FORMAT_NAME = FF_CSV_STANDARD) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE ON_ERROR = ABORT_STATEMENT;
COPY INTO LOOKUP_DIST_BANDS      FROM @DATA_STAGE/lookup_dist_bands.csv      FILE_FORMAT = (FORMAT_NAME = FF_CSV_STANDARD) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE ON_ERROR = ABORT_STATEMENT;
COPY INTO LOOKUP_FOREIGN_REGIONS FROM @DATA_STAGE/lookup_foreign_regions.csv FILE_FORMAT = (FORMAT_NAME = FF_CSV_STANDARD) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE ON_ERROR = ABORT_STATEMENT;


-- ---------------------------------------------------------------------------
-- 4. ROW-COUNT VALIDATION  (each row should show match = '✓')
-- ---------------------------------------------------------------------------
SELECT 'FREIGHT_FLOWS'           AS table_name, COUNT(*) AS actual_rows, 7791945 AS expected_rows,
       CASE WHEN COUNT(*) = 7791945 THEN '✓' ELSE '✗' END AS match
FROM   FREIGHT_FLOWS
UNION ALL SELECT 'FREIGHT_REPORTS',        COUNT(*),    50, CASE WHEN COUNT(*) =    50 THEN '✓' ELSE '✗' END FROM FREIGHT_REPORTS
UNION ALL SELECT 'LOOKUP_STATES',          COUNT(*),    51, CASE WHEN COUNT(*) =    51 THEN '✓' ELSE '✗' END FROM LOOKUP_STATES
UNION ALL SELECT 'LOOKUP_SCTG',            COUNT(*),    42, CASE WHEN COUNT(*) =    42 THEN '✓' ELSE '✗' END FROM LOOKUP_SCTG
UNION ALL SELECT 'LOOKUP_MODES',           COUNT(*),     8, CASE WHEN COUNT(*) =     8 THEN '✓' ELSE '✗' END FROM LOOKUP_MODES
UNION ALL SELECT 'LOOKUP_TRADE_TYPES',     COUNT(*),     3, CASE WHEN COUNT(*) =     3 THEN '✓' ELSE '✗' END FROM LOOKUP_TRADE_TYPES
UNION ALL SELECT 'LOOKUP_DIST_BANDS',      COUNT(*),     8, CASE WHEN COUNT(*) =     8 THEN '✓' ELSE '✗' END FROM LOOKUP_DIST_BANDS
UNION ALL SELECT 'LOOKUP_FOREIGN_REGIONS', COUNT(*),     8, CASE WHEN COUNT(*) =     8 THEN '✓' ELSE '✗' END FROM LOOKUP_FOREIGN_REGIONS
ORDER BY table_name;


-- ---------------------------------------------------------------------------
-- 5. MEASURE-TOTAL VALIDATION  (cross-checks against the pivot script's audit)
--    Expected totals come from pivot_to_long.py (validated to 1e-15 precision)
-- ---------------------------------------------------------------------------
SELECT 'tons'          AS measure, ROUND(SUM(tons),          2) AS actual_sum, 138965654.85 AS expected_sum,
       CASE WHEN ABS(SUM(tons)          - 138965654.85) < 1 THEN '✓' ELSE '✗' END AS match FROM FREIGHT_FLOWS
UNION ALL SELECT 'value',          ROUND(SUM(value),         2), 131284710.61, CASE WHEN ABS(SUM(value)         - 131284710.61) < 1 THEN '✓' ELSE '✗' END FROM FREIGHT_FLOWS
UNION ALL SELECT 'current_value',  ROUND(SUM(current_value), 2), 155235499.01, CASE WHEN ABS(SUM(current_value) - 155235499.01) < 1 THEN '✓' ELSE '✗' END FROM FREIGHT_FLOWS
UNION ALL SELECT 'tmiles',         ROUND(SUM(tmiles),        2),  37607491.73, CASE WHEN ABS(SUM(tmiles)        -  37607491.73) < 1 THEN '✓' ELSE '✗' END FROM FREIGHT_FLOWS
ORDER BY measure;


-- ---------------------------------------------------------------------------
-- 6. FINAL STATUS
-- ---------------------------------------------------------------------------
SELECT 'Data ingestion complete. Check the previous two result tabs for ✓ on every row.' AS status;
