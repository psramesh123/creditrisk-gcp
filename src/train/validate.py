"""
Data validation before training.

Checks the train / valid / test splits loaded from BigQuery and stops
training if something is clearly wrong, so a bad upstream change (a broken
SQL edit, a reloaded table, a changed source file) cannot silently produce a
model.

Two levels:
    FAIL  stops training (structural problems, leakage, impossible values)
    WARN  is printed and saved, but training continues

Set SKIP_VALIDATION=1 to bypass (for example, while debugging).
"""

import json
import os

import pandas as pd

LABEL_COL = "label"
MATURITY_GUARD = pd.Timestamp("2017-12-01")

MIN_TRAIN_ROWS = 100_000     # full table has ~1M train rows; skipped with BQ_LIMIT
LABEL_RATE_RANGE = (0.05, 0.60)
NULL_WARN, NULL_FAIL = 0.05, 0.50
RANGE_WARN, RANGE_FAIL = 0.0, 0.01  # share of rows outside the plausible range
LABEL_SHIFT_WARN = 0.10      # absolute change in default rate between splits

# Plausible ranges for Lending Club features. Wide on purpose: these catch
# unit changes and parsing errors, not unusual borrowers.
RANGES = {
    "loan_amount": (500, 50_000),
    "interest_rate": (1, 40),
    "installment": (1, 2_000),
    "annual_income": (1, 1e8),
    "dti": (0, 100),
    "fico_low": (300, 850),
    "fico_high": (300, 850),
    "open_acc": (0, 200),
    "total_acc": (0, 300),
    "pub_rec": (0, 100),
    "delinq_2yrs": (0, 100),
    "inq_last_6mths": (0, 50),
    "revol_bal": (0, 1e8),
    "revol_util": (0, 1_000),
    "credit_history_years": (0, 90),
}
ALLOWED_VALUES = {"term_months": {36, 60}}


class _Report:
    def __init__(self):
        self.fails, self.warns = [], []

    def fail(self, msg):
        self.fails.append(msg)

    def warn(self, msg):
        self.warns.append(msg)


def validate_splits(splits: dict, num_cols: list, cat_cols: list, limited: bool = False) -> dict:
    """Validate {"train": df, "valid": df, "test": df}. Returns a report dict."""
    r = _Report()
    features = num_cols + cat_cols
    stats = {}

    # 1. Structure
    for name in ("train", "valid"):
        if name not in splits or len(splits[name]) == 0:
            r.fail(f"{name} split is empty")
    if not limited and len(splits.get("train", [])) < MIN_TRAIN_ROWS:
        r.fail(f"train has {len(splits.get('train', [])):,} rows (< {MIN_TRAIN_ROWS:,})")
    for name, df in splits.items():
        missing = [c for c in features + [LABEL_COL, "loan_id", "issue_date"] if c not in df.columns]
        if missing:
            r.fail(f"{name}: missing columns {missing}")
    if r.fails:
        return _finish(r, stats)

    nonempty = {k: v for k, v in splits.items() if len(v)}

    # 2. Labels
    for name, df in nonempty.items():
        y = df[LABEL_COL]
        if y.isna().any():
            r.fail(f"{name}: {int(y.isna().sum())} missing labels")
        bad = ~y.dropna().isin([0, 1])
        if bad.any():
            r.fail(f"{name}: label has values other than 0/1")
        rate = float(y.mean())
        stats[f"{name}_rows"] = int(len(df))
        stats[f"{name}_default_rate"] = round(rate, 4)
        lo, hi = LABEL_RATE_RANGE
        if not lo <= rate <= hi:
            r.fail(f"{name}: default rate {rate:.3f} outside {LABEL_RATE_RANGE}")
    if "train" in nonempty:
        base = stats["train_default_rate"]
        for name in ("valid", "test"):
            if name in nonempty and abs(stats[f"{name}_default_rate"] - base) > LABEL_SHIFT_WARN:
                r.warn(f"{name} default rate {stats[f'{name}_default_rate']} differs from "
                       f"train {base} by more than {LABEL_SHIFT_WARN}")

    # 3. Time ordering and maturity guard (out-of-time split must hold)
    dates = {k: pd.to_datetime(v["issue_date"]) for k, v in nonempty.items()}
    order = [s for s in ("train", "valid", "test") if s in dates]
    for a, b in zip(order, order[1:]):
        if dates[a].max() >= dates[b].min():
            r.fail(f"time split broken: latest {a} date {dates[a].max().date()} "
                   f">= earliest {b} date {dates[b].min().date()}")
    latest = max(d.max() for d in dates.values())
    if latest > MATURITY_GUARD:
        r.fail(f"loans issued after the maturity guard ({latest.date()} > {MATURITY_GUARD.date()})")

    # 4. No loan in more than one split, no duplicates within a split
    seen = {}
    for name, df in nonempty.items():
        ids = df["loan_id"].astype(str)
        if ids.duplicated().any():
            r.fail(f"{name}: {int(ids.duplicated().sum())} duplicate loan_ids")
        for other, other_ids in seen.items():
            overlap = len(set(ids) & other_ids)
            if overlap:
                r.fail(f"{overlap} loan_ids appear in both {other} and {name}")
        seen[name] = set(ids)

    # 5. Missing values (on train, where the model learns)
    if "train" in nonempty:
        train = nonempty["train"]
        for c in features:
            share = float(train[c].isna().mean())
            if share > NULL_FAIL:
                r.fail(f"train.{c}: {share:.1%} missing")
            elif share > NULL_WARN:
                r.warn(f"train.{c}: {share:.1%} missing")

    # 6. Plausible ranges and allowed values (all splits)
    all_rows = pd.concat(nonempty.values(), ignore_index=True)
    for c, (lo, hi) in RANGES.items():
        if c not in num_cols:
            continue
        x = pd.to_numeric(all_rows[c], errors="coerce").dropna()
        if len(x) == 0:
            continue
        share = float(((x < lo) | (x > hi)).mean())
        if share > RANGE_FAIL:
            r.fail(f"{c}: {share:.2%} of values outside [{lo}, {hi}]")
        elif share > RANGE_WARN:
            r.warn(f"{c}: {share:.3%} of values outside [{lo}, {hi}]")
    for c, allowed in ALLOWED_VALUES.items():
        if c in num_cols:
            vals = set(pd.to_numeric(all_rows[c], errors="coerce").dropna().astype(int))
            if not vals <= allowed:
                r.fail(f"{c}: unexpected values {sorted(vals - allowed)}")

    return _finish(r, stats)


def _finish(r: _Report, stats: dict) -> dict:
    return {"passed": not r.fails, "fails": r.fails, "warnings": r.warns, "stats": stats}


def enforce(report: dict, out_path: str | None = None) -> None:
    """Print the report, save it, and stop if any check failed."""
    if out_path:
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        with open(out_path, "w") as f:
            json.dump(report, f, indent=2)
    for w in report["warnings"]:
        print(f"[validation WARN] {w}")
    for e in report["fails"]:
        print(f"[validation FAIL] {e}")
    if not report["passed"]:
        raise SystemExit(
            f"Data validation failed ({len(report['fails'])} problem(s)); training stopped. "
            "Fix the data or set SKIP_VALIDATION=1 to bypass."
        )
    print(f"Data validation passed ({len(report['warnings'])} warning(s)).")
