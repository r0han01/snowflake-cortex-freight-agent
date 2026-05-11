-- ============================================================================
-- HIGHLINE FREIGHT INTELLIGENCE — Infrastructure Setup
-- File   : 01_setup_infra.sql
-- Phase  : 1 of 9  (foundation)
-- Author : Rishi Kumar Kota
--
-- What this script creates
-- -----------------------------------------------------------------------------
--   Database  : HIGHLINE_FREIGHT
--   Schemas   : DATA   (fact tables, lookups, views, data stage)
--               MODELS (semantic-model YAML stage)
--               TOOLS  (custom stored procedures: forecast, anomaly, backhaul,
--                       brief generator)
--   Warehouse : HIGHLINE_FREIGHT_WH     (X-Small, 5-minute auto-suspend)
--   Role      : FREIGHT_ANALYST_ROLE    (least privilege)
--   Stages    : HIGHLINE_FREIGHT.DATA.DATA_STAGE      (parquet + CSV uploads)
--               HIGHLINE_FREIGHT.MODELS.YAML_STAGE    (semantic-model YAML)
--   + Verifies SNOWFLAKE_INTELLIGENCE prerequisites so the agent can be created
--     in SNOWFLAKE_INTELLIGENCE.AGENTS later.
--
-- Safety
-- -----------------------------------------------------------------------------
--   * All CREATE statements use IF NOT EXISTS — safe to re-run on a partially
--     provisioned account. No DROP statements anywhere.
--   * Account-level authentication / network policies are NOT recreated; they
--     were set up during the previous sales-template project and are still in
--     effect. This script assumes they're already attached.
--   * Required role : ACCOUNTADMIN.
-- ============================================================================


USE ROLE ACCOUNTADMIN;
SET my_user = CURRENT_USER();


-- ---------------------------------------------------------------------------
-- 1. DATABASE + SCHEMAS
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS HIGHLINE_FREIGHT
  COMMENT = 'Freight Intelligence Co-Pilot — FAF5 freight data + analyst reports for Highline Warren';

CREATE SCHEMA IF NOT EXISTS HIGHLINE_FREIGHT.DATA
  COMMENT = 'Lookup tables, fact table (FREIGHT_FLOWS), reports table, enriched views, data stage';

CREATE SCHEMA IF NOT EXISTS HIGHLINE_FREIGHT.MODELS
  COMMENT = 'Holds the Cortex Analyst semantic model YAML(s)';

CREATE SCHEMA IF NOT EXISTS HIGHLINE_FREIGHT.TOOLS
  COMMENT = 'Custom agent tools: forecast_freight, detect_anomalies, find_backhaul_lanes, generate_brief';


-- ---------------------------------------------------------------------------
-- 2. WAREHOUSE
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS HIGHLINE_FREIGHT_WH
  WITH
    WAREHOUSE_SIZE       = 'XSMALL'
    AUTO_SUSPEND         = 300            -- 5 minutes idle  →  suspend (cost discipline)
    AUTO_RESUME          = TRUE
    INITIALLY_SUSPENDED  = TRUE
  COMMENT = 'Compute for the Freight Intelligence project — small + fast-suspend';


-- ---------------------------------------------------------------------------
-- 3. ROLE + GRANT TO CURRENT USER
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS FREIGHT_ANALYST_ROLE
  COMMENT = 'Operates the Freight Intelligence Co-Pilot — least-privilege access to FAF5 data and the agent';

-- Required for any Cortex AI function call (LLM, embeddings, etc.)
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE FREIGHT_ANALYST_ROLE;

-- Make the role usable by the current user
GRANT ROLE FREIGHT_ANALYST_ROLE TO USER IDENTIFIER($my_user);


-- ---------------------------------------------------------------------------
-- 4. GRANTS — give FREIGHT_ANALYST_ROLE access to our new objects
-- ---------------------------------------------------------------------------

-- Database + schemas: USAGE
GRANT USAGE ON DATABASE HIGHLINE_FREIGHT             TO ROLE FREIGHT_ANALYST_ROLE;
GRANT USAGE ON SCHEMA   HIGHLINE_FREIGHT.DATA        TO ROLE FREIGHT_ANALYST_ROLE;
GRANT USAGE ON SCHEMA   HIGHLINE_FREIGHT.MODELS      TO ROLE FREIGHT_ANALYST_ROLE;
GRANT USAGE ON SCHEMA   HIGHLINE_FREIGHT.TOOLS       TO ROLE FREIGHT_ANALYST_ROLE;

-- DATA schema: full ability to build tables, views, stages, file formats, and the Cortex Search service
GRANT CREATE TABLE,
      CREATE VIEW,
      CREATE STAGE,
      CREATE FILE FORMAT,
      CREATE CORTEX SEARCH SERVICE
  ON SCHEMA HIGHLINE_FREIGHT.DATA  TO ROLE FREIGHT_ANALYST_ROLE;

-- MODELS schema: needs to create the YAML stage
GRANT CREATE STAGE
  ON SCHEMA HIGHLINE_FREIGHT.MODELS TO ROLE FREIGHT_ANALYST_ROLE;

-- TOOLS schema: stored procs + UDTFs for custom agent tools
GRANT CREATE PROCEDURE,
      CREATE FUNCTION
  ON SCHEMA HIGHLINE_FREIGHT.TOOLS  TO ROLE FREIGHT_ANALYST_ROLE;

-- SELECT on all current + future tables/views in DATA (lookups, fact, reports, views)
GRANT SELECT ON ALL    TABLES IN SCHEMA HIGHLINE_FREIGHT.DATA TO ROLE FREIGHT_ANALYST_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA HIGHLINE_FREIGHT.DATA TO ROLE FREIGHT_ANALYST_ROLE;
GRANT SELECT ON ALL    VIEWS  IN SCHEMA HIGHLINE_FREIGHT.DATA TO ROLE FREIGHT_ANALYST_ROLE;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA HIGHLINE_FREIGHT.DATA TO ROLE FREIGHT_ANALYST_ROLE;

-- Usage on future stored procs / functions in TOOLS
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA HIGHLINE_FREIGHT.TOOLS TO ROLE FREIGHT_ANALYST_ROLE;
GRANT USAGE ON FUTURE FUNCTIONS  IN SCHEMA HIGHLINE_FREIGHT.TOOLS TO ROLE FREIGHT_ANALYST_ROLE;

-- Warehouse: usage to run queries, operate to suspend/resume
GRANT USAGE, OPERATE ON WAREHOUSE HIGHLINE_FREIGHT_WH TO ROLE FREIGHT_ANALYST_ROLE;


-- ---------------------------------------------------------------------------
-- 5. STAGES — file upload destinations
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS HIGHLINE_FREIGHT.DATA.DATA_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT   = 'Raw data files: Parquet (fact), reports CSV, 6 lookup CSVs';

CREATE STAGE IF NOT EXISTS HIGHLINE_FREIGHT.MODELS.YAML_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT   = 'Cortex Analyst semantic model YAML files';

GRANT READ, WRITE ON STAGE HIGHLINE_FREIGHT.DATA.DATA_STAGE     TO ROLE FREIGHT_ANALYST_ROLE;
GRANT READ, WRITE ON STAGE HIGHLINE_FREIGHT.MODELS.YAML_STAGE   TO ROLE FREIGHT_ANALYST_ROLE;


-- ---------------------------------------------------------------------------
-- 6. SNOWFLAKE INTELLIGENCE PREREQUISITES
--    (the agent itself will be created later in Phase 6 — Snowsight UI or REST)
-- ---------------------------------------------------------------------------

-- The dedicated DB/schema for agents (already exists from the previous project,
-- but IF NOT EXISTS keeps this safe).
CREATE DATABASE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE;
CREATE SCHEMA   IF NOT EXISTS SNOWFLAKE_INTELLIGENCE.AGENTS;

-- The account-level container that lets the agent show up in the
-- Snowflake Intelligence chat UI.  (Lesson from the sales-template build:
-- this object does NOT exist on a fresh trial account — must be created
-- before any GRANT references it.)
CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

-- Grant the role the ability to create / use agents
GRANT USAGE        ON DATABASE SNOWFLAKE_INTELLIGENCE          TO ROLE FREIGHT_ANALYST_ROLE;
GRANT USAGE        ON SCHEMA   SNOWFLAKE_INTELLIGENCE.AGENTS   TO ROLE FREIGHT_ANALYST_ROLE;
GRANT CREATE AGENT ON SCHEMA   SNOWFLAKE_INTELLIGENCE.AGENTS   TO ROLE FREIGHT_ANALYST_ROLE;
GRANT USAGE        ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE FREIGHT_ANALYST_ROLE;
GRANT MODIFY       ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE FREIGHT_ANALYST_ROLE;


-- ---------------------------------------------------------------------------
-- 7. CROSS-REGION INFERENCE  (enables Cortex LLMs from any AWS US region)
-- ---------------------------------------------------------------------------
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'AWS_US';


-- ---------------------------------------------------------------------------
-- 8. FINAL VERIFICATION — should print "Infrastructure setup complete."
-- ---------------------------------------------------------------------------
SELECT 'Infrastructure setup complete.' AS status;
