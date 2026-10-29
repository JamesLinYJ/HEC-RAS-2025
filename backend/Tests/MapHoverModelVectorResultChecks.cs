using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Ras.Backend;

/// <summary>
/// Exercises the public hover route against source HDFs from the retained CPU
/// solver acceptance fixture. No Result or source geometry is synthesized.
/// </summary>
internal static partial class MapHoverModelVectorChecks
{
    private static readonly JsonSerializerOptions ResultFixtureJSON = new(JsonSerializerDefaults.Web);

    private static async Task RunResultOwnedPositiveAsync()
    {
        string sourceDirectory = Environment.GetEnvironmentVariable(
            "HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY")
            ?? throw new DirectoryNotFoundException(
                "The real CPU-solver culvert acceptance fixture is required for Result-owned model-vector hover.");
        if (!Directory.Exists(sourceDirectory))
            throw new DirectoryNotFoundException("The CPU-solver culvert acceptance fixture is unavailable: " + sourceDirectory);

        string sourceDigest = DigestDirectory(sourceDirectory);
        using var temporary = new TemporaryDirectory();
        CopyDirectory(sourceDirectory, temporary.FullName);
        AcceptanceManifest manifest = JsonSerializer.Deserialize<AcceptanceManifest>(
            File.ReadAllText(Path.Combine(temporary.FullName, "acceptance.json")), ResultFixtureJSON)
            ?? throw new InvalidDataException("The CPU-solver acceptance manifest is missing.");
        if (manifest.Results.Length != 2 ||
            !manifest.Results.Select(item => item.Role).SequenceEqual(["signed-flow", "zero-flow"]))
            throw new InvalidDataException("The acceptance fixture must retain its signed-flow and zero-flow Result HDFs.");

        string projectPath = FixturePath(temporary.FullName, manifest.ProjectRelativePath);
        string planPath = FixturePath(temporary.FullName, manifest.PlanRelativePath);
        string sharedPlanPath = FixturePath(temporary.FullName, manifest.SharedPlanRelativePath);
        string alternatePlanPath = FixturePath(temporary.FullName, manifest.AlternatePlanRelativePath);
        string geometryPath = FixturePath(temporary.FullName, manifest.GeometryRelativePath);
        string alternateGeometryPath = FixturePath(temporary.FullName, manifest.AlternateGeometryRelativePath);
        string boundaryPath = FixturePath(temporary.FullName, manifest.BoundaryConditionRelativePath);
        string terrainPath = FixturePath(temporary.FullName, manifest.TerrainRasterRelativePath);
        ResultFixture signed = manifest.Results.Single(item => item.Role == "signed-flow");
        ResultFixture zero = manifest.Results.Single(item => item.Role == "zero-flow");
        string signedPath = FixturePath(temporary.FullName, signed.Path);
        string zeroPath = FixturePath(temporary.FullName, zero.Path);
        string signedRevision = HashFile(signedPath);
        string zeroRevision = HashFile(zeroPath);
        Check(signedRevision.Equals(signed.Revision, StringComparison.OrdinalIgnoreCase) &&
              zeroRevision.Equals(zero.Revision, StringComparison.OrdinalIgnoreCase),
            "The private Result fixture copies retain the manifest's exact source HDF revisions.");

        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project",
            Name: "Result Hover Source " + Guid.NewGuid().ToString("N")));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        AddResultRows(visualizationPath, created.MapName, manifest, signedPath);
        string visualizationRevision = HashFile(visualizationPath);
        var map = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            Guid.NewGuid().ToString("D"), created.MapIndex, created.MapName, created.MapType,
            visualizationRevision,
            [new MapTreeResultSelectionOverride(planPath, manifest.PlanName, zeroPath, zeroRevision)]);

        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNode multiResultRow = FindResultNode(tree.Roots, "MultiResult", manifest.PlanName);
        CatalogTreeNode multiGeometry = FindChild(multiResultRow, "Geometry", manifest.GeometryName);
        CatalogTreeNode multiBoundary = FindChild(multiResultRow, "BoundaryCondition", manifest.BoundaryConditionName);
        CatalogTreeNodeLocator multiResultLocator = RequiredLocator(multiResultRow);
        CatalogTreeNodeLocator geometryLocator = RequiredLocator(multiGeometry);
        CatalogTreeNodeLocator boundaryLocator = RequiredLocator(multiBoundary);

        MapResultSelectionOverride[] outerOverrides =
        [
            new(multiResultLocator, 0, "Explicit", zeroPath, zeroRevision)
        ];
        MapResultSourcesResult outerSources = MapResultChartService.Sources(new(map, outerOverrides));
        MapResultActiveNode outerMultiResult = outerSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && MapResultRenderService.SameLocator(node.Node, multiResultLocator));
        MapResultSourceChoice outerSlotZero = outerMultiResult.Selections.Single(slot =>
            slot.SelectionIndex == 0).SelectedResult
            ?? throw new InvalidDataException("The outer Result chart context has no selected keyframe in slot zero.");
        Check(SamePath(outerSlotZero.ResultPath, zeroPath) &&
              outerSlotZero.Revision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase),
            $"The visible MultiResult row resolves its real zero-flow HDF in exact slot zero. " +
            $"Expected path={zeroPath}; revision={zeroRevision}; actual path={outerSlotZero.ResultPath}; revision={outerSlotZero.Revision}.");

        // Match the source map workflow: obtain a valid exact owner token and
        // ask the Result-geometry adapter for the child locator it actually
        // resolved. Do not infer ParentResultAssetID from a displayed path.
        MapResultSelectionOverride[] ownerOverrides =
        [
            new(multiResultLocator, 0, "Explicit", zeroPath, zeroRevision),
            new(multiResultLocator, 1, "Previous")
        ];
        MapResultSourcesResult ownerSources = MapResultChartService.Sources(new(map, ownerOverrides));
        MapResultActiveNode ownerMultiResult = ownerSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && MapResultRenderService.SameLocator(node.Node, multiResultLocator));
        MapResultSourceChoice ownerSlotZero = ownerMultiResult.Selections.Single(slot =>
            slot.SelectionIndex == 0).SelectedResult
            ?? throw new InvalidDataException("The captured Result owner has no current slot-zero HDF.");
        Check(ownerSources.ContextToken != outerSources.ContextToken &&
              SamePath(ownerSlotZero.ResultPath, zeroPath) &&
              ownerSlotZero.Revision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase) &&
              ownerMultiResult.Selections.Any(slot => slot.SelectionIndex == 1 && slot.SelectedResult is not null),
            "A valid Result owner token may differ from the outer map token while retaining the same exact slot-zero HDF.");
        var owner = new MapResultGeometryOwner(multiResultLocator, ownerSources.ContextToken,
            ownerOverrides, 0, ownerSlotZero.ResultPath, ownerSlotZero.Revision);
        MapResultGeometrySnapshot initialResultGeometry = await ModelEditorAdapter.LoadMapResultGeometryAsync(
            new MapResultGeometryRequest(map, owner, geometryLocator, PageSize: 512));
        CatalogTreeNodeLocator culvertLocator = initialResultGeometry.Geometry.CulvertsState.Locator
            ?? throw new InvalidDataException("The selected Result Geometry response omitted its exact CulvertBarrel locator.");
        Check(initialResultGeometry.SelectionIndex == 0 &&
              SamePath(initialResultGeometry.GeometryPath, zeroPath) &&
              initialResultGeometry.GeometryRevision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase),
            "The initial map capture resolves the CulvertBarrel node from the real slot-zero Result HDF.");

        // Make the exact Result-owned renderer rows visible through the same
        // serialized map-tree action used by the product UI.
        map = MakeVisible(map, culvertLocator);
        map = MakeVisible(map, boundaryLocator);
        tree = MapTreeService.Load(map);
        multiResultRow = FindResultNode(tree.Roots, "MultiResult", manifest.PlanName);
        multiResultLocator = RequiredLocator(multiResultRow);
        multiGeometry = FindChild(multiResultRow, "Geometry", manifest.GeometryName);
        multiBoundary = FindChild(multiResultRow, "BoundaryCondition", manifest.BoundaryConditionName);
        geometryLocator = RequiredLocator(multiGeometry);
        boundaryLocator = RequiredLocator(multiBoundary);
        outerOverrides =
        [
            new(multiResultLocator, 0, "Explicit", zeroPath, zeroRevision)
        ];
        outerSources = MapResultChartService.Sources(new(map, outerOverrides));
        outerMultiResult = outerSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && MapResultRenderService.SameLocator(node.Node, multiResultLocator));
        outerSlotZero = outerMultiResult.Selections.Single(slot =>
            slot.SelectionIndex == 0).SelectedResult
            ?? throw new InvalidDataException("The committed outer Result context has no selected slot-zero HDF.");
        Check(SamePath(outerSlotZero.ResultPath, zeroPath) &&
              outerSlotZero.Revision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase),
            $"The committed map tree retains the same exact slot-zero Result after materializing visible rows. " +
            $"Expected path={zeroPath}; revision={zeroRevision}; actual path={outerSlotZero.ResultPath}; revision={outerSlotZero.Revision}.");

        // Refresh the source-owner token after the visibility commit. The
        // nested child locator below comes from this exact committed capture.
        ownerOverrides =
        [
            new(multiResultLocator, 0, "Explicit", zeroPath, zeroRevision),
            new(multiResultLocator, 1, "Previous")
        ];
        ownerSources = MapResultChartService.Sources(new(map, ownerOverrides));
        ownerMultiResult = ownerSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && MapResultRenderService.SameLocator(node.Node, multiResultLocator));
        ownerSlotZero = ownerMultiResult.Selections.Single(slot =>
            slot.SelectionIndex == 0).SelectedResult
            ?? throw new InvalidDataException("The captured Result owner has no current slot-zero HDF.");
        Check(ownerSources.ContextToken != outerSources.ContextToken &&
              SamePath(ownerSlotZero.ResultPath, zeroPath) &&
              ownerSlotZero.Revision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase) &&
              ownerMultiResult.Selections.Any(slot => slot.SelectionIndex == 1 && slot.SelectedResult is not null),
            "A valid Result owner token may differ from the outer map token while retaining the same exact slot-zero HDF.");
        owner = new MapResultGeometryOwner(multiResultLocator, ownerSources.ContextToken,
            ownerOverrides, 0, ownerSlotZero.ResultPath, ownerSlotZero.Revision);

        MapResultGeometrySnapshot resultGeometry = await ModelEditorAdapter.LoadMapResultGeometryAsync(
            new MapResultGeometryRequest(map, owner, geometryLocator, PageSize: 512));
        GeometryCulvertFeatureRow[] barrels = resultGeometry.Geometry.Culverts?.Features ?? [];
        culvertLocator = resultGeometry.Geometry.CulvertsState.Locator
            ?? throw new InvalidDataException("The committed Result Geometry response omitted its exact CulvertBarrel locator.");
        Check(barrels.Length > 0 && manifest.BarrelNames.Length > 0 &&
              resultGeometry.SelectionIndex == 0 &&
              MapResultRenderService.SameLocator(resultGeometry.ResultNode, multiResultLocator) &&
              SamePath(resultGeometry.SelectedResultPath, zeroPath) &&
              resultGeometry.SelectedResultRevision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase) &&
              SamePath(resultGeometry.GeometryPath, zeroPath) &&
              resultGeometry.Geometry.GeometryName == manifest.GeometryName &&
              barrels.Length == manifest.BarrelNames.Length &&
              barrels.Select(row => row.Values["Name"]).SequenceEqual(manifest.BarrelNames, StringComparer.Ordinal) &&
              resultGeometry.Geometry.CulvertsState.Locator is { } resultCulvertLocator &&
              MapResultRenderService.SameLocator(resultCulvertLocator, culvertLocator) &&
              resultGeometry.Geometry.CulvertsState.EffectiveVisible,
            "The Result-owned Geometry is the exact selected HDF geometry and exposes real source-order culvert names and renderer visibility.");

        var culvertCapture = new MapHoverModelVectorCapture(culvertLocator, "culvertBarrel",
            resultGeometry.GeometryPath, resultGeometry.GeometryRevision, "resultSource",
            GeometryNode: resultGeometry.GeometryNode,
            GeometryContextToken: resultGeometry.Geometry.ContextToken,
            ResultOwner: owner);
        string[] readOnlyPaths = [projectPath, planPath, sharedPlanPath, alternatePlanPath,
            geometryPath, alternateGeometryPath, boundaryPath, terrainPath,
            visualizationPath, signedPath, zeroPath];
        Dictionary<string, byte[]> before = readOnlyPaths.Distinct(PathComparer())
            .ToDictionary(path => path, File.ReadAllBytes, PathComparer());

        for (int ordinal = 0; ordinal < barrels.Length; ordinal++)
        {
            GeometryCulvertFeatureRow barrel = barrels[ordinal];
            Check(barrel.FID == ordinal && barrel.Polyline.Length >= 2,
                "Each real Result culvert row retains its source renderer FID and source polyline.");
            MapHoverCoordinate hit = SegmentMidpoint(barrel.Polyline);
            MapHoverIdentifyEntry entry = (await Identify(map, outerSources,
                "result-owned-culvert-" + ordinal.ToString(System.Globalization.CultureInfo.InvariantCulture),
                hit, new(culvertLocator, "modelVector", culvertCapture.SourcePath,
                    culvertCapture.SourceRevision, ModelVector: culvertCapture), outerOverrides)).Entries.Single();
            Check(entry.Kind == "modelVector" && entry.Label == manifest.BarrelNames[ordinal] &&
                  entry.Value == ordinal.ToString(System.Globalization.CultureInfo.InvariantCulture) &&
                  entry.ValueType == "culvertBarrel" && entry.ElementIndex == ordinal &&
                  SamePath(entry.SourcePath!, zeroPath) &&
                  entry.SourceRevision!.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase),
                "The public hover route returns the selected Result's real barrel name and exact source ordinal.");
        }

        MapBoundaryGeometrySnapshot resultBoundary = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(map, boundaryLocator, zeroRevision, ResultOwner: owner));
        Check(resultBoundary.ResultOwner is { SelectionIndex: 0 } boundaryOwner &&
              MapResultRenderService.SameLocator(boundaryOwner.ResultNode, multiResultLocator) &&
              boundaryOwner.ContextToken == owner.ContextToken &&
              SamePath(resultBoundary.BoundaryPath, zeroPath) &&
              resultBoundary.BoundaryRevision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase),
            "The embedded Boundary child is read from the same exact slot-zero Result owner.");
        MapHoverModelVectorLine[] boundaryLines = resultBoundary.Lines
            .Where(line => line.Coordinates is { Length: >= 2 })
            .Select(line => new MapHoverModelVectorLine(line.Id, line.Name, line.SourceOrdinal,
                line.Coordinates!.Select(point => new MapHoverCoordinate(point.X, point.Y)).ToArray()))
            .ToArray();
        Check(boundaryLines.Length > 0 && boundaryLines.Select((line, index) =>
            line.SourceOrdinal == index).All(value => value),
            "The selected Result's embedded Boundary source preserves actual BCL ordering.");
        var boundaryCapture = new MapHoverModelVectorCapture(boundaryLocator,
            "boundaryConditionLine", resultBoundary.BoundaryPath, resultBoundary.BoundaryRevision,
            "resultSource", ResultOwner: owner,
            BoundarySourceState: resultBoundary.BoundarySourceState,
            BoundaryContextToken: resultBoundary.ContextToken, BoundaryLines: boundaryLines);
        MapBoundaryLineData firstBoundaryLine = resultBoundary.Lines.Single(line =>
            line.SourceOrdinal == 0 && line.Coordinates is { Length: >= 2 });
        MapHoverIdentifyEntry boundaryEntry = (await Identify(map, outerSources,
            "result-owned-boundary-line", SegmentMidpoint(firstBoundaryLine.Coordinates!),
            new(boundaryLocator, "modelVector", boundaryCapture.SourcePath,
                boundaryCapture.SourceRevision, ModelVector: boundaryCapture), outerOverrides)).Entries.Single();
        Check(boundaryEntry.Kind == "modelVector" && boundaryEntry.Label == "BCL: 0" &&
              boundaryEntry.Value == "0" && boundaryEntry.ValueType == "boundaryConditionLine" &&
              boundaryEntry.ElementIndex == 0 && SamePath(boundaryEntry.SourcePath!, zeroPath),
            "The public hover route invokes the embedded Boundary source renderer's exact BCL ordinal callback.");

        await ExpectAsync<SourceFileChangedException>(() => Identify(map, outerSources,
            "result-owned-wrong-slot", SegmentMidpoint(barrels[0].Polyline),
            new(culvertLocator, "modelVector", culvertCapture.SourcePath,
                culvertCapture.SourceRevision,
                ModelVector: culvertCapture with { ResultOwner = owner with { SelectionIndex = 1 } }), outerOverrides));
        await ExpectAsync<SourceFileChangedException>(() => Identify(map, outerSources,
            "result-owned-stale-source", SegmentMidpoint(barrels[0].Polyline),
            new(culvertLocator, "modelVector", culvertCapture.SourcePath,
                new string('0', 64),
                ModelVector: culvertCapture with { SourceRevision = new string('0', 64) }), outerOverrides));
        await ExpectAsync<SourceFileChangedException>(() => Identify(map, outerSources,
            "result-owned-stale-owner", SegmentMidpoint(barrels[0].Polyline),
            new(culvertLocator, "modelVector", culvertCapture.SourcePath,
                culvertCapture.SourceRevision,
                ModelVector: culvertCapture with
                { ResultOwner = owner with { ContextToken = new string('0', 64) } }), outerOverrides));

        MapTreeRequest leasedMap = map with
        {
            ComputeReadLease = new MapResultComputeReadLease(Guid.NewGuid().ToString("D"),
                Guid.NewGuid().ToString("D"), projectPath, [zeroPath], zeroPath)
        };
        await ExpectAsync<NotSupportedException>(() => Identify(leasedMap, outerSources,
            "result-owned-protected-lease", SegmentMidpoint(barrels[0].Polyline),
            new(culvertLocator, "modelVector", culvertCapture.SourcePath,
                culvertCapture.SourceRevision, ModelVector: culvertCapture), outerOverrides));

        Check(before.All(item => File.Exists(item.Key) && File.ReadAllBytes(item.Key).SequenceEqual(item.Value)),
            "Successful and rejected Result-owned hover requests leave project, visualization, source Geometry, Boundary and both Result HDFs byte-identical.");
        Check(DigestDirectory(sourceDirectory) == sourceDigest,
            "The original CPU-solver acceptance fixture remains unchanged after Result-owned model hover.");
        Console.WriteLine("Real Result-owned culvert and embedded Boundary hover passed against immutable CPU-solver HDFs, including distinct owner context, slot/revision/lease rejection and exact source ordinals.");
    }

    private static MapTreeRequest MakeVisible(MapTreeRequest map, CatalogTreeNodeLocator node)
    {
        MapTreeMutationResult mutation = MapTreeService.Perform(new(map, "visibility",
            Node: node, Checked: true));
        return map with { ExpectedVisualizationRevision = mutation.VisualizationRevision };
    }

    private static MapHoverCoordinate SegmentMidpoint(GeometryCulvertCoordinate[] coordinates)
    {
        for (int index = 0; index + 1 < coordinates.Length; index++)
        {
            GeometryCulvertCoordinate first = coordinates[index];
            GeometryCulvertCoordinate second = coordinates[index + 1];
            if (first.X != second.X || first.Y != second.Y)
                return new((first.X + second.X) / 2, (first.Y + second.Y) / 2);
        }
        throw new InvalidDataException("The source model-vector has no nonzero line segment to hit-test.");
    }

    private static MapHoverCoordinate SegmentMidpoint(BoundaryLineCoordinateData[] coordinates)
    {
        for (int index = 0; index + 1 < coordinates.Length; index++)
        {
            BoundaryLineCoordinateData first = coordinates[index];
            BoundaryLineCoordinateData second = coordinates[index + 1];
            if (first.X != second.X || first.Y != second.Y)
                return new((first.X + second.X) / 2, (first.Y + second.Y) / 2);
        }
        throw new InvalidDataException("The embedded Boundary line has no nonzero segment to hit-test.");
    }

    private static CatalogTreeNode FindResultNode(IEnumerable<CatalogTreeNode> roots,
        string nodeType, string nodeName)
    {
        CatalogTreeNode resultsRoot = roots.Single(node => node.Name == "Results" &&
            node.Locator?.NodeType == "Root");
        CatalogTreeNode[] matches = (resultsRoot.Children ?? []).Where(node =>
            node.Locator?.NodeType == nodeType && node.Name == nodeName).ToArray();
        if (matches.Length != 1)
            throw new InvalidDataException($"Expected one Result tree row '{nodeName}', found {matches.Length}.");
        return matches[0];
    }

    private static CatalogTreeNode FindChild(CatalogTreeNode parent, string nodeType, string nodeName)
    {
        CatalogTreeNode[] matches = (parent.Children ?? []).Where(node =>
            node.Locator?.NodeType == nodeType && node.Name == nodeName).ToArray();
        if (matches.Length != 1)
            throw new InvalidDataException($"Expected one embedded {nodeType} child '{nodeName}', found {matches.Length}.");
        return matches[0];
    }

    private static CatalogTreeNodeLocator RequiredLocator(CatalogTreeNode node) => node.Locator
        ?? throw new InvalidDataException("An exact Result-owned map node omitted its locator.");

    private static void AddResultRows(string visualizationPath, string mapName,
        AcceptanceManifest manifest, string signedPath)
    {
        XDocument document = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement map = document.Root?.Element("Maps")?.Elements("Map").Single(node =>
            (string?)node.Attribute("Name") == mapName)
            ?? throw new InvalidDataException("The newly created Project map is absent from the visualization file.");
        XElement tree = map.Element("Tree") ?? new XElement("Tree");
        if (tree.Parent is null) map.Add(tree);
        XElement nodes = tree.Element("Nodes") ?? new XElement("Nodes");
        if (nodes.Parent is null) tree.Add(nodes);
        XElement root = nodes.Elements("Node").SingleOrDefault(node =>
            (string?)node.Attribute("Type") == "Root" &&
            (string?)node.Attribute("Name") == "Results") ??
            new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Results"));
        if (root.Parent is null) nodes.Add(root);
        root.Add(new XElement("Node", new XAttribute("Type", "MultiResult"),
            new XAttribute("Name", manifest.PlanName), new XAttribute("IsChecked", true),
            new XAttribute("SelectedMapType", "Depth"), new XAttribute("ProfileIndex", 0),
            Children(manifest)));
        root.Add(new XElement("Node", new XAttribute("Type", "Result"),
            new XAttribute("Name", Path.GetFileNameWithoutExtension(signedPath)),
            new XAttribute("IsChecked", true), new XAttribute("SelectedMapType", "Depth"),
            new XAttribute("ProfileIndex", 0), Children(manifest)));
        document.Save(visualizationPath, SaveOptions.DisableFormatting);

        static object[] Children(AcceptanceManifest source) =>
        [
            new XElement("Node", new XAttribute("Type", "Plan"), new XAttribute("Name", source.PlanName)),
            new XElement("Node", new XAttribute("Type", "Geometry"), new XAttribute("Name", source.GeometryName),
                new XAttribute("IsChecked", true)),
            new XElement("Node", new XAttribute("Type", "BoundaryCondition"),
                new XAttribute("Name", source.BoundaryConditionName), new XAttribute("IsChecked", true))
        ];
    }

    private static string FixturePath(string root, string relative)
    {
        string path = Path.GetFullPath(Path.Combine(root,
            relative.Replace('/', Path.DirectorySeparatorChar)));
        string prefix = Path.GetFullPath(root) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(prefix, OperatingSystem.IsWindows()
                ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidDataException("An acceptance fixture path escaped its private test copy.");
        if (!File.Exists(path)) throw new FileNotFoundException("A CPU-solver fixture source file is missing.", path);
        return path;
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, folder)));
        foreach (string file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(source, file)), overwrite: false);
    }

    private static string DigestDirectory(string directory)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (string path in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories)
                     .OrderBy(path => Path.GetRelativePath(directory, path), StringComparer.Ordinal))
        {
            string relative = Path.GetRelativePath(directory, path).Replace(Path.DirectorySeparatorChar, '/');
            hash.AppendData(Encoding.UTF8.GetBytes(relative + "\0"));
            using FileStream stream = File.OpenRead(path);
            hash.AppendData(SHA256.HashData(stream));
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    private static StringComparer PathComparer() => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private sealed record ResultFixture(string Role, string Path, string Revision);

    private sealed record AcceptanceManifest(string ProjectRelativePath, string PlanRelativePath,
        string SharedPlanRelativePath, string AlternatePlanRelativePath,
        string GeometryRelativePath, string AlternateGeometryRelativePath,
        string BoundaryConditionRelativePath, string TerrainRasterRelativePath,
        string PlanName, string SharedPlanName, string AlternatePlanName,
        string GeometryName, string AlternateGeometryName, string BoundaryConditionName,
        string[] BarrelNames, ResultFixture[] Results);
}
