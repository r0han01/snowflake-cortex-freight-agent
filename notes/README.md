# Project Notes — Plan & Progress

Detailed working notes for the Snowflake Cortex Agent built over the U.S. DOT FAF5 freight dataset. The agent translates plain-English questions into SQL on a 7.8M-row fact table and pulls context from 50 synthetic freight analyst reports.

These are the **detailed** notes — every phase, decision, gotcha, and validation number encountered during the build. For the top-level overview, see [`../README.md`](../README.md).

---

## 1. What We Are Building

A **Freight Intelligence Co-Pilot** — a Snowflake Cortex Agent that:

1. Answers structured questions about U.S. freight flows (2018–2024) in plain English by translating them to SQL — via **Cortex Analyst**.
2. Answers contextual questions about market events, carrier negotiations, supply chain disruptions, regional capacity, and mode-shift trends — via **Cortex Search** over 50 internal-style analyst reports.
3. Combines both for cross-modal questions (e.g., "Why did Texas petroleum truck volumes spike in 2020, and what did the carrier negotiation report say?").
4. Goes beyond chat: provides **forecasting**, **anomaly detection**, **backhaul opportunity analysis**, and **executive brief generation** through custom tools wired into the agent.

This mirrors and significantly extends the architecture of the `sfguide-getting-started-with-cortex-agents` quickstart.

---

## 2. Why This Matters for the Business

Highline Warren is an auto-aftermarket distributor. Freight flows directly drive:

- **Cost** — diesel rates, truck/rail mix, lane-level economics
- **Network strategy** — where to expand, where to consolidate
- **Supply chain risk** — lead prices (battery raw material), import dependencies, port disruptions
- **Backhaul revenue** — empty trucks returning on lanes Highline already operates could carry SCTG 41 (waste/scrap, incl. battery recycling) inbound

FAF5 covers 1.1M wide rows (7.8M long rows) of state-level freight, every commodity, every transport mode, 2018–2024. Today, no one at Highline can query it without a data analyst. We make it a chat.

**The unfair advantage:** an analyst at Highline asks a question in English; the agent returns SQL-grounded numbers, cited reports, a forecast, and a dollar-quantified recommendation — in 30 seconds.

---

## 3. Architecture

```
                    ┌───────────────────────────┐
                    │ User (Snowflake Intelligence chat) │
                    └───────────┬───────────────┘
                                │ NL question
                                ▼
                ┌──────────────────────────────────┐
                │   FREIGHT_INTELLIGENCE_AGENT     │  ← claude-4-sonnet orchestration
                └──────┬─────────┬─────────┬───────┘
                       │         │         │
            ┌──────────┘         │         └──────────┐
            ▼                    ▼                    ▼
   Cortex Analyst        Cortex Search        Custom tools (stored procs / UDTFs)
   (FAF5 freight)        (50 reports)          - forecast_freight
   semantic YAML         hybrid retrieval      - detect_anomalies
            │                    │             - find_backhaul_lanes
            │                    │             - generate_brief
            ▼                    ▼                    │
   ┌─────────────────┐  ┌─────────────────┐          │
   │ FREIGHT_FLOWS   │  │ FREIGHT_REPORTS │          │
   │ (7.8M rows)     │  │ (50 docs)       │          │
   │ + 6 lookup tabs │  │ + attributes    │          │
   └─────────────────┘  └─────────────────┘          │
                                                      │
                                  Snowflake ML.FORECAST
                                  Snowflake AI Budget cap
```

Everything runs **inside Snowflake's security perimeter** — no data leaves the platform, no external LLM calls.

---

## 4. Data Inventory (What We Have)

| File | Size | Rows | Description |
|---|---|---|---|
| `FAF5.7.1_State_2018-2024.csv` | 309 MB | 1,113,135 | Original wide-format FAF5 freight data (38 cols, years as suffixes) |
| `FAF5.7.1_State_2018-2024_long.csv` | 443 MB | 7,791,945 | Pivoted to long format (15 cols, year as row) |
| `FAF5.7.1_State_2018-2024_long.parquet` | **181 MB** ⭐ | 7,791,945 | **Working file** — long-format Parquet, our load target |
| `freight_analyst_reports.csv` | 65 KB | 50 | Synthetic-but-realistic freight analyst reports (5 categories × 10 each) |
| `FAF5_metadata.xlsx` | 28 KB | — | Official FAF5 codebook (state codes, SCTG codes, modes, etc.) |
| `pivot_to_long.py` | 7 KB | — | Re-runnable wide→long conversion script, with full data-integrity validation |

### Long-format schema (the working dataset)
```
fr_orig        string   foreign origin region code (empty for domestic)
dms_origst     string   US state of origin (FIPS code, e.g. '06' = California)
dms_destst     string   US state of destination
fr_dest        string   foreign destination region code (empty for domestic)
fr_inmode      string   transport mode from foreign region → US entry
dms_mode       string   transport mode within the US (1=Truck, 2=Rail, ...)
fr_outmode     string   transport mode from US exit → foreign destination
sctg2          string   2-digit commodity code (01=Live animals, 36=Motor vehicles, ...)
trade_type     string   1=Domestic, 2=Import, 3=Export
dist_band      string   distance bucket (1=<100mi, ... 8=>2000mi)
year           int16    2018..2024
tons           float    thousand tons
value          float    million USD (2017 constant dollars)
current_value  float    million USD (current dollars of that year)
tmiles         float    million ton-miles
```

### Reports schema
```
report_id      VARCHAR  e.g. FRT_001
title          VARCHAR  e.g. "Q3 2020 Truck Carrier Negotiation - Texas Petroleum Routes"
report_date    DATE     2019-04-12 → 2024-09-20
report_type    VARCHAR  carrier_negotiation | supply_chain_disruption |
                        commodity_market_update | regional_capacity_report | mode_shift_analysis
report_text    TEXT     ~1,230 chars per report
```

### Why the reports complement FAF5 perfectly

The 5 report categories map directly onto FAF5 dimensions:

| Report category | FAF5 dimension it explains |
|---|---|
| `carrier_negotiation` | mode + lanes + rates |
| `supply_chain_disruption` | trade_type + year + commodity (the "why" behind anomalies) |
| `commodity_market_update` | sctg2 + time |
| `regional_capacity_report` | dms_origst / dms_destst |
| `mode_shift_analysis` | dms_mode shifts over time |

This tight semantic alignment is **better than the sales template's transcripts** — the agent has a real chance of synthesizing structured numbers and unstructured "why" into a single answer.

---

## 5. Project Structure on Disk (live)

```
Highline Warren Project/
├── FAF5.7.1_State_2018-2024/                    (raw data)
│   ├── FAF5.7.1_State_2018-2024.csv             ✅ have (original 309 MB)
│   ├── FAF5.7.1_State_2018-2024_long.csv        ✅ have (443 MB long)
│   ├── FAF5.7.1_State_2018-2024_long.parquet    ✅ have (181 MB — load target)
│   ├── FAF5_metadata.xlsx                       ✅ have (codebook)
│   ├── freight_analyst_reports.csv              ✅ have (65 KB, 50 reports)
│   └── pivot_to_long.py                         ✅ have (re-runnable wide→long)
├── Project/                                     (the live project)
│   ├── README.md                                ← THIS FILE
│   ├── lookups/                                 ✅ built (Phase 2)
│   │   ├── lookup_states.csv                    ✅ 51 rows
│   │   ├── lookup_sctg.csv                      ✅ 42 rows
│   │   ├── lookup_modes.csv                     ✅ 8 rows
│   │   ├── lookup_trade_types.csv               ✅ 3 rows
│   │   ├── lookup_dist_bands.csv                ✅ 8 rows
│   │   └── lookup_foreign_regions.csv           ✅ 8 rows
│   ├── scripts/
│   │   └── build_lookups.py                     ✅ re-runnable lookup extractor
│   ├── snowflake/
│   │   ├── 01_setup_infra.sql                   ✅ run — infra provisioned
│   │   ├── 02_load_data.sql                     ✅ run — 7.8M + 50 + 120 rows loaded
│   │   ├── 03_create_views.sql                  ✅ run — V_FREIGHT_FLOWS_ENRICHED
│   │   ├── 04_create_search.sql                 ✅ run — FREIGHT_REPORTS_SEARCH active
│   │   ├── 05_custom_tools.sql                  ⨯ to build (Phase 7)
│   │   └── 06_test_queries.sql                  ⨯ to build (Phase 8)
│   ├── semantic_models/
│   │   └── freight_semantic_model.yaml          ✅ built + uploaded to YAML_STAGE
│   ├── agent/                                   ⨯ optional — created via UI (Phase 6 done)
│   │   └── create_agent.json
│   └── demo/                                    ⨯ to build (Phase 8/9)
│       ├── test_questions.md
│       └── demo_script.md
└── sfguide-getting-started-with-cortex-agents-main/   (reference quickstart)
```

Every artifact is version-controllable. Every step is reproducible. This is what "prod-level" actually means.

---

## 6. The 9 Phases

### Phase 1 — Foundation (Snowflake infra)
**Time: ~1 hour. Deliverable: `snowflake/01_setup_infra.sql`**

Provisions:
- Database `HIGHLINE_FREIGHT` with schemas `DATA`, `MODELS`, `TOOLS`, `AGENTS`
- Warehouse `HIGHLINE_FREIGHT_WH` (Small, **5-minute auto-suspend** for cost discipline)
- Role `FREIGHT_ANALYST_ROLE` with `CORTEX_USER` and all needed grants
- Stages: `MODELS` (for the YAML) and `DATA_FILES` (for parquet + CSV uploads)
- Pre-applies the same authentication policy fixes we learned from the sales template (so PAT auth works later if we need REST access)
- Includes `CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS …` to avoid the trial-account GRANT issue

Re-runnable on any fresh Snowflake account.

### Phase 2 — Data ingestion
**Time: 2-3 hours. Deliverables: `02_load_data.sql`, `03_lookups.sql`, six lookup CSVs**

Steps:
1. Generate 6 lookup CSVs from `FAF5_metadata.xlsx` (states, SCTG, modes, trade types, dist bands, foreign regions). Small reference tables — < 100 rows each.
2. `PUT` parquet + CSVs to stages
3. `COPY INTO` to load:
   - `FREIGHT_FLOWS` — 7.8M rows from the Parquet
   - `FREIGHT_REPORTS` — 50 rows from the reports CSV
   - 6 lookup tables
4. Data quality checks:
   - Row counts match expected (7,791,945 / 50 / lookup table totals)
   - Sum totals match validation numbers from `pivot_to_long.py` (tons: 138,965,654.85; value: 131,284,710.61; current_value: 155,235,499.01; tmiles: 37,607,491.73)
   - Null counts match
5. Apply clustering on `(year, sctg2)` for `FREIGHT_FLOWS` — most queries filter by these.

### Phase 3 — Enriched view layer
**Time: 1-2 hours. Deliverable: `04_create_views.sql`**

Creates `V_FREIGHT_FLOWS_ENRICHED` — a view that joins `FREIGHT_FLOWS` to all 6 lookups and exposes both raw codes and human-readable labels:

```sql
SELECT
  ff.*,
  s_orig.state_name          AS origin_state_name,         -- "California"
  s_dest.state_name          AS destination_state_name,    -- "Texas"
  c.commodity_name           AS commodity_name,            -- "Gasoline"
  m.mode_name                AS mode_name,                 -- "Truck"
  tt.trade_type_name         AS trade_type_name,           -- "Domestic"
  db.dist_band_label         AS distance_band_label,       -- "500 - 749 miles"
  fr_o.region_name           AS foreign_origin_name,
  fr_d.region_name           AS foreign_destination_name
FROM FREIGHT_FLOWS ff
LEFT JOIN LOOKUP_STATES         s_orig ON ff.dms_origst = s_orig.state_code
LEFT JOIN LOOKUP_STATES         s_dest ON ff.dms_destst = s_dest.state_code
LEFT JOIN LOOKUP_SCTG           c      ON ff.sctg2      = c.sctg_code
LEFT JOIN LOOKUP_MODES          m      ON ff.dms_mode   = m.mode_code
LEFT JOIN LOOKUP_TRADE_TYPES    tt     ON ff.trade_type = tt.trade_code
LEFT JOIN LOOKUP_DIST_BANDS     db     ON ff.dist_band  = db.band_code
LEFT JOIN LOOKUP_FOREIGN_REGIONS fr_o  ON ff.fr_orig    = fr_o.region_code
LEFT JOIN LOOKUP_FOREIGN_REGIONS fr_d  ON ff.fr_dest    = fr_d.region_code
```

Why a view (not denormalized table): we can re-materialize cheaply, swap lookups if FAF6 ships, and the semantic model becomes far simpler. Cortex Analyst targets this view.

### Phase 4 — Cortex Analyst (THE MOST IMPORTANT PHASE)
**Time: 4-6 hours. Deliverable: `semantic_models/freight_semantic_model.yaml`**

This is where 80% of agent accuracy comes from. We invest here heavily.

The semantic model defines:

#### Logical table
`V_FREIGHT_FLOWS_ENRICHED`

#### Dimensions (with rich synonym lists)

| Dimension | Synonyms (excerpt) |
|---|---|
| `origin_state_name` | origin, from, source, shipped from, starting state, where it came from |
| `destination_state_name` | destination, to, target, shipped to, ending state, where it went |
| `foreign_origin_name` | imported from, source country, foreign source |
| `foreign_destination_name` | exported to, destination country, foreign buyer |
| `commodity_name` | product, goods, item, category, what's being shipped, freight type |
| `mode_name` | transportation method, transport mode, how it's shipped, shipping method |
| `trade_type_name` | flow type, domestic vs import vs export |
| `distance_band_label` | distance range, how far, mileage bucket |

Each dimension also documents its values and ties to the underlying code where useful.

#### Time dimension
`year` (INTEGER) with synonyms: when, time, period, annual.

#### Measures

| Measure | Expression | Synonyms |
|---|---|---|
| `total_tons` | `SUM(tons)` | weight, tonnage, volume, mass |
| `total_value` | `SUM(value)` | dollar value, worth, value, $ |
| `total_current_value` | `SUM(current_value)` | nominal value, actual dollars, current $ |
| `total_ton_miles` | `SUM(tmiles)` | freight effort, logistics intensity, ton-miles |
| `record_count` | `COUNT(*)` | row count, number of flows |
| `value_per_ton` | `SUM(value) / NULLIF(SUM(tons), 0)` | $ per ton, dollar density, freight value density |

#### Domain-specific filters (Highline Warren shortcuts)

```yaml
- name: highline_relevant_commodities
  expr: sctg2 IN ('24', '32', '33', '36', '37', '41')
  description: Auto-aftermarket relevant commodity codes — plastics/rubber, base metals (lead),
               metal articles, motor vehicles, transport equipment, waste/scrap (battery recycling)
```

So users can say "our category" and the LLM knows what to filter.

#### Verified queries (huge for accuracy)

Pre-defined SQL for common questions:
- "Top 10 commodities by total value (last full year)"
- "Year-over-year change by mode"
- "Top origin-destination lanes for a given commodity"
- "Truck-vs-rail share for a given commodity"
- "Domestic vs. import vs. export split"

Cortex Analyst will reference these when ambiguous questions come in.

### Phase 5 — Cortex Search (the unstructured side)
**Time: ~1 hour. Deliverable: `05_create_search.sql`**

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE freight_reports_search
  ON report_text
  ATTRIBUTES title, report_type, report_date
  WAREHOUSE = highline_freight_wh
  TARGET_LAG = '1 hour'
  AS (
    SELECT report_id, title, report_text, report_type, report_date
    FROM freight_reports
  );
```

The `ATTRIBUTES` line is the key — it lets the agent pre-filter by `report_type` or `report_date` *before* semantic ranking. Sharper retrieval, fewer irrelevant pulls.

### Phase 6 — The agent
**Time: 2-3 hours. Deliverable: `agent/create_agent.json` + agent registered in Snowflake**

Creates `FREIGHT_INTELLIGENCE_AGENT` in `SNOWFLAKE_INTELLIGENCE.AGENTS` with:
- Tool 1: `cortex_analyst_freight` → the semantic model
- Tool 2: `cortex_search_freight_reports` → the search service
- **Model:** `claude-4-sonnet`
- **Orchestration instructions:** when to use Analyst, when to use Search, when to use both. Includes the rule "For Highline Warren questions, default to filtering by highline_relevant_commodities unless a different commodity is explicit."
- **Response instructions:** concise, source-attributed, dollar-quantified, no speculation beyond available data.

After creation: register the agent with Snowflake Intelligence (the `+ Add agent` step from the sales template's hard-learned lesson).

### Phase 7 — Custom tools (the "WTF" layer)
**Time: 8-15 hours, ~1 day per tool. Deliverable: `06_custom_tools.sql` + agent re-wired**

This is the differentiation from a vanilla quickstart. Four tools, each wired into the agent.

#### Tool A — Forecast (`forecast_freight`)
Stored procedure that wraps Snowflake's `ML.FORECAST`:
```sql
CALL forecast_freight(
  metric         => 'tons',
  filters        => OBJECT_CONSTRUCT('origin_state', '48', 'sctg2', '17'),
  horizon_years  => 5
);
```
Returns: `(year, forecast_value, lower_bound, upper_bound)`. Trained on the relevant historical slice.

Agent use: *"Forecast Texas gasoline freight through 2029."*

#### Tool B — Anomaly detection (`detect_anomalies`)
UDTF (user-defined table function) that scans for year-over-year shifts > threshold:
```sql
SELECT * FROM TABLE(detect_anomalies(
  threshold_pct => 25.0,
  metric        => 'tons',
  group_by      => ARRAY_CONSTRUCT('origin_state', 'sctg2', 'mode')
));
```
Returns: top anomalies with origin/destination/commodity/mode breakdown and percent change.

Agent use: *"Where did things shift the most in 2020 vs 2019?"*

#### Tool C — Backhaul opportunity (`find_backhaul_lanes`) — Highline-specific
The kill shot.

Inputs: a list of Highline's representative outbound lanes (we start with 10–15 defensible ones; real ones if available).
For each lane, find what's flowing the **opposite** direction in SCTG 41 (waste/scrap) plus other relevant commodities.
Rank by tons + value. Estimate dollar savings using a configurable per-mile rate assumption.

```sql
SELECT * FROM TABLE(find_backhaul_lanes(
  outbound_lanes => ARRAY_CONSTRUCT(
    OBJECT_CONSTRUCT('from_state', '17', 'to_state', '48'),
    OBJECT_CONSTRUCT('from_state', '13', 'to_state', '12'),
    ...
  ),
  target_sctg => '41',
  rate_per_ton_mile => 0.18
));
```

Agent use: *"Find me the 3 best backhaul opportunities for Highline's current outbound network."*

#### Tool D — Executive brief generator (`generate_brief`)
Stored procedure (orchestration logic). Given a topic:
1. Calls Cortex Analyst for structured insights
2. Calls Cortex Search for relevant report quotes (with citations)
3. Calls forecast tool if relevant
4. Formats output as a one-page Markdown brief with chart-ready data + cited quotes + a recommendation

```sql
CALL generate_brief(topic => 'Lead supply chain freight trends 2018–2024');
```

Agent use: *"Generate a one-page executive brief on lead supply chain trends for our board meeting."*

### Phase 8 — Validation & test harness
**Time: 4-6 hours. Deliverable: `demo/test_questions.md`**

We don't ship "demoware". We ship a system that has been **graded**.

#### The test set: ~40-50 curated questions across all paths

| Category | Count | Examples |
|---|---|---|
| Pure Analyst | 10 | "Total US freight tons in 2023", "Top 5 commodities by current value in 2024" |
| Pure Search | 8 | "Recap the Suez Canal blockage report", "What did the East Palestine report cover?" |
| Cross-modal | 10 | "Why did Texas petroleum truck volumes spike in 2020? Show data + report context" |
| Forecast | 5 | "Forecast California gasoline imports through 2028" |
| Anomaly | 5 | "Where did freight shift the most year-over-year between 2019 and 2020?" |
| Backhaul (Highline) | 4 | "Top 3 backhaul opportunities for our outbound network" |
| Trick / edge | 5 | "Tons shipped by Bob Smith" (no such person), "Q3 2026 outlook" (no data) |
| Brief generation | 3 | "Generate a brief on lead supply chain trends" |

#### Grading
Each question gets:
- ✅ Correct — agent returned what we expected, with proper tool routing
- 🟡 Partial — directionally right but missed something
- ❌ Wrong — hallucinated, wrong tool, refused incorrectly

Failing items drive iteration on the YAML or the agent instructions, then we re-run.

### Phase 9 — Polish & demo
**Time: 4-6 hours. Deliverable: `demo/demo_script.md`**

The 6-slide demo arc (rehearsed and timed):

| Slide | Question | What it shows |
|---|---|---|
| 1 — Set the stage | "How has total auto-aftermarket-related freight in the US changed from 2018 to 2024?" | Basic Analyst competence + chart generation |
| 2 — Get specific | "Top 5 state-to-state lanes for motor vehicle parts since 2020, by mode" | Complex multi-dim aggregation |
| 3 — Bring context | "Mexico→Texas auto parts imports jumped after 2021 — why?" | Cross-modal: Analyst + Search synthesizing |
| 4 — Forecast | "Forecast lead (SCTG 32) freight inflow to top 5 battery-manufacturing states through 2028" | Forecast tool invoked |
| 5 — Recommend | "Identify backhaul opportunities where SCTG 41 inbound matches our outbound lanes. Top 3 with savings estimates." | Custom tool returning $-quantified recommendation |
| 6 — Generate | "Generate a one-page executive brief on US lead supply chain freight trends for next week's board meeting" | Compose-and-format from all tools, output Markdown brief |

Plus:
- AI Budget cap set so cost can't surprise
- `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` view shows query volume + cost during demo
- One-page README delivered alongside the demo

---

## 7. Key Technical Decisions, With Rationale

| Decision | Choice | Why |
|---|---|---|
| Data format | Long Parquet | Better for analytics, 42% smaller than wide CSV, native typing |
| Fact + lookups vs denormalized | Fact + lookups + enriched view | SQL-clean joins, semantic-friendly view, easy to update |
| Semantic model exposes | Labels (via enriched view) | LLM understands "California" not "06" |
| Search attributes | `report_type`, `report_date`, `title` | Enables sharp pre-filtering before semantic search |
| Forecasting | Snowflake `ML.FORECAST` | Native, no Python, in-perimeter, free |
| Backhaul lanes | Start with 10–15 representative lanes | Don't block on Highline data dumps; defensible by category logic |
| Auth | Snowflake Intelligence (UI session) for demo; key-pair JWT for future REST | PAT debugging on trial accounts is a rabbit hole; sidestep it |
| Demo UI | Snowflake Intelligence | Already shows SQL trace, chart auto-render, conversation history — no custom code |

---

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Cortex Analyst accuracy on 7.8M-row table | Heavy investment in semantic model (synonyms, verified queries) in Phase 4 |
| Cost runaway from agent queries | AI Budget cap in Phase 9; warehouse 5-minute auto-suspend; small WH size |
| `ML.FORECAST` quirks on sparse slices | Test with small slice first; have fallback linear regression UDF |
| Reports search miss-retrieval | Pre-filter via `report_type` attribute; spot-check with the test set |
| Demo fails live | Rehearse end-to-end twice; screen-record a backup; have static slides for the kill-shot moment |
| Semantic model becomes too big | Modularize by use case; consider Semantic Views (newer Snowflake first-class object) |
| Trial-account auth-policy quirks | Pre-bake the auth-policy fix into `01_setup_infra.sql` so we never hit it again |

---

## 9. Realistic Timeline

Assuming ~4-5 focused hours/day, no other blockers:

| Week | Phases | End state |
|---|---|---|
| 1 | 1, 2, 3 | Data fully loaded into Snowflake; enriched view queryable in SQL |
| 2 | 4 (heavy), 5 | Cortex Analyst + Search both working; agent can be built |
| 3 | 6, 7 (tools A & B) | Agent answers basic + cross-modal questions, plus forecast + anomaly detection |
| 4 | 7 (tools C & D), 8, 9 | All 4 custom tools wired; test set graded; demo rehearsed |

If working part-time alongside other internship duties, double the calendar weeks but the effective hours stay the same.

---

## 10. What "Top Notch" Means Here (vs the Quickstart)

| Dimension | Quickstart minimum | Our version |
|---|---|---|
| Data scale | 10 rows | 7,791,945 rows |
| Reference tables | 0 | 6 lookups (proper data model) |
| Semantic model | 5 synonyms | 50+ synonyms, verified queries, domain phrases |
| Tools | 2 (Analyst + Search) | 6 (Analyst, Search, Forecast, Anomaly, Backhaul, Brief) |
| Output formats | Chat answer | Chat + chart + executive brief + cited sources |
| Test coverage | "It worked once" | 40+ question eval set, graded |
| Cost discipline | None | AI Budget + warehouse auto-suspend |
| Documentation | None | Project README + semantic model docs + demo script |
| Business framing | "Cool freight queries" | $-quantified recommendations for Highline backhaul |
| Domain tuning | Generic | Auto-aftermarket SCTG filters, Highline-specific phrases |

---

## 11. The First Commit (Day 1 Plan)

We start with infrastructure + ingestion. By end of Day 1 we have a queryable freight dataset in Snowflake.

Build, in order:
1. `lookups/lookup_states.csv` — from `FAF5_metadata.xlsx`
2. `lookups/lookup_sctg.csv`
3. `lookups/lookup_modes.csv`
4. `lookups/lookup_trade_types.csv`
5. `lookups/lookup_dist_bands.csv`
6. `lookups/lookup_foreign_regions.csv`
7. `snowflake/01_setup_infra.sql` (run in Snowsight)
8. `snowflake/02_load_data.sql` (run in Snowsight; loads parquet + reports + lookups)
9. `snowflake/03_lookups.sql` (optional: separated lookup loads for clarity)
10. Validation queries: row counts and sum totals against expected values from this README

Day 2 moves to the enriched view and the semantic model.

---

## 12. The Demo Story (One Paragraph)

> "Highline Warren receives shipments daily but has no way to ask the macro question: how does U.S. freight actually move, and where does our network fit? We built a Snowflake Cortex Agent over the federal Freight Analysis Framework — 7.8 million rows of state-level freight from 2018 to 2024. An analyst can ask, in plain English, anything from 'what's the rail share of plastics freight to California' to 'forecast lead inflow to battery-manufacturing states through 2028' to 'identify backhaul opportunities for our outbound lanes.' The agent generates SQL, pulls cited context from 50 analyst reports on disruptions and carrier negotiations, runs forecasts, and produces executive-ready briefs — all inside Snowflake's security perimeter, with no data leaving the platform. Our first analysis identified $X.X M/year in offsettable freight cost from underutilized backhaul lanes."

That's the elevator pitch. Everything in this plan exists to make that paragraph defensible.

---

## 13. Things We Already Learned (From Sales Template Build)

Lessons that pre-baked into this plan so we don't re-pay the tax:

- **Use `Run All` (Cmd+Shift+Return)** in Snowsight worksheets — not just `Run`. Otherwise only the cursor's statement runs.
- **`SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT`** must be created before granting on it. Pre-bake the `CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS …` into Phase 1.
- **The new Snowsight UI** calls Worksheets "Workspaces" now. Same thing.
- **`DESC USER` doesn't show `AUTHENTICATION_POLICY`** — use `INFORMATION_SCHEMA.POLICY_REFERENCES` to verify policy attachments.
- **Tool attachments on an agent can fail silently** on first save. Always verify on the Overview page before testing.
- **For trial accounts, PAT auth requires:** a network policy attached to the user, an authentication policy that includes `PROGRAMMATIC_ACCESS_TOKEN` in `AUTHENTICATION_METHODS`, and `MFA_ENROLLMENT` set to `OPTIONAL` (or `REQUIRED_SNOWFLAKE_UI_PASSWORD_ONLY`). Apply all three in Phase 1 even if we don't immediately need REST.
- **Cortex Analyst accuracy lives or dies by the semantic model**, specifically the synonyms list. We over-invest in Phase 4 for that reason.
- **For UI usage you don't need tokens at all.** Snowflake Intelligence handles login via the user session. PATs are only for external clients.

---

## 14. Open Questions (Decide Before We Start)

These don't block Day 1 but should be settled before Phase 7:

- **Are Highline's actual outbound lanes available to us?** If yes, the backhaul tool uses real data and recommendations have real dollar weight. If no, we use 10–15 representative lanes and frame the tool as "methodology demo".
- **Do we want a custom Streamlit on top?** Snowflake Intelligence is enough for an internal demo, but if the project is going to be embedded in a Highline-branded portal, we'd add a Streamlit layer. Decide before Phase 9.
- **Forecast horizon — 3 years or 5?** Longer is more impressive but less defensible. Default to 5 with confidence bands; reviewers can argue down.
- **Should the agent be allowed to write?** All current tools are read-only. If we add write tools (e.g., "save this brief to a stage"), we need a different auth posture. Default: read-only forever.

---

## 15. Status Tracker

| Phase | Status | Notes |
|---|---|---|
| 0 — Data prep | ✅ **Done** | Wide CSV → long Parquet (181 MB), validated zero data loss; pivot script + audit numbers committed |
| 1 — Foundation | ✅ **Done** | `HIGHLINE_FREIGHT` DB + 3 schemas (DATA/MODELS/TOOLS), `HIGHLINE_FREIGHT_WH` (X-Small, 5-min auto-suspend), `FREIGHT_ANALYST_ROLE`, 2 stages, Snowflake Intelligence prereqs |
| 2 — Ingestion | ✅ **Done** | All 8 files uploaded to `DATA_STAGE`. Loaded: 7,791,945 freight rows + 50 reports + 120 lookup rows. **Every measure total matches to the cent** (tons 138,965,654.85 / value 131,284,710.61 / current_value 155,235,499.01 / tmiles 37,607,491.73) |
| 3 — Enriched view | ✅ **Done** | `V_FREIGHT_FLOWS_ENRICHED` joins fact + 6 lookups; **all 10 unmatched-code counters = 0** (perfect lookup coverage); trade-type distribution = 21 rows (3 × 7 years); row count unchanged at 7,791,945 |
| 4 — Cortex Analyst (semantic model) | ✅ **Done** | `freight_semantic_model.yaml` (429 lines) built and uploaded to `@HIGHLINE_FREIGHT.MODELS.YAML_STAGE`. 8 dimensions with 8-12 synonyms each, 1 time dimension, 6 measures (incl. derived `VALUE_PER_TON`), 2 Highline-specific filters (`highline_relevant_commodities`, `highline_lead_battery`). Verified queries removed from YAML (schema mismatch) — to be added via UI later. |
| 5 — Cortex Search | ✅ **Done** *(done before Phase 4 — quick win)* | `FREIGHT_REPORTS_SEARCH` active. 3 test queries verified: semantic search ("supply chain disruption" → hurricane/freeze/COVID), exact match ("Suez Canal blockage" → Suez report at #1), attribute filter (carrier_negotiation type filter works) |
| 6 — Agent | ✅ **Done** | `FREIGHT_INTELLIGENCE_AGENT` created in `SNOWFLAKE_INTELLIGENCE.AGENTS` via Snowsight UI with both tools wired (`cortex_analyst_freight` + `freight_reports_search`). Orchestration + response instructions tuned for Highline domain. Registered in Snowflake Intelligence. **First test: "Top 5 commodities by total value 2024" → correct table + auto-chart + insight commentary + source attribution + follow-up suggestion.** All 4 agent capabilities (chart auto-gen, insight commentary, source citation, suggestion engine) verified working. |
| 7a — Forecast tool | ⨯ Not started | `ML.FORECAST` wrapper |
| 7b — Anomaly tool | ⨯ Not started | YoY shift detector |
| 7c — Backhaul tool | ⨯ Not started | **The kill shot** — $-quantified Highline-specific recommendations |
| 7d — Brief tool | ⨯ Not started | Executive Markdown brief generator |
| 8 — Test harness | ⨯ Not started | 40-question eval set, graded |
| 9 — Demo + polish | ⨯ Not started | 6-slide demo arc, rehearsed |

**Execution note:** Phase 5 (Cortex Search, ~30 min) was completed before Phase 4 (Cortex Analyst, 4-6 hours) as a quick-win confidence builder. The original plan listed them 4→5; actual order was 5→4. The dependency arrows still work — Phase 5 only depends on Phase 2 (reports loaded), not Phase 4.

---

## 16. Progress Log — What We Actually Built

### Phase 0 — Data prep (✅ before Snowflake)
- Pivoted wide CSV (38 cols, year-as-suffix) → long Parquet (15 cols, year-as-row)
- **Validation**: 1,113,135 wide rows × 7 years = 7,791,945 long rows ✓ exact
- **Validation**: every measure sum preserved to 1e-15 relative precision (machine epsilon)
- Output: `FAF5.7.1_State_2018-2024_long.parquet` (181 MB, 42% smaller than original CSV)

### Phase 1 — Snowflake infra (✅ run via Snowsight)
- `01_setup_infra.sql` — idempotent, ACCOUNTADMIN-only, pre-bakes the auth-policy lessons from the sales template
- Created: 1 database, 3 schemas, 1 warehouse (X-Small), 1 role, 2 stages
- `+ Add agent` capability granted to `FREIGHT_ANALYST_ROLE` (so we can create the agent later)
- Verified via `SHOW DATABASES / SCHEMAS / WAREHOUSES / ROLES / STAGES` — every object present

### Phase 2 — Data ingestion (✅ run via Snowsight)
- Uploaded 8 files to `@HIGHLINE_FREIGHT.DATA.DATA_STAGE` via Snowsight UI
- `02_load_data.sql` — created 8 tables (1 fact, 1 reports, 6 lookups), `COPY INTO` from stage
- **Row-count validation**: all 8 tables match expected counts ✓
- **Measure-total validation**: all 4 measures match cross-pipeline audit to the cent ✓
- Encountered + fixed: `MATCH_BY_COLUMN_NAME` for CSV requires `PARSE_HEADER = TRUE` (lesson captured in script)

### Phase 3 — Enriched view (✅ run via Snowsight)
- `03_create_views.sql` — created `V_FREIGHT_FLOWS_ENRICHED` (10 raw codes + 5 measures + 10 human-readable label columns)
- **Row count**: 7,791,945 ✓ (joins didn't multiply or drop)
- **Data quality**: all 10 unmatched-code counters = 0 ✓ (every code in fact table has a lookup match)
- Top-10 commodities by 2024 value smoke test: Electronics ($1.94T), Motorized vehicles ($1.61T), Pharma ($1.59T), Mixed freight, Machinery, **Plastics/rubber ($806B — Highline-relevant)**, Gasoline (highest tonnage at 1.46B kT), Natural gas, Other foodstuffs, Misc. mfg.

### Phase 5 — Cortex Search (✅ done out of order)
- `04_create_search.sql` — created `FREIGHT_REPORTS_SEARCH` with `ON report_text`, attributes `title / report_id / report_type / report_date`, default Arctic Embed
- Encountered + fixed: new multi-index `TEXT INDEXES / VECTOR INDEXES` syntax rejected our column types on this trial account — fell back to the legacy `ON column` syntax (same as sales template)
- **Test 1** (semantic): *"supply chain disruption from natural disaster"* → returned Hurricane Laura / Texas Freeze / COVID-19 — perfect semantic match
- **Test 2** (exact event): *"Suez Canal blockage"* → returned Suez 2021 at #1, Red Sea 2024 at #2 (Snowflake understood Red Sea is conceptually similar — same chokepoint category)
- **Test 3** (filtered): *"trucking rates and carrier capacity"* + `report_type = 'carrier_negotiation'` → returned 3 carrier-negotiation reports, all directly about trucking rates

### Phase 4 — Cortex Analyst semantic model (✅ uploaded + active)
- `freight_semantic_model.yaml` — **429 lines** describing `V_FREIGHT_FLOWS_ENRICHED` for the LLM
- **Coverage**: 8 dimensions × 8-12 synonyms each, 1 time dimension (`YEAR` 2018-2024), 6 measures (`TONS / VALUE / CURRENT_VALUE / TON_MILES / RECORD_COUNT / VALUE_PER_TON`), 2 Highline named filters (`highline_relevant_commodities` for SCTGs 24/32/33/36/37/41, `highline_lead_battery` for SCTGs 32+41)
- Uploaded to `@HIGHLINE_FREIGHT.MODELS.YAML_STAGE` (17.7 KB)
- Encountered + fixed (2 schema gotchas):
  - `expr: 1` (integer literal) → must be quoted string `expr: '1'`
  - `verified_queries:` field rejected by current YAML schema — removed from YAML; Snowflake's documented path is to add them via the Snowsight Semantic Model UI later
- Cross-validated against Phase 3 enrichment numbers (semantic model returns the same top-10 commodities)

### Phase 6 — Agent build (✅ created + tested)
- Agent: `SNOWFLAKE_INTELLIGENCE.AGENTS.FREIGHT_INTELLIGENCE_AGENT`
- Display name: "Freight Intelligence Agent"
- Tools wired: `cortex_analyst_freight` (semantic model) + `freight_reports_search` (Cortex Search)
- Model: `auto` (Snowflake-managed orchestration)
- Orchestration + response instructions tuned for Highline auto-aftermarket context (recognizes "our category" → applies SCTG filter; refuses out-of-scope years/granularity; cites sources)
- Registered with Snowflake Intelligence (`+ Add agent`) so it appears in the chat UI at `ai.snowflake.com/...`
- **First demo question** — *"What are the top 5 commodities by total value in 2024?"*  →  agent correctly:
  1. Routed to `cortex_analyst_freight`
  2. Generated valid SQL against `V_FREIGHT_FLOWS_ENRICHED`
  3. Returned the right top 5 (Electronics $2.33T, Mixed freight $2.05T, Pharmaceuticals $1.92T, Motorized vehicles $1.88T, Machinery $1.56T)
  4. Auto-generated a horizontal bar chart with proper axis label
  5. Wrote an interpretive insight ("Electronics leads by +$282B over Mixed freight…")
  6. Added source attribution ("Source: FAF5 freight data")
  7. Proposed a sensible follow-up ("What are the top 5 commodities by total tonnage in 2024?")

### Key validation numbers (pinned for posterity)

| Measure | Total across 2018-2024 | Notes |
|---|---|---|
| tons | **138,965,654.85** (thousand tons) | Verified at pivot, load, view |
| value | **131,284,710.61** (M USD, 2017 constant) | Verified at pivot, load, view |
| current_value | **155,235,499.01** (M USD, current) | Verified at pivot, load, view |
| tmiles | **37,607,491.73** (M ton-miles) | Verified at pivot, load, view |
| Total long-format rows | **7,791,945** | = 1,113,135 wide rows × 7 years |
| Reports indexed | **50** | 5 categories × 10 each |
| Lookup rows total | **120** | states 51 + sctg 42 + 8 + 3 + 8 + 8 |

---

*Plan owner: Rishi Kumar Kota. Last updated: 2026-05-10 (Phases 0-6 complete — agent is live and answering correctly; next is Phase 7 custom tools).*
