# `semantic_models/` — Cortex Analyst semantic model

YAML file that tells Snowflake Cortex Analyst how to translate natural-language questions into SQL against `V_FREIGHT_FLOWS_ENRICHED`. This is the single most important file for agent accuracy — ~80% of question-answering quality lives here.

## File

### `freight_semantic_model.yaml` (429 lines)

| Section | Count | Notes |
|---|---|---|
| Logical tables | 1 | Targets `HIGHLINE_FREIGHT.DATA.V_FREIGHT_FLOWS_ENRICHED` |
| Dimensions | 8 | Origin/dest state, foreign origin/dest, commodity, mode, trade type, distance band — each with 8–12 synonyms |
| Time dimensions | 1 | `YEAR` (2018–2024) |
| Measures | 6 | `TONS / VALUE / CURRENT_VALUE / TON_MILES / RECORD_COUNT / VALUE_PER_TON` |
| Named filters | 2 | `highline_relevant_commodities` (auto-aftermarket SCTGs), `highline_lead_battery` (lead supply chain) |

## How to upload

Snowsight → **Catalog → HIGHLINE_FREIGHT → MODELS → YAML_STAGE → + Files** → pick `freight_semantic_model.yaml` → Upload.

Or via SnowSQL:

```sql
PUT file://freight_semantic_model.yaml @HIGHLINE_FREIGHT.MODELS.YAML_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```

## How the agent uses it

The `FREIGHT_INTELLIGENCE_AGENT` tool `cortex_analyst_freight` references this YAML at `@HIGHLINE_FREIGHT.MODELS.YAML_STAGE/freight_semantic_model.yaml`. When the user asks a structured question, the agent invokes Cortex Analyst, which reads this YAML and produces SQL.

## Domain-specific shortcuts

User phrases that trigger built-in filters:

| User says | YAML filter | Effect |
|---|---|---|
| "our category", "auto aftermarket", "our products" | `highline_relevant_commodities` | Restricts to SCTGs 24/32/33/36/37/41 |
| "battery supply chain", "lead and recycling" | `highline_lead_battery` | Restricts to SCTGs 32 (lead) + 41 (scrap) |

## Schema notes (learned the hard way)

- `expr:` fields must be **strings**. Quote any numeric literal (`expr: '1'` not `expr: 1`).
- `verified_queries:` is not supported in this YAML schema at the table level — add them through the Snowsight Semantic Model UI instead.
- Sample values that are numbers should be quoted strings (`'2024'` not `2024`).
