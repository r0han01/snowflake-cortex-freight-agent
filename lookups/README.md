# `lookups/` — FAF5 reference tables

Six small reference CSVs that translate FAF5 numeric codes into human-readable names. Loaded into Snowflake as the `LOOKUP_*` tables and joined to the fact table in `V_FREIGHT_FLOWS_ENRICHED`.

## Files

| File | Rows | Codes → Names |
|---|---|---|
| `lookup_states.csv` | 51 | FIPS state codes (e.g. `06` → California). 50 states + DC. |
| `lookup_sctg.csv` | 42 | SCTG2 commodity codes (`01`–`41`, `43`; `42` skipped per FAF5 spec). |
| `lookup_modes.csv` | 8 | Transport modes (`1`=Truck, `2`=Rail, `3`=Water, ...). |
| `lookup_trade_types.csv` | 3 | `1`=Domestic, `2`=Import, `3`=Export. |
| `lookup_dist_bands.csv` | 8 | Distance buckets (`1`=<100mi … `8`=>2000mi). |
| `lookup_foreign_regions.csv` | 8 | Foreign region codes (`801`=Canada … `808`=SE Asia & Oceania). |

## How they were generated

Extracted from the official FAF5 codebook `FAF5_metadata.xlsx` by [`../scripts/build_lookups.py`](../scripts/build_lookups.py). Re-runnable — codes will match the FAF5 fact table byte-for-byte.

## How they're used in Snowflake

Loaded by [`../snowflake/02_load_data.sql`](../snowflake/02_load_data.sql) into tables in `HIGHLINE_FREIGHT.DATA`. Joined into [`../snowflake/03_create_views.sql`](../snowflake/03_create_views.sql)'s `V_FREIGHT_FLOWS_ENRICHED` view so the agent sees labels (`California`) instead of raw codes (`06`).
