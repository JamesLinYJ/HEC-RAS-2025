using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Xml.Linq;
using Ras.Backend;

internal static class MapResultVelocityFieldChecks
{
    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(
            directory.FullName, velocityVariesByProfile: true);
        XDocument visualization = XDocument.Load(fixture.VisualizationPath, LoadOptions.PreserveWhitespace);
        XElement resultNode = visualization.Descendants("Node").Single(node =>
            (string?)node.Attribute("Type") == "Result");
        resultNode.SetAttributeValue("SelectedMapType", "Velocity");
        visualization.Save(fixture.VisualizationPath, SaveOptions.DisableFormatting);

        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] resultBefore = File.ReadAllBytes(fixture.ResultPath);
        byte[] terrainBefore = File.ReadAllBytes(fixture.TerrainPath);
        string visualizationRevision;
        using (FileStream stream = File.OpenRead(fixture.VisualizationPath))
            visualizationRevision = Convert.ToHexString(SHA256.HashData(stream));
        MapTreeRequest map = fixture.Map with { ExpectedVisualizationRevision = visualizationRevision };
        MapResultSourcesResult sources = MapResultChartService.Sources(new(map, []));
        MapResultActiveNode active = sources.ActiveNodes.Single(node => node.NodeKind == "Result");
        MapResultSourceChoice selected = active.Selections.Single(slot => slot.SelectionIndex == 0)
            .SelectedResult ?? throw new InvalidDataException("The Result velocity fixture has no selected source.");
        var viewport = new RasterMapViewExtent(0, 0, 1, 1, 32, 32);

        MapResultVelocityFieldResult first = MapResultVelocityFieldService.Sample(new(map, [],
            sources.ContextToken, active.Node, "velocity-profile-0", selected.ResultPath,
            selected.Revision, 0, viewport));
        MapResultVelocityFieldResult last = MapResultVelocityFieldService.Sample(new(map, [],
            sources.ContextToken, active.Node, "velocity-profile-2", selected.ResultPath,
            selected.Revision, 2, viewport));

        int expectedBytes = checked(viewport.PixelWidth * viewport.PixelHeight * 3 * sizeof(float));
        Check(first.RequestID == "velocity-profile-0" && last.RequestID == "velocity-profile-2"
            && first.ContextToken == sources.ContextToken && last.ContextToken == sources.ContextToken
            && first.SourceID == last.SourceID
            && first.SourceID == MapResultRenderService.NodeIdentity(active.Node)
            && first.SourceMapID == fixture.Map.MapID && last.SourceMapID == fixture.Map.MapID
            && MapResultRenderService.SameLocator(first.Node, active.Node)
            && MapResultRenderService.SameLocator(last.Node, active.Node)
            && MapResultRenderService.NodeIdentity(first.Node) == MapResultRenderService.NodeIdentity(active.Node)
            && MapResultRenderService.NodeIdentity(last.Node) == MapResultRenderService.NodeIdentity(active.Node)
            && first.MapType == "Velocity" && last.MapType == "Velocity"
            && first.SelectionIndex == 0 && last.SelectionIndex == 0,
            "Velocity samples retain the exact active map, checked Result node, source context, and slot identity.");
        Check(first.ProfileIndex == 0 && last.ProfileIndex == 2
            && first.Width == viewport.PixelWidth && first.Height == viewport.PixelHeight
            && first.InterleavedVelocity.Length == expectedBytes
            && MapSourceTestPaths.SameFile(first.ResultPath, fixture.ResultPath)
            && first.Revision.Length == 64 && first.TerrainRevision.Length == 64,
            "The field response contains actual source profile indices, SHA-bound Result/terrain identity, and viewport-sized interleaved vectors.");
        Check(HasUsableVelocity(first) && HasUsableVelocity(last)
            && !first.InterleavedVelocity.SequenceEqual(last.InterleavedVelocity),
            "Velocity vectors and magnitude change with the retained OutputBlock profile values; no vector field is synthesized by the service.");

        Expect<SourceFileChangedException>(() => MapResultVelocityFieldService.Sample(new(map, [],
            new string('0', 64), active.Node, "stale-velocity-context", selected.ResultPath,
            selected.Revision, 1, viewport)));
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore)
            && File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore)
            && File.ReadAllBytes(fixture.ResultPath).SequenceEqual(resultBefore)
            && File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBefore),
            "Velocity sampling leaves the project, .vis, Result HDF and terrain byte-identical.");
        Console.WriteLine("Map-scoped Result Velocity mapper sampling, keyframe identity, per-profile vector changes, stale-context rejection and source byte preservation passed.");
    }

    private static bool HasUsableVelocity(MapResultVelocityFieldResult field)
    {
        for (int index = 0; index < field.Width * field.Height; index++)
        {
            int offset = checked(index * 3 * sizeof(float));
            float velocityX = BinaryPrimitives.ReadSingleLittleEndian(field.InterleavedVelocity.AsSpan(offset, sizeof(float)));
            float velocityY = BinaryPrimitives.ReadSingleLittleEndian(field.InterleavedVelocity.AsSpan(offset + sizeof(float), sizeof(float)));
            float magnitude = BinaryPrimitives.ReadSingleLittleEndian(field.InterleavedVelocity.AsSpan(offset + 2 * sizeof(float), sizeof(float)));
            if (float.IsFinite(velocityX) && float.IsFinite(velocityY) && float.IsFinite(magnitude)
                && magnitude != field.NoDataValue && magnitude >= 1e-5f)
                return true;
        }
        return false;
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }
}
