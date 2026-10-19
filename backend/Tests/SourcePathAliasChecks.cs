using System.Reflection;
using Geospatial.Rasters.Classifications;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Classifiers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class SourcePathAliasChecks
{
    private const string ClassificationDescription = "ClassificationCatalogSummary/Context_Description";
    private const string ClassificationSelection = "ClassificationLayersEditor/ClassificationLayer_SelectedClassificationInput";
    private const string TerrainDescription = "TerrainCatalogSummary/Context_Description";

    internal static async Task Run()
    {
        using var root = new TemporaryDirectory();
        TerrainFixture terrain = CreateTerrain(root.FullName);
        ClassificationFixture classification = CreateClassification(root.FullName);

        // Keep the alias outside the fixture root so recursive fixture handling
        // cannot traverse the symlink back into the same source tree.
        string aliasDirectory = Path.Combine(Path.GetDirectoryName(root.FullName)!, "source-path-alias-" + Guid.NewGuid().ToString("N"));
        Directory.CreateSymbolicLink(aliasDirectory, root.FullName);
        try
        {
            ModelSnapshot terrainAfterAliasedProject = await SaveTerrainAlias(
                terrain, Path.Combine(aliasDirectory, Path.GetFileName(terrain.ProjectPath)), terrain.AssetPath,
                "terrain-project-alias", "Terrain saved through aliased project path");
            await RejectMissingTerrainRaster(terrain, terrainAfterAliasedProject,
                Path.Combine(aliasDirectory, Path.GetFileName(terrain.ProjectPath)), terrain.AssetPath);
            ModelSnapshot terrainAfterAliasedAsset = await SaveTerrainAlias(
                terrain, terrain.ProjectPath, AliasPath(aliasDirectory, root.FullName, terrain.AssetPath),
                "terrain-asset-alias", "Terrain saved through aliased asset path");
            await RejectChangedTerrainRaster(terrain, terrainAfterAliasedAsset,
                terrain.ProjectPath, AliasPath(aliasDirectory, root.FullName, terrain.AssetPath));

            ModelSnapshot classificationAfterAliasedProject = await SaveClassificationAlias(
                classification, Path.Combine(aliasDirectory, Path.GetFileName(classification.ProjectPath)), classification.AssetPath,
                "classification-project-alias", "Classification saved through aliased project path");
            await RejectMissingClassificationRaster(classification, classificationAfterAliasedProject,
                Path.Combine(aliasDirectory, Path.GetFileName(classification.ProjectPath)), classification.AssetPath);
            ModelSnapshot classificationAfterAliasedAsset = await SaveClassificationAlias(
                classification, classification.ProjectPath, AliasPath(aliasDirectory, root.FullName, classification.AssetPath),
                "classification-asset-alias", "Classification saved through aliased asset path");
            await RejectChangedClassificationRaster(classification, classificationAfterAliasedAsset,
                classification.ProjectPath, AliasPath(aliasDirectory, root.FullName, classification.AssetPath));

            Check(terrainAfterAliasedProject.SourceState != null && terrainAfterAliasedAsset.SourceState != null,
                "Terrain source dependency state is retained across both path aliases");
            Check(classificationAfterAliasedProject.SourceState != null && classificationAfterAliasedAsset.SourceState != null,
                "Classification source dependency state is retained across both path aliases");
        }
        finally
        {
            Directory.Delete(aliasDirectory);
        }

        Console.WriteLine("Terrain and classification staged saves preserve source identity across aliased project and HDF paths, while changed external rasters remain guarded.");
    }

    private static TerrainFixture CreateTerrain(string root)
    {
        string projectPath = Path.Combine(root, "Terrain Source Alias.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Terrain Alias");
        string rasterPath = Path.Combine(terrain.SourceDirectory, "existing-terrain.tif");
        CreateRaster(rasterPath, DataType.GDT_Float32, 42);
        var rasterInput = RasterTerrainInput.CreateAndScan(terrain, rasterPath);
        rasterInput.Name = "Original terrain raster";
        terrain.Add(rasterInput);
        project.Save();
        terrain.Save();

        var fixture = new TerrainFixture(
            projectPath,
            terrain.Filename,
            rasterPath,
            RelativeRasterPath(rasterInput),
            File.ReadAllBytes(projectPath),
            File.ReadAllBytes(rasterPath));
        terrain.Dispose();
        return fixture;
    }

    private static ClassificationFixture CreateClassification(string root)
    {
        string projectPath = Path.Combine(root, "Classification Source Alias.ras");
        string rasterPath = Path.Combine(root, "existing-classification.tif");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        CreateRaster(rasterPath, DataType.GDT_Int32, 7);
        Classification classes = new();
        classes.Set(7, "Original classification");
        ClassificationLayer layer = project.AddNewClassification("Classification Alias");
        RasterClassificationInput rasterInput = layer.AddNewRasterLayer(rasterPath, classes);
        rasterInput.Name = "Original classification raster";
        project.Save();
        layer.Save();

        var fixture = new ClassificationFixture(
            projectPath,
            layer.Filename,
            rasterPath,
            RelativeRasterPath(rasterInput),
            File.ReadAllBytes(projectPath),
            File.ReadAllBytes(rasterPath));
        layer.Dispose();
        return fixture;
    }

    private static async Task<ModelSnapshot> SaveTerrainAlias(
        TerrainFixture fixture, string projectPath, string assetPath, string description, string inputName)
    {
        ModelSnapshot loaded = await ModelEditorAdapter.LoadAsync(new(assetPath, "Terrain", projectPath));
        Check(loaded.SourceState != null, "Terrain alias load returns the original raster dependency state");
        var rasterInput = loaded.Terrain!.Inputs.Single(input => input.Type == "Raster");
        var fields = new Dictionary<string, string>
        {
            [TerrainDescription] = description,
            [rasterInput.Scope + "/Name"] = inputName
        };
        var request = new ModelSaveRequest(assetPath, "Terrain", projectPath, loaded.Revision, fields, [], SourceState: loaded.SourceState);
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(request);

        using (var reread = new Terrain(fixture.AssetPath))
        {
            var raster = reread.Layers.OfType<RasterTerrainInput>().Single();
            Check(reread.Description == description && raster.Name == inputName,
                "Terrain metadata and existing raster-input edits persist in an independent HDF reload");
            Check(RelativeRasterPath(raster) == fixture.RelativeRasterPath,
                "Terrain existing relative raster filename survives the staged alias save");
        }
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(fixture.ProjectBytes),
            "Terrain alias save leaves the owning project XML unchanged");
        Check(File.ReadAllBytes(fixture.RasterPath).SequenceEqual(fixture.RasterBytes),
            "Terrain alias save leaves its external raster unchanged");
        Check(saved.SourceState != null, "Terrain save returns fresh source dependency state");
        return saved;
    }

    private static async Task<ModelSnapshot> SaveClassificationAlias(
        ClassificationFixture fixture, string projectPath, string assetPath, string description, string inputName)
    {
        ModelSnapshot loaded = await ModelEditorAdapter.LoadAsync(new(assetPath, "Surface Layers", projectPath));
        Check(loaded.SourceState != null, "Classification alias load returns the original raster dependency state");
        var rasterInput = loaded.Classification!.Inputs.Single(input => input.Type == "Raster");
        ModelRow[] rows = rasterInput.Rows.Select(row => row.Values["Key"] == "7"
            ? row with { Values = new(row.Values) { ["Value"] = description } }
            : row).ToArray();
        var fields = new Dictionary<string, string>
        {
            [ClassificationDescription] = description,
            [ClassificationSelection] = rasterInput.Id,
            [rasterInput.Scope + "/Name"] = inputName
        };
        var request = new ModelSaveRequest(assetPath, "Surface Layers", projectPath, loaded.Revision, fields, [],
            SourceState: loaded.SourceState,
            Rows: new Dictionary<string, ModelRow[]> { [rasterInput.TableId!] = rows });
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(request);

        using (var reread = new ClassificationLayer(fixture.AssetPath))
        {
            var raster = reread.AllRasterInputs().Single();
            Check(reread.Description == description && raster.Name == inputName && raster.Classification.GetName(7) == description,
                "Classification metadata, existing raster name, and mapping-row edits persist in an independent HDF reload");
            Check(RelativeRasterPath(raster) == fixture.RelativeRasterPath,
                "Classification existing relative raster filename survives the staged alias save");
        }
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(fixture.ProjectBytes),
            "Classification alias save leaves the owning project XML unchanged");
        Check(File.ReadAllBytes(fixture.RasterPath).SequenceEqual(fixture.RasterBytes),
            "Classification alias save leaves its external raster unchanged");
        Check(saved.SourceState != null, "Classification save returns fresh source dependency state");
        return saved;
    }

    private static async Task RejectChangedTerrainRaster(
        TerrainFixture fixture, ModelSnapshot saved, string projectPath, string assetPath)
    {
        byte[] hdfBefore = File.ReadAllBytes(fixture.AssetPath);
        ChangeRasterPixel(fixture.RasterPath, 99);
        try
        {
            var request = new ModelSaveRequest(assetPath, "Terrain", projectPath, saved.Revision,
                new Dictionary<string, string> { [TerrainDescription] = "must be rejected" }, [], SourceState: saved.SourceState);
            await ExpectSourceChanged(() => ModelEditorAdapter.SaveAsync(request), "Changed terrain raster dependency rejects the aliased staged save");
            Check(!File.ReadAllBytes(fixture.RasterPath).SequenceEqual(fixture.RasterBytes), "Terrain external raster fixture was genuinely changed");
            Check(File.ReadAllBytes(fixture.AssetPath).SequenceEqual(hdfBefore), "Rejected terrain dependency edit never replaces the source HDF");
            Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(fixture.ProjectBytes), "Rejected terrain dependency edit leaves project XML unchanged");
        }
        finally
        {
            File.WriteAllBytes(fixture.RasterPath, fixture.RasterBytes);
        }
    }

    private static async Task RejectMissingTerrainRaster(
        TerrainFixture fixture, ModelSnapshot saved, string projectPath, string assetPath)
    {
        byte[] hdfBefore = File.ReadAllBytes(fixture.AssetPath);
        File.Delete(fixture.RasterPath);
        try
        {
            var request = new ModelSaveRequest(assetPath, "Terrain", projectPath, saved.Revision,
                new Dictionary<string, string> { [TerrainDescription] = "missing dependency must be rejected" }, [], SourceState: saved.SourceState);
            await ExpectMissingDependency(() => ModelEditorAdapter.SaveAsync(request), fixture.RasterPath);
            Check(!File.Exists(fixture.RasterPath), "Terrain source raster remains missing until the dependency check completes");
            Check(File.ReadAllBytes(fixture.AssetPath).SequenceEqual(hdfBefore), "Missing terrain dependency never replaces the source HDF");
            Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(fixture.ProjectBytes), "Missing terrain dependency leaves project XML unchanged");
        }
        finally
        {
            File.WriteAllBytes(fixture.RasterPath, fixture.RasterBytes);
        }
    }

    private static async Task RejectChangedClassificationRaster(
        ClassificationFixture fixture, ModelSnapshot saved, string projectPath, string assetPath)
    {
        byte[] hdfBefore = File.ReadAllBytes(fixture.AssetPath);
        ChangeRasterPixel(fixture.RasterPath, 99);
        try
        {
            var request = new ModelSaveRequest(assetPath, "Surface Layers", projectPath, saved.Revision,
                new Dictionary<string, string> { [ClassificationDescription] = "must be rejected" }, [], SourceState: saved.SourceState);
            await ExpectSourceChanged(() => ModelEditorAdapter.SaveAsync(request), "Changed classification raster dependency rejects the aliased staged save");
            Check(!File.ReadAllBytes(fixture.RasterPath).SequenceEqual(fixture.RasterBytes), "Classification external raster fixture was genuinely changed");
            Check(File.ReadAllBytes(fixture.AssetPath).SequenceEqual(hdfBefore), "Rejected classification dependency edit never replaces the source HDF");
            Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(fixture.ProjectBytes), "Rejected classification dependency edit leaves project XML unchanged");
        }
        finally
        {
            File.WriteAllBytes(fixture.RasterPath, fixture.RasterBytes);
        }
    }

    private static async Task RejectMissingClassificationRaster(
        ClassificationFixture fixture, ModelSnapshot saved, string projectPath, string assetPath)
    {
        byte[] hdfBefore = File.ReadAllBytes(fixture.AssetPath);
        File.Delete(fixture.RasterPath);
        try
        {
            var request = new ModelSaveRequest(assetPath, "Surface Layers", projectPath, saved.Revision,
                new Dictionary<string, string> { [ClassificationDescription] = "missing dependency must be rejected" }, [], SourceState: saved.SourceState);
            await ExpectMissingDependency(() => ModelEditorAdapter.SaveAsync(request), fixture.RasterPath);
            Check(!File.Exists(fixture.RasterPath), "Classification source raster remains missing until the dependency check completes");
            Check(File.ReadAllBytes(fixture.AssetPath).SequenceEqual(hdfBefore), "Missing classification dependency never replaces the source HDF");
            Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(fixture.ProjectBytes), "Missing classification dependency leaves project XML unchanged");
        }
        finally
        {
            File.WriteAllBytes(fixture.RasterPath, fixture.RasterBytes);
        }
    }

    private static void CreateRaster(string path, DataType type, double fill)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var driver = Gdal.GetDriverByName("GTiff");
        using var raster = driver.Create(path, 16, 16, 1, type, ["TILED=YES"]);
        raster.SetGeoTransform([0, 1, 0, 16, 0, -1]);
        using var band = raster.GetRasterBand(1);
        band.Fill(fill, 0);
    }

    private static void ChangeRasterPixel(string path, float value)
    {
        using var raster = Gdal.Open(path, Access.GA_Update);
        using var band = raster.GetRasterBand(1);
        band.WriteRaster(0, 0, 1, 1, [value], 1, 1, 0, 0);
    }

    private static string RelativeRasterPath(object input)
    {
        PropertyInfo property = input.GetType().GetProperty("PathRelFilename", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("The retained raster input must expose its persisted relative-path metadata.");
        return property.GetValue(input) as string
            ?? throw new InvalidOperationException("The retained raster input relative path is empty.");
    }

    private static string AliasPath(string aliasDirectory, string fixtureRoot, string path) =>
        Path.Combine(aliasDirectory, Path.GetRelativePath(fixtureRoot, path));

    private static async Task ExpectSourceChanged(Func<Task<ModelSnapshot>> action, string message)
    {
        try { await action(); }
        catch (SourceFileChangedException) { return; }
        throw new InvalidOperationException(message);
    }

    private static async Task ExpectMissingDependency(Func<Task<ModelSnapshot>> action, string path)
    {
        try { await action(); }
        catch (SourceFileChangedException) { return; }
        // Source layer loading can reject the missing raster before a draft
        // ledger is constructed. Require that exact missing dependency error;
        // do not accept unrelated I/O failures or relax changed-file checks.
        catch (IOException error) when (!File.Exists(path) && error.Message.Contains(Path.GetFileName(path), StringComparison.Ordinal)) { return; }
        throw new InvalidOperationException("A missing raster dependency must reject the save.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record TerrainFixture(string ProjectPath, string AssetPath, string RasterPath,
        string RelativeRasterPath, byte[] ProjectBytes, byte[] RasterBytes);

    private sealed record ClassificationFixture(string ProjectPath, string AssetPath, string RasterPath,
        string RelativeRasterPath, byte[] ProjectBytes, byte[] RasterBytes);
}
