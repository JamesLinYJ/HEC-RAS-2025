using System.Security.Cryptography;
using System.Globalization;
using Geospatial.IO;
using Geospatial.Vectors;
using Ras.Backend;
using Utility.Memory;
using Visual.Observables;

static class AttributeTableChecks
{
    public static void Run()
    {
        var dir = Path.Combine(Path.GetTempPath(), "HECRASAttributeTable-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            using var culture = new CultureScope(CultureInfo.GetCultureInfo("fr-FR"));
            var table = new Table();
            table.AddColumn("Name", typeof(string)); table.AddColumn("Count", typeof(int)); table.AddColumn("Depth", typeof(double)); table.AddColumn("Active", typeof(bool));
            table.AddNewRow(["中文样本", 7, 2.5, true]); table.AddNewRow(["second", -3, 0.125, false]); table.AddNewRow(["空值", null!, null!, null!]);
            var path = Path.Combine(dir, "属性.shp");
            var write = ShapefileIO.Write(path, new List<Point> { new(1, 2), new(3, 4), new(5, 6) }, table);
            Check(write, "Source shapefile fixture write");
            var hashes = Directory.GetFiles(dir).ToDictionary(file => file, file => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(file))));
            var snapshot = AttributeTableService.Load(new(path));
            Check(snapshot.ShapeType == "Point" && snapshot.Rows.Length == 3 && snapshot.Columns.Length == 4, "Actual source table load");
            string name = snapshot.Columns.Single(c => c.Name == "Name").Id, depth = snapshot.Columns.Single(c => c.Name == "Depth").Id;
            Check(snapshot.Rows[0].Values[name] == "中文样本" && snapshot.Rows[1].Values[depth] == "0.125", "Actual UTF8 and typed source values");
            Check(snapshot.Columns.Single(c => c.Name == "Active").Type == "Boolean" && snapshot.Rows[0].Values[snapshot.Columns[3].Id] == "True", "DBF logical values restore source Boolean type");
            Check(snapshot.Rows[2].Values[depth] is null && snapshot.Rows[2].Values[snapshot.Columns[1].Id] is null && snapshot.Rows[2].Values[snapshot.Columns[3].Id] is null, "DBF numeric/logical nulls are not fabricated zero/false");
            var added = AttributeTableService.Transform(new(snapshot, new("addColumn", Name: "中文新列", Type: "Integer")));
            var newColumn = added.Columns.Last();
            Check(added.Rows.All(row => row.Values.ContainsKey(newColumn.Id) && row.Values[newColumn.Id] is null), "New source column retains null default");
            var edited = AttributeTableService.Transform(new(added, new("setCells", Cells: [new(snapshot.Rows[0].Id, newColumn.Id, "42"), new(snapshot.Rows[1].Id, depth, null)])));
            Check(edited.Rows[0].Values[newColumn.Id] == "42" && edited.Rows[1].Values[depth] is null, "Source typed edit and null remain distinct");
            var renamed = AttributeTableService.Transform(new(edited, new("renameColumn", newColumn.Id, "更名")));
            Check(renamed.Columns.Last().Id == newColumn.Id && renamed.Columns.Last().Name == "更名", "Rename retains column identity");
            var removed = AttributeTableService.Transform(new(renamed, new("removeColumn", name)));
            Check(removed.Columns.Length == 4 && removed.Rows[0].Values[newColumn.Id] == "42" && !removed.Rows[0].Values.ContainsKey(name), "Deleting earlier column preserves cell association");
            Expect<ArgumentException>(() => AttributeTableService.Transform(new(snapshot, new("addColumn", Name: "name", Type: "String"))));
            Expect<ArgumentException>(() => AttributeTableService.Transform(new(snapshot, new("renameColumn", depth, "NAME"))));
            Expect<FormatException>(() => AttributeTableService.Transform(new(added, new("setCells", Cells: [new(snapshot.Rows[0].Id, newColumn.Id, "3.5")]))));
            Check(added.Rows[0].Values[newColumn.Id] is null, "Failed source edit preserves input snapshot");
            foreach (var file in hashes) Check(file.Value == Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(file.Key))), "Table viewing/working edits never overwrite original shapefile files");
            var defaults = AttributeTableService.Transform(new(snapshot with { InitValueTypesToDefault = true }, new("addColumn", Name: "Default", Type: "Integer")));
            Check(defaults.Rows.All(row => row.Values[defaults.Columns.Last().Id] == "0"), "Source value-type default policy retained");
            var unicode = new Table(); unicode.AddColumn("分类名称甲", typeof(string)); unicode.AddColumn("分类名称乙", typeof(string));
            unicode.AddNewRow(["🙂" + new string('汉', 100), ""]);
            string unicodePath = Path.Combine(dir, "unicode.dbf");
            Check(DbfIO.TryWrite(unicodePath, unicode), "UTF8 DBF field write");
            Check(DbfIO.TryRead(unicodePath, out var unicodeRead), "UTF8 DBF field read");
            Check(unicodeRead.Columns.Select(c => c.Name).Distinct().Count() == 2 && unicodeRead.Columns.All(c => System.Text.Encoding.UTF8.GetByteCount(c.Name) <= 10), "UTF8 byte-limited names remain unique and valid");
            string unicodeValue = (string)unicodeRead.Rows[0][0];
            Check(unicodeValue.StartsWith("🙂") && !unicodeValue.Contains('\uFFFD') && System.Text.Encoding.UTF8.GetByteCount(unicodeValue) <= 254, "UTF8 field truncation preserves whole scalars");
            Check((string)unicodeRead.Rows[0][1] == "", "Empty string columns keep a valid DBF byte width");
            var observed = new ObservableTable(new Table());
            Check(observed.TryEnsureColumn("new", typeof(string), out _) && observed.NeedsSave, "Adding a source column marks unsaved state");
            string? acceptance = Environment.GetEnvironmentVariable("HECRAS_ATTRIBUTE_TABLE_ACCEPTANCE_DIRECTORY");
            if (!string.IsNullOrEmpty(acceptance))
            {
                Directory.CreateDirectory(acceptance);
                foreach (var file in Directory.GetFiles(dir)) File.Copy(file, Path.Combine(acceptance, Path.GetFileName(file)), overwrite: true);
            }
            Console.WriteLine("Actual source shapefile attributes, typed edits, nulls, stable columns and unchanged-file checks passed.");
        }
        finally { Directory.Delete(dir, recursive: true); }
    }
    private sealed class CultureScope : IDisposable
    {
        private readonly CultureInfo previous = CultureInfo.CurrentCulture;
        public CultureScope(CultureInfo value) { CultureInfo.CurrentCulture = value; }
        public void Dispose() { CultureInfo.CurrentCulture = previous; }
    }
    static void Check(bool condition, string name) { if (!condition) throw new InvalidOperationException(name); }
    static void Expect<T>(Action action) where T : Exception
    {
        try { action(); } catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
