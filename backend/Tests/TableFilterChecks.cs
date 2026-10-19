using Ras.Backend;

internal static class TableFilterChecks
{
    internal static void Run()
    {
        TableFilterColumn[] columns = [new("name", "Name", "string"), new("length", "Length", "double"),
            new("enabled", "Enabled", "bool"), new("time", "Start Time", "DateTime"),
            new("duration", "Duration", "TimeSpan"), new("private", "Private", "string", false)];
        TableFilterRow[] rows = [
            Row("reach", "Reach A", "1200", "true", "2025-04-03T09:30:00", "00:15:00"),
            Row("small", "Reach B", "80", "false", "2025-04-02T09:30:00", "00:02:00"),
            Row("other", "渠段一", "2000", "true", "2025-04-04T09:30:00", "00:25:00"),
            Row("missing", "", "NaN", "false", "", "")];
        Expect("Length > 1000 AND Name LIKE 'Reach%'", ["reach"]);
        Expect("Enabled = true AND (Name LIKE 'Reach%' OR Name = '渠段一')", ["reach", "other"]);
        Expect("NOT (Length IN (80, 1200)) AND Length IS NOT NULL", ["other"]);
        Expect("Start_Time >= '2025-04-03' AND Duration >= 15min", ["reach", "other"]);
        Expect("Name IS NULL OR Length IS NULL", ["missing"]);
        Expect("Name LIKE 'reach%'", ["reach", "small"]);
        Expect("", rows.Select(row => row.Id).ToArray());
        TableFilterResult syntax = TableFilterService.Evaluate(new("Length > AND Name", columns, rows));
        Check(!syntax.Valid && !syntax.ClearActiveFilter && !string.IsNullOrEmpty(syntax.Error), "Invalid syntax retains the last active filter.");
        TableFilterResult absent = TableFilterService.Evaluate(new("Private = 'secret'", columns, rows));
        Check(!absent.Valid && absent.ClearActiveFilter, "A nonfilterable column cannot be referenced in expressions.");
        TableFilterResult removed = TableFilterService.Evaluate(new("Length > 1000", columns.Where(column => column.Id != "length").ToArray(), rows));
        Check(!removed.Valid && removed.ClearActiveFilter, "Removing a referenced column clears the active filter as in the source grid.");
        TableFilterColumn[] duplicateHeaders = [new("first", "Flow Rate", "double"), new("second", "Flow_Rate", "double")];
        TableFilterRow[] duplicateRows = [new("same", new() { ["first"] = "10", ["second"] = "200" })];
        Check(TableFilterService.Evaluate(new("FlowRate = 10", duplicateHeaders, duplicateRows)).RowIds.SequenceEqual(["same"]),
            "The first normalized header wins exactly as in DataGrid.BuildFilterRow.");
        bool duplicateRejected = false;
        try { TableFilterService.Evaluate(new("Name = 'A'", columns, [rows[0], rows[0]])); }
        catch (ArgumentException) { duplicateRejected = true; }
        Check(duplicateRejected, "Duplicate row identities are rejected.");
        TableFilterRow[] pendingDraft = [Row("raw", "A", "unfinished number", "false", "", "")];
        Check(TableFilterService.Evaluate(new("Name = 'A' OR Length > 10", columns, pendingDraft)).RowIds.SequenceEqual(["raw"]),
            "Unrelated or short-circuited numeric draft fields do not fail a string filter.");

        void Expect(string expression, string[] expected)
        {
            TableFilterResult result = TableFilterService.Evaluate(new(expression, columns, rows));
            Check(result.Valid && result.RowIds.SequenceEqual(expected), "Retained parser/evaluator: " + expression + " / " + result.Error);
        }
    }

    private static TableFilterRow Row(string id, string name, string length, string enabled, string time, string duration) =>
        new(id, new() { ["name"] = name, ["length"] = length, ["enabled"] = enabled, ["time"] = time,
            ["duration"] = duration, ["private"] = "secret" });
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
