using System.Xml.Linq;
using H5Assist;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class SurfaceCreationChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "surface-create.ras");
        Project.CreateNew(projectPath, UnitSystem.SI).Save();
        byte[] savedProjectBytes = File.ReadAllBytes(projectPath);

        XElement draft = XElement.Load(projectPath);
        var unsavedProjection = new XElement("Projection");
        ProjectionDefinition.Local(UnitSystem.USCustomary).Serialize(unsavedProjection);
        draft.Element("Projection")!.ReplaceWith(unsavedProjection);
        draft.Add(new XElement("UncommittedDraftMarker", "must remain unsaved"));
        string draftXml = draft.ToString(SaveOptions.DisableFormatting);

        SurfaceCreationRequest Request(string kind, string name, string? revision = null) =>
            new(kind, projectPath, draftXml, name, revision);

        var expected = new[]
        {
            (Kind: "newTerrain", Suggested: "Terrain", Name: "Terrain", Section: "Terrains"),
            (Kind: "newClassification", Suggested: "Classifications", Name: "Classifications", Section: "Surface Layers"),
            (Kind: "newNValue", Suggested: "N Values", Name: "N Values", Section: "Surface Layers")
        };

        foreach (var item in expected)
        {
            var initial = SurfaceCreationService.Inspect(Request(item.Kind, ""));
            Check(!initial.CanExecute && initial.SuggestedName == item.Suggested,
                item.Kind + " retains the source default name");
            Check(Path.GetFullPath(initial.TargetDirectory) == Path.GetFullPath(Path.Combine(
                temporary.FullName, item.Section == "Terrains" ? "Terrains" : "Surface Layers")),
                item.Kind + " reports the actual source output directory");

            var request = Request(item.Kind, item.Name);
            var inspection = SurfaceCreationService.Inspect(request);
            Check(inspection.CanExecute && inspection.ValidationMessage == null, item.Kind + " validates a legal name");
            var created = SurfaceCreationService.Create(request with { Revision = inspection.Revision });
            Check(created.Name == item.Name && created.Section == item.Section
                && created.Group == null && created.Element == null && created.PrimaryKey == null
                && created.Associations.Count == 0,
                item.Kind + " returns the shared CreatedModel shape without invented associations");
            Check(Path.GetFullPath(created.AssetPath) == Path.Combine(Path.GetFullPath(initial.TargetDirectory), item.Name + ".h5"),
                item.Kind + " publishes under its source directory without the staging path");

            using (var reader = new H5Reader(created.AssetPath))
                Check(reader.TryReadStringAttributeScalar("/", "Project Units") == "USC",
                    item.Kind + " stores the current unsaved project XML metadata in the HDF header");

            switch (item.Kind)
            {
                case "newTerrain":
                    using (var layer = new Terrain(created.AssetPath))
                        Check(layer.Name == item.Name, "Terrain source HDF reopens with its requested name");
                    break;
                case "newClassification":
                    using (var layer = new ClassificationLayer(created.AssetPath))
                        Check(layer.Name == item.Name, "Classification source HDF reopens with its requested name");
                    break;
                case "newNValue":
                    using (var layer = new NValueLayer(created.AssetPath))
                        Check(layer.Name == item.Name && Math.Abs(layer.ConstantValue - NValueLayer.DefaultConstantValue) < 1e-6,
                            "N-Value source HDF reopens with its native 0.06 default");
                    break;
            }

            byte[] bytes = File.ReadAllBytes(created.AssetPath);
            var collision = SurfaceCreationService.Inspect(request);
            Check(!collision.CanExecute && collision.ValidationMessage != null,
                item.Kind + " rejects a duplicate name before writing");
            Check(collision.SuggestedName == item.Suggested + " (1)",
                item.Kind + " applies the source numeric suffix to its next suggested name");
            Check(File.ReadAllBytes(created.AssetPath).SequenceEqual(bytes), item.Kind + " does not overwrite a colliding HDF file");
        }

        var invalid = Request("newTerrain", "../escape");
        var invalidInspection = SurfaceCreationService.Inspect(invalid);
        Check(!invalidInspection.CanExecute && invalidInspection.ValidationMessage != null,
            "Path traversal names fail source and portable filename validation");
        Expect<ArgumentException>(() => SurfaceCreationService.Create(invalid with { Revision = invalidInspection.Revision }));
        Check(!File.Exists(Path.Combine(temporary.FullName, "escape.h5")), "Invalid names publish no file");

        string staleName = "Stale Terrain";
        var staleRequest = Request("newTerrain", staleName);
        string staleRevision = SurfaceCreationService.Inspect(staleRequest).Revision;
        File.AppendAllText(projectPath, Environment.NewLine);
        Expect<SourceFileChangedException>(() => SurfaceCreationService.Create(staleRequest with { Revision = staleRevision }));
        Check(!File.Exists(Path.Combine(temporary.FullName, "Terrains", staleName + ".h5")),
            "A changed project path/SHA is rejected before publishing a model");
        File.WriteAllBytes(projectPath, savedProjectBytes);

        Check(File.ReadAllBytes(projectPath).SequenceEqual(savedProjectBytes),
            "Successful creation uses the unsaved XML draft without saving or rewriting the project");
        Check(!Directory.EnumerateDirectories(temporary.FullName, ".surface-create-*", SearchOption.AllDirectories).Any(),
            "Successful and rejected requests leave no surface-creation staging directories");
        Console.WriteLine("Surface creation checks passed: native terrain/classification/N-value HDF, source defaults, validation, draft metadata, no-overwrite, stale SHA and project preservation.");
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }
}
