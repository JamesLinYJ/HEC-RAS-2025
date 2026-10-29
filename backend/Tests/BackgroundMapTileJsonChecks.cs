using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Google.Protobuf;
using VectorTile;
using Ras.Backend;

internal static class BackgroundMapTileJsonChecks
{
    internal static async Task Run()
    {
        BackgroundMapRenderRequest capture = CreateCapture(areBackgroundMapsOn: true, isOpenStreetMapOn: true);
        BackgroundMapTileJsonRequest request = new(capture, new BackgroundMapCoordinate(15, 25));
        TileParser tile = new();
        TileParser.Types.Layer layer = new() { Name = "transportation", Extent = 4096 };
        layer.Keys.Add("class");
        layer.Values.Add(new TileParser.Types.Value { StringValue = "primary" });
        layer.Features.Add(new TileParser.Types.Feature
        {
            Id = 42,
            Type = TileParser.Types.GeomType.Linestring,
            Tags = { 0, 0 },
            Geometry = { 9, 100, 200, 10, 300, 400 }
        });
        tile.Layers.Add(layer);
        byte[] compressedTile = Compress(tile);

        BackgroundMapTileJsonResult result = BackgroundMapService.DecodeTileJson(request,
            new OsmCpuTileCoordinate(5, 9, 17), compressedTile);
        Check(result.Status == "available" && result.SourceID == "osm"
            && result.Capture == capture && result.ClickedWorldPoint == request.ClickedWorldPoint,
            "A decoded tile result preserves the complete map/source capture and clicked world point");
        Check(result.Tile == new BackgroundMapTileAddress(5, 9, 17)
            && result.SourceRevision == Convert.ToHexString(SHA256.HashData(compressedTile)),
            "The response identifies the actual TMS tile and hashes its original compressed bytes");
        using (JsonDocument json = JsonDocument.Parse(result.RawJson ?? throw new InvalidOperationException("Decoded MVT JSON was missing.")))
        {
            JsonElement rawLayer = json.RootElement.GetProperty("layers")[0];
            JsonElement rawFeature = rawLayer.GetProperty("features")[0];
            Check(rawLayer.GetProperty("name").GetString() == "transportation"
                && rawFeature.GetProperty("id").GetString() == "42"
                && rawFeature.GetProperty("tags").GetArrayLength() == 2
                && rawFeature.GetProperty("geometry").GetArrayLength() == 6,
                "The payload is JSON from the retained VectorTile protobuf schema, including raw feature fields");
        }

        BackgroundMapTileAddress? center = BackgroundMapService.GetOsmTileAddress(2, 0, 0);
        Check(center == new BackgroundMapTileAddress(2, 2, 2)
            && BackgroundMapService.GetOsmTileAddress(2, 20037509, 0) is null,
            "Clicked WebMercator coordinates use the renderer's exact tile grid and reject points beyond coverage");

        BackgroundMapTileJsonRequest disabledRequest = new(
            CreateCapture(areBackgroundMapsOn: false, isOpenStreetMapOn: true),
            new BackgroundMapCoordinate(15, 25));
        BackgroundMapTileJsonResult disabled = await BackgroundMapService.GetTileJsonAsync(disabledRequest);
        Check(disabled.Status == "disabled" && disabled.Tile is null && disabled.RawJson is null
            && disabled.Capture == disabledRequest.Capture,
            "Disabled OSM background maps return an honest empty state without requesting a tile");
    }

    private static BackgroundMapRenderRequest CreateCapture(bool areBackgroundMapsOn, bool isOpenStreetMapOn) =>
        new("tile-json-request", "map-tile-json", "session-tile-json", "", "",
            new RasterMapViewExtent(0, 0, 100, 100, 100, 100), 1,
            new BackgroundMapSettings(areBackgroundMapsOn, isOpenStreetMapOn,
                false, false, "basic", 1, true, 1));

    private static byte[] Compress(TileParser tile)
    {
        using MemoryStream compressed = new();
        using (GZipStream gzip = new(compressed, CompressionLevel.SmallestSize, leaveOpen: true))
            tile.WriteTo(gzip);
        return compressed.ToArray();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
