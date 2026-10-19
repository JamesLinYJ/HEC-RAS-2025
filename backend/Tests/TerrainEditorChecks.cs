using Geospatial.Vectors;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class TerrainEditorChecks
{
    internal static async Task Run()
    {
        using var root = new TemporaryDirectory(); string projectPath = Path.Combine(root.FullName, "地形输入.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI); var terrain = project.AddNewTerrain("地形编辑");
        string rasterPath = Path.Combine(terrain.SourceDirectory, "真实高程.tif");
        using (var driver = Gdal.GetDriverByName("GTiff")) using (var data = driver.Create(rasterPath, 16, 16, 1, DataType.GDT_Float32, ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
        { data.SetGeoTransform([0, 1, 0, 16, 0, -1]); using var band = data.GetRasterBand(1); band.Fill(42, 0); }
        var constant = new ConstantTerrainInput(terrain, 10, new Extent(0, 20, 0, 20), "常数基础"); terrain.Add(constant);
        var cached = terrain.ValidExtent; long version = terrain.VersionXY; constant.ValidExtent = new Extent(0, 30, 0, 30);
        Check(terrain.VersionXY != version && terrain.ValidExtent.MaxX == 30, "Constant extent changes invalidate the retained source extent cache"); constant.ValidExtent = cached;
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, rasterPath));
        terrain.Add(new FunctionalTerrainInput(terrain, "x+y", new Extent(0, 10, 0, 10), "函数地形")); project.Save(); terrain.Save();
        Check(!terrain.NeedsSave(), "Successful source save acknowledges the actual terrain input hash");
        string asset = terrain.Filename; terrain.Dispose(); byte[] original = File.ReadAllBytes(asset), xml = File.ReadAllBytes(projectPath), rasterBytes = File.ReadAllBytes(rasterPath);
        var snapshot = await ModelEditorAdapter.LoadAsync(new(asset, "Terrain", projectPath));
        var dataInputs = snapshot.Terrain!.Inputs; var c = dataInputs[0]; var f = dataInputs[2];
        var edits = new Dictionary<string, string> { ["TerrainCatalogSummary/Context_Description"] = "中文地形草稿", [c.Scope + "/Name"] = "基础改名", [c.Scope + "/ConstantTerrainInput/Context_Value"] = "12.5", [f.Scope + "/FunctionalTerrainInputProperties/Context_Expression"] = "2*x+y", [f.Scope + "/FunctionalTerrainInputProperties/Context_MinX"] = "2", [f.Scope + "/FunctionalTerrainInputProperties/Context_MaxX"] = "12", ["TerrainLayersEditor/SelectedInputWithMap"] = f.Id };
        ModelSaveRequest Draft() => new(asset, "Terrain", projectPath, snapshot.Revision, edits, [], SourceState: snapshot.SourceState);
        var map = await ModelEditorAdapter.TerrainMapAsync(new(Draft(), f.Id));
        Check(map.Raster != null && map.Raster.MinX == 0 && map.Raster.MaxX == 20
            && map.SelectedRaster != null && map.SelectedRaster.MinX == 2 && map.SelectedRaster.MaxX == 12
            && map.SelectedRaster.Minimum > 4 && map.SelectedRaster.Maximum > 33
            && map.Raster.Rgba.Where((_, index) => index % 4 == 3).Any(alpha => alpha > 0)
            && map.SelectedRaster.Rgba.Where((_, index) => index % 4 == 3).Any(alpha => alpha > 0),
            "Composite preview retains the complete terrain and evaluates the actual selected source function over its edited bounds");
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Draft(), "reorder", From: 2, To: 0));
        Check(snapshot.Terrain!.Inputs[0].Id == f.Id && snapshot.Terrain.SelectedId == f.Id && snapshot.Fields[c.Scope + "/Name"] == "基础改名", "Source priority transform retains actual IDs, names, selection and metadata draft");
        Check(File.ReadAllBytes(asset).SequenceEqual(original) && File.ReadAllBytes(projectPath).SequenceEqual(xml), "Terrain transforms and preview never implicitly save");
        snapshot = await ModelEditorAdapter.SaveAsync(Draft());
        using (var read = new Terrain(asset))
        {
            Check(read.Layers[0] is FunctionalTerrainInput actual && actual.Expression == "2*x+y" && actual.ValidExtent.MinX == 2 && actual.ValidExtent.MaxX == 12, "Independent source HDF functional expression/bounds/order persistence");
            Check(read.Layers[1] is ConstantTerrainInput baseInput && baseInput.Name == "基础改名" && baseInput.Value == 12.5f && read.Description == "中文地形草稿", "Constant, name and metadata persist through actual HDF");
        }
        Check(snapshot.Terrain!.SelectedId == snapshot.Terrain.Inputs[0].Id && File.ReadAllBytes(projectPath).SequenceEqual(xml) && File.ReadAllBytes(rasterPath).SequenceEqual(rasterBytes), "Save rebases selection and preserves project XML/external source raster");
        string? fixture = Environment.GetEnvironmentVariable("HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY");
        if (!string.IsNullOrEmpty(fixture)) foreach (string file in Directory.EnumerateFiles(root.FullName, "*", SearchOption.AllDirectories))
        { string target = Path.Combine(fixture, Path.GetRelativePath(root.FullName, file)); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(file, target, true); }
        edits = []; var current = snapshot.Terrain.Inputs; string rasterID = current.Single(x => x.Type == "Raster").Id;
        snapshot = await ModelEditorAdapter.TransformTerrainAsync(new(Draft(), "remove", ItemId: rasterID));
        Check(snapshot.Terrain!.Inputs.Length == 2 && snapshot.Terrain.Inputs.All(x => x.Id != rasterID), "Actual raster input removal stays a draft");
        byte[] saved = File.ReadAllBytes(asset);
        File.WriteAllBytes(rasterPath, [1, 2, 3]);
        try { await ModelEditorAdapter.SaveAsync(Draft()); throw new InvalidOperationException("Changed terrain raster accepted"); } catch (SourceFileChangedException) { }
        Check(File.ReadAllBytes(asset).SequenceEqual(saved), "Removed-input draft still rejects external raster changes against its original baseline");
        File.WriteAllBytes(rasterPath, rasterBytes); snapshot = await ModelEditorAdapter.SaveAsync(Draft());
        using (var read = new Terrain(asset)) Check(read.Layers.Count == 2, "Explicit source writer persists input removal");
        Check(File.ReadAllBytes(rasterPath).SequenceEqual(rasterBytes), "Removing an input preserves its external raster");
        var functional = snapshot.Terrain!.Inputs.First(x => x.Type == "Functional");
        edits = new() { [functional.Scope + "/FunctionalTerrainInputProperties/Context_Expression"] = "this is not an expression" };
        await Reject(() => ModelEditorAdapter.SaveAsync(Draft()));
        edits = new() { [functional.Scope + "/FunctionalTerrainInputProperties/Context_MinX"] = "99" };
        await Reject(() => ModelEditorAdapter.TerrainMapAsync(new(Draft(), functional.Id)));
        edits = new() { [functional.Scope + "/Name"] = snapshot.Terrain.Inputs.Last().Name };
        await Reject(() => ModelEditorAdapter.SaveAsync(Draft()));
        edits = []; byte[] latest = File.ReadAllBytes(asset); File.WriteAllBytes(rasterPath, [1, 2, 3]);
        // The remaining terrain no longer depends on the removed raster, while
        // a draft based on the earlier baseline still guards that dependency.
        var stale = new ModelSaveRequest(asset, "Terrain", projectPath, Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(saved)), [], [], SourceState: null);
        try { await ModelEditorAdapter.SaveAsync(stale); throw new InvalidOperationException("Stale model accepted"); } catch (SourceFileChangedException) { }
        Check(File.ReadAllBytes(asset).SequenceEqual(latest) && File.ReadAllBytes(projectPath).SequenceEqual(xml), "Invalid terrain changes preserve exact saved HDF/XML");
        await TerrainEditorTableChecks.Run();
        Console.WriteLine("Actual terrain priority/selection drafts, constant and functional edits, source previews, extent versions, input hashes, removal, HDF saves and invalid requests passed.");
    }
    private static async Task Reject(Func<Task> action) { try { await action(); } catch (ArgumentException) { return; } throw new InvalidOperationException("Invalid terrain edit accepted"); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
