using System.IO.Compression;
using System.Security.Cryptography;
using System.Xml.Linq;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using Geospatial.Rasters.Classifications;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Layers.Payloads;
using Ras.Layers.Terrains;
using Utility.Files;
using Utility.Units;

internal static class PlanExportChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string sourceDirectory = Path.Combine(temporary.FullName, "source");
        string external = Path.Combine(temporary.FullName, "external");
        Directory.CreateDirectory(sourceDirectory); Directory.CreateDirectory(external);
        string rasterPath = Path.Combine(external, "中文地形.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var dataset = driver.Create(rasterPath, 16, 16, 1, DataType.GDT_Float32, ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
        {
            dataset.SetGeoTransform([0, 1, 0, 16, 0, -1]);
            using var band = dataset.GetRasterBand(1); band.Fill(42, 0);
        }
        string dataFile = Path.Combine(external, "原始数据.dss"); File.WriteAllText(dataFile, "copy exact source bytes 🌊");
        string classificationPath = Path.Combine(external, "中文分类.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var dataset = driver.Create(classificationPath, 16, 16, 1, DataType.GDT_Int32, ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
        {
            dataset.SetGeoTransform([0, 1, 0, 16, 0, -1]); using var band = dataset.GetRasterBand(1); band.Fill(7, 0);
        }
        string dataDirectory = Path.Combine(external, "目录"); Directory.CreateDirectory(Path.Combine(dataDirectory, "nested"));
        File.WriteAllText(Path.Combine(dataDirectory, "first.csv"), "time,value\n0,1");
        File.WriteAllText(Path.Combine(dataDirectory, "nested", "second.CSV"), "time,value\n1,2");
        File.WriteAllText(Path.Combine(dataDirectory, "ignore.txt"), "must not copy");
        string sourcePath = Path.Combine(sourceDirectory, "原工程.ras");
        var source = Project.CreateNew(sourcePath, UnitSystem.SI);
        var terrain = source.AddNewTerrain("地形"); terrain.Add(RasterTerrainInput.CreateAndScan(terrain, rasterPath));
        var classification = source.AddNewClassification("土地分类");
        var classes = new Classification(); classes.Set(7, "草地"); classification.AddNewRasterLayer(classificationPath, classes);
        var nvalues = source.AddNewNValueLayer("糙率"); nvalues.SetTrackClassificationLayer(classification); nvalues.InterpretationTable.Set("草地", .035f);
        var geometry = source.AddNewGeometry("几何", terrain, nvalues);
        geometry.FlowAreaLayer.Add(new FlowArea(CreateMesh(), "区域"));
        var boundary = source.AddNewBoundaryCondition("边界", new DateTime(2026, 10, 15), TimeSpan.FromDays(1));
        var connection = source.ConnectionSource.AddFileConnection("文件连接", dataFile); connection.Description = "中文连接说明";
        Check(Path.GetFullPath(Path.Combine(source.ProjectDirectory, connection.RelativePath)) == dataFile, "New project connections use the project directory before and after the project file first exists");
        var directoryConnection = new DirectoryExternalConnection(source.ProjectDirectory) { Name = "目录连接", Description = "递归筛选", SearchPattern = "*.csv", Recurse = true };
        directoryConnection.SetConnectedPathname(dataDirectory); source.ConnectionSource.Connections.Add(directoryConnection);
        source.ConnectionSource.AddFileConnection("未使用的失效连接", Path.Combine(external, "absent.dss"));
        var line = boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(0, 0), new(2, 0) }), new ExternalPayload(WellKnownPayloadVariables.Flow, "文件连接", "/A/B/C/D/E/F/"));
        line.Add(new ExternalPayload(WellKnownPayloadVariables.Stage, "目录连接", ""));
        var plan = source.AddNewPlan("选择的方案", geometry, boundary);
        source.AddNewPlan("不应导出的方案", geometry, boundary);
        source.Save(); Dispose(source);
        var originalFiles = Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories).Append(rasterPath).Append(classificationPath)
            .ToDictionary(path => path, Hash);
        XElement draft = XElement.Load(sourcePath); draft.SetElementValue("Description", "未保存关联上下文的导出说明");
        PlanExportRequest Request(string name, bool zip = false, bool clip = false, float? cell = null, string behavior = "CopyToProject") =>
            new(sourcePath, draft.ToString(), plan.Filename, Path.Combine(temporary.FullName, name), zip, clip, cell, behavior);
        PlanExportResult Export(PlanExportRequest request)
        {
            var inspection = PlanExportService.Inspect(request);
            Check(inspection.CanExecute, inspection.ValidationMessage ?? "Export readiness");
            return PlanExportService.Export(request with { Revision = inspection.Revision });
        }
        var request = Request("目录导出");
        string disguisedNValues = Path.Combine(temporary.FullName, "Classifications.h5"), disguisedClassification = Path.Combine(temporary.FullName, "NValues.h5");
        File.Copy(nvalues.Filename, disguisedNValues); File.Copy(classification.Filename, disguisedClassification);
        var catalog = ModelEditorAdapter.Catalog(new([disguisedNValues, disguisedClassification, plan.Filename]));
        Check(catalog[0].Category == "NValues" && catalog[1].Category == "Classifications" && catalog[2].Category == null && !string.IsNullOrEmpty(catalog[2].Error),
            "Surface catalog uses source HDF groups instead of misleading filenames and retains errors for unrecognized models");
        Check(PlanExportService.AccessFolders(request).SequenceEqual([external]), "External access discovery returns the required common data folder without enumerating the directory connection or including unused connections");
        Check(PlanExportService.AccessFolders(request with { PlanPath = null }).Length == 0, "Access discovery does not ask for data from an unselected plan");
        var ready = PlanExportService.Inspect(request);
        Check(ready.Plans.Length == 2 && ready.SourceFiles.Contains(rasterPath) && ready.RequiredConnections.Length == 2,
            "Inspection dependency mismatch: " + System.Text.Json.JsonSerializer.Serialize(ready) + "; expected raster " + rasterPath);
        var exported = Export(request);
        string copiedProject = Path.Combine(exported.OutputPath, exported.ProjectFilename);
        VerifyCopy(copiedProject, originalFiles[rasterPath], originalFiles[classificationPath]);
        string moved = Path.Combine(temporary.FullName, "重新移动后的导出"); Directory.Move(exported.OutputPath, moved);
        VerifyCopy(Path.Combine(moved, exported.ProjectFilename), originalFiles[rasterPath], originalFiles[classificationPath]);
        var referenced = Export(Request("绝对路径引用", behavior: "ReferenceByAbsolutePath"));
        var referenceProject = new Project(Path.Combine(referenced.OutputPath, referenced.ProjectFilename));
        try
        {
            var file = (FileExternalConnection)referenceProject.ConnectionSource.Connections.Single(item => item.Name == "文件连接");
            XElement savedConnection = XElement.Load(referenceProject.Filename).Element("Connections")!.Elements("Connection").Single(item => item.Attribute("Name")?.Value == "文件连接");
            Check(file.TryGetFile(out string target) && target == dataFile && savedConnection.Element("AbsolutePath")?.Value == dataFile && savedConnection.Element("RelativePath") == null, "Absolute-reference persistence retains original file identity");
        }
        finally { Dispose(referenceProject); }
        var clipped = Export(Request("裁剪重采样", clip: true, cell: .5f));
        CheckRaster(clipped, expectedCellSize: .5, expectClipped: true);
        var resampled = Export(Request("全幅重采样", cell: 2));
        CheckRaster(resampled, expectedCellSize: 2, expectClipped: false);
        var uploadSessionID = Guid.NewGuid().ToString();
        var zipped = Export(Request("完整导出.zip", zip: true) with { ProjectSessionID = uploadSessionID });
        await PlanModelUploadChecks.VerifyCommittedReceipt(zipped);
        using (var archive = ZipFile.OpenRead(zipped.OutputPath))
        {
            Check(archive.Entries.Any(item => item.FullName == "原工程/原工程.ras") && archive.Entries.All(item => !item.FullName.Contains('\\')), "ZIP entries have a stable project root and portable separators");
        }
        Check(!PlanExportService.Inspect(Request("完整导出.zip", zip: true)).CanExecute, "Existing ZIP is not overwritten without native-save authorization");
        var replace = Request("完整导出.zip", zip: true) with { ReplaceFile = true };
        string expectedDestination = PlanExportService.Inspect(replace).Revision;
        File.AppendAllText(zipped.OutputPath, "external edit");
        string editedDestination = Hash(zipped.OutputPath);
        ExpectChanged(() => PlanExportService.Export(replace with { Revision = expectedDestination }));
        Check(Hash(zipped.OutputPath) == editedDestination, "Externally changed destination survives rejected replacement");
        Export(replace);
        using (var archive = ZipFile.OpenRead(zipped.OutputPath)) Check(archive.Entries.Count > 5, "Authorized replacement publishes a complete ZIP");
        var stale = Request("来源变更不能发布"); string revision = PlanExportService.Inspect(stale).Revision;
        byte[] externalBytes = File.ReadAllBytes(dataFile); File.AppendAllText(dataFile, "source edit");
        ExpectChanged(() => PlanExportService.Export(stale with { Revision = revision }));
        Check(!Directory.Exists(stale.OutputPath), "Changed external source leaves no published output");
        File.WriteAllBytes(dataFile, externalBytes);
        foreach (var item in originalFiles) Check(Hash(item.Key) == item.Value, "Export preserves source project, model and raster bytes");
        Check(!Directory.EnumerateDirectories(temporary.FullName, ".plan-export-*", SearchOption.AllDirectories).Any(), "Export staging is removed after success and rejected writes");
        if (Environment.GetEnvironmentVariable("HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY") is string acceptance)
        {
            Directory.CreateDirectory(acceptance);
            foreach (string folder in new[] { "source", "external" })
                foreach (string filename in Directory.EnumerateFiles(Path.Combine(temporary.FullName, folder), "*", SearchOption.AllDirectories))
                {
                    string target = Path.Combine(acceptance, Path.GetRelativePath(temporary.FullName, filename));
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(filename, target, overwrite: false);
                }
        }
        Console.WriteLine("Actual source plan exports, independent relocated HDF/raster/connection reads, clipping, full resampling, ZIP, revisions and unchanged source bytes passed.");
    }
    private static void VerifyCopy(string filename, string rasterHash, string classificationHash)
    {
        var project = new Project(filename);
        try
        {
            Check(project.Plans.Count == 1 && project.Plans.Single().Name == "选择的方案", "Only selected source plan exported");
            var plan = project.Plans.Single();
            Check(plan.Geometry.Name == "几何" && plan.BoundaryCondition.Name == "边界" && project.Description.Contains("未保存"),
                "Actual exported project mismatch: " + plan.Geometry.Name + "; " + plan.BoundaryCondition.Name + "; " + project.Description);
            string raster = plan.Geometry.AssociatedTerrain.AllRasterInputs().Single().Filename;
            Check(raster.StartsWith(project.ProjectDirectory + Path.DirectorySeparatorChar, StringComparison.Ordinal) && Hash(raster) == rasterHash, "Copied raster relocates and preserves actual TIFF bytes");
            string classes = plan.Geometry.AssociatedNValueLayer.AssociatedClassificationLayer.AllRasterInputs().Single().Filename;
            Check(classes.StartsWith(project.ProjectDirectory + Path.DirectorySeparatorChar, StringComparison.Ordinal) && Hash(classes) == classificationHash, "Copied classification relocates independently and retains raster bytes");
            Check(project.ConnectionSource.Count == 2, "Only connections required by the selected plan migrate");
            var file = (FileExternalConnection)project.ConnectionSource.Connections.Single(item => item.Name == "文件连接");
            Check(file.Description == "中文连接说明" && file.TryGetFile(out string data) && data.StartsWith(project.ProjectDirectory + Path.DirectorySeparatorChar, StringComparison.Ordinal), "Copied source connection preserves name, description and relative location");
            var directory = (DirectoryExternalConnection)project.ConnectionSource.Connections.Single(item => item.Name == "目录连接");
            Check(directory.TryGetFiles(out string[] files) && files.Length == 2 && files.All(item => item.EndsWith("csv", StringComparison.OrdinalIgnoreCase)), "Recursive case-insensitive directory filter survives project relocation");
            Check(directory.TryGetHash(out string first) && directory.TryGetHash(out string second) && first == second, "Source directory hash is deterministic");
        }
        finally { Dispose(project); }
    }
    private static void CheckRaster(PlanExportResult exported, double expectedCellSize, bool expectClipped)
    {
        var project = new Project(Path.Combine(exported.OutputPath, exported.ProjectFilename));
        try
        {
            string filename = project.Plans.Single().Geometry.AssociatedTerrain.AllRasterInputs().Single().Filename;
            using var dataset = Gdal.Open(filename, Access.GA_ReadOnly);
            double[] transform = new double[6]; dataset.GetGeoTransform(transform);
            Check(Math.Abs(transform[1] - expectedCellSize) < 1e-8 && (expectClipped ? dataset.RasterXSize < 16 : dataset.RasterXSize == 8), "Native GDAL independently reads requested clip/resample grid");
            using var band = dataset.GetRasterBand(1);
            float[] pixels = new float[dataset.RasterXSize * dataset.RasterYSize];
            band.ReadRaster(0, 0, dataset.RasterXSize, dataset.RasterYSize, pixels, dataset.RasterXSize, dataset.RasterYSize, 0, 0);
            band.GetNoDataValue(out double noData, out int hasNoData);
            float[] valid = pixels.Where(value => float.IsFinite(value) && (hasNoData == 0 || value != noData)).ToArray();
            Check(valid.Length > 0 && valid.All(value => Math.Abs(value - 42) < 1e-5), "Native GDAL verifies actual clipped/resampled source elevations, not only file dimensions");
        }
        finally { Dispose(project); }
    }
    private static Mesh CreateMesh()
    {
        Point[] points = [new(0, 0), new(2, 0), new(2, 2), new(0, 2)];
        Face[] faces = Enumerable.Range(0, 4).Select(i => new Face { fpA = i, fpB = (i + 1) % 4, cellA = 0, cellB = -1 }).ToArray();
        FacePoint[] nodes = points.Select((point, index) => new FacePoint(point) { Faces = new int[] { (index + 3) % 4, index } }).ToArray();
        return new Mesh(new Polygon(points), new Cell[] { new() { Faces = new int[] { 0, 1, 2, 3 } } }, faces, nodes, new Point[] { new(1, 1) }, null!);
    }
    private static string Hash(string filename) { using var input = File.OpenRead(filename); return Convert.ToHexString(SHA256.HashData(input)); }
    private static void Dispose(Project project)
    {
        foreach (var layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries).Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues).Concat(project.ClassificationLayers)) layer.Dispose();
    }
    private static void ExpectChanged(Action action) { try { action(); throw new InvalidOperationException("Stale export accepted"); } catch (SourceFileChangedException) { } }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
