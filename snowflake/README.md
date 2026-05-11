# `snowflake/` — Snowflake setup SQL

Four SQL files to provision the Snowflake environment, load data, build the enriched view, and create the Cortex Search service. Run them **in order** in Snowsight as `ACCOUNTADMIN`.

## Files (run order)

| # | File | What it does | Time |
|---|---|---|---|
| 1 | `01_setup_infra.sql` | Creates database `HIGHLINE_FREIGHT` + 3 schemas (`DATA`/`MODELS`/`TOOLS`), warehouse `HIGHLINE_FREIGHT_WH` (X-Small, 5-min auto-suspend), role `FREIGHT_ANALYST_ROLE`, 2 stages, Snowflake Intelligence prerequisites. Idempotent. | ~30 s |
| 2 | `02_load_data.sql` | Creates 8 tables (1 fact, 1 reports, 6 lookups), `COPY INTO` from `DATA_STAGE`, validates row counts + measure totals against pinned baselines. | ~60 s |
| 3 | `03_create_views.sql` | Creates `V_FREIGHT_FLOWS_ENRICHED` joining fact + all 6 lookups; verifies zero unmatched codes. | ~10 s |
| 4 | `04_create_search.sql` | Creates `FREIGHT_REPORTS_SEARCH` Cortex Search service over the 50 reports; runs 3 test queries (semantic, exact-match, attribute-filtered). | ~60 s |

## Before running

Upload the data files to `@HIGHLINE_FREIGHT.DATA.DATA_STAGE` after running `01_setup_infra.sql`:

- `FAF5.7.1_State_2018-2024_long.parquet` (181 MB)
- `freight_analyst_reports.csv` (65 KB)
- All 6 files from [`../lookups/`](../lookups/)

Upload the semantic model to `@HIGHLINE_FREIGHT.MODELS.YAML_STAGE` before creating the agent:

- [`../semantic_models/freight_semantic_model.yaml`](../semantic_models/freight_semantic_model.yaml)

## Validation baselines

Every file ends with `SELECT 'X complete'` plus validation queries. Expected totals:

| Measure | Sum (2018–2024) |
|---|---|
| tons | 138,965,654.85 |
| value | 131,284,710.61 |
| current_value | 155,235,499.01 |
| tmiles | 37,607,491.73 |

## Safety

- All `CREATE` use `OR REPLACE` or `IF NOT EXISTS` — re-runnable
- No `DROP` statements anywhere
- `COPY INTO` uses `ON_ERROR = ABORT_STATEMENT` — halts cleanly on bad data

## Not yet in this folder

- `05_custom_tools.sql` — Phase 7 (forecast, anomaly, backhaul, brief)
- `06_test_queries.sql` — Phase 8 (graded test set)
