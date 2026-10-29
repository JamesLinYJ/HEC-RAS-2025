using System.Security.Cryptography;
using System.Text;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class CoreLayerImportChecks
{
    internal static async Task Run()
    {
        VerifyContextIdentityWireParity();

        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Core layer session.ras");
        Project created = Project.CreateNew(projectPath, UnitSystem.SI);
        created.Save();
        DisposeProject(created);

        string geometryPath = Path.Combine(temporary.FullName, "Referenced Geometry.h5");
        Geometry geometry = Geometry.CreateNew(geometryPath);
        geometry.Dispose();
        string boundaryPath = Path.Combine(temporary.FullName, "Referenced Boundary.h5");
        BoundaryCondition boundary = BoundaryCondition.CreateNew(boundaryPath);
        boundary.StartTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        boundary.EndTime = new DateTime(2026, 1, 2, 0, 0, 0, DateTimeKind.Utc);
        boundary.Save();
        boundary.Dispose();

        string projectXml = File.ReadAllText(projectPath);
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        string projectXmlRevision = Hash(Encoding.UTF8.GetBytes(projectXml));
        string sessionID = Guid.NewGuid().ToString("D").ToUpperInvariant();
        CoreLayerRequestContext emptyContext = Context(sessionID, projectPath, projectRevision, []);
        byte[] projectBefore = File.ReadAllBytes(projectPath);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");

        CoreLayerImportInspection geometryInspection = CoreLayerImportService.Inspect(Request(
            projectPath, sessionID, projectRevision, projectXml, projectXmlRevision,
            geometryPath, Hash(File.ReadAllBytes(geometryPath)), emptyContext));
        Check(geometryInspection.Kind == "geometry" && geometryInspection.ReferenceIsSessionOnly &&
              geometryInspection.AvailableActions.Contains("addReference"),
            "The retained import inspection identifies Geometry and offers the session-only reference action.");
        CoreLayerImportInspection boundaryInspection = CoreLayerImportService.Inspect(Request(
            projectPath, sessionID, projectRevision, projectXml, projectXmlRevision,
            boundaryPath, Hash(File.ReadAllBytes(boundaryPath)), emptyContext));
        Check(boundaryInspection.Kind == "boundaryCondition" && boundaryInspection.ReferenceIsSessionOnly,
            "The retained import inspection identifies Boundary Condition as a session-only reference.");

        CoreLayerImportReceipt geometryReceipt = CoreLayerImportService.Perform(Request(
            projectPath, sessionID, projectRevision, projectXml, projectXmlRevision,
            geometryPath, geometryInspection.SourceRevision, emptyContext) with { Action = "addReference" });
        CoreLayerImportReceipt boundaryReceipt = CoreLayerImportService.Perform(Request(
            projectPath, sessionID, projectRevision, projectXml, projectXmlRevision,
            boundaryPath, boundaryInspection.SourceRevision, emptyContext) with { Action = "addReference" });
        CoreLayerReferenceCapture geometryReference = geometryReceipt.Reference
            ?? throw new InvalidDataException("The backend did not return the inspected Geometry reference.");
        CoreLayerReferenceCapture boundaryReference = boundaryReceipt.Reference
            ?? throw new InvalidDataException("The backend did not return the inspected Boundary Condition reference.");
        Check(geometryReceipt.ReferenceIsSessionOnly && boundaryReceipt.ReferenceIsSessionOnly &&
              geometryReceipt.ImportedAssetPath is null && boundaryReceipt.ImportedAssetPath is null &&
              !File.Exists(visualizationPath) && File.ReadAllBytes(projectPath).SequenceEqual(projectBefore),
            "Add Reference returns exact captures without copying files or persisting project/map metadata.");

        CoreLayerRequestContext context = Context(sessionID, projectPath, projectRevision,
            [geometryReference, boundaryReference]);
        string[] geometryFocusAliases =
        [
            Path.GetFullPath(geometryReference.SourcePath),
            SourceFilePaths.Canonical(geometryReference.SourcePath)
        ];
        string[] boundaryFocusAliases =
        [
            Path.GetFullPath(boundaryReference.SourcePath),
            SourceFilePaths.Canonical(boundaryReference.SourcePath)
        ];
        foreach (string geometryFocus in geometryFocusAliases)
        foreach (string boundaryFocus in boundaryFocusAliases)
        {
            CatalogTreeNode[] focusedDefaults = CatalogTreeService.LoadMapTreeDefaults(new CatalogTreeRequest(
                projectPath, projectXml, FocusedGeometryIds: [geometryFocus],
                FocusedBoundaryConditionIds: [boundaryFocus], ProjectSessionID: sessionID,
                ExternalCoreLayerReferences: context.References, CoreLayerContext: context), "Buildable");
            Check(FindCatalogLayer(focusedDefaults, "ObservableGeometry", geometryReference.CanonicalSourcePath) is not null &&
                  FindCatalogLayer(focusedDefaults, "ObservableBoundaryCondition", boundaryReference.CanonicalSourcePath) is not null,
                "Focused Geometry and Boundary Condition filters resolve display and canonical aliases to the same source rows.");
        }

        MapDocumentMutationReceipt createdMap = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlRevision, null, "Buildable", Name: "External layers",
            CoreLayerContext: context));
        MapTreeRequest map = new(projectPath, projectXml, projectXmlRevision, "core-layer-session-map",
            createdMap.MapIndex, createdMap.MapName, createdMap.MapType, createdMap.VisualizationRevision,
            ProjectSessionID: sessionID, ExternalCoreLayerReferences: context.References,
            CoreLayerContext: context);
        MapTreeMutationResult geometryAdded = MapTreeService.Perform(new MapTreeActionRequest(map,
            "addGeometry", SourcePath: geometryReference.SourcePath,
            SourceRevision: geometryReference.SourceRevision));
        map = map with { ExpectedVisualizationRevision = geometryAdded.VisualizationRevision };
        MapTreeMutationResult boundaryAdded = MapTreeService.Perform(new MapTreeActionRequest(map,
            "addBoundaryCondition", SourcePath: boundaryReference.SourcePath,
            SourceRevision: boundaryReference.SourceRevision));
        map = map with { ExpectedVisualizationRevision = boundaryAdded.VisualizationRevision };
        MapTreeSnapshot mapReadback = MapTreeService.Load(map);
        Check(FindLayer(mapReadback.Roots, "Geometry", geometryReference.CanonicalSourcePath) is not null &&
              FindLayer(mapReadback.Roots, "BoundaryCondition", boundaryReference.CanonicalSourcePath) is not null,
            "Map add actions reopen the captured project and read back both external source rows by exact path.");
        await Expect<SourceFileChangedException>(() => Task.Run(() => MapTreeService.Load(map with
        {
            CoreLayerContext = null
        })));

        CatalogTreeSnapshot catalog = CatalogTreeService.LoadCatalog(new CatalogTreeRequest(projectPath,
            projectXml, ProjectSessionID: sessionID, ExternalCoreLayerReferences: context.References,
            CoreLayerContext: context));
        Check(FindCatalogLayer(catalog.Roots, "ObservableGeometry", geometryReference.CanonicalSourcePath) is not null &&
              FindCatalogLayer(catalog.Roots, "ObservableBoundaryCondition", boundaryReference.CanonicalSourcePath) is not null,
            "Catalog reads with the same explicit capture expose both external layer rows.");
        await Expect<SourceFileChangedException>(() => Task.Run(() => CatalogTreeService.LoadCatalog(
            new CatalogTreeRequest(projectPath, projectXml, ProjectSessionID: sessionID,
                ExternalCoreLayerReferences: context.References))));

        ModelSnapshot geometryModel = await ModelEditorAdapter.LoadAsync(new ModelRequest(
            geometryReference.SourcePath, "Geometry", projectPath, projectXml,
            CoreLayerContext: context));
        ModelSnapshot boundaryModel = await ModelEditorAdapter.LoadAsync(new ModelRequest(
            boundaryReference.SourcePath, "Boundary Conditions", projectPath, projectXml,
            CoreLayerContext: context));
        Check(geometryModel.Revision.Equals(geometryReference.SourceRevision, StringComparison.OrdinalIgnoreCase) &&
              boundaryModel.Revision.Equals(boundaryReference.SourceRevision, StringComparison.OrdinalIgnoreCase),
            "Geometry and Boundary Condition editors open their session-only references using the captured project context.");
        ModelSnapshot standaloneGeometry = await ModelEditorAdapter.LoadAsync(new ModelRequest(
            geometryReference.SourcePath, "Geometry", projectPath, projectXml));
        Check(standaloneGeometry.Revision.Equals(geometryReference.SourceRevision, StringComparison.OrdinalIgnoreCase) &&
              File.ReadAllBytes(projectPath).SequenceEqual(projectBefore),
            "An explicit standalone model path retains its existing read contract without registering ambient project references.");
        await Expect<ArgumentException>(async () =>
        {
            _ = await ModelEditorAdapter.LoadAsync(new ModelRequest(
                geometryReference.SourcePath, "Geometry", projectPath, projectXml,
                CoreLayerContext: emptyContext));
        });

        string editedDescription = "saved through the external core-layer context";
        CoreLayerRequestContext contextBeforeGeometrySave = context;
        CoreLayerReferenceCapture geometryBeforeSave = geometryReference;
        ModelSnapshot savedGeometry = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(
            AssetPath: geometryReference.SourcePath, Kind: "Geometry", ProjectPath: projectPath,
            Revision: geometryModel.Revision,
            Fields: new Dictionary<string, string>
            {
                ["GeometryCatalogSummary/Context_Description"] = editedDescription
            },
            Images: [], ProjectXml: projectXml, CoreLayerContext: context));
        string savedGeometryRevision = Hash(File.ReadAllBytes(geometryReference.SourcePath));
        Check(savedGeometry.Revision.Equals(savedGeometryRevision, StringComparison.OrdinalIgnoreCase),
            "A Geometry property edit saves and returns the committed HDF revision.");
        CoreLayerRequestContext saveRebasedContext = CoreLayerImportService.RebaseContext(context,
            projectRevision, geometryReference.SourcePath, savedGeometry.Revision)
            ?? throw new InvalidDataException("The Geometry save did not return a rebased core-layer context.");
        CoreLayerReferenceCapture savedGeometryReference = saveRebasedContext.References.Single(reference =>
            reference.Kind == "geometry" && PathEquals(reference.SourcePath, geometryReference.SourcePath));
        Check(savedGeometryReference.SourceRevision.Equals(savedGeometry.Revision, StringComparison.OrdinalIgnoreCase) &&
              savedGeometryReference.Name == savedGeometry.Fields["GeometryCatalogSummary/Context_Name"],
            "The post-save reference capture uses the committed Geometry revision and the name read from the saved snapshot.");

        // Construct a stale Geometry capture whose identity sorts on the
        // opposite side of the Boundary capture from the new revision. This
        // verifies that the recovery receipt sorts its full context after an
        // ID change, rather than retaining the old array position.
        string newGeometryReferenceID = savedGeometryReference.ReferenceID;
        CoreLayerReferenceCapture? staleReloadTarget = null;
        for (int candidate = 0; candidate < 4096 && staleReloadTarget is null; candidate++)
        {
            string candidateRevision = candidate.ToString("X").PadLeft(64, '0');
            string candidateID = CoreLayerImportService.ReferenceID(sessionID, projectPath, "geometry",
                SourceFilePaths.Canonical(geometryBeforeSave.SourcePath), candidateRevision);
            bool candidateBeforeBoundary = string.CompareOrdinal(candidateID, boundaryReference.ReferenceID) < 0;
            bool newBeforeBoundary = string.CompareOrdinal(newGeometryReferenceID, boundaryReference.ReferenceID) < 0;
            if (candidateBeforeBoundary != newBeforeBoundary)
                staleReloadTarget = geometryBeforeSave with
                {
                    ReferenceID = candidateID,
                    SourceRevision = candidateRevision
                };
        }
        CoreLayerReferenceCapture reloadTarget = staleReloadTarget
            ?? throw new InvalidDataException("Could not construct the core-layer reload sort-order fixture.");
        CoreLayerRequestContext reloadContext = Context(sessionID, projectPath, projectRevision,
            [boundaryReference, reloadTarget]);
        string unavailableBoundaryPath = boundaryPath + ".temporarily-unavailable";
        File.Move(boundaryPath, unavailableBoundaryPath);
        CoreLayerReferenceReloadReceipt reloadReceipt;
        try
        {
            reloadReceipt = CoreLayerImportService.ReloadReference(new CoreLayerReferenceReloadRequest(
                projectPath, sessionID, projectRevision, reloadContext, reloadTarget.ReferenceID));
        }
        finally { File.Move(unavailableBoundaryPath, boundaryPath); }
        string[] returnedReferenceIDs = reloadReceipt.NextContext.References
            .Select(reference => reference.ReferenceID).ToArray();
        Check(reloadReceipt.Reference.SourceRevision.Equals(savedGeometry.Revision, StringComparison.OrdinalIgnoreCase) &&
              reloadReceipt.NextContext.IdentityToken == saveRebasedContext.IdentityToken &&
              returnedReferenceIDs.SequenceEqual(returnedReferenceIDs.OrderBy(id => id, StringComparer.Ordinal)) &&
              (string.CompareOrdinal(reloadTarget.ReferenceID, boundaryReference.ReferenceID) < 0) !=
                  (string.CompareOrdinal(reloadReceipt.Reference.ReferenceID, boundaryReference.ReferenceID) < 0) &&
              reloadReceipt.NextContext.References.Single(reference => reference.Kind == "boundaryCondition") == boundaryReference,
            "Reload reads only its exact target, preserves an unavailable unrelated reference, and sorts the changed identity into the returned context.");

        CoreLayerRequestContext badTokenContext = reloadReceipt.NextContext with { IdentityToken = new string('0', 64) };
        await Expect<SourceFileChangedException>(() => Task.Run(() => CoreLayerImportService.ReloadReference(
            new CoreLayerReferenceReloadRequest(projectPath, sessionID, projectRevision,
                badTokenContext, reloadReceipt.Reference.ReferenceID))));

        string geometryBackupPath = geometryPath + ".wrong-kind-backup";
        File.Move(geometryPath, geometryBackupPath);
        try
        {
            File.Copy(boundaryPath, geometryPath);
            await Expect<SourceFileChangedException>(() => Task.Run(() => CoreLayerImportService.ReloadReference(
                new CoreLayerReferenceReloadRequest(projectPath, sessionID, projectRevision,
                    reloadReceipt.NextContext, reloadReceipt.Reference.ReferenceID))));
        }
        finally
        {
            File.Delete(geometryPath);
            File.Move(geometryBackupPath, geometryPath);
        }

        context = saveRebasedContext;
        geometryReference = savedGeometryReference;
        ModelSnapshot reopenedGeometry = await ModelEditorAdapter.LoadAsync(new ModelRequest(
            geometryReference.SourcePath, "Geometry", projectPath, projectXml,
            CoreLayerContext: context));
        Check(reopenedGeometry.Revision.Equals(savedGeometry.Revision, StringComparison.OrdinalIgnoreCase) &&
              reopenedGeometry.Fields["GeometryCatalogSummary/Context_Description"] == editedDescription,
            "A new explicit context reopens the edited external Geometry after its committed source revision changes.");

        string otherProjectPath = Path.Combine(temporary.FullName, "Different project.ras");
        Project otherProject = Project.CreateNew(otherProjectPath, UnitSystem.SI);
        otherProject.Save();
        DisposeProject(otherProject);
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadAsync(new ModelRequest(
            geometryReference.SourcePath, "Geometry", otherProjectPath, File.ReadAllText(otherProjectPath),
            CoreLayerContext: context)));

        CoreLayerImportRequest copyRequest = Request(projectPath, sessionID, projectRevision,
            projectXml, projectXmlRevision, geometryReference.SourcePath,
            geometryReference.SourceRevision, context) with { Action = "copyFile" };
        byte[] sourceBytes = File.ReadAllBytes(geometryReference.SourcePath);
        CoreLayerImportReceipt firstCopy = CoreLayerImportService.Perform(copyRequest);
        CoreLayerImportReceipt secondCopy = CoreLayerImportService.Perform(copyRequest);
        Check(firstCopy.ImportedAssetPath is { } firstPath && secondCopy.ImportedAssetPath is { } secondPath &&
              !PathEquals(firstPath, secondPath) && File.ReadAllBytes(firstPath).SequenceEqual(sourceBytes) &&
              File.ReadAllBytes(secondPath).SequenceEqual(sourceBytes) &&
              firstCopy.ImportedAssetRevision == geometryReference.SourceRevision &&
              secondCopy.ImportedAssetRevision == geometryReference.SourceRevision &&
              File.ReadAllBytes(geometryReference.SourcePath).SequenceEqual(sourceBytes),
            "Copy File publishes byte-identical files at distinct no-clobber destinations and returns their verified revisions.");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBefore),
            "Map reference and copy actions never rewrite the source project file.");

        Project reopened = new(projectPath);
        try
        {
            Check(!reopened.Geometries.Any(item => PathEquals(item.Filename, geometryReference.SourcePath)) &&
                  !reopened.BoundaryConditions.Any(item => PathEquals(item.Filename, boundaryReference.SourcePath)),
                "Session-only external paths are not serialized into a reopened project, while copied project assets remain ordinary owned files.");
        }
        finally { DisposeProject(reopened); }

        Console.WriteLine("Core-layer Add Reference, typed map/catalog/editor round trips, project-session scope, no-clobber Copy File and non-persistence passed.");
    }

    private static void VerifyContextIdentityWireParity()
    {
        if (!OperatingSystem.IsMacOS()) return;

        const string sessionID = "12345678-1234-5678-9ABC-DEF012345678";
        const string projectAlias = "/var/tmp/core-layer-token-parity.ras";
        const string projectPhysical = "/private/var/tmp/core-layer-token-parity.ras";
        const string sourceAlias = "/var/tmp/core-layer-token-parity.h5";
        const string sourcePhysical = "/private/var/tmp/core-layer-token-parity.h5";
        string sourceRevision = new('B', 64);

        string emptyAlias = CoreLayerImportService.ContextIdentityToken(sessionID, projectAlias, null, []);
        string emptyPhysical = CoreLayerImportService.ContextIdentityToken(sessionID, projectPhysical, null, []);
        Check(emptyAlias == "d0957ea6585ef9200b05109e5187925717f4611bb6520e8295c181ac8aa94cdb" &&
              emptyAlias == emptyPhysical,
            "An empty-reference token matches the Swift wire fixture for both /var and /private/var project paths.");
        var emptyContext = new CoreLayerRequestContext(sessionID,
            SourceFilePaths.Canonical(projectAlias), null, [], emptyAlias);
        CoreLayerImportService.ValidateContextShape(emptyContext, projectPhysical);

        string canonicalProject = SourceFilePaths.Canonical(projectAlias);
        string canonicalSourceAlias = SourceFilePaths.Canonical(sourceAlias);
        string canonicalSourcePhysical = SourceFilePaths.Canonical(sourcePhysical);
        string referenceID = CoreLayerImportService.ReferenceID(sessionID, canonicalProject,
            "geometry", canonicalSourceAlias, sourceRevision);
        Check(referenceID == "3d451753535674c344f01d0d8451b379498ccdea4c781ccbc57a67fc41831236" &&
              canonicalSourceAlias == canonicalSourcePhysical,
            "A referenced source identity resolves /var and /private/var aliases to one physical source.");
        var reference = new CoreLayerReferenceCapture(referenceID, sessionID, canonicalProject,
            "geometry", sourceAlias, canonicalSourceAlias, sourceRevision, "Wire Geometry");
        string referencedAlias = CoreLayerImportService.ContextIdentityToken(sessionID,
            projectAlias, null, [reference]);
        string referencedPhysical = CoreLayerImportService.ContextIdentityToken(sessionID,
            projectPhysical, null, [reference]);
        Check(referencedAlias == "0945bcda129f10bbcfaa75933252d8c8f0f13df66c93380dadbe4b3b43382696" &&
              referencedAlias == referencedPhysical,
            "A nonempty-reference token matches the Swift wire fixture for both /var and /private/var paths.");
        var referencedContext = new CoreLayerRequestContext(sessionID, canonicalProject, null,
            [reference], referencedAlias);
        CoreLayerImportService.ValidateContextShape(referencedContext, projectPhysical);
    }

    private static CoreLayerImportRequest Request(string projectPath, string sessionID,
        string projectRevision, string projectXml, string projectXmlRevision,
        string sourcePath, string sourceRevision, CoreLayerRequestContext context) => new(
        projectPath, sessionID, projectRevision, projectXml, projectXmlRevision,
        sourcePath, sourceRevision, CoreLayerContext: context);

    private static CoreLayerRequestContext Context(string sessionID, string projectPath,
        string projectRevision, CoreLayerReferenceCapture[] references)
    {
        string canonicalProject = Path.GetFullPath(projectPath);
        string identity = CoreLayerImportService.ContextIdentityToken(sessionID, canonicalProject,
            projectRevision, references);
        return new(sessionID, canonicalProject, projectRevision, references, identity);
    }

    private static CatalogTreeNode? FindLayer(IEnumerable<CatalogTreeNode> nodes,
        string nodeType, string path) => Descendants(nodes).SingleOrDefault(node =>
        node.Locator?.NodeType == nodeType && node.AssetID is { } asset && PathEquals(asset, path));

    // Catalog rows use their source class and exact AssetID for identity. They
    // do not carry map-tree Locators, which are specific to editable map rows.
    private static CatalogTreeNode? FindCatalogLayer(IEnumerable<CatalogTreeNode> nodes,
        string sourceClass, string path) => Descendants(nodes).SingleOrDefault(node =>
        node.SourceClass == sourceClass && node.AssetID is { } asset && PathEquals(asset, path));

    private static IEnumerable<CatalogTreeNode> Descendants(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            if (node.Children is { } children)
                foreach (CatalogTreeNode child in Descendants(children)) yield return child;
        }
    }

    private static bool PathEquals(string first, string second) =>
        SourceFilePaths.SameSourceFile(first, second);

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void DisposeProject(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Expect<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }
}
