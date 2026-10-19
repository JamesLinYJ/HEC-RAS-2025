using System.Security.Cryptography;
using Geospatial.GDALAssist;
using Geospatial.IO;
using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Classifiers;
using Utility.Files;
using Utility.Memory;
using Utility.Units;

internal static class ClassificationImportChecks
{
    internal static async Task Run()
    {
        using var root = new TemporaryDirectory();
        string projectPath = Path.Combine(root.FullName, "分类导入.ras"), source = Path.Combine(root.FullName, "来源栅格.tif"), shape = Path.Combine(root.FullName, "分类面.shp");
        var project = Project.CreateNew(projectPath, UnitSystem.SI); var layer = project.AddNewClassification("分类导入层");
        var polygons = layer.AddNewPolygonLayer("已有面"); polygons.Add(Square(0), "已有分类"); project.Save(); string asset = layer.Filename;
        using (var driver = Gdal.GetDriverByName("GTiff")) using (var raster = driver.Create(source, 16, 16, 1, DataType.GDT_Int32, ["TILED=YES"]))
        {
            raster.SetGeoTransform([0, 1, 0, 16, 0, -1]); if (project.Projection is { } projection) raster.SetProjection(projection.GetWKT());
            using var band = raster.GetRasterBand(1); band.Fill(11, 0); band.SetNoDataValue(-9999);
        }
        var table = new Table(); table.AddColumn("Class", typeof(string)); table.AddColumn("Count", typeof(int)); table.AddNewRow(["中文草地", 1]); table.AddNewRow(["中文农田", 2]);
        Check(ShapefileIO.Write(shape, new List<Polygon> { Square(2), Square(5) }, table), "Real classification polygon shapefile fixture");
        layer.Dispose(); byte[] xml = File.ReadAllBytes(projectPath), original = File.ReadAllBytes(asset); string sourceHash = Hash(source);
        var current = await ModelEditorAdapter.LoadAsync(new(asset, "Surface Layers", projectPath));
        ModelSaveRequest Draft(Dictionary<string, string>? fields = null) => new(asset, "Surface Layers", projectPath, current.Revision, fields ?? [], [], SourceState: current.SourceState);
        var inspection = await ModelEditorAdapter.InspectClassificationAsync(new(Draft(), [source, shape]));
        var rasterItem = inspection.Items.Single(item => item.Selection.Kind == "Raster"); var shapeItem = inspection.Items.Single(item => item.Selection.Kind == "Polygon");
        Check(rasterItem.Rows == 16 && rasterItem.ColumnsCount == 16 && rasterItem.Raster!.Rgba.Length > 0 && shapeItem.FeatureCount == 2 && System.Text.Json.JsonDocument.Parse(shapeItem.GeoJson!).RootElement.GetProperty("features")[0].GetProperty("properties").GetProperty("classification").GetString() == "中文草地" && shapeItem.Columns.SequenceEqual(["Class"]), "Actual raster and polygon preview with original string-column rules");
        Check(File.ReadAllBytes(asset).SequenceEqual(original), "Inspection does not mutate model HDF");
        var selected = new[] { rasterItem.Selection with { Name = "导入中文栅格" }, shapeItem.Selection };
        var input = current.Classification!.Inputs.Single(); string field = input.Polygons[0].Scope + "/PolygonClassificationInputProperties/ClassifierMod_Classification";
        current = await ModelEditorAdapter.ImportClassificationAsync(new(Draft(new() { [field] = "保留面草稿", ["ClassificationCatalogSummary/Context_Description"] = "导入时保留说明" }), selected));
        using (var read = new ClassificationLayer(asset, new Project(projectPath)))
        {
            var raster = read.AllRasterInputs().Single(); var poly = read.Layers.OfType<PolygonClassificationInput>().Single();
            Check(raster.Name == "导入中文栅格" && raster.Filename != source && File.Exists(raster.Filename) && raster.Classification.GetName(11) == "Open Water" && raster.Classification.GetName(-9999) == "NoData", "Source discrete converter, copied raster, NLCD map and NoData persist");
            Check(poly.Features.Count == 3 && poly.Features[0].Classification == "保留面草稿" && poly.Features[1].Classification == "中文草地" && poly.Features[2].Classification == "中文农田" && read.Description == "导入时保留说明", "Source polygon append and metadata/geometry drafts save together");
            using var data = TiffDataSource<int>.TryLoad(raster.Filename); Check(data != null && data.BasePyramidLevel.RasterDefinition.Rows == 16, "Independent copied source TIFF read");
        }
        Check(File.ReadAllBytes(projectPath).SequenceEqual(xml) && Hash(source) == sourceHash, "Import preserves source TIFF and project XML");
        var expectedSelection = current.Classification!.Inputs.Single(item => item.Type == "PolyClassifier").Id;
        Check(current.Classification.SelectedId == expectedSelection, "Import selection follows actual final polygon input");
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_CLASSIFICATION_IMPORT_FIXTURE_DIRECTORY");
        if (!string.IsNullOrEmpty(fixture)) foreach (string file in Directory.EnumerateFiles(root.FullName, "*", SearchOption.AllDirectories))
        { string target = Path.Combine(fixture, Path.GetRelativePath(root.FullName, file)); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(file, target, true); }
        byte[] saved = File.ReadAllBytes(asset); string[] before = Directory.GetFiles(Path.GetDirectoryName(asset)!).Order().ToArray();
        try { await ModelEditorAdapter.ImportClassificationAsync(new(Draft(), [selected[0]])); throw new InvalidOperationException("Duplicate raster name accepted"); } catch (ArgumentException) { }
        var stale = shapeItem.Selection; string dbf = Path.ChangeExtension(shape, ".dbf"); byte[] dbfBytes = File.ReadAllBytes(dbf); File.AppendAllText(dbf, "stale");
        try { await ModelEditorAdapter.ImportClassificationAsync(new(Draft(), [stale])); throw new InvalidOperationException("Changed shape attributes accepted"); } catch (SourceFileChangedException) { }
        File.WriteAllBytes(dbf, dbfBytes);
        try { await ModelEditorAdapter.ImportClassificationAsync(new(Draft(), [rasterItem.Selection with { Name = "应回滚栅格" }, shapeItem.Selection with { Column = "Count" }])); throw new InvalidOperationException("Numeric classification field accepted"); } catch (ArgumentException) { }
        Check(File.ReadAllBytes(asset).SequenceEqual(saved) && Directory.GetFiles(Path.GetDirectoryName(asset)!).Order().SequenceEqual(before), "Failed multi-input import preserves HDF and cleans owned raster files");
        await ModelEditorAdapter.ImportClassificationAsync(new(Draft(), [shapeItem.Selection with { Column = null }]));
        using (var read = new ClassificationLayer(asset)) Check(read.Layers.OfType<PolygonClassificationInput>().Single().Features.TakeLast(2).All(feature => feature.Classification == "NoData"), "No selected classification column uses source NoData rule");
        Console.WriteLine("Actual classification TIFF/shapefile inspection, source import, Chinese mapping, draft preservation, dependency conflicts and failed-import rollback passed.");
    }
    private static Polygon Square(double x) => new(new Point[] { new(x, 1), new(x + 1, 1), new(x + 1, 2), new(x, 2) });
    private static string Hash(string file) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(file)));
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
