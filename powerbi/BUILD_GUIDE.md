# Power BI dashboard: build guide

Rebuilds the five-page monitoring dashboard in Power BI Desktop on top of the same
BigQuery `*_latest` views. Files in this folder:

| File | What it is |
|---|---|
| `queries.pq` | Power Query (M) for every table, including a CSV-source variant |
| `measures.dax` | Every DAX measure, with the display format for each |
| `theme.json` | Report theme (colours, fonts, table header style) |
| `export_views.sh` | Cloud Shell script that exports the views to CSV (fallback source) |

Budget roughly half a day for a first build.

---

## 0. Prerequisites

- **Windows** with **Power BI Desktop** (free, Microsoft Store). It does not run on macOS;
  on a Mac use Parallels/UTM with Windows 11, or a Windows cloud PC.
- A Google account with BigQuery read access to `project-01523b1d-fc19-4c00-97e`.
- Create the one new view, once, in Cloud Shell:
  ```bash
  bq query --use_legacy_sql=false < sql/07_model_metrics_latest.sql
  ```

## 1. Create the project file

1. Open Power BI Desktop > **File > Save as** > choose **Power BI project (\*.pbip)**,
   name it `CreditRiskMonitoring`, save it inside this `powerbi/` folder.
   (If .pbip isn't offered: **File > Options > Preview features > Power BI Project
   (.pbip) save option**, restart.) A .pbip is a folder of text files, so it diffs in git.
2. **View > Themes > Browse for themes** > `powerbi/theme.json`.

## 2. Connect and load

**Live BigQuery (preferred):** **Home > Get data > Google BigQuery** > sign in with the
Google account > **Connect** > close the Navigator without loading. This stores the
credential.

**CSV fallback:** in Cloud Shell run `./powerbi/export_views.sh`, download
`powerbi/data/`, and use the *CSV variant* of `BigQuerySource` from `queries.pq`
(edit `Folder` to where you saved the files).

Then **Home > Transform data**, and for each section of `queries.pq` in order:
**New Source > Blank Query > Advanced Editor**, paste, rename the query to the name in
the section header. Right-click `BigQuerySource` and `LatestModelVersion` > untick
**Enable load**. **Close & Apply**.

Tables you should now have: `model_metrics`, `rollups`, `topk`, `score_drift`,
`feature_drift`, `alerts`, `Split`, `Month`, `Feature`.

## 3. Model view

Relationships (all single-direction, one-to-many from the dimension):

| From (one) | To (many) |
|---|---|
| `Split[split]` | `model_metrics[split]`, `rollups[split]`, `topk[split]`, `score_drift[split]`, `feature_drift[split]` |
| `Month[issue_month]` | `score_drift[issue_month]`, `feature_drift[issue_month]` |
| `Feature[feature_name]` | `feature_drift[feature_name]` |

`alerts` stays unrelated (the Alerts page shows all current alerts, as before).

Sort-by-column (**Column tools > Sort by column**):
- `topk[K]` by `topk[k_order]`
- `Month[issue_month]` by `Month[month_start]`
- `Split[split]` by `Split[split_order]`
- `alerts[severity]` by `alerts[severity_rank]`

Hide the raw numeric columns in the fact tables (right-click > Hide in report view) so
only measures show up in the field list.

## 4. Measures

**Home > Enter data**, name the table `_Measures`, **Load**. Select it, then for each
block in `measures.dax`: **Modeling > New measure**, paste, and set the format from the
comment under it.

## 5. Pages

Canvas: 16:9. Each page gets a centred title text box, a grey subtitle, and the grey
explanatory paragraph at the bottom (copy the wording from the current screenshots in
`docs/screenshots/`).

### Page 1: Executive Summary
- Title "Credit Risk PD Model - Executive Summary", subtitle "Out-of-time test
  performance, latest run".
- Five **Card** visuals in a row: `ROC AUC (Test)`, `Brier (Test)`, `Lift @ 5% (Test)`,
  `Recall @ 5% (Test)`, `Loans Evaluated (Test)`.
- **Table**: `Split[split]`, `Loans`, `Base Rate`, `Lift @ 1%`, `Lift @ 5%`,
  `Lift @ 10%`, `Recall @ 5%`, `Recall @ 10%` (shows valid and test rows).
- Footer: a **Card** with `Model Version`, plus the training-data sentence.

### Page 2: Lift / Recall Performance
- **Slicer** `Split[split]`, style **Dropdown**, **Single select** on, set to `test`.
- **Clustered column chart** "Lift @ K": X `topk[K]`, Y `Lift @ K`, data labels on.
  Analytics pane > **Constant line** at 1, dashed grey, label "Random baseline".
- **Clustered column chart** "Recall @ K": X `topk[K]`, Y `Recall @ K`, data labels on.
- **Table**: `Split[split]`, `Loans`, `Base Rate`, `Top 5% Default Rate`, `Lift @ 1%`,
  `Lift @ 5%`, `Lift @ 10%`, `Recall @ 5%`, `Recall @ 10%`.
- Footer: the Lift@K / Recall@K definitions.

### Page 3: Score Drift
- Split slicer (as page 2).
- **Line chart** "Predicted PD distribution by issue month": X `Month[issue_month]`,
  Y `Mean PD`, `Median PD (p50)`, `PD p90`, `PD p99`. Make p50 dashed
  (Format > Lines > per series).
- **Clustered column chart** "Loans scored per month": X `Month[issue_month]`,
  Y `Loans Scored`.
- **Table**: `Month[issue_month]`, `Loans Scored`, `Mean PD`, `Median PD (p50)`,
  `PD p90`, `PD p99`, sorted by month ascending.

### Page 4: Feature Drift
- **Slicer** `Feature[feature_name]` (Dropdown, single select, default `interest_rate`)
  and the Split slicer.
- **Line chart** "Feature mean over time": X `Month[issue_month]`, Y `Feature Mean`.
  For categorical features this is blank; add a second line chart with
  `Top Category Share` so both feature types show something.
- **Table** "Feature summary": `Feature[feature_name]`, `feature_drift[feature_type]`,
  `feature_drift[top_category]`, `Feature Loans`, `Null Rate`, `Feature Mean`,
  `Feature Std Dev`, `Top Category Share`, `Entropy`.

### Page 5: Alerts
- Three **Cards**: `Critical Alerts`, `Warning Alerts`, `Info Alerts`. Format >
  Effects > Background > fx > Field value > `Critical Card Colour` /
  `Warning Card Colour` (Info stays grey).
- **Table** "Alert counts": `alerts[severity]`, `alerts[alert_type]`, `Alert Count`.
- **Table** "Alert detail": `alerts[severity]`, `alerts[alert_type]`,
  `alerts[issue_month]`, `alerts[feature_name]`, `alerts[model_version]`,
  `alerts[observed_value]`, `alerts[threshold_value]`, `alerts[message]`.
  Conditional formatting on `severity`: red / orange / grey background.

### Sync the Split slicer
Select the Split slicer > **View > Sync slicers** > tick pages 2, 3, 4 (sync and
visible). Leave pages 1 and 5 unticked.

## 6. Check against the old dashboard

The numbers must match the current screenshots for the same model version
(`20260430-002800`): test ROC-AUC 0.706, Brier 0.179, Lift@5% 2.11×, Recall@5% 11.2%,
147,389 test loans, 1 critical `categorical_share_drift` alert for 2016-09. A mismatch
usually means a missing relationship or the model-version filter.

## 7. Screenshots and commit

1. For each page, **File > Export > Export to PDF**, or take a window screenshot at
   1800px wide, and save over the existing files so the README links keep working:
   `docs/screenshots/01_executive_summary.png`, `02_lift_recall_performance.png`,
   `03_score_drift.png`, `04_feature_drift.png`, `05_alerts.png`.
2. Commit `powerbi/CreditRiskMonitoring.pbip` plus the `CreditRiskMonitoring.Report/` and
   `CreditRiskMonitoring.SemanticModel/` folders. `.gitignore` already excludes the
   local cache and credentials files Power BI writes alongside them.
3. Then update the README, `ARCHITECTURE.md` and `MODEL_CARD.md` to describe the Power BI
   dashboard.
