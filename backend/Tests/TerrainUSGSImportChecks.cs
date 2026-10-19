using Geospatial.IO.Network.USGS;
using Ras.Backend;
using System.Text.Json;

internal static class TerrainUSGSImportChecks
{
    internal static void Run()
    {
        USGSItem first = CreateItem("https://example.invalid/elevation.tif");
        USGSItem same = CreateItem("https://example.invalid/elevation.tif");
        USGSItem changed = CreateItem("https://example.invalid/replaced.tif");
        string productId = ModelEditorAdapter.ProductId(first);
        Check(productId.Length == 64 && productId.All(Uri.IsHexDigit)
            && productId == ModelEditorAdapter.ProductId(same)
            && productId != ModelEditorAdapter.ProductId(changed)
            && !productId.Contains(first.DownloadURL, StringComparison.Ordinal),
            "USGS products receive stable opaque identifiers bound to provider metadata.");
        Check(ModelEditorAdapter.IsDownloadableProduct(first)
            && !ModelEditorAdapter.IsDownloadableProduct(CreateItem("file:///tmp/untrusted.tif")),
            "A queried USGS item is downloadable only through an absolute HTTP(S) provider URL.");

        Check(ModelEditorAdapter.IsFiniteTerrainExtent(new(10, 11, 20, 21))
            && !ModelEditorAdapter.IsFiniteTerrainExtent(new(11, 10, 20, 21))
            && !ModelEditorAdapter.IsFiniteTerrainExtent(new(double.NaN, 11, 20, 21))
            && !ModelEditorAdapter.IsFiniteTerrainExtent(new(10, double.PositiveInfinity, 20, 21)),
            "USGS scope extents must be finite, ordered project coordinates.");

        CheckOwnedManifestCleanup();
        Console.WriteLine("USGS terrain import identity and extent contracts preserve source-only selection.");
    }

    private static void CheckOwnedManifestCleanup()
    {
        string directory = ModelEditorAdapter.CreateTerrainUSGSDirectory(out string token);
        string assetPath = Path.Combine(directory, "terrain.hdf");
        string projectPath = Path.Combine(directory, "project.ras");
        string sourcePath = Path.Combine(directory, "owned-source.tmp");
        try
        {
            File.WriteAllText(sourcePath, "token-owned temporary file fixture");
            var source = new TerrainUSGSDownloadedFile("opaque-product", "USGS DEM", sourcePath,
                new string('a', 64), 1.0, "ThirtySeconds");
            var manifest = new TerrainUSGSImportManifest(1, token, assetPath, projectPath,
                new string('b', 64), "input", [source]);
            File.WriteAllText(Path.Combine(directory, ModelEditorAdapter.TerrainUSGSManifestName),
                JsonSerializer.Serialize(manifest, BackendJson.Options));

            bool rejected = false;
            try
            {
                _ = ModelEditorAdapter.CleanupTerrainUSGSAsync(new(
                    new ModelRequest(Path.Combine(directory, "other-terrain.hdf"), "Terrain", projectPath), token))
                    .GetAwaiter().GetResult();
            }
            catch (ArgumentException)
            {
                rejected = true;
            }
            Check(rejected && File.Exists(sourcePath) && Directory.Exists(directory),
                "A USGS cleanup token cannot remove files for a different terrain asset.");

            TerrainUSGSCleanupData cleanup = ModelEditorAdapter.CleanupTerrainUSGSAsync(new(
                new ModelRequest(assetPath, "Terrain", projectPath), token)).GetAwaiter().GetResult();
            Check(cleanup.Removed && !File.Exists(sourcePath) && !Directory.Exists(directory),
                "The owning terrain project can remove exactly its token-owned USGS temporary files.");
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    private static USGSItem CreateItem(string downloadUrl) => new()
    {
        Title = "1/3 arc second elevation DEM",
        DownloadURL = downloadUrl,
        PublicationDate = "2025-01-15",
        MetaURL = "https://example.invalid/metadata/1",
        SizeInBytesNullable = 128,
        BoundingBox = new BoundingBoxJson { MinX = -122, MaxX = -121, MinY = 37, MaxY = 38 }
    };

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
