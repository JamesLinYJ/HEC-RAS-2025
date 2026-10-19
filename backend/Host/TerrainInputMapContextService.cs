using Utility.Files;

namespace Ras.Backend;

public sealed record TerrainInputMapContextRequest(MapTreeRequest Map, string InputNodeID,
    string? ExpectedSourceClass = null, string? ExpectedTerrainPath = null);
public sealed record TerrainInputMapContextFeature(string Id, string Kind, TerrainMapCoordinate[] Points, bool Closed);
public sealed record TerrainInputMapContextData(string InputNodeID, int InputIndex, string TerrainPath, string TerrainRevision,
    string SourceClass, TerrainInputMapContextFeature[] Features);

/// <summary>
/// Reads only the selected terrain input's source vector render layer. It does
/// not sample or substitute the parent Terrain raster. The map tree request
/// proves that the input is still present under the captured saved map before
/// CatalogTreeService resolves the same source input and its project CRS.
/// </summary>
public static class TerrainInputMapContextService
{
    private static readonly HashSet<string> RenderableSourceClasses = new(StringComparer.Ordinal)
    {
        "ChannelModTerrainInputParentVC",
        "LeveeModTerrainInputVC",
        "PolygonRasterModTerrainInputVisualContext"
    };

    public static TerrainInputMapContextData Render(TerrainInputMapContextRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(request.Map);
        if (string.IsNullOrWhiteSpace(request.InputNodeID) ||
            !request.InputNodeID.StartsWith("terrain-input:", StringComparison.Ordinal))
            throw new ArgumentException("Choose a source terrain input from the current map tree.");

        MapTreeSnapshot mapTree = MapTreeService.Load(request.Map);
        CatalogTreeNode[] matchingNodes = mapTree.Roots.SelectMany(Descendants)
            .Where(node => string.Equals(node.Id, request.InputNodeID, StringComparison.Ordinal)).ToArray();
        if (matchingNodes.Length != 1) throw new SourceFileChangedException();
        CatalogTreeNode selected = matchingNodes[0];
        if (selected.Locator?.NodeType != "TerrainInput" ||
            !RenderableSourceClasses.Contains(selected.SourceClass) ||
            string.IsNullOrWhiteSpace(selected.AssetID))
            throw new NotSupportedException("This terrain input does not expose a source map render layer.");
        if (request.ExpectedSourceClass is { Length: > 0 } expectedSourceClass &&
            !string.Equals(expectedSourceClass, selected.SourceClass, StringComparison.Ordinal))
            throw new SourceFileChangedException();
        if (request.ExpectedTerrainPath is { Length: > 0 } expectedTerrainPath &&
            !SourceFilePaths.Canonical(expectedTerrainPath).Equals(SourceFilePaths.Canonical(selected.AssetID),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new SourceFileChangedException();

        var projectRequest = new CatalogTreeRequest(request.Map.ProjectPath,
            request.Map.ProjectXml, Mode: "Project");
        TerrainInputMapContextData data = CatalogTreeService.ReadTerrainInputMapContext(
            projectRequest, request.InputNodeID, selected.SourceClass, selected.AssetID);
        if (!string.Equals(data.InputNodeID, selected.Id, StringComparison.Ordinal) ||
            !string.Equals(data.SourceClass, selected.SourceClass, StringComparison.Ordinal) ||
            !SourceFilePaths.Canonical(data.TerrainPath).Equals(SourceFilePaths.Canonical(selected.AssetID),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new SourceFileChangedException();
        return data;
    }

    private static IEnumerable<CatalogTreeNode> Descendants(CatalogTreeNode node)
    {
        yield return node;
        foreach (CatalogTreeNode child in node.Children ?? [])
            foreach (CatalogTreeNode descendant in Descendants(child)) yield return descendant;
    }
}
