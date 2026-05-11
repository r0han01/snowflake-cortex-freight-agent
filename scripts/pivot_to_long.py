"""
Pivot the FAF5 state-level freight CSV from wide (year columns) to long (year rows)
format and save as Parquet, with full data-integrity validation.

Source : FAF5.7.1_State_2018-2024.csv  (wide format, 1,113,136 rows × 38 cols)
Output : FAF5.7.1_State_2018-2024_long.parquet  (long format, ~7.79M rows × 15 cols)
"""

import os
import sys
import time
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
WIDE_CSV   = os.path.join(HERE, "FAF5.7.1_State_2018-2024.csv")
LONG_CSV   = os.path.join(HERE, "FAF5.7.1_State_2018-2024_long.csv")
LONG_PQT   = os.path.join(HERE, "FAF5.7.1_State_2018-2024_long.parquet")

YEARS = [2018, 2019, 2020, 2021, 2022, 2023, 2024]
DIM_COLS = ["fr_orig", "dms_origst", "dms_destst", "fr_dest",
            "fr_inmode", "dms_mode", "fr_outmode",
            "sctg2", "trade_type", "dist_band"]
MEASURES = ["tons", "value", "current_value", "tmiles"]

# Dimension columns are codes — keep as strings to preserve leading zeros (e.g. "01"=Alabama)
# and to handle empty strings (foreign-region codes are blank for domestic rows).
DIM_DTYPES = {c: "string" for c in DIM_COLS}


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def main():
    # ---- 1. Read the wide CSV ---------------------------------------------------
    log(f"Reading {os.path.basename(WIDE_CSV)} ({os.path.getsize(WIDE_CSV)/1e6:.1f} MB)")
    df_wide = pd.read_csv(WIDE_CSV, dtype=DIM_DTYPES, keep_default_na=False, na_values=[""])

    wide_rows = len(df_wide)
    wide_cols = df_wide.shape[1]
    log(f"Wide shape: {wide_rows:,} rows × {wide_cols} cols")

    expected_cols = DIM_COLS + [f"{m}_{y}" for m in MEASURES for y in YEARS]
    missing = set(expected_cols) - set(df_wide.columns)
    extra   = set(df_wide.columns) - set(expected_cols)
    assert not missing, f"Missing expected columns: {missing}"
    assert not extra,   f"Unexpected extra columns: {extra}"
    log("Column schema matches expected 38-column layout")

    # ---- 2. Compute wide-side checksums (for validation later) -----------------
    log("Computing wide-side measure totals (for validation)")
    wide_totals = {}
    wide_nonnull = {}
    for m in MEASURES:
        total = 0.0
        nn = 0
        for y in YEARS:
            col = f"{m}_{y}"
            s = df_wide[col]
            total += s.sum(skipna=True)
            nn += s.notna().sum()
        wide_totals[m]  = total
        wide_nonnull[m] = int(nn)
    for m in MEASURES:
        log(f"  wide sum({m}_*) = {wide_totals[m]:,.6f}   (non-null cells: {wide_nonnull[m]:,})")

    # ---- 3. Pivot wide -> long via per-year slices ------------------------------
    # Doing it as 7 explicit slices (rather than wide_to_long) avoids the
    # 'current_value' / 'value' stub-name collision and is dead-simple to audit.
    log("Pivoting wide -> long (7 per-year slices, then concat)")
    parts = []
    for y in YEARS:
        cols_for_year = [f"{m}_{y}" for m in MEASURES]
        part = df_wide[DIM_COLS + cols_for_year].copy()
        part.columns = DIM_COLS + MEASURES
        part.insert(len(DIM_COLS), "year", pd.Series([y] * len(part), dtype="int16"))
        parts.append(part)
    df_long = pd.concat(parts, ignore_index=True)
    # Reorder so dim cols, then year, then measures
    df_long = df_long[DIM_COLS + ["year"] + MEASURES]

    long_rows = len(df_long)
    long_cols = df_long.shape[1]
    log(f"Long shape:  {long_rows:,} rows × {long_cols} cols")

    # ---- 4. Validate ------------------------------------------------------------
    log("Validating row count and measure totals")
    assert long_rows == wide_rows * len(YEARS), (
        f"Row count mismatch: {long_rows:,} != {wide_rows:,} × {len(YEARS)}"
    )
    log(f"  ✓ row count: {long_rows:,} == {wide_rows:,} × {len(YEARS)}")

    for m in MEASURES:
        long_total = df_long[m].sum(skipna=True)
        long_nn    = int(df_long[m].notna().sum())
        diff = abs(long_total - wide_totals[m])
        # Floating-point: allow a relative tolerance of 1e-9
        rel = diff / abs(wide_totals[m]) if wide_totals[m] != 0 else diff
        assert rel < 1e-9, (
            f"Sum mismatch for '{m}': wide={wide_totals[m]:.6f} long={long_total:.6f} diff={diff}"
        )
        assert long_nn == wide_nonnull[m], (
            f"Non-null count mismatch for '{m}': wide={wide_nonnull[m]} long={long_nn}"
        )
        log(f"  ✓ {m}: total {long_total:,.6f}  (rel diff {rel:.2e}), non-null {long_nn:,}")

    # ---- 5. Spot check a specific row -------------------------------------------
    # Take wide row 0 and confirm all 7 long rows for that key exist and match
    log("Spot-checking the first wide row across all 7 years")
    w0 = df_wide.iloc[0]
    key_mask = pd.Series([True] * len(df_long))
    for c in DIM_COLS:
        if pd.isna(w0[c]):
            key_mask &= df_long[c].isna()
        else:
            key_mask &= (df_long[c] == w0[c])
    matched = df_long[key_mask].sort_values("year").reset_index(drop=True)
    assert len(matched) == len(YEARS), f"Expected {len(YEARS)} long rows for wide row 0, got {len(matched)}"
    for i, y in enumerate(YEARS):
        for m in MEASURES:
            wval = w0[f"{m}_{y}"]
            lval = matched.iloc[i][m]
            if pd.isna(wval) and pd.isna(lval):
                continue
            assert wval == lval, (
                f"Spot check mismatch row0 {m}_{y}: wide={wval} long={lval}"
            )
    log(f"  ✓ All {len(YEARS)} years × {len(MEASURES)} measures match for wide row 0")

    # ---- 6. Write Parquet -------------------------------------------------------
    log(f"Writing Parquet -> {os.path.basename(LONG_PQT)}")
    # Compression: snappy is the default (fast read/write). Switch to 'zstd' for max compression.
    table = pa.Table.from_pandas(df_long, preserve_index=False)
    pq.write_table(table, LONG_PQT, compression="snappy")

    # ---- 7. Round-trip read the Parquet and re-validate -------------------------
    log("Round-trip: reading Parquet back and re-validating")
    df_rt = pq.read_table(LONG_PQT).to_pandas()
    assert len(df_rt) == long_rows, f"Parquet read row count mismatch: {len(df_rt)} != {long_rows}"
    for m in MEASURES:
        rt_total = df_rt[m].sum(skipna=True)
        diff = abs(rt_total - wide_totals[m])
        rel = diff / abs(wide_totals[m]) if wide_totals[m] != 0 else diff
        assert rel < 1e-9, f"Parquet round-trip sum mismatch for {m}: rel diff {rel}"
    log("  ✓ Parquet round-trip: row count + all measure totals match")

    # ---- 8. (Optional) also write the long CSV so user has both formats --------
    log(f"Writing long CSV -> {os.path.basename(LONG_CSV)} (for side-by-side comparison)")
    df_long.to_csv(LONG_CSV, index=False)

    # ---- 9. Final file-size report ---------------------------------------------
    sz_wide_csv = os.path.getsize(WIDE_CSV)
    sz_long_csv = os.path.getsize(LONG_CSV)
    sz_long_pqt = os.path.getsize(LONG_PQT)
    log("=" * 60)
    log("FINAL REPORT")
    log("=" * 60)
    log(f"Wide CSV    : {sz_wide_csv/1e6:>8.1f} MB   {wide_rows:>10,} rows × {wide_cols} cols")
    log(f"Long CSV    : {sz_long_csv/1e6:>8.1f} MB   {long_rows:>10,} rows × {long_cols} cols")
    log(f"Long Parquet: {sz_long_pqt/1e6:>8.1f} MB   {long_rows:>10,} rows × {long_cols} cols")
    log(f"Parquet vs wide CSV : {sz_long_pqt/sz_wide_csv*100:.1f}% of size")
    log(f"Parquet vs long CSV : {sz_long_pqt/sz_long_csv*100:.1f}% of size")


if __name__ == "__main__":
    sys.exit(main())
