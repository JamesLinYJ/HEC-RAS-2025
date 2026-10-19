using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Classifiers;
using Utility.Files;
using Utility.Units;

internal static class ClassificationPasteChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "classification-paste.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var layer = project.AddNewClassification("Paste target");
        var source = layer.AddNewPolygonLayer("Source polygons");
        Polygon first = Triangle(1); first.TrackZ([1, 2, 3]); first.TrackM([4, double.NaN, 6]);
        source.Add(first, "保留分类"); source.Add(Triangle(5), "Second class");
        var target = layer.AddNewPolygonLayer("Selected target"); target.Add(Triangle(10), "Existing target");
        project.Save(); string assetPath = layer.Filename; layer.Dispose();
        byte[] original = File.ReadAllBytes(assetPath), projectBytes = File.ReadAllBytes(projectPath);
        ModelSnapshot current = await ModelEditorAdapter.LoadAsync(new(assetPath, "Surface Layers", projectPath));
        var sourceInput = current.Classification!.Inputs.Single(input => input.Name == "Source polygons");
        var destination = current.Classification.Inputs.Single(input => input.Name == "Selected target");
        var copied = sourceInput.Polygons.Select(polygon => new ClassificationClipboardPolygon(
            polygon.Vertices, polygon.HasZ, polygon.HasM, polygon.Classification)).ToArray();
        ModelSaveRequest Draft() => new(assetPath, "Surface Layers", projectPath, current.Revision, [], [], SourceState: current.SourceState);
        async Task Edit(ClassificationGeometryMutation mutation) => current = await ModelEditorAdapter.TransformClassificationAsync(
            new(Draft(), "geometry", Geometry: mutation));
        await Edit(new("paste", InputId: destination.Id, Features: copied));
        var pasted = current.Classification!.Inputs.Single(input => input.Id == destination.Id).Polygons;
        Check(pasted.Length == 3 && pasted[0].Id == destination.Polygons[0].Id
            && pasted.Skip(1).Select(item => item.Classification).SequenceEqual(copied.Select(item => item.Classification)),
            "Paste appends the copied classes only to the exact selected polygon input");
        Check(current.Classification.Inputs.Single(input => input.Id == sourceInput.Id).Polygons.Select(item => item.Id)
            .SequenceEqual(sourceInput.Polygons.Select(item => item.Id)), "Pasting leaves the source input and its feature identities untouched");
        Check(pasted[1].HasZ && pasted[1].HasM && pasted[1].Vertices[1].M == "NaN"
            && pasted[1].Vertices[2].Z == "3", "Feature clipboard retains source Z/M and NaN ordinates");
        string[] pastedIDs = pasted.Select(item => item.Id).ToArray();
        await Edit(new("undo"));
        Check(current.Classification!.Inputs.Single(input => input.Id == destination.Id).Polygons.Length == 1,
            "One undo removes the entire clipboard import");
        await Edit(new("redo"));
        Check(current.Classification!.Inputs.Single(input => input.Id == destination.Id).Polygons.Select(item => item.Id)
            .SequenceEqual(pastedIDs), "One redo restores the same pasted feature identities");
        string pastedClassField = pasted[1].Scope + "/PolygonClassificationInputProperties/ClassifierMod_Classification";
        current = await ModelEditorAdapter.TransformClassificationAsync(new(Draft() with {
            Fields = new() { [pastedClassField] = "Edited pasted class" }
        }, "refresh"));
        await Edit(new("undo")); await Edit(new("redo"));
        Check(current.Classification!.Inputs.Single(input => input.Id == destination.Id).Polygons[1].Classification == "Edited pasted class",
            "Undo/redo of a paste retains classifications edited after the original feature import");
        await Edit(new("delete", InputId: destination.Id, PolygonIds: [pastedIDs[1]]));
        await Edit(new("undo"));
        current = await ModelEditorAdapter.TransformClassificationAsync(new(Draft() with {
            Fields = new() { [pastedClassField] = "Edited after delete undo" }
        }, "refresh"));
        await Edit(new("redo")); await Edit(new("undo"));
        Check(current.Classification!.Inputs.Single(input => input.Id == destination.Id).Polygons[1].Classification == "Edited after delete undo",
            "Repeated delete redo/undo retains the source feature's latest class draft");
        await Reject(() => Edit(new("paste", InputId: "missing-input", Features: copied)));
        await Reject(() => Edit(new("paste", InputId: destination.Id, Features: [])));
        await Reject(() => Edit(new("paste", InputId: destination.Id, Features: [copied[0],
            new([new(0, 0), new(1, 1), new(2, 2)], false, false, "Invalid polygon")])));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original) && File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "Clipboard drafts and failed batch imports do not write source HDF or project XML");
        current = await ModelEditorAdapter.SaveAsync(Draft());
        using var reopened = new ClassificationLayer(assetPath);
        var savedSource = reopened.Layers.OfType<PolygonClassificationInput>().Single(input => input.Name == "Source polygons");
        var savedTarget = reopened.Layers.OfType<PolygonClassificationInput>().Single(input => input.Name == "Selected target");
        Check(savedSource.Count == 2 && savedTarget.Count == 3
            && savedTarget.Features[1].Classification == "Edited after delete undo" && savedTarget.Features[1].Polygon.HasZ
            && double.IsNaN(savedTarget.Features[1].Polygon.M[1]),
            "Independent source HDF reload retains exact target, classifications and copied coordinates");
        Console.WriteLine("Source classification feature clipboard target identity, atomic validation, batch undo/redo and HDF persistence passed.");
    }

    private static Polygon Triangle(double x) => new(new Point[] { new(x, 0), new(x + 2, 0), new(x, 2) });
    private static async Task Reject(Func<Task> action)
    {
        try { await action(); } catch (ArgumentException) { return; }
        throw new InvalidOperationException("An invalid classification paste was accepted.");
    }
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
