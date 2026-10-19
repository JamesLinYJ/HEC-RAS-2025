using Geospatial.Rasters.Classifications;
using OSGeo.GDAL;
using Ras.Layers;
using Ras.Layers.Classifiers;
using Utility.Files;
using Utility.Units;

internal static class ModelSaveFailureChecks
{
    internal static void Run()
    {
        using var folder = new TemporaryDirectory();
        string path = Path.Combine(folder.FullName, "失败保存.ras");
        var project = Project.CreateNew(path, UnitSystem.SI);
        var layer = project.AddNewClassification("分类");
        string filename = Path.Combine(folder.FullName, "输入.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var dataset = driver.Create(filename, 16, 16, 1, DataType.GDT_Int32, ["TILED=YES"]))
        { using var band = dataset.GetRasterBand(1); band.Fill(7, 0); }
        var classification = new Classification(); classification.Set(7, "草地");
        // The lower-level constructor permits a not-yet-scanned input. Saving
        // its absent required signature must surface an error, never drop it.
        var input = new RasterClassificationInput(layer, filename, classification);
        layer.Add(input); project.Description = "失败时不应写入";
        byte[] before = File.ReadAllBytes(path);
        try { project.Save(force: true); throw new InvalidOperationException("Project swallowed a failed model save"); }
        catch (AggregateException) { }
        if (!File.ReadAllBytes(path).SequenceEqual(before) || layer.AllRasterInputs().Count != 1)
            throw new InvalidOperationException("Failed save lost its input or changed project metadata");
        input.Signature = FileSignature.LoadDefault(filename);
        project.Save(force: true); layer.Dispose();
        var reread = new Project(path);
        try
        {
            if (reread.Description != "失败时不应写入" || reread.ClassificationLayers.Single().AllRasterInputs().Count != 1)
                throw new InvalidOperationException("Corrected source input did not survive retry and independent reread");
        }
        finally { foreach (var item in reread.ClassificationLayers) item.Dispose(); }
        Console.WriteLine("Failed source input saves propagate, preserve project XML and input identity, and retry after correction.");
    }
}
