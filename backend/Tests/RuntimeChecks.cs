using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using Geospatial.GDALAssist;
using Geospatial.IO.Vectors;
using Geospatial.Rendering.Systems;
using Geospatial.Rendering.TiledRenderingSystem;
using Geospatial.Vectors;
using H5Assist;
using OSGeo.GDAL;
using Utility.Memory;
using Utility.VisualElements;
using Visual.Observables.Filtering;

internal static class RuntimeChecks
{
    internal static async Task Run()
    {
        Ras.Backend.HdfRuntimeService.Configure();
        Check(Ras.Backend.HdfRuntimeService.Inspect().IsThreadSafe,
            "The actual HDF5 runtime supports concurrent readers and finalizer closes.");
        using var directory = new TemporaryDirectory();
        var filter = new ObservableStringFilter<string>(value => value);
        var events = new List<string>();
        filter.PropertyChanging += (_, e) => events.Add("before:" + e.PropertyName + ":" + filter.SearchText);
        filter.PropertyChanged += (_, e) => events.Add("after:" + e.PropertyName + ":" + filter.SearchText);
        filter.SearchText = "河道";
        filter.SearchText = "河道";
        Check(events.SequenceEqual(new[] { "before:SearchText:", "after:SearchText:河道" }), "Observable notifications retain ordering, property names and equality guard");

        int evictions = 0;
        var cache = new CacheManager<int, byte[]>(value => value.Length);
        cache.OnItemEvicted += (_, _) => evictions++;
        byte[] bytes = [0, 128, 255, 0, 13, 10];
        cache.Make(1, bytes);
        Check(cache.TryTake(1, out var taken) && ReferenceEquals(bytes, taken) && cache.ItemsInCache == 0 && evictions == 0, "Cache transfer retains ownership without eviction disposal");
        cache.Make(2, bytes);
        cache.ForceEvict(2);
        Check(cache.ItemsInCache == 0 && cache.ActualCacheSize() == 0 && evictions == 1, "Eviction counts each item once");
        Check(!cache.TryTake(2, out _), "Evicted entry is unavailable");
        CheckRenderTile();

        GDALSetup.InitializeMultiplatform();
        Check(GDALSetup.IsInitialized && !string.IsNullOrWhiteSpace(GDALSetup.LoadedVersion), "Packaged GDAL initializes on this Mac");
        var gdalInformation = Ras.Backend.GdalRuntimeService.Inspect();
        Check(gdalInformation.Directory == GDALSetup.ToolDirectory
            && gdalInformation.Version == GDALSetup.LoadedVersion
            && gdalInformation.ReleaseName == Gdal.VersionInfo("RELEASE_NAME")
            && Directory.Exists(gdalInformation.Directory) && Directory.Exists(gdalInformation.DataDirectory)
            && gdalInformation.ExpectedLocations.Contains(AppContext.BaseDirectory),
            "GDAL information describes the actual loaded runtime and its portable search locations");
        using (var file = VirtualFile.CreateInMemory())
        {
            file.WriteBytes(bytes.AsMemory(0, 3));
            file.WriteBytes(bytes.AsMemory(3));
            Check(Gdal.VSIFFlushL(file.NativeHandle) == 0, "Virtual-file flush");
            nint memory = Gdal.GetMemFileBuffer(file.VirtualFilename, out ulong length, false);
            byte[] actual = new byte[checked((int)length)];
            Marshal.Copy(memory, actual, 0, actual.Length);
            Check(actual.SequenceEqual(bytes), "GDAL virtual files retain arbitrary binary bytes and append position");
        }
        var geographic = new EPSGProjection(4326);
        var mercator = new EPSGProjection(3857);
        foreach (int count in new[] { 1, 48 })
        {
            Point[] points = Enumerable.Repeat(new Point(1, 1), count).ToArray();
            Projector.TransformPoints(geographic, mercator, points);
            Check(points.All(p => Math.Abs(p.X - 111319.49079327357) < 1e-6 && Math.Abs(p.Y - 111325.1428663851) < 1e-6), "Small and large coordinate batches use actual native projection");
        }
        var psi = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "gdalinfo"))
        { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        psi.ArgumentList.Add("--version");
        using (var process = Process.Start(psi)!)
        {
            Task<string> output = process.StandardOutput.ReadToEndAsync();
            Task<string> error = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
            Check(process.ExitCode == 0 && (await output).Contains("GDAL"), "Packaged native GDAL command executes: " + await error);
        }
        string hdf = Path.Combine(directory.FullName, "中文数据.hdf");
        double[] elevations = [1.25, -9.5, 1024.125];
        using (var writer = new H5Writer(hdf)) writer.WriteDataset("/检查/高程", elevations);
        using (var reader = new H5Reader(hdf))
        {
            reader.ReadDataset("/检查/高程", out double[] actual);
            Check(actual.SequenceEqual(elevations), "HEC HDF wrapper writes and reads a Unicode path with native HDF5");
        }
        var mesh = new Mesh { Faces = new Face[2] };
        float[] stations = [1.5f, 7.25f];
        mesh.SetFaceCentroidStations(stations);
        stations[0] = 999;
        Check(mesh.FaceCentroidDistance(0) == 1.5f && mesh.FaceCentroidDistance(1) == 7.25f, "Mesh centroid data retains its own HDF input snapshot");
        Console.WriteLine("Native GDAL, CLI, projection, binary I/O, HDF and object lifecycle checks passed on " + RuntimeInformation.RuntimeIdentifier + ".");
    }

    private static void CheckRenderTile()
    {
        int images = 0, bitmaps = 0, returned = 0;
        var image = Proxy<IImage>((_, _) => null);
        var bitmap = Proxy<IBitmap>((_, _) => null);
        var canvas = Proxy<ITileCanvas>((_, _) => null);
        var labels = Proxy<ILabelHandler>((_, _) => null);
        var imageProvider = Proxy<IImageProvider>((method, _) => method.Name == "Acquire" ? (++images, image).Item2 : Return());
        var bitmapProvider = Proxy<IBitmapProvider>((method, _) => method.Name == "Acquire" ? (++bitmaps, bitmap).Item2 : Return());
        object? Return() { returned++; return null; }
        using (var tile = RenderTile.CreateUninitialized())
        {
            tile.TryInitialize(canvas, imageProvider, bitmapProvider, labels);
            tile.TryInitialize(canvas, Proxy<IImageProvider>((_, _) => throw new Exception("Reinitialized image provider")), Proxy<IBitmapProvider>((_, _) => throw new Exception("Reinitialized bitmap provider")), labels);
            tile.Reset(1, 2, PyramidLevel.Dynamic);
        }
        Check(images == 1 && bitmaps == 1 && returned == 2, "Render tile initializes once and returns both resources to their owning providers");
    }

    private static T Proxy<T>(Func<MethodInfo, object?[]?, object?> handler) where T : class
    {
        T proxy = DispatchProxy.Create<T, TestInterfaceProxy>();
        ((TestInterfaceProxy)(object)proxy).Handler = handler;
        return proxy;
    }
    private static void Check(bool value, string name)
    {
        if (!value) throw new InvalidOperationException(name);
    }
}

public class TestInterfaceProxy : DispatchProxy
{
    public Func<MethodInfo, object?[]?, object?> Handler { get; set; } = null!;
    protected override object? Invoke(MethodInfo? method, object?[]? args) => Handler(method!, args);
}

internal sealed class TemporaryDirectory : IDisposable
{
    private readonly DirectoryInfo _directory = Directory.CreateTempSubdirectory("hecras-backend-");
    // Backend source contracts return physical file identities. Construct
    // fixtures under that same physical root, so /var and /private/var do
    // not produce false owner mismatches or escaping relative manifests.
    public string FullName => CanonicalDirectory(_directory);
    private static string CanonicalDirectory(DirectoryInfo directory)
    {
        if (directory.LinkTarget is not null)
            return CanonicalDirectory(new DirectoryInfo((directory.ResolveLinkTarget(returnFinalTarget: true)
                ?? throw new IOException("The fixture temporary-directory alias could not be resolved.")).FullName));
        return directory.Parent is { } parent
            ? Path.Combine(CanonicalDirectory(parent), directory.Name)
            : directory.FullName;
    }
    public void Dispose() => _directory.Delete(recursive: true);
}
