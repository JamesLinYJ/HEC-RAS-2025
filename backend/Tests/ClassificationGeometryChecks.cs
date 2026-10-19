using Geospatial.Rasters;
using Geospatial.Rendering;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Classifiers;
using Utility.Files;
using Utility.Units;

internal static class ClassificationGeometryChecks
{
    internal static async Task Run()
    {
        using var root = new TemporaryDirectory(); string path = Path.Combine(root.FullName, "分类地图.ras");
        var project = Project.CreateNew(path, UnitSystem.SI); var layer = project.AddNewClassification("地图分类");
        var background = new ConstantClassificationInput(layer, new Extent(0, 20, 0, 20), "背景"); background.Value = "背景类别"; layer.Add(background);
        var input = layer.AddNewPolygonLayer("分类面"); var first = Square(2); first.TrackM(new double[] { 10, 20, double.NaN, 40 });
        input.Add(first, "原面甲"); input.Add(Square(6), "原面乙"); project.Save(); string asset = layer.Filename; layer.Dispose();
        byte[] original = File.ReadAllBytes(asset), xml = File.ReadAllBytes(path);
        var current = await ModelEditorAdapter.LoadAsync(new(asset, "Surface Layers", path));
        ModelSaveRequest Draft(Dictionary<string, string>? fields = null) => new(asset, "Surface Layers", path, current.Revision, fields ?? current.Fields.Where(pair => pair.Key == "ClassificationCatalogSummary/Context_Description").ToDictionary(pair => pair.Key, pair => pair.Value), [], SourceState: current.SourceState);
        async Task Geometry(ClassificationGeometryMutation mutation, Dictionary<string, string>? fields = null) => current = await ModelEditorAdapter.TransformClassificationAsync(new(Draft(fields), "geometry", Geometry: mutation));
        var originalInput = current.Classification!.Inputs.Single(item => item.Type == "PolyClassifier"); var a = originalInput.Polygons[0]; var b = originalInput.Polygons[1];
        Check(a.HasM && !a.HasZ && a.Vertices[2].M == "NaN", "Source M-only ordinates are explicitly represented without inventing Z");
        var vertices = new[] { new ClassificationVertex(10, 10, "1", "11"), new ClassificationVertex(14, 10, "2", "12"), new ClassificationVertex(14, 14, "3", "NaN"), new ClassificationVertex(10, 14, "4", "14") };
        await Geometry(new("create", originalInput.Id, Vertices: vertices, HasZ: true, HasM: true, Classification: "新绘制中文面"), new() { [a.Scope + "/PolygonClassificationInputProperties/ClassifierMod_Classification"] = "保留甲分类草稿", ["ClassificationCatalogSummary/Context_Description"] = "地图草稿说明" });
        var created = current.Classification!.Inputs.Single(item => item.Type == "PolyClassifier").Polygons.Last(); string id = created.Id;
        await Geometry(new("delete", PolygonIds: [a.Id, b.Id]));
        Check(current.Classification!.Inputs.Single(item => item.Type == "PolyClassifier").Polygons.Single().Id == id, "Deleting earlier features does not shift the surviving polygon identity");
        await Geometry(new("undo"));
        var restored = current.Classification!.Inputs.Single(item => item.Type == "PolyClassifier").Polygons;
        Check(restored.Length == 3 && restored[0].Id == a.Id && restored[0].Classification == "保留甲分类草稿" && restored[2].Id == id && current.Classification.CanRedoGeometry, "Batch delete undo restores exact IDs and class drafts");
        await Geometry(new("redo")); Check(current.Classification!.Inputs.Single(item => item.Type == "PolyClassifier").Polygons.Length == 1, "Batch deletion redo");
        await Geometry(new("undo"));
        vertices[0] = vertices[0] with { X = 9 };
        await Geometry(new("replace", originalInput.Id, [id], vertices, true, true));
        Check(!current.Classification!.CanRedoGeometry && current.Fields["ClassificationCatalogSummary/Context_Description"] == "地图草稿说明", "New vertex operation clears redo and retains independent metadata draft");
        var preview = await ModelEditorAdapter.ClassificationMapAsync(new(Draft()));
        var map = preview.Raster!; Check(map.MinX == 0 && map.MinY == 0 && map.MaxX == 20 && map.MaxY == 20, "Source preview retains the full background extent"); int col = (int)((11 - map.MinX) / (map.MaxX - map.MinX) * map.Width), row = (int)((map.MaxY - 11) / (map.MaxY - map.MinY) * map.Height);
        var color = Convert.FromHexString(preview.Legend.Single(item => item.Name == "新绘制中文面").Color[1..]);
        Check(map.Rgba.AsSpan((row * map.Width + col) * 4, 4).SequenceEqual(color), "Map pixels come from actual source priority sampling and class map");
        const string selectionField = "ClassificationLayersEditor/ClassificationLayer_SelectedClassificationInput";
        var selectedPreview = await ModelEditorAdapter.ClassificationMapAsync(new(Draft(new() { [selectionField] = originalInput.Id })));
        Check(selectedPreview.SelectedInputId == originalInput.Id && selectedPreview.SelectedRaster != null,
            "Classification map keeps the exact selected source identity and a separate actual resampler overlay");
        var overlay = selectedPreview.SelectedRaster!;
        Check(overlay.MinX == map.MinX && overlay.MinY == map.MinY && overlay.MaxX == map.MaxX && overlay.MaxY == map.MaxY,
            "Selected and full classification rasters share the source coordinate frame");
        Check(overlay.Rgba.AsSpan((row * overlay.Width + col) * 4, 4).SequenceEqual(color),
            "Selected polygon input retains the source saturated colors over the dimmed full classification");
        int outside = ((int)((map.MaxY - 18) / (map.MaxY - map.MinY) * map.Height) * map.Width
            + (int)((18 - map.MinX) / (map.MaxX - map.MinX) * map.Width)) * 4;
        Check(overlay.Rgba[outside + 3] == 0 && selectedPreview.Raster!.Rgba[outside + 3] != 0,
            "Outside the selected input the overlay is no-data and the actual full background stays visible");
        int classID = preview.Legend.Single(item => item.Name == "新绘制中文面").Id;
        int[] sourceValue = [classID], dimmedColor = [0];
        ColorMaps.NLCD2011().CloneRatioSaturation(.5f, .5f).ParallelPaint(sourceValue, dimmedColor);
        uint dimmed = unchecked((uint)dimmedColor[0]);
        byte[] expectedDimmed = [(byte)(dimmed >> 16), (byte)(dimmed >> 8), (byte)dimmed, (byte)(dimmed >> 24)];
        Check(selectedPreview.Raster!.Rgba.AsSpan((row * map.Width + col) * 4, 4).SequenceEqual(expectedDimmed),
            "Full classification background uses retained CloneRatioSaturation, not an invented color transform");
        var clearedPreview = await ModelEditorAdapter.ClassificationMapAsync(new(Draft(new() { [selectionField] = "" })));
        Check(clearedPreview.SelectedRaster == null && clearedPreview.SelectedInputId == null
            && clearedPreview.Raster!.Rgba.SequenceEqual(preview.Raster!.Rgba),
            "Clearing source selection restores the complete saturated source layer without stale overlay pixels");
        Check(File.ReadAllBytes(asset).SequenceEqual(original) && File.ReadAllBytes(path).SequenceEqual(xml), "Geometry and preview operations remain unsaved drafts");
        current = await ModelEditorAdapter.SaveAsync(Draft());
        using (var read = new ClassificationLayer(asset))
        {
            var poly = read.Layers.OfType<PolygonClassificationInput>().Single(); var p = poly.Features[0].Polygon; var createdPolygon = poly.Features[2].Polygon;
            Check(poly.Features.Count == 3 && poly.Features[0].Classification == "保留甲分类草稿" && poly.Features[2].Classification == "新绘制中文面" && read.Description == "地图草稿说明", "Independent HDF geometry/class/name/metadata persistence");
            Check(!p.HasZ && p.HasM && p.M[0] == 10 && double.IsNaN(p.M[2]), "Source M-only and NaN ordinates survive draft replay and HDF save");
            Check(createdPolygon.Points[0].X == 9 && createdPolygon.HasZ && createdPolygon.HasM && createdPolygon.Z[3] == 4 && createdPolygon.M[1] == 12 && double.IsNaN(createdPolygon.M[2]), "Edited XYZM coordinates survive actual source HDF reread");
        }
        Check(!current.Classification!.CanUndoGeometry && !current.Classification.CanRedoGeometry, "Saved geometry operations rebase to a new source baseline");
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_CLASSIFICATION_GEOMETRY_FIXTURE_DIRECTORY");
        if (!string.IsNullOrEmpty(fixture)) foreach (string file in Directory.EnumerateFiles(root.FullName, "*", SearchOption.AllDirectories))
        { string target = Path.Combine(fixture, Path.GetRelativePath(root.FullName, file)); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(file, target, true); }
        var savedInput = current.Classification.Inputs.Single(item => item.Type == "PolyClassifier"); byte[] saved = File.ReadAllBytes(asset);
        await Reject(() => ModelEditorAdapter.TransformClassificationAsync(new(Draft(), "geometry", Geometry: new("replace", savedInput.Id, [savedInput.Polygons[0].Id], [new(0, 0), new(1, 1), new(2, 2)]))));
        await Reject(() => ModelEditorAdapter.TransformClassificationAsync(new(Draft(), "geometry", Geometry: new("delete", PolygonIds: ["stale-polygon"]))));
        Check(File.ReadAllBytes(asset).SequenceEqual(saved), "Invalid geometry/identity leaves source HDF unchanged");
        var empty = project.AddNewClassification("空分类"); empty.Save(); string emptyAsset = empty.Filename; empty.Dispose();
        var baseline = await ModelEditorAdapter.LoadAsync(new(emptyAsset, "Surface Layers", path));
        var emptyRequest = new ModelSaveRequest(emptyAsset, "Surface Layers", path, baseline.Revision, [], [], SourceState: baseline.SourceState);
        var createdInput = await ModelEditorAdapter.TransformClassificationAsync(new(emptyRequest, "geometry", Geometry: new("create", Vertices: [new(1, 1), new(4, 1), new(1, 4)], Classification: "空模型绘制")));
        var savedEmpty = await ModelEditorAdapter.SaveAsync(emptyRequest with { SourceState = createdInput.SourceState });
        Check(savedEmpty.Classification!.Inputs.Single().Polygons.Single().Classification == "空模型绘制", "Drawing in an empty classification creates the actual source polygon input");
        Console.WriteLine("Actual classification map sampling, stable polygon IDs, batch delete undo/redo, XYZM/NaN geometry drafts, HDF save and empty-input drawing passed.");
    }
    private static Polygon Square(double x) => new(new Point[] { new(x, 2), new(x + 2, 2), new(x + 2, 4), new(x, 4) });
    private static async Task Reject(Func<Task> action) { try { await action(); } catch (ArgumentException) { return; } throw new InvalidOperationException("Invalid polygon edit accepted"); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
