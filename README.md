# Snowflake Cortex AI on FAF5 Freight Data

A Snowflake Cortex Agent that answers natural-language questions about U.S. freight movements (2018–2024). End-to-end implementation using Snowflake's Cortex AI stack: **Cortex Analyst** (NL → SQL), **Cortex Search** (hybrid semantic + keyword retrieval), and **Cortex Agents** (orchestration).

The agent runs over a 7.8M-row fact table of state-level freight flows from the U.S. DOT Freight Analysis Framework, with retrieval over 50 freight analyst reports for cross-modal questions that need both structured numbers and narrative context.

---

## Data source

The freight dataset is the **Freight Analysis Framework version 5.7.1 (FAF5)**, published by:

> **U.S. Department of Transportation**
> Federal Highway Administration (FHWA)
> Bureau of Transportation Statistics (BTS)
> [bts.gov/faf](https://www.bts.gov/faf) · [faf.ornl.gov/faf5](https://faf.ornl.gov/faf5/)

License: U.S. federal government public domain.
File used: state-level OD totals for 2018–2024 (~309 MB CSV, 1.1M wide rows pivoted to 7.8M long rows).

The 50 freight analyst reports in this project are **synthetic** — written to exercise Cortex Search retrieval against realistic prose. They are not real internal documents.

---

## Tech stack

- **Snowflake** — database, compute, and Cortex AI services
- **Snowflake Cortex Analyst** — NL → SQL via a YAML semantic model
- **Snowflake Cortex Search** — managed hybrid (semantic + keyword) retrieval, default Arctic Embed model
- **Snowflake Cortex Agents** — orchestrates Analyst + Search behind one chat interface
- **Snowflake Intelligence** — Snowsight chat UI for end-user interaction
- **Python** (`pandas`, `pyarrow`, `openpyxl`) — one-time data-prep utilities

---

## What's built

| Layer | What | Status |
|---|---|---|
| Data prep | Wide CSV → long Parquet, with row/measure-sum validation | ✅ |
| Snowflake infra | Database, warehouse, role, schemas, stages | ✅ |
| Data load | 7.8M-row fact + 50 reports + 6 lookups | ✅ |
| Enriched view | Fact joined to all 6 lookups (human-readable labels) | ✅ |
| Cortex Search | Hybrid search over the 50 reports | ✅ |
| Cortex Analyst | YAML semantic model — 8 dimensions, 6 measures, 2 named filters | ✅ |
| Cortex Agent | Both tools wired into one Snowflake Intelligence agent | ✅ |

Roadmap (not yet built): custom tools (forecast / anomaly detection / brief generation), a graded eval set, demo polish.

---

## Folder layout

```
Project/
├── lookups/             6 reference CSVs (state codes, commodity codes, modes, ...)
├── scripts/             Python scripts for one-time data prep
├── snowflake/           SQL files for Snowflake setup, load, view, search
├── semantic_models/     Cortex Analyst YAML semantic model
└── notes/               Detailed project plan + progress log
```

Each folder has its own `README.md`.

---

## How to run it

**Prerequisites**
- A Snowflake account with Cortex AI enabled (trial works)
- Python 3.9+ for the data-prep scripts
- The raw FAF5 CSV + the FAF5 metadata Excel file from BTS / ORNL

**Order**
1. `python3 scripts/build_lookups.py` — extract 6 lookup CSVs from the FAF5 metadata workbook
2. `python3 scripts/pivot_to_long.py` — pivot wide CSV to long Parquet
3. Upload the Parquet + reports CSV + 6 lookup CSVs to the `DATA_STAGE` in Snowsight
4. In Snowsight, run `snowflake/01_setup_infra.sql` through `04_create_search.sql` in order, as `ACCOUNTADMIN`
5. Upload `semantic_models/freight_semantic_model.yaml` to the `YAML_STAGE`
6. In Snowsight, create an Agent and wire both tools (`cortex_analyst_freight` + `freight_reports_search`)
7. Open the agent in Snowflake Intelligence and ask freight questions

Full step-by-step — with every validation check, gotcha, and copy-paste field value — is in [`notes/README.md`](notes/README.md).

---

## Credits

- **U.S. Bureau of Transportation Statistics** — for the FAF5 dataset
- **Snowflake** — for the Cortex AI platform and the [getting-started-with-cortex-agents](https://github.com/Snowflake-Labs/sfguide-getting-started-with-cortex-agents) quickstart that this project's architecture follows

## License

[MIT](LICENSE).
