using System.IO.Compression;
using Google.Protobuf;
using VectorTile;
using Ras.Backend;

internal static class BackgroundMapOsmCpuChecks
{
    internal static void Run()
    {
        const string styleJson = """
        {
          "version": 8,
          "layers": [
            { "id": "background", "type": "background", "paint": { "background-color": "#f5f5f5" } },
            { "id": "landuse-park", "type": "fill", "source-layer": "landuse", "minzoom": 0, "maxzoom": 14,
              "filter": ["==", "class", "park"],
              "paint": { "fill-color": "#00ff00", "fill-opacity": 0.5, "fill-outline-color": "#006600" } },
            { "id": "transportation-name", "type": "symbol", "source-layer": "transportation_name", "minzoom": 0,
              "filter": ["has", "name:en"],
              "layout": { "text-field": "{class}", "text-size": 12, "text-font": ["Open Sans Bold"], "text-transform": "uppercase" },
              "paint": { "text-color": "#112233", "text-halo-color": "#ffffff", "text-halo-width": 1.5 } }
          ]
        }
        """;

        OsmCpuStyleDocument style = OsmBackgroundCpuRenderer.ParseStyle(styleJson);
        TileParser tile = new();
        tile.Layers.Add(CreatePolygonLayer());
        tile.Layers.Add(CreateRoadNameLayer());

        OsmCpuTileFrame frame = OsmBackgroundCpuRenderer.DecodeTile(
            Compress(tile), style, new OsmCpuTileCoordinate(3, 3, 2),
            new OsmCpuRenderOptions { Density = 1, ShowLabels = true });

        Check(frame.StyleZoomLevel == 4, "The source density offset determines style zoom");
        Check(frame.CoordinateSpace == OsmCpuCoordinateSpace.WebMercator900913,
            "Unprojected CPU tile output declares its WebMercator coordinates");
        Check(frame.BackgroundColor == new OsmCpuColor(245, 245, 245, 255),
            "The original style background color is returned");
        Check(frame.ClipPolygon.Length == 32, "The tile clip ring retains the source 512-unit edge sampling");

        OsmCpuFeaturePath park = frame.Features.Single();
        Check(park.StyleLayerId == "landuse-park" && park.SourceLayer == "landuse"
            && park.GeometryType == OsmCpuGeometryType.Polygon && park.Parts.Length == 1
            && park.Parts[0].IsClosed,
            "The class filter keeps only the styled park polygon and closes its MVT ring");
        Check(park.Appearance.FillColor == new OsmCpuColor(0, 255, 0, 127)
            && park.Appearance.StrokeColor == new OsmCpuColor(0, 102, 0, 127),
            "The retained ColorScheme.GenerateFill applies fill opacity to both fill and a constant outline");
        // Source GenerateFill only exempts an outline supplied by zoom stops.
        string stoppedOutlineStyle = styleJson.Replace(
            "\"fill-outline-color\": \"#006600\"",
            "\"fill-outline-color\": {\"stops\":[[0,\"#006600\"],[12,\"#006600\"]]}",
            StringComparison.Ordinal);
        OsmCpuTileFrame stoppedOutline = OsmBackgroundCpuRenderer.DecodeTile(Compress(tile),
            OsmBackgroundCpuRenderer.ParseStyle(stoppedOutlineStyle), new OsmCpuTileCoordinate(3, 3, 2),
            new OsmCpuRenderOptions { Density = 1 });
        Check(stoppedOutline.Features.Single().Appearance.FillColor == new OsmCpuColor(0, 255, 0, 127)
            && stoppedOutline.Features.Single().Appearance.StrokeColor == new OsmCpuColor(0, 102, 0, 255),
            "A source zoom-stop outline retains its own alpha while fill opacity still scales the fill");
        Check(park.ZIndex == 3000, "The source tile-level z-index stride is retained");
        Check(frame.Features[0].Parts[0].Points.All(point => double.IsFinite(point.X) && double.IsFinite(point.Y)),
            "MVT delta geometry converts to finite WebMercator world coordinates");

        OsmCpuTileFrame projectedFrame = OsmBackgroundCpuRenderer.DecodeTile(
            Compress(tile), style, new OsmCpuTileCoordinate(3, 3, 2),
            new OsmCpuRenderOptions { Density = 1 },
            (x, y) => (x + 10.0, y - 20.0));
        OsmCpuPoint unprojectedPoint = frame.Features[0].Parts[0].Points[0];
        OsmCpuPoint projectedPoint = projectedFrame.Features[0].Parts[0].Points[0];
        Check(projectedFrame.CoordinateSpace == OsmCpuCoordinateSpace.ProjectWorld
            && projectedFrame.ClipPolygon.Length == 32
            && Math.Abs(projectedPoint.X - unprojectedPoint.X - 10.0) < 1E-6
            && Math.Abs(projectedPoint.Y - unprojectedPoint.Y + 20.0) < 1E-6,
            "The supplied projection callback maps paths and tile clips into project-world coordinates");

        OsmCpuLabel roadName = frame.Labels.Single();
        Check(roadName.Text == "MAIN STREET" && roadName.Anchor is null && roadName.FollowPath?.Length == 2,
            "Symbol line geometry follows its path and prefers name:en before name");
        Check(roadName.FontFamily == "Open Sans" && roadName.Bold && roadName.FontSize == 12
            && roadName.Color == new OsmCpuColor(17, 34, 51, 255)
            && roadName.HaloColor == new OsmCpuColor(255, 255, 255, 255)
            && roadName.HaloWidth == 1.5,
            "The symbol layer returns its source font, size, color and halo style");
        Check(roadName.ZIndex == OsmBackgroundCpuRenderer.LabelZIndex,
            "Source labels remain above tile geometry");

        OsmCpuTileFrame withoutLabels = OsmBackgroundCpuRenderer.DecodeTile(
            Compress(tile), style, new OsmCpuTileCoordinate(3, 3, 2),
            new OsmCpuRenderOptions { Density = 1, ShowLabels = false });
        Check(withoutLabels.Features.Length == 1 && withoutLabels.Labels.Length == 0,
            "ShowLabels suppresses label output while preserving map geometry");

        CheckWaterNameAndSymbolFallback();

        Console.WriteLine("Source-format OSM style filtering, gzip MVT geometry, TMS world conversion, z-order, opacity, and label output passed.");
    }

    private static void CheckWaterNameAndSymbolFallback()
    {
        const string styleJson = """
        {
          "version": 8,
          "layers": [
            { "id": "water-name", "type": "symbol", "source-layer": "water_name",
              "layout": { "text-size": 9 }, "paint": {} }
          ]
        }
        """;

        TileParser tile = new();
        TileParser.Types.Layer layer = new() { Name = "water_name", Extent = 4096 };
        layer.Keys.Add("name");
        layer.Values.Add(new TileParser.Types.Value { StringValue = "Lake Label" });
        layer.Features.Add(new TileParser.Types.Feature
        {
            Type = TileParser.Types.GeomType.Point,
            Tags = { 0, 0 },
            Geometry = { 9, 400, 800 }
        });
        tile.Layers.Add(layer);

        OsmCpuTileFrame frame = OsmBackgroundCpuRenderer.DecodeTile(
            Compress(tile), OsmBackgroundCpuRenderer.ParseStyle(styleJson),
            new OsmCpuTileCoordinate(2, 1, 1));

        Check(frame.Features.Length == 0 && frame.Labels.Length == 1,
            "The original wanted-layer list includes water_name and point symbols become labels only");
        Check(frame.Labels[0].Text == "Lake Label"
            && frame.Labels[0].Color == new OsmCpuColor(255, 105, 180, 255),
            "A symbol without text-color keeps the source's transparent fill and HotPink label pen fallback");
    }

    private static TileParser.Types.Layer CreatePolygonLayer()
    {
        TileParser.Types.Layer layer = new() { Name = "landuse", Extent = 4096 };
        layer.Keys.Add("class");
        layer.Values.Add(new TileParser.Types.Value { StringValue = "park" });
        layer.Values.Add(new TileParser.Types.Value { StringValue = "water" });
        layer.Features.Add(new TileParser.Types.Feature
        {
            Type = TileParser.Types.GeomType.Polygon,
            Tags = { 0, 0 },
            Geometry = { 9, 2000, 2000, 26, 2000, 0, 0, 2000, 1999, 0, 15 }
        });
        layer.Features.Add(new TileParser.Types.Feature
        {
            Type = TileParser.Types.GeomType.Polygon,
            Tags = { 0, 1 },
            Geometry = { 9, 2000, 2000, 26, 2000, 0, 0, 2000, 1999, 0, 15 }
        });
        return layer;
    }

    private static TileParser.Types.Layer CreateRoadNameLayer()
    {
        TileParser.Types.Layer layer = new() { Name = "transportation_name", Extent = 4096 };
        layer.Keys.Add("name");
        layer.Keys.Add("name:en");
        layer.Values.Add(new TileParser.Types.Value { StringValue = "当地名称" });
        layer.Values.Add(new TileParser.Types.Value { StringValue = "Main Street" });
        layer.Features.Add(new TileParser.Types.Feature
        {
            Type = TileParser.Types.GeomType.Linestring,
            Tags = { 0, 0, 1, 1 },
            Geometry = { 9, 200, 400, 10, 200, 200 }
        });
        return layer;
    }

    private static byte[] Compress(TileParser tile)
    {
        using MemoryStream compressed = new();
        using (GZipStream gzip = new(compressed, CompressionLevel.SmallestSize, leaveOpen: true))
            tile.WriteTo(gzip);
        return compressed.ToArray();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }
}

