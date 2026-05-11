# `scripts/` — Python data prep utilities

Two re-runnable Python scripts that prep the raw FAF5 data and metadata into Snowflake-ready files.

## Files

### `pivot_to_long.py`
Converts the official wide-format FAF5 CSV (38 columns, year-as-suffix: `tons_2018, tons_2019, ...`) into long format (15 columns, `year` as a row value). Outputs Parquet (and CSV) with full data-integrity validation: every measure sum is verified to floating-point precision against the source.

- **Input**: `../../FAF5.7.1_State_2018-2024/FAF5.7.1_State_2018-2024.csv` (309 MB, 1,113,135 rows)
- **Output**: `..._long.parquet` (181 MB, 7,791,945 rows) + `..._long.csv` (443 MB)

### `build_lookups.py`
Extracts the FAF5 codebook (`FAF5_metadata.xlsx`) into the 6 lookup CSVs in [`../lookups/`](../lookups/). Applies sheet-specific overrides (e.g. simplifying trade-type names from verbose descriptions to `Domestic`/`Import`/`Export`).

- **Input**: `../../FAF5.7.1_State_2018-2024/FAF5_metadata.xlsx`
- **Output**: 6 files in `../lookups/`

## Run them

```bash
# from the Project/ directory
python3 scripts/build_lookups.py
python3 scripts/pivot_to_long.py
```

## Dependencies

See [`../requirements.txt`](../requirements.txt). Tested on Python 3.9+.
