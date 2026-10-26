// Power Query (M) for the Power BI dashboard.
//
// In Power BI Desktop: Home > Transform data > New Source > Blank Query, open the
// Advanced Editor, paste ONE section below, and rename the query to the name in
// its header. Create the queries in order: BigQuerySource first, LatestModelVersion
// second, the rest after. Mark BigQuerySource and LatestModelVersion as
// "Enable load = off" (right-click the query) so they are helpers, not tables.
//
// If a navigation step errors (connector versions name things slightly
// differently), connect once through Get Data > Google BigQuery > Navigator and
// copy the first three generated steps over the ones here.


// ============================================================================
// BigQuerySource   (helper, load disabled)
// ============================================================================
let
    Source = GoogleBigQuery.Database([BillingProject = "project-01523b1d-fc19-4c00-97e"]),
    Project = Source{[Name = "project-01523b1d-fc19-4c00-97e"]}[Data],
    Dataset = Project{[Name = "creditrisk", Kind = "Schema"]}[Data]
in
    Dataset


// ============================================================================
// BigQuerySource, CSV variant   (use INSTEAD of the BigQuery version above when
// building from files exported by powerbi/export_views.sh; everything else
// stays the same because this returns the same Name/Kind/Data navigation table)
// ============================================================================
let
    Folder = "C:\path\to\creditrisk-gcp\powerbi\data\",  // M strings do not escape backslashes
    Views = {"model_metrics_latest", "monitoring_rollups_latest", "score_drift_latest",
             "feature_drift_latest", "monitoring_alerts_latest"},
    Load = (view as text) as table =>
        let
            Raw = Csv.Document(File.Contents(Folder & view & ".csv"), [Delimiter = ",", Encoding = 65001]),
            Promoted = Table.PromoteHeaders(Raw, [PromoteAllScalars = true]),
            // bq writes NULL as an empty field; make it a real null before typing
            Nulls = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted))
        in
            Nulls,
    Dataset = Table.FromRecords(List.Transform(Views, each [Name = _, Kind = "View", Data = Load(_)]))
in
    Dataset


// ============================================================================
// LatestModelVersion   (helper, load disabled)
// The *_latest views keep the newest run per model_version, so older model
// versions are still in them. Every table below is filtered to this version.
// model_version is a sortable timestamp string (e.g. 20260430-002800).
// ============================================================================
let
    Metrics = BigQuerySource{[Name = "model_metrics_latest", Kind = "View"]}[Data],
    Latest = List.Max(Metrics[model_version])
in
    Latest


// ============================================================================
// model_metrics
// ============================================================================
let
    Source = BigQuerySource{[Name = "model_metrics_latest", Kind = "View"]}[Data],
    Filtered = Table.SelectRows(Source, each [model_version] = LatestModelVersion),
    Kept = Table.SelectColumns(Filtered, {"ts", "model_version", "split", "roc_auc", "pr_auc", "brier"}),
    Typed = Table.TransformColumnTypes(Kept, {
        {"roc_auc", type number}, {"pr_auc", type number}, {"brier", type number}}, "en-US")
in
    Typed


// ============================================================================
// rollups
// ============================================================================
let
    Source = BigQuerySource{[Name = "monitoring_rollups_latest", Kind = "View"]}[Data],
    Filtered = Table.SelectRows(Source, each [model_version] = LatestModelVersion),
    Typed = Table.TransformColumnTypes(Filtered, {
        {"n", Int64.Type}, {"base_rate", type number},
        {"top_1pct_default_rate", type number}, {"top_5pct_default_rate", type number},
        {"top_10pct_default_rate", type number},
        {"lift_at_1pct", type number}, {"lift_at_5pct", type number}, {"lift_at_10pct", type number},
        {"recall_at_1pct", type number}, {"recall_at_5pct", type number},
        {"recall_at_10pct", type number}}, "en-US")
in
    Typed


// ============================================================================
// topk   (rollups reshaped to one row per split x K, for the Lift@K / Recall@K bars)
// ============================================================================
let
    Source = rollups,
    ForK = (label as text, order as number, liftCol as text, recallCol as text) as table =>
        let
            Picked = Table.SelectColumns(Source, {"split", liftCol, recallCol}),
            Renamed = Table.RenameColumns(Picked, {{liftCol, "lift"}, {recallCol, "recall"}}),
            WithK = Table.AddColumn(Renamed, "K", each label),
            WithOrder = Table.AddColumn(WithK, "k_order", each order)
        in
            WithOrder,
    Rows = Table.Combine({
        ForK("Top 1%", 1, "lift_at_1pct", "recall_at_1pct"),
        ForK("Top 5%", 5, "lift_at_5pct", "recall_at_5pct"),
        ForK("Top 10%", 10, "lift_at_10pct", "recall_at_10pct")
    }),
    Typed = Table.TransformColumnTypes(Rows, {
        {"split", type text}, {"K", type text}, {"k_order", Int64.Type},
        {"lift", type number}, {"recall", type number}}, "en-US")
in
    Typed


// ============================================================================
// score_drift
// ============================================================================
let
    Source = BigQuerySource{[Name = "score_drift_latest", Kind = "View"]}[Data],
    Filtered = Table.SelectRows(Source, each [model_version] = LatestModelVersion),
    Typed = Table.TransformColumnTypes(Filtered, {
        {"n", Int64.Type}, {"avg_pd", type number}, {"p50", type number},
        {"p90", type number}, {"p99", type number}}, "en-US")
in
    Typed


// ============================================================================
// feature_drift
// ============================================================================
let
    Source = BigQuerySource{[Name = "feature_drift_latest", Kind = "View"]}[Data],
    Filtered = Table.SelectRows(Source, each [model_version] = LatestModelVersion),
    Typed = Table.TransformColumnTypes(Filtered, {
        {"n", Int64.Type}, {"null_rate", type number}, {"mean", type number},
        {"std", type number}, {"min", type number}, {"max", type number},
        {"top_category_share", type number}, {"entropy", type number}}, "en-US")
in
    Typed


// ============================================================================
// alerts   (alerts are not filtered by model version: older-version alerts that
// are still the latest run of their alert_type stay visible, as in the old dashboard)
// ============================================================================
let
    Source = BigQuerySource{[Name = "monitoring_alerts_latest", Kind = "View"]}[Data],
    Typed = Table.TransformColumnTypes(Source, {
        {"observed_value", type number}, {"threshold_value", type number}}, "en-US"),
    // Severities are written as CRITICAL / WARN / INFO; normalise for display and sorting
    Upper = Table.TransformColumns(Typed, {{"severity", Text.Upper, type text}}),
    WithRank = Table.AddColumn(Upper, "severity_rank", each
        if [severity] = "CRITICAL" then 1 else if [severity] = "WARN" then 2 else 3, Int64.Type)
in
    WithRank


// ============================================================================
// Split   (dimension: drives the Split slicer on every page that has one)
// ============================================================================
let
    Source = Table.FromRecords({[split = "test", split_order = 1], [split = "valid", split_order = 2]}),
    Typed = Table.TransformColumnTypes(Source, {{"split", type text}, {"split_order", Int64.Type}}, "en-US")
in
    Typed


// ============================================================================
// Month   (dimension: shared issue-month axis for score and feature drift)
// ============================================================================
let
    Months = List.Distinct(List.Combine({score_drift[issue_month], feature_drift[issue_month]})),
    AsTable = Table.FromList(Months, Splitter.SplitByNothing(), {"issue_month"}),
    WithDate = Table.AddColumn(AsTable, "month_start", each Date.FromText([issue_month] & "-01"), type date),
    Typed = Table.TransformColumnTypes(WithDate, {{"issue_month", type text}}, "en-US")
in
    Typed


// ============================================================================
// Feature   (dimension: drives the Feature slicer on the Feature Drift page)
// ============================================================================
let
    Names = List.Sort(List.Distinct(feature_drift[feature_name])),
    AsTable = Table.FromList(Names, Splitter.SplitByNothing(), {"feature_name"}),
    Typed = Table.TransformColumnTypes(AsTable, {{"feature_name", type text}}, "en-US")
in
    Typed
