using Geospatial;
using Geospatial.Rasters.Classifications;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Classifiers;
using Utility.Files;
using Utility.Units;

internal static class ClassificationEditorChecks
{
    private const string Source = "ClassificationLayersEditor/ClassificationLayer_SelectedClassificationInput";
    internal static async Task Run()
    {
        using var root = new TemporaryDirectory();
        string path = Path.Combine(root.FullName, "分类集成.ras"), rasterPath = Path.Combine(root.FullName, "分类栅格.tif");
        var project = Project.CreateNew(path, UnitSystem.SI);
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var raster = driver.Create(rasterPath, 16, 16, 1, DataType.GDT_Int32, ["TILED=YES"]))
        { raster.SetGeoTransform([0, 1, 0, 16, 0, -1]); using var band = raster.GetRasterBand(1); band.Fill(7, 0); }
        var layer = project.AddNewClassification("土地分类"); var classes = new Classification(); classes.Set(7, "原草地"); classes.Set(8, "原农田");
        var input = layer.AddNewRasterLayer(rasterPath, classes); input.Name = "中文栅格名称";
        var constant = new ConstantClassificationInput(layer, new Extent(0, 0, 16, 16), "常数底图"); layer.Add(constant);
        var polygons = layer.AddNewPolygonLayer("面覆盖"); polygons.Add(new Polygon(new Point[] { new(2, 2), new(6, 2), new(6, 6), new(2, 6) }), "面分类");
        project.Save(); string asset = layer.Filename;
        classes.Set(7, "草地"); Check(layer.NeedsSave(), "Source dirty detection includes actual raster mapping values"); project.Save(); Check(!layer.NeedsSave(), "Source mapping save rebases dirty state");
        using (var reread = new ClassificationLayer(asset)) Check(reread.AllRasterInputs().Single().Name == "中文栅格名称" && reread.AllRasterInputs().Single().Classification.GetName(7) == "草地", "Source reload retains definition names rather than replacing them with raster filenames");
        string oldName = constant.Name; constant.Name = input.Name;
        try { ClassificationInputDefinition.FromInputs("/Classification", layer.Layers); throw new InvalidOperationException("Duplicate HDF input path accepted"); } catch (InvalidOperationException error) when (error.Message.Contains("distinct HDF groups", StringComparison.Ordinal)) { }
        constant.Name = oldName; layer.Dispose();
        byte[] xml = File.ReadAllBytes(path), original = File.ReadAllBytes(asset);
        var current = await ModelEditorAdapter.LoadAsync(new(asset, "Surface Layers", path));
        var rasterData = current.Classification!.Inputs.Single(item => item.Type == "Raster");
        var polygonData = current.Classification.Inputs.Single(item => item.Type == "PolyClassifier");
        var constantData = current.Classification.Inputs.Single(item => item.Type == "Constant");
        Check(rasterData.Rows.Length == 3 && !polygonData.CanRemove && polygonData.Polygons.Single().VertexCount == 4 && current.Classification.Inputs.Length == 3, "Actual input types, mapping IDs, polygon classes and deletion capabilities are exposed");
        ModelSaveRequest Draft(Dictionary<string, string>? fields = null, Dictionary<string, ModelRow[]>? rows = null) => new(asset, "Surface Layers", path, current.Revision,
            fields ?? new() { [Source] = current.Fields[Source] }, [], SourceState: current.SourceState,
            Rows: rows ?? current.Classification!.Inputs.Where(item => item.TableId != null).ToDictionary(item => item.TableId!, item => item.Rows));
        string polygonField = polygonData.Polygons[0].Scope + "/PolygonClassificationInputProperties/ClassifierMod_Classification";
        var editedRows = rasterData.Rows.Select(row => row.Values["Key"] == "7" ? row with { Values = new(row.Values) { ["Value"] = "新中文草地" } } : row).ToArray();
        current = await ModelEditorAdapter.TransformClassificationAsync(new(Draft(new() { [Source] = rasterData.Id, [rasterData.Scope + "/Name"] = "重命名分类输入", [polygonField] = "新面分类", [constantData.Scope + "/ConstantClassification/Value"] = "新常数分类", ["ClassificationCatalogSummary/Context_Description"] = "分类草稿" }, new() { [rasterData.TableId!] = editedRows }), "reorder", From: 0, To: 2));
        Check(current.Classification!.Inputs[2].Id == rasterData.Id && current.Fields[polygonField] == "新面分类" && current.Classification.Classes.Contains("新中文草地"), "Actual source reorder retains scoped mapping and polygon drafts");
        Check(File.ReadAllBytes(asset).SequenceEqual(original), "Classification source transforms do not save HDF");
        current = await ModelEditorAdapter.SaveAsync(Draft(new() { [Source] = rasterData.Id, [rasterData.Scope + "/Name"] = "重命名分类输入", [polygonField] = "新面分类", [constantData.Scope + "/ConstantClassification/Value"] = "新常数分类", ["ClassificationCatalogSummary/Context_Description"] = "分类草稿" }));
        using (var read = new ClassificationLayer(asset))
        {
            var actualRaster = read.AllRasterInputs().Single(); var actualPolygons = (PolygonClassificationInput)read.Layers.Single(item => item is PolygonClassificationInput);
            Check(read.Layers[2] == actualRaster && actualRaster.Name == "重命名分类输入" && actualRaster.Classification.GetName(7) == "新中文草地" && actualPolygons.Features[0].Classification == "新面分类" && actualPolygons.Features[0].Polygon.Points.Count == 4 && read.Description == "分类草稿", "Independent source HDF reload retains exact raster mapping, name, order, polygon geometry/class and metadata");
            Check(((ConstantClassificationInput)read.Layers[0]).Value == "新常数分类", "Actual constant classification persists");
        }
        Check(current.Classification!.SelectedId == current.Classification.Inputs[2].Id, "Saved selection follows the actual input after IDs rebase");
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_CLASSIFICATION_FIXTURE_DIRECTORY");
        if (!string.IsNullOrEmpty(fixture))
            foreach (string source in Directory.EnumerateFiles(root.FullName, "*", SearchOption.AllDirectories))
            { string target = Path.Combine(fixture, Path.GetRelativePath(root.FullName, source)); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(source, target, true); }
        byte[] saved = File.ReadAllBytes(asset);
        rasterData = current.Classification.Inputs.Single(item => item.Type == "Raster"); polygonData = current.Classification.Inputs.Single(item => item.Type == "PolyClassifier");
        var badRows = rasterData.Rows.Select((row, index) => index == 0 ? row with { Values = new(row.Values) { ["Key"] = "999" } } : row).ToArray();
        await Reject(() => ModelEditorAdapter.SaveAsync(Draft(rows: new() { [rasterData.TableId!] = badRows })));
        await Reject(() => ModelEditorAdapter.TransformClassificationAsync(new(Draft(), "remove", polygonData.Id)));
        await Reject(() => ModelEditorAdapter.TransformClassificationAsync(new(Draft(), "reorder", From: -1, To: 0)));
        await Reject(() => ModelEditorAdapter.SaveAsync(Draft(new() { [rasterData.Scope + "/Name"] = polygonData.Name })));
        byte[] rasterBytes = File.ReadAllBytes(rasterPath);
        File.AppendAllText(rasterPath, "source changed");
        try { await ModelEditorAdapter.SaveAsync(Draft()); throw new InvalidOperationException("Changed source raster accepted"); } catch (SourceFileChangedException) { }
        Check(File.ReadAllBytes(asset).SequenceEqual(saved), "Stale raster dependency rejects save without replacing HDF");
        File.WriteAllBytes(rasterPath, rasterBytes);
        current = await ModelEditorAdapter.TransformClassificationAsync(new(Draft(), "remove", rasterData.Id));
        Check(current.Classification!.Inputs.Length == 2 && !current.Classification.Classes.Contains("新中文草地") && File.ReadAllBytes(asset).SequenceEqual(saved), "Input deletion updates source classes and remains an unsaved draft");
        current = await ModelEditorAdapter.SaveAsync(Draft());
        using (var read = new ClassificationLayer(asset)) Check(read.LayerCount == 2 && read.AllRasterInputs().Count == 0, "Deleted raster input is absent after independent HDF reload");
        Check(File.ReadAllBytes(path).SequenceEqual(xml), "Classification operations never implicitly save project XML");
        Console.WriteLine("Actual classification mapping, source names/hash, priority/order, polygon/constant fields, draft removal, HDF persistence and dependency conflicts passed.");
    }
    private static async Task Reject(Func<Task> operation)
    { try { await operation(); } catch (ArgumentException) { return; } throw new InvalidOperationException("Invalid classification operation accepted"); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
