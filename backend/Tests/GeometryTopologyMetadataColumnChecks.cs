using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryTopologyMetadataColumnChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Topology columns.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var geometry = project.AddNewGeometry("Topology columns");
        geometry.ConceptualMeshLayer.Topology = Topology.FromExtent(new Extent(0, 100, 0, 100));
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();

        var model = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        byte[] original = File.ReadAllBytes(assetPath);
        GeometryTopologySnapshot loaded = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model));
        Check(loaded.Arcs.Columns.Any(column => column.ID == "Bias" && !column.IsUserDefined),
            "The Arc source default is not exposed as a user-defined column");
        Check(loaded.Regions.Columns.Any(column => column.ID == "PatchType" && !column.IsUserDefined),
            "The Region source default is not exposed as a user-defined column");
        Check(loaded.Nodes.Columns.All(column => !column.IsUserDefined),
            "Node columns are not exposed as user-manageable columns");

        GeometryTopologySnapshot arcAdded = await Edit(model, loaded,
            new("addMetadataColumn", "arc", [], "Review Note", "String"));
        Check(arcAdded.Arcs.Columns.Single(column => column.ID == "Review Note").IsUserDefined
            && arcAdded.Arcs.Rows.All(row => row.Values["Review Note"] == ""),
            "Adding an Arc string column uses source-managed row defaults");
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, arcAdded.DraftState, new("addMetadataColumn", "arc", [], "review note", "String"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, arcAdded.DraftState, new("addMetadataColumn", "arc", [], "Unsupported Type", "DateTime"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, arcAdded.DraftState, new("addMetadataColumn", "node", [], "Node Note", "String"))));

        GeometryTopologySnapshot arcRenamed = await Edit(model, arcAdded,
            new("renameMetadataColumn", "arc", [], "Review Note", "Reviewer"));
        Check(arcRenamed.Arcs.Columns.Any(column => column.ID == "Reviewer" && column.IsUserDefined)
            && arcRenamed.Arcs.Rows.All(row => row.Values["Reviewer"] == ""),
            "Renaming an Arc column preserves its row values and user-defined status");
        GeometryTopologySnapshot renameNoOp = await Edit(model, arcRenamed,
            new("renameMetadataColumn", "arc", [], "Reviewer", "Reviewer"));
        Check(renameNoOp.DraftState == arcRenamed.DraftState,
            "Renaming a column to its existing name does not create a history entry");
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, arcRenamed.DraftState, new("renameMetadataColumn", "arc", [], "Bias", "Bias Copy"))));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, arcRenamed.DraftState, new("renameMetadataColumn", "arc", [], "Reviewer", "Bias"))));

        GeometryTopologySnapshot renameUndone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, arcRenamed.DraftState, new("undo", "history", [])));
        Check(renameUndone.Arcs.Columns.Any(column => column.ID == "Review Note")
            && !renameUndone.Arcs.Columns.Any(column => column.ID == "Reviewer"),
            "Undo restores the original Arc metadata column name");
        GeometryTopologySnapshot renameRedone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, renameUndone.DraftState, new("redo", "history", [])));
        Check(renameRedone.Arcs.Columns.Any(column => column.ID == "Reviewer"),
            "Redo reapplies the Arc metadata column rename");

        GeometryTopologySnapshot regionAdded = await Edit(model, renameRedone,
            new("addMetadataColumn", "region", [], "Scenario Weight", "Numeric"));
        Check(regionAdded.Regions.Columns.Single(column => column.ID == "Scenario Weight").IsUserDefined
            && regionAdded.Regions.Rows.All(row => row.Values["Scenario Weight"] == "0"),
            "Adding a Region numeric column uses the source's zero default");
        GeometryTopologySnapshot regionDeleted = await Edit(model, regionAdded,
            new("deleteMetadataColumn", "region", [], "Scenario Weight"));
        Check(regionDeleted.Regions.Columns.All(column => column.ID != "Scenario Weight"),
            "Deleting a Region user-defined column removes it from the draft table");
        GeometryTopologySnapshot deleteUndone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, regionDeleted.DraftState, new("undo", "history", [])));
        Check(deleteUndone.Regions.Columns.Any(column => column.ID == "Scenario Weight"),
            "Undo restores a deleted Region column");
        GeometryTopologySnapshot deleteRedone = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, deleteUndone.DraftState, new("redo", "history", [])));
        Check(deleteRedone.Regions.Columns.All(column => column.ID != "Scenario Weight"),
            "Redo deletes the same Region column again");
        GeometryTopologySnapshot finalDraft = await ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, deleteRedone.DraftState, new("undo", "history", [])));
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            loaded.Revision, finalDraft.DraftState, new("deleteMetadataColumn", "arc", [], "Bias"))));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Column edits, undo and redo remain in the geometry topology draft before parent save");

        ModelSnapshot parent = await ModelEditorAdapter.LoadAsync(new ModelRequest(assetPath, "Geometry", projectPath));
        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry", projectPath,
            parent.Revision, new(), new(), GeometryTopologyState: finalDraft.DraftState));
        GeometryTopologySnapshot reopened = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model, saved.Revision));
        Check(!reopened.IsDirty && reopened.Arcs.Columns.Any(column => column.ID == "Reviewer" && column.IsUserDefined)
            && reopened.Arcs.Rows.All(row => row.Values["Reviewer"] == "")
            && reopened.Regions.Columns.Any(column => column.ID == "Scenario Weight" && column.IsUserDefined)
            && reopened.Regions.Rows.All(row => row.Values["Scenario Weight"] == "0"),
            "Parent save and HDF reopen preserve Arc and Region metadata columns and defaults");
    }

    private static Task<GeometryTopologySnapshot> Edit(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot snapshot, GeometryTopologyMutation mutation) =>
        ModelEditorAdapter.EditGeometryTopologyAsync(new(model, snapshot.Revision, snapshot.DraftState, mutation));

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Expect<T>(Func<Task<GeometryTopologySnapshot>> action) where T : Exception
    {
        try { _ = await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
