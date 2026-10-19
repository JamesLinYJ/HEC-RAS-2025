using Geospatial.Rasters.Classifications;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Classifiers;
using Ras.Observables;
using Utility.Files;
using Utility.Units;

internal static class ManningEditorChecks
{
    private const string Mode = "ManningsNEditor/NValueLayer_Mode", Constant = "ConstantManningsNEditor/NValueLayer_ConstantValue",
        Association = "ClassificationLayerManningNEditor/NValueLayer_ClassificationLayer", Table = "ClassificationLayerManningNEditor/InterpretationTable";
    internal static async Task Run()
    {
        using var root = new TemporaryDirectory();
        string path = Path.Combine(root.FullName, "糙率集成.ras");
        var project = Project.CreateNew(path, UnitSystem.SI);
        string raster = Path.Combine(root.FullName, "土地利用.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var dataset = driver.Create(raster, 16, 16, 1, DataType.GDT_Int32, ["TILED=YES"]))
        { using var band = dataset.GetRasterBand(1); band.Fill(7, 0); }
        ClassificationLayer MakeClassification(string name, params string[] names)
        {
            var layer = project.AddNewClassification(name); var classifier = new Classification();
            for (int index = 0; index < names.Length; index++) classifier.Set(index + 7, names[index]);
            var input = new RasterClassificationInput(layer, raster, classifier) { Signature = FileSignature.LoadDefault(raster) };
            layer.Add(input); return layer;
        }
        var classes = MakeClassification("土地利用", "Open Water", "Developed, High Intensity", "自定中文草地");
        var second = MakeClassification("第二分类", "Open Water", "森林");
        var n = project.AddNewNValueLayer("曼宁糙率");
        n.SetConstant(.03f); n.ClassificationLayerName = "缺失的历史分类"; n.InterpretationTable.Set("保留的历史映射", .075f);
        project.Save(); string asset = n.Filename, classFile = classes.Filename;
        var observable = new ObservableProject(project, Utility.SynchronizationContext.None);
        Check(n.ClassificationLayerName == "缺失的历史分类" && n.InterpretationTable.Get("保留的历史映射") == .075f,
            "Constructing observables preserves unresolved associations and hidden persisted tables");
        foreach (var layer in project.ClassificationLayers) layer.Dispose(); n.Dispose();
        byte[] xml = File.ReadAllBytes(path), original = File.ReadAllBytes(asset);
        // An associated layer with no mapping remains untouched on read but can
        // be populated by an explicit source-default operation.
        string emptyAsset = Path.Combine(Path.GetDirectoryName(asset)!, "空解释表.h5");
        using (var empty = NValueLayer.CreateNew(emptyAsset)) { empty.Mode = NValueSource.ClassificationLayer; empty.AssociatedClassificationLayer = classes; empty.Save(); }
        byte[] emptyBytes = File.ReadAllBytes(emptyAsset);
        var emptySnapshot = await ModelEditorAdapter.LoadAsync(new(emptyAsset, "Surface Layers", path));
        Check(emptySnapshot.Manning!.Rows.Length == 0 && File.ReadAllBytes(emptyAsset).SequenceEqual(emptyBytes), "Reading an absent mapping does not fabricate saved rows");
        var filled = await ModelEditorAdapter.TransformManningAsync(new(new(emptyAsset, "Surface Layers", path, emptySnapshot.Revision, [], [], SourceState: emptySnapshot.SourceState,
            Rows: new() { [Table] = [] }), "setNLCD"));
        Check(filled.Manning!.Rows.Length == 4 && filled.Manning.Rows.Single(row => row.Values["Key"] == "Open Water").Values["Value"] == "0.035" && File.ReadAllBytes(emptyAsset).SequenceEqual(emptyBytes),
            "Explicit NLCD reconciles a missing mapping with actual class names and remains an unsaved draft");
        var current = await ModelEditorAdapter.LoadAsync(new(asset, "Surface Layers", path));
        Check(current.Fields[Association] == "missing:缺失的历史分类" && current.Manning!.Warning != null && current.Manning.Rows.Length == 1,
            "Snapshot presents missing association without choosing another source or discarding mappings");
        ModelSaveRequest Draft(Dictionary<string, string>? fields = null, ModelRow[]? rows = null) =>
            new(asset, "Surface Layers", path, current.Revision, fields ?? [], [], SourceState: current.SourceState,
                Rows: new() { [Table] = rows ?? current.Manning!.Rows });
        current = await ModelEditorAdapter.SaveAsync(Draft(new() { [Constant] = "0", ["NValueCatalogSummary/Context_Description"] = "保留隐藏解释表" }));
        using (var read = new NValueLayer(asset))
            Check(read.ConstantValue == 0 && read.ClassificationLayerName == "缺失的历史分类" && read.InterpretationTable.Get("保留的历史映射") == .075f,
                "Constant zero follows source absolute bounds and metadata save preserves hidden mappings");
        original = File.ReadAllBytes(asset);
        current = await ModelEditorAdapter.TransformManningAsync(new(Draft(new() { [Mode] = "ClassificationLayer", [Association] = classFile }), "refresh"));
        Check(current.Manning!.Rows.Length == 4 && current.Fields[Association] == classFile && current.AvailableOperations.Contains("setDefaultNValues"),
            "Explicit classification association reconciles actual class map including NoData");
        var rows = current.Manning.Rows.Select(row => row.Values["Key"] == "自定中文草地" ? row with { Values = new(row.Values) { ["Value"] = ".087" } } : row).ToArray();
        current = await ModelEditorAdapter.TransformManningAsync(new(Draft(rows: rows), "setNLCD"));
        float Value(string name) => float.Parse(current.Manning!.Rows.Single(row => row.Values["Key"] == name).Values["Value"], System.Globalization.CultureInfo.InvariantCulture);
        Check(Value("Open Water") == .035f && Value("Developed, High Intensity") == .16f && Value("自定中文草地") == .087f,
            "NLCD uses exact source defaults including .16; unknown Chinese classification retains its working value");
        Check(File.ReadAllBytes(asset).SequenceEqual(original), "Classification and NLCD operations do not autosave HDF");
        current = await ModelEditorAdapter.SaveAsync(Draft(new() { [Mode] = "ClassificationLayer" }));
        using (var readerProject = new DisposableProject(path))
        {
            var actual = readerProject.Project.NValues.Single(item => item.Name == "曼宁糙率");
            Check(actual.Mode == NValueSource.ClassificationLayer && actual.ClassificationLayerName == "土地利用" && actual.InterpretationTable.Get("自定中文草地") == .087f && actual.InterpretationTable.Get("Open Water") == .035f,
                "Independent source model reads classification mode, association and actual HDF interpretation values");
        }
        rows = current.Manning!.Rows.Select(row => row with { Values = new(row.Values) { ["Value"] = row.Values["Key"] == "Open Water" ? ".123" : row.Values["Value"] } }).ToArray();
        current = await ModelEditorAdapter.TransformManningAsync(new(Draft(new() { [Association] = second.Filename }, rows), "refresh"));
        Check(current.Manning!.Rows.Length == 3 && Value("Open Water") == .123f && Value("森林") == 0, "Changing classifications retains common draft values and adds new keys with source defaults");
        current = await ModelEditorAdapter.TransformManningAsync(new(Draft(new() { [Association] = "" }), "refresh"));
        Check(current.Manning!.Rows.Length == 0 && current.Fields[Association] == "", "None clears both draft association and mapping");
        current = await ModelEditorAdapter.SaveAsync(Draft());
        using (var actual = new NValueLayer(asset)) Check(string.IsNullOrEmpty(actual.ClassificationLayerName) && actual.InterpretationTable.Count == 0, $"None persists an empty association and deletes original mapping dataset: association={actual.ClassificationLayerName ?? "<null>"}, rows={actual.InterpretationTable.Count}");
        current = await ModelEditorAdapter.TransformManningAsync(new(Draft(new() { [Association] = classFile }), "refresh"));
        current = await ModelEditorAdapter.TransformManningAsync(new(Draft(), "setNLCD"));
        current = await ModelEditorAdapter.SaveAsync(Draft());
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_MANNING_FIXTURE_DIRECTORY");
        if (!string.IsNullOrEmpty(fixture))
            foreach (string source in Directory.EnumerateFiles(root.FullName, "*", SearchOption.AllDirectories))
            { string target = Path.Combine(fixture, Path.GetRelativePath(root.FullName, source)); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(source, target, true); }
        byte[] saved = File.ReadAllBytes(asset);
        await Reject(() => ModelEditorAdapter.SaveAsync(Draft(new() { [Constant] = "-1" })));
        await Reject(() => ModelEditorAdapter.SaveAsync(Draft(new() { [Constant] = "NaN" })));
        await Reject(() => ModelEditorAdapter.SaveAsync(Draft(new() { [Mode] = "Debug" })));
        rows = current.Manning!.Rows.Select((row, index) => index == 0 ? row with { Values = new(row.Values) { ["Key"] = "改名" } } : row).ToArray();
        await Reject(() => ModelEditorAdapter.SaveAsync(Draft(rows: rows)));
        File.AppendAllText(classFile, "changed classification");
        try { await ModelEditorAdapter.SaveAsync(Draft()); throw new InvalidOperationException("Stale classification was accepted"); } catch (SourceFileChangedException) { }
        Check(File.ReadAllBytes(asset).SequenceEqual(saved) && File.ReadAllBytes(path).SequenceEqual(xml), "Invalid edits and changed classification dependencies preserve model HDF and project XML");
        Console.WriteLine("Manning modes, source NLCD defaults, draft association lifecycle, exact table HDF, hidden mapping preservation and stale classification rejection passed.");
    }
    private sealed class DisposableProject(string path) : IDisposable
    {
        public Project Project { get; } = new(path);
        public void Dispose() { foreach (var layer in Project.NValues) layer.Dispose(); foreach (var layer in Project.ClassificationLayers) layer.Dispose(); }
    }
    private static async Task Reject(Func<Task> operation)
    {
        try { await operation(); } catch (Exception error) when (error is ArgumentException or System.ComponentModel.DataAnnotations.ValidationException) { return; }
        throw new InvalidOperationException("Invalid Manning edit was accepted");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
