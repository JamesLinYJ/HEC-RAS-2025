using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Filtering;
using Utility.Memory;
using Utility.Units;
using Visual.Mapping.Observables;

internal static class GeometryTopologyToolChecks
{
    private const string CategoryTag = "Tool Category";
    private const string PhaseTag = "Tool Phase";
    private const string IntegerTag = "Tool Integer";
    private const string FloatTag = "Tool Float";
    private const string FlagTag = "Tool Flag";
    private const string RegionTag = "Tool Region Kind";
    private const string InvalidRecipe = "NotARecipe(";

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Topology tools.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry geometry = project.AddNewGeometry("Topology tools geometry");
        Topology topology = CreateTopology();
        geometry.ConceptualMeshLayer.Topology = topology;
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();
        using (var writer = new H5Assist.H5Writer(assetPath))
            writer.WriteAttribute(Geometry.HDF5Group, "Unknown Topology Tools Metadata", "Retain this attribute");

        var model = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        byte[] projectBytes = File.ReadAllBytes(projectPath);
        byte[] initialGeometryBytes = File.ReadAllBytes(assetPath);
        GeometryTopologySnapshot initial = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model));
        Check(initial.CanEdit && initial.Arcs.Rows.Length >= 8 && initial.Nodes.Rows.Length >= 8
            && initial.Regions.Rows.Length >= 2,
            "The real source topology exposes arcs, nodes and both regions around its inner ring");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(initialGeometryBytes),
            "Loading topology tools leaves the source geometry HDF unchanged");

        GeometryTopologySnapshot seeded = await SeedSourceMetadata(model, initial);
        GeometryTopologySnapshot savedSeed = await ModelEditorAdapter.SaveGeometryTopologyAsync(
            new GeometryTopologySaveRequest(model, seeded.Revision, seeded.DraftState));
        GeometryTopologySnapshot baseline = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(model, savedSeed.Revision));
        Check(!baseline.IsDirty && !baseline.CanUndo && baseline.Regions.Rows.Length >= 2,
            "The source metadata fixture reopens as a clean real HDF baseline");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes),
            "Saving topology metadata does not rewrite the owning project file");

        await ExportFixtureIfRequested(directory.FullName, projectPath, assetPath, baseline);
        byte[] sourceBytes = File.ReadAllBytes(assetPath);
        byte[] cleanProjectBytes = File.ReadAllBytes(projectPath);

        await CheckFactorOperations(model, baseline, assetPath, sourceBytes);
        await CheckRecipeOperations(model, baseline, assetPath, sourceBytes);
        await CheckFilterOperations(model, baseline, assetPath, sourceBytes);
        await CheckArcPointOperations(model, baseline, assetPath, sourceBytes);

        GeometryTopologySnapshot recipeDraft = await Edit(model, baseline,
            RecipeMutation(baseline.Regions.Rows.Select(row => row.FID).ToArray(), InvalidRecipe, forceSet: true));
        GeometryTopologyRecipeSnapshot invalidRecipe = await Recipe(model, recipeDraft,
            baseline.Regions.Rows.Select(row => row.FID).ToArray());
        Check(invalidRecipe.RawText == InvalidRecipe && !invalidRecipe.IsValid
            && !string.IsNullOrWhiteSpace(invalidRecipe.ParseIssue) && invalidRecipe.Steps.Length == 0,
            "The recipe editor reports invalid source text without replacing or normalizing it");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBytes),
            "Factor, recipe, filter and arc-point drafts leave source bytes unchanged until explicit save");

        GeometryTopologySnapshot saved = await ModelEditorAdapter.SaveGeometryTopologyAsync(
            new GeometryTopologySaveRequest(model, recipeDraft.Revision, recipeDraft.DraftState));
        Check(!saved.IsDirty && saved.Revision != baseline.Revision
            && !File.ReadAllBytes(assetPath).SequenceEqual(sourceBytes),
            "An explicit topology save commits the raw recipe draft and returns a fresh clean revision");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(cleanProjectBytes),
            "The explicit topology HDF save leaves the project file bytes unchanged");
        foreach (int fid in baseline.Regions.Rows.Select(row => row.FID))
            Check(saved.Regions.Rows.Single(row => row.FID == fid).Values["Recipe"] == InvalidRecipe,
                "Saved HDF readback preserves the exact invalid recipe text for control point " + fid.ToString(CultureInfo.InvariantCulture));
        using (var reader = new H5Assist.H5Reader(assetPath))
            Check(reader.TryReadStringAttributeScalar(Geometry.HDF5Group, "Unknown Topology Tools Metadata") == "Retain this attribute",
                "Explicit topology save preserves unknown source HDF attributes");

        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            baseline.Revision, baseline.DraftState, FactorMutation("2"))));
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadGeometryTopologyArcPointsAsync(
            new GeometryTopologyArcPointsRequest(model, baseline.Revision, baseline.DraftState,
                baseline.Arcs.Rows[0].FID)));
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadGeometryTopologyRecipeAsync(
            new GeometryTopologyRecipeRequest(model, baseline.Revision, baseline.DraftState, [])));
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.FilterGeometryTopologyAsync(
            new GeometryTopologyFilterRequest(model, baseline.Revision, baseline.DraftState, "arc", [])));

        Console.WriteLine("Geometry topology factor, recipe, arc-point and source TagFilter checks passed.");
    }

    private static Topology CreateTopology()
    {
        Topology topology = Topology.FromExtent(new Extent(0, 100, 0, 100));
        // A real internal point exercises the source ArcPoints row independently
        // from its shared start/end Node identities.
        topology.Arcs[0].AddPoint(new Point(0, 50));

        topology.AddNode(20, 20, out int lowerLeft);
        topology.AddNode(40, 20, out int lowerRight);
        topology.AddNode(40, 40, out int upperRight);
        topology.AddNode(20, 40, out int upperLeft);
        topology.AddArc(lowerLeft, lowerRight, [], out int holeSouth);
        topology.AddArc(lowerRight, upperRight, [], out int holeEast);
        topology.AddArc(upperRight, upperLeft, [], out int holeNorth);
        topology.AddArc(upperLeft, lowerLeft, [], out int holeWest);
        var innerRing = new RegionRing(4);
        innerRing.Arcs.Add(new ArcWithDirection(holeSouth, isForward: true));
        innerRing.Arcs.Add(new ArcWithDirection(holeEast, isForward: true));
        innerRing.Arcs.Add(new ArcWithDirection(holeNorth, isForward: true));
        innerRing.Arcs.Add(new ArcWithDirection(holeWest, isForward: true));
        topology.CompletedRegions.Single().AddInnerRing(innerRing);
        return topology;
    }

    private static async Task<GeometryTopologySnapshot> SeedSourceMetadata(
        GeometryTopologyModelRequest model, GeometryTopologySnapshot initial)
    {
        GeometryTopologySnapshot current = initial;
        foreach ((string Name, string Type) definition in new[]
        {
            (CategoryTag, "String"), (PhaseTag, "String"), (IntegerTag, "Integer"),
            (FloatTag, "Numeric"), (FlagTag, "Boolean")
        })
        {
            current = await Edit(model, current,
                new GeometryTopologyMutation("createTag", "arc", [], TagName: definition.Name, TagType: definition.Type));
        }
        current = await Edit(model, current,
            new GeometryTopologyMutation("createTag", "region", [], TagName: RegionTag, TagType: "String"));

        GeometryTopologyFeatureRow[] arcs = current.Arcs.Rows.OrderBy(row => row.FID).ToArray();
        Check(arcs.Length >= 8, "The source fixture has enough real arcs for the filter matrix");
        for (int index = 0; index < arcs.Length; index++)
        {
            int fid = arcs[index].FID;
            // Force typed source cells to exist instead of relying on the
            // observable getter's display default for null table values.
            current = await Edit(model, current, new GeometryTopologyMutation("setField", "arc", [fid],
                "SizeFunction", "Unset"));
            current = await Edit(model, current, new GeometryTopologyMutation("setField", "arc", [fid],
                "ConstantSize", (16 + index).ToString(CultureInfo.InvariantCulture)));
        }
        string[] categoryValues = ["East", "West", "east", "South"];
        string[] phaseValues = ["B", "A", "A", "B"];
        string[] integerValues = ["10", "20", "30", "40"];
        string[] floatValues = ["1.5", "12.25", "23.75", "34.5"];
        for (int index = 0; index < 4; index++)
        {
            int fid = arcs[index].FID;
            current = await SetTag(model, current, "arc", fid, CategoryTag, categoryValues[index]);
            current = await SetTag(model, current, "arc", fid, PhaseTag, phaseValues[index]);
            current = await SetTag(model, current, "arc", fid, IntegerTag, integerValues[index]);
            current = await SetTag(model, current, "arc", fid, FloatTag, floatValues[index]);
        }
        for (int index = 0; index < 2; index++)
            current = await SetTag(model, current, "arc", arcs[index].FID, FlagTag, "true");

        GeometryTopologyFeatureRow[] regions = current.Regions.Rows.OrderBy(row => row.FID).Take(2).ToArray();
        Check(regions.Length == 2, "The source inner-ring fixture has two real control-point rows");
        current = await SetTag(model, current, "region", regions[0].FID, RegionTag, "Outer");
        current = await SetTag(model, current, "region", regions[1].FID, RegionTag, "Inner");

        // The retained HDF writer materializes the source Count default on
        // every arc. The persisted fixture therefore contains eight zero
        // cells; the independent in-memory check covers true null cells.
        // False is separately tested after changing one Boolean through the
        // retained setter.
        current = await Edit(model, current, new GeometryTopologyMutation("setField", "arc", [arcs[0].FID],
            "PointCount", "5"));
        current = await Edit(model, current, new GeometryTopologyMutation("setField", "arc", [arcs[0].FID],
            "PointCount", "0"));
        current = await Edit(model, current, new GeometryTopologyMutation("setField", "arc", [arcs[1].FID],
            "DistanceStraightLine", "true"));
        current = await Edit(model, current, new GeometryTopologyMutation("setField", "arc", [arcs[1].FID],
            "DistanceStraightLine", "false"));

        int firstRegion = regions[0].FID;
        int secondRegion = regions[1].FID;
        current = await Edit(model, current, RecipeMutation([firstRegion], "Smooth()", forceSet: true));
        current = await Edit(model, current, RecipeMutation([secondRegion], "Default()", forceSet: true));
        // An explicit empty string is non-null in the source table and is
        // intentionally distinct from an unmaterialized Recipe cell.
        current = await Edit(model, current, new GeometryTopologyMutation("setField", "region", [secondRegion],
            "Recipe", ""));
        return current;
    }

    private static async Task CheckFactorOperations(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot baseline, string assetPath, byte[] sourceBytes)
    {
        GeometryTopologySnapshot doubled = await Edit(model, baseline, FactorMutation("2"));
        GeometryTopologyDraftState factorState = JsonSerializer.Deserialize<GeometryTopologyDraftState>(
            doubled.DraftState, BackendJson.Options)
            ?? throw new InvalidDataException("Factor edit omitted its source draft state.");
        Check(doubled.IsDirty && doubled.CanUndo && !doubled.CanRedo && factorState.Mutations.Length == 1,
            "Applying the global factor to both tables creates one undoable source command");
        VerifyFactorValues(baseline, doubled, 2f, arcIDs: null, pointIDs: null);

        GeometryTopologySnapshot undone = await Edit(model, doubled, new GeometryTopologyMutation("undo", "history", []));
        Check(undone.CanRedo && !undone.CanUndo && SameRows(baseline.Arcs, undone.Arcs)
            && SameRows(baseline.Regions, undone.Regions),
            "One Undo reverses the global factor from both arc and control-point collections atomically");
        GeometryTopologySnapshot redone = await Edit(model, undone, new GeometryTopologyMutation("redo", "history", []));
        Check(redone.CanUndo && !redone.CanRedo && SameRows(doubled.Arcs, redone.Arcs)
            && SameRows(doubled.Regions, redone.Regions),
            "One Redo restores the same all-table factor result");

        int selectedArc = baseline.Arcs.Rows[1].FID;
        int selectedPoint = baseline.Regions.Rows[0].FID;
        GeometryTopologySnapshot selected = await Edit(model, baseline,
            FactorMutation("0.5", selectedOnly: true, [selectedArc], [selectedPoint]));
        VerifyFactorValues(baseline, selected, 0.5f, [selectedArc], [selectedPoint]);
        Check(selected.Arcs.Rows.Where(row => row.FID != selectedArc)
                .All(row => SameRow(row, baseline.Arcs.Rows.Single(source => source.FID == row.FID)))
            && selected.Regions.Rows.Where(row => row.FID != selectedPoint)
                .All(row => SameRow(row, baseline.Regions.Rows.Single(source => source.FID == row.FID))),
            "Selected-only factor changes only the exact selected arc and control point");

        GeometryTopologySnapshot emptySelection = await Edit(model, baseline,
            FactorMutation("2", selectedOnly: true, [], []));
        Check(emptySelection.DraftState == baseline.DraftState && !emptySelection.CanUndo && !emptySelection.IsDirty
            && SameRows(emptySelection.Arcs, baseline.Arcs) && SameRows(emptySelection.Regions, baseline.Regions),
            "An empty selected-only factor is a no-op and creates no history entry");

        foreach (float factor in new[] { 0f, -2f, float.NaN, float.PositiveInfinity })
        {
            string raw = factor.ToString(CultureInfo.CurrentCulture);
            GeometryTopologySnapshot applied = await Edit(model, baseline, FactorMutation(raw));
            VerifyFactorValues(baseline, applied, factor, arcIDs: null, pointIDs: null);
        }
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBytes),
            "Global, selected, empty, zero, negative and non-finite factor edits remain unsaved drafts");
    }

    private static void VerifyFactorValues(GeometryTopologySnapshot source, GeometryTopologySnapshot actual,
        float factor, int[]? arcIDs, int[]? pointIDs)
    {
        HashSet<int>? selectedArcs = arcIDs is null ? null : arcIDs.ToHashSet();
        HashSet<int>? selectedPoints = pointIDs is null ? null : pointIDs.ToHashSet();
        foreach (GeometryTopologyFeatureRow row in source.Arcs.Rows)
        {
            GeometryTopologyFeatureRow result = actual.Arcs.Rows.Single(item => item.FID == row.FID);
            if (selectedArcs is not null && !selectedArcs.Contains(row.FID))
            {
                Check(SameRow(row, result), "Unselected source arc " + row.FID.ToString(CultureInfo.InvariantCulture) + " is preserved");
                continue;
            }
            Check(SameFloat(ReadFloat(row, "ConstantSize") * factor, ReadFloat(result, "ConstantSize"))
                && ReadInteger(result, "PointCount") == Math.Max(1, (int)((float)ReadInteger(row, "PointCount") / factor)),
                "Arc factor result matches the retained ConstantSize and integer PointCount formulas");
        }
        foreach (GeometryTopologyFeatureRow row in source.Regions.Rows)
        {
            GeometryTopologyFeatureRow result = actual.Regions.Rows.Single(item => item.FID == row.FID);
            if (selectedPoints is not null && !selectedPoints.Contains(row.FID))
            {
                Check(SameRow(row, result), "Unselected source control point " + row.FID.ToString(CultureInfo.InvariantCulture) + " is preserved");
                continue;
            }
            Check(SameFloat(ReadFloat(row, "ConstantSize") * factor, ReadFloat(result, "ConstantSize"))
                && SameFloat(ReadFloat(row, "SecondaryConstantSize") * factor, ReadFloat(result, "SecondaryConstantSize")),
                "Control-point factor scales both retained source cell-size fields");
        }
    }

    private static async Task CheckRecipeOperations(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot baseline, string assetPath, byte[] sourceBytes)
    {
        int[] pointIDs = baseline.Regions.Rows.OrderBy(row => row.FID).Take(2).Select(row => row.FID).ToArray();
        GeometryTopologyRecipeSnapshot noSelection = await Recipe(model, baseline, [], "Smooth(count=3,scaled=false)");
        Check(!noSelection.HasSelection && noSelection.ControlPointFIDs.Length == 0
            && noSelection.RawText == "Smooth(count=3,scaled=false)" && noSelection.IsValid,
            "The recipe source accepts a raw valid expression even when no control point is selected");
        GeometryTopologyRecipeStepSchema smoothSchema = noSelection.StepSchema.Single(step => step.Name == "Smooth");
        Check(smoothSchema.Parameters.Select(parameter => parameter.Name).ToHashSet(StringComparer.Ordinal)
                .SetEquals(["count", "scaled", "sliding", "useArea"])
            && smoothSchema.Parameters.Single(parameter => parameter.Name == "count").DefaultValue == "10"
            && smoothSchema.Parameters.Single(parameter => parameter.Name == "scaled").SourceType == "bool",
            "Recipe parameter schema and defaults come from the retained SmoothStep fields");
        Check(noSelection.StepSchema.Single(step => step.Name == "RemoveFaces").Aliases.Contains("Merge", StringComparer.Ordinal),
            "The recipe schema preserves the retained Merge alias for RemoveFaces");

        GeometryTopologyRecipeSnapshot mixed = await Recipe(model, baseline, pointIDs);
        Check(mixed.HasSelection && mixed.HasMismatch && mixed.CommonRecipe is null
            && mixed.SelectedRecipes.Select(item => item.FID).SequenceEqual(pointIDs)
            && mixed.SelectedRecipes[0].Recipe == "Smooth()" && mixed.SelectedRecipes[1].Recipe == "",
            "Recipe selection reports exact control-point identity and the source mixed-recipe state");
        await Expect<ArgumentException>(() => ModelEditorAdapter.EditGeometryTopologyAsync(new(model,
            baseline.Revision, baseline.DraftState, RecipeMutation(pointIDs, "Smooth()", forceSet: false))));

        GeometryTopologyRecipeSnapshot alias = await Recipe(model, baseline, pointIDs, "Merge(threshold=0.25)");
        Check(alias.IsValid && alias.Steps.Length == 1 && alias.Steps[0].Name == "RemoveFaces"
            && alias.Steps[0].Parameters["threshold"] == "0.25",
            "The retained recipe parser resolves the Merge alias and its real threshold parameter");
        GeometryTopologyRecipeSnapshot invalid = await Recipe(model, baseline, pointIDs, InvalidRecipe);
        Check(!invalid.IsValid && invalid.RawText == InvalidRecipe && !string.IsNullOrWhiteSpace(invalid.ParseIssue)
            && invalid.Steps.Length == 0,
            "Recipe validation returns source parse details while retaining the invalid text");

        GeometryTopologyMutation emptyRecipe = RecipeMutation([], "Smooth()", forceSet: true);
        GeometryTopologySnapshot empty = await Edit(model, baseline, emptyRecipe);
        Check(empty.DraftState == baseline.DraftState && !empty.CanUndo && !empty.IsDirty,
            "Applying a recipe with no selected control points is a source no-op");
        GeometryTopologySnapshot noForce = await Edit(model, baseline,
            RecipeMutation(pointIDs, "Smooth()", forceSet: true));
        GeometryTopologyRecipeSnapshot forced = await Recipe(model, noForce, pointIDs);
        Check(forced.SelectedRecipes.All(item => item.Recipe == "Smooth()") && !forced.HasMismatch,
            "Force Set applies one recipe to exactly the selected mismatched control points");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBytes),
            "Recipe parsing and Force Set do not persist until parent save");
    }

    private static async Task CheckFilterOperations(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot baseline, string assetPath, byte[] sourceBytes)
    {
        int[] arcIDs = baseline.Arcs.Rows.Select(row => row.FID).OrderBy(fid => fid).ToArray();
        int[] firstFour = arcIDs.Take(4).ToArray();
        GeometryTopologyFilterSnapshot empty = await Filter(model, baseline, "arc", []);
        CheckIds(empty.MatchedFeatureIDs, arcIDs, "An empty source filter matches all arc rows in source order");
        Check(empty.Revision == baseline.Revision && empty.DraftIdentity == DraftIdentity(baseline.DraftState),
            "Filter result carries the exact source revision and replayed draft identity");

        GeometryTopologyPropertyDescriptor count = empty.PropertyDescriptors.Single(item => item.Name == "PointCount");
        GeometryTopologyPropertyDescriptor constantSize = empty.PropertyDescriptors.Single(item => item.Name == "ConstantSize");
        GeometryTopologyPropertyDescriptor sizeFunction = empty.PropertyDescriptors.Single(item => item.Name == "SizeFunction");
        Check(sizeFunction.IsEnum && !count.IsEnum && !constantSize.IsEnum,
            "Filter descriptors distinguish the retained enum SizeFunction from numeric columns");

        GeometryTopologyFilterSnapshot grouped = await Filter(model, baseline, "arc",
        [
            TagClause(CategoryTag, "Equals", "East"),
            TagClause(CategoryTag, "Equals", "West"),
            TagClause(PhaseTag, "Equals", "A")
        ]);
        CheckIds(grouped.MatchedFeatureIDs, [firstFour[1]],
            "Same-definition Tag rows combine as OR, while a different definition remains AND");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "Contains", "E")])).MatchedFeatureIDs,
            [firstFour[0], firstFour[1], firstFour[2]],
            "String Tag Contains follows the source ordinal-ignore-case predicate");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "DoesNotContain", "th")])).MatchedFeatureIDs,
            [firstFour[0], firstFour[1], firstFour[2], .. arcIDs.Skip(4)],
            "String Tag DoesNotContain includes missing source tags and excludes matching values");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "Equals", "East")])).MatchedFeatureIDs,
            [firstFour[0]], "String Tag Equals retains the source case-sensitive comparison");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "NotEquals", "East")])).MatchedFeatureIDs,
            arcIDs.Where(fid => fid != firstFour[0]), "Missing Tag values satisfy source NotEquals semantics");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "IsBlank", null)])).MatchedFeatureIDs,
            arcIDs.Except(firstFour), "A source Tag is blank when its value is the definition default");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "IsNotBlank", null)])).MatchedFeatureIDs,
            firstFour, "A source Tag is nonblank only when the retained definition has a materialized value");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "Contains", "z")])).MatchedFeatureIDs,
            [], "A missing Tag does not satisfy Contains");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "DoesNotContain", "z")])).MatchedFeatureIDs,
            arcIDs, "A missing Tag satisfies DoesNotContain");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "LessThan", "z")])).MatchedFeatureIDs,
            firstFour, "A missing Tag does not satisfy ordered comparisons");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "AtMost", "z")])).MatchedFeatureIDs,
            firstFour, "A missing Tag does not satisfy inclusive ordered comparisons");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "GreaterThan", "A")])).MatchedFeatureIDs,
            firstFour, "A missing Tag does not satisfy greater-than comparisons");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(CategoryTag, "AtLeast", "A")])).MatchedFeatureIDs,
            firstFour, "A missing Tag does not satisfy inclusive greater-than comparisons");

        CheckIds((await Filter(model, baseline, "arc", [TagClause(FlagTag, "Equals", "true")])).MatchedFeatureIDs,
            firstFour.Take(2), "Boolean tags compare against their actual retained Boolean values");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(FlagTag, "IsBlank", null)])).MatchedFeatureIDs,
            arcIDs.Skip(2), "Default Boolean tags remain absent in the retained tag collection");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(IntegerTag, "GreaterThan", "10")])).MatchedFeatureIDs,
            firstFour.Skip(1), "Integer Tag comparisons parse and compare using the retained cell type");
        CheckIds((await Filter(model, baseline, "arc", [TagClause(FloatTag, "GreaterThan", "10")])).MatchedFeatureIDs,
            firstFour.Skip(1), "Float Tag comparisons parse and compare using the retained cell type");
        CheckIds((await Filter(model, baseline, "region", [TagClause(RegionTag, "Contains", "inner")])).MatchedFeatureIDs,
            [baseline.Regions.Rows.OrderBy(row => row.FID).ElementAt(1).FID],
            "Region Tag filtering uses control-point identities and the same source string predicate");

        await CheckInvalidNumericFallback(model, baseline, IntegerTag, isTag: true, arcIDs, firstFour);
        await CheckInvalidNumericFallback(model, baseline, FloatTag, isTag: true, arcIDs, firstFour);
        await CheckInvalidNumericFallback(model, baseline, count.ColumnName, isTag: false, arcIDs, null);
        await CheckInvalidNumericFallback(model, baseline, constantSize.ColumnName, isTag: false, arcIDs, null);

        int[] pointCountZero = baseline.Arcs.Rows
            .Where(row => row.Values.TryGetValue(count.ColumnName, out string? value) && value == "0")
            .Select(row => row.FID).ToArray();
        CheckIds(pointCountZero, arcIDs,
            "The saved source HDF materializes its integer Count default as zero on every arc row");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "Equals", "0")])).MatchedFeatureIDs,
            pointCountZero, "Persisted integer zero cells are nonblank and compare exactly");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "IsNotBlank", null)])).MatchedFeatureIDs,
            pointCountZero, "Property IsNotBlank reads the materialized HDF table cells");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "IsBlank", null)])).MatchedFeatureIDs,
            [], "The saved Count column contains no null cells after source-default materialization");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "Equals", "z")])).MatchedFeatureIDs,
            [], "Persisted zero cells do not equal an invalid integer filter value");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "NotEquals", "z")])).MatchedFeatureIDs,
            pointCountZero, "Invalid integer comparison falls back to the source text value");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "Contains", "z")])).MatchedFeatureIDs,
            [], "Persisted zero text does not contain the filter text");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "DoesNotContain", "z")])).MatchedFeatureIDs,
            pointCountZero, "Persisted zero text does not contain the filter text");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "LessThan", "z")])).MatchedFeatureIDs,
            pointCountZero, "Invalid integer comparison uses the source text ordering fallback");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "AtMost", "z")])).MatchedFeatureIDs,
            pointCountZero, "Invalid integer comparison uses the inclusive source text ordering fallback");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "GreaterThan", "z")])).MatchedFeatureIDs,
            [], "Persisted zero text is not greater than the invalid integer filter text");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(count.ColumnName, "AtLeast", "z")])).MatchedFeatureIDs,
            [], "Persisted zero text is not at least the invalid integer filter text");

        CheckInMemoryNullPropertySemantics();

        GeometryTopologyFilterSnapshot regionFields = await Filter(model, baseline, "region", []);
        GeometryTopologyPropertyDescriptor recipe = regionFields.PropertyDescriptors.Single(item => item.Name == "Recipe");
        int[] regionIDs = baseline.Regions.Rows.Select(row => row.FID).ToArray();
        CheckIds((await Filter(model, baseline, "region", [PropertyClause(recipe.ColumnName, "IsNotBlank", null)])).MatchedFeatureIDs,
            regionIDs, "An explicitly stored empty string remains a non-null source Property value");
        CheckIds((await Filter(model, baseline, "region", [PropertyClause(recipe.ColumnName, "IsBlank", null)])).MatchedFeatureIDs,
            [], "An explicitly stored empty string is not a null source Property cell");

        GeometryTopologyPropertyDescriptor booleanProperty = empty.PropertyDescriptors.Single(item => item.Name == "DistanceStraightLine");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(booleanProperty.ColumnName, "IsNotBlank", null)])).MatchedFeatureIDs,
            arcIDs,
            "The saved Boolean column is materialized for every arc, including the explicitly stored false value");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(booleanProperty.ColumnName, "IsBlank", null)])).MatchedFeatureIDs,
            [], "The saved Boolean source column contains no null cells");
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(booleanProperty.ColumnName, "Equals", "false")])).MatchedFeatureIDs,
            arcIDs,
            "Persisted Boolean false values match all materialized source Arc cells");
        Check(baseline.Arcs.Rows.All(row => row.Values[booleanProperty.ColumnName] == "false"),
            "HDF readback materializes Boolean false for every source Arc row");

        string enumValue = baseline.Arcs.Rows[0].Values[sizeFunction.ColumnName];
        CheckIds((await Filter(model, baseline, "arc", [PropertyClause(sizeFunction.ColumnName, "Equals", enumValue)])).MatchedFeatureIDs,
            baseline.Arcs.Rows.Where(row => row.Values[sizeFunction.ColumnName] == enumValue).Select(row => row.FID),
            "Enum-backed source properties are parsed and compared as their actual enum type");

        CheckIds((await Filter(model, baseline, "arc",
            [new GeometryTopologyFilterClause("Tag", null, null, "not-a-source-operator")])).MatchedFeatureIDs,
            arcIDs, "A Tag filter row with no selected definition follows the source no-op behavior");
        CheckIds((await Filter(model, baseline, "arc",
            [new GeometryTopologyFilterClause("Property", null, null, "not-a-source-operator")])).MatchedFeatureIDs,
            arcIDs, "A Property filter row with no selected column follows the source no-op behavior");
        CheckIds((await Filter(model, baseline, "arc",
            [new GeometryTopologyFilterClause("Tag", CategoryTag, null, "Equals", null)])).MatchedFeatureIDs,
            arcIDs, "A source Tag comparison with a null value is a no-op");
        CheckIds((await Filter(model, baseline, "arc",
            [new GeometryTopologyFilterClause("Property", null, count.ColumnName, "Equals", null)])).MatchedFeatureIDs,
            baseline.Arcs.Rows.Where(row => row.Values[count.ColumnName].Length > 0).Select(row => row.FID),
            "A Property comparison with a null value matches source nonnull cells");

        await Expect<ArgumentException>(() => Filter(model, baseline, "arc", [TagClause("missing-tag", "Equals", "x")]));
        await Expect<ArgumentException>(() => Filter(model, baseline, "arc", [PropertyClause("missing-column", "Equals", "x")]));
        await Expect<ArgumentException>(() => Filter(model, baseline, "arc", [TagClause(CategoryTag, "not-a-source-operator", "x")]));
        await Expect<ArgumentException>(() => Filter(model, baseline, "other", []));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBytes),
            "All successful and rejected filter queries are read-only against the source HDF");
    }

    private static void CheckInMemoryNullPropertySemantics()
    {
        // HDF persistence materializes mesh defaults, so a null Property cell
        // has to be exercised on the retained in-memory table before saving.
        // The test deliberately invokes the production row predicate rather
        // than duplicating its null-handling rules or adding a test API.
        Topology topology = Topology.FromExtent(new Extent(0, 10, 0, 10));
        Table table = topology.ArcMetadata;
        int countColumn;
        if (table.TryGetColumnIndex("Count", out int existingColumn))
        {
            if (table.Columns[existingColumn].Type != typeof(int))
                throw new InvalidOperationException("The in-memory Count property column is not an integer.");
            countColumn = existingColumn;
        }
        else countColumn = table.AddColumn("Count", typeof(int));
        foreach (TableRow row in table.Rows)
            row.ItemArray.SetValue(null, countColumn);

        var observableTopology = new ObservableConceptualMeshTopology(topology);
        ObservableConceptualMeshArc[] arcs = observableTopology.Arcs.ToArray();
        Check(arcs.Length == topology.ArcCount && arcs.Length > 0
            && arcs.All(arc => arc.TableRow["Count"] is null),
            "The unsaved retained Observable topology keeps real null Count table cells");
        Check(arcs.All(arc => arc.PointCount == 0),
            "The source PointCount display getter can show zero while its raw table cell remains null");

        Type clauseType = typeof(ModelEditorAdapter).GetNestedType("ResolvedTopologyFilterClause",
            BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("The production topology filter clause type is unavailable.");
        Type[] clauseSignature =
        [typeof(FilterCondition), typeof(string), typeof(ObservableTagDefinition), typeof(string), typeof(bool), typeof(bool)];
        ConstructorInfo clauseConstructor = clauseType.GetConstructors(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .SingleOrDefault(candidate => candidate.GetParameters().Select(parameter => parameter.ParameterType)
                .SequenceEqual(clauseSignature))
            ?? throw new InvalidOperationException("The production topology filter clause constructor changed.");
        MethodInfo predicate = typeof(ModelEditorAdapter).GetMethod("MatchesTopologyFilterClause",
            BindingFlags.Static | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("The production topology filter row predicate is unavailable.");

        bool Matches(ObservableConceptualMeshArc feature, FilterCondition operation, string? value = "0")
        {
            object clause = clauseConstructor.Invoke([operation, value, null, "Count", true, false])
                ?? throw new InvalidOperationException("The production topology filter clause could not be created.");
            return predicate.Invoke(null, [feature, clause]) is bool result
                ? result
                : throw new InvalidOperationException("The production topology filter predicate returned no Boolean.");
        }

        foreach (ObservableConceptualMeshArc arc in arcs)
        {
            Check(Matches(arc, FilterCondition.IsBlank), "A raw null Property cell matches IsBlank");
            Check(!Matches(arc, FilterCondition.IsNotBlank), "A raw null Property cell does not match IsNotBlank");
            Check(!Matches(arc, FilterCondition.Equals), "A raw null Property cell does not match Equals");
            Check(!Matches(arc, FilterCondition.NotEquals), "A raw null Property cell does not match NotEquals");
            Check(!Matches(arc, FilterCondition.Contains), "A raw null Property cell does not match Contains");
            Check(!Matches(arc, FilterCondition.DoesNotContain), "A raw null Property cell does not match DoesNotContain");
            Check(!Matches(arc, FilterCondition.LessThan), "A raw null Property cell does not match ordered comparisons");
            Check(!Matches(arc, FilterCondition.AtMost), "A raw null Property cell does not match inclusive ordered comparisons");
            Check(!Matches(arc, FilterCondition.GreaterThan), "A raw null Property cell does not match greater-than comparisons");
            Check(!Matches(arc, FilterCondition.AtLeast), "A raw null Property cell does not match inclusive greater-than comparisons");
            Check(!Matches(arc, FilterCondition.Equals, value: null),
                "A null-valued comparison still rejects a raw null Property cell before applying the value no-op rule");
        }
    }

    private static async Task CheckInvalidNumericFallback(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot baseline, string id, bool isTag, int[] allIDs, int[]? numericTagIDs)
    {
        string clauseType = isTag ? "Tag" : "Property";
        string? tagID = isTag ? id : null;
        string? columnID = isTag ? null : id;
        int[] nonblank = isTag
            ? numericTagIDs ?? throw new InvalidOperationException("Numeric tag fixture IDs are missing.")
            : baseline.Arcs.Rows.Where(row => row.Values[id].Length > 0).Select(row => row.FID).ToArray();
        GeometryTopologyFilterClause Clause(string op) => new(clauseType, tagID, columnID, op, "z");

        CheckIds((await Filter(model, baseline, "arc", [Clause("Equals")])).MatchedFeatureIDs,
            [], "Invalid numeric Equals falls back to source text comparison without throwing");
        CheckIds((await Filter(model, baseline, "arc", [Clause("NotEquals")])).MatchedFeatureIDs,
            isTag ? allIDs : nonblank, "Invalid numeric NotEquals follows source text comparison and missing-value behavior");
        CheckIds((await Filter(model, baseline, "arc", [Clause("LessThan")])).MatchedFeatureIDs,
            nonblank, "Invalid numeric LessThan uses actual.ToString().CompareTo(filterValue)");
        CheckIds((await Filter(model, baseline, "arc", [Clause("AtMost")])).MatchedFeatureIDs,
            nonblank, "Invalid numeric AtMost uses source text comparison without throwing");
        CheckIds((await Filter(model, baseline, "arc", [Clause("GreaterThan")])).MatchedFeatureIDs,
            [], "Invalid numeric GreaterThan uses source text comparison without throwing");
        CheckIds((await Filter(model, baseline, "arc", [Clause("AtLeast")])).MatchedFeatureIDs,
            [], "Invalid numeric AtLeast uses source text comparison without throwing");
    }

    private static async Task CheckArcPointOperations(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot baseline, string assetPath, byte[] sourceBytes)
    {
        var sharedEndpoint = baseline.Arcs.Rows
            .SelectMany(row => new[]
            {
                (Node: row.StartNodeID, Arc: row.FID, Kind: "start"),
                (Node: row.EndNodeID, Arc: row.FID, Kind: "end")
            })
            .Where(item => item.Node is not null)
            .GroupBy(item => item.Node!.Value)
            .Select(group => new
            {
                Node = group.Key,
                Edges = group.ToArray(),
                ArcIDs = group.Select(item => item.Arc).Distinct().ToArray()
            })
            .First(group => group.ArcIDs.Length >= 2);
        int editedArcID = sharedEndpoint.Edges[0].Arc;
        string editedEndpointKind = sharedEndpoint.Edges[0].Kind;
        GeometryTopologyArcPointsSnapshot sourcePoints = await ArcPoints(model, baseline, editedArcID);
        GeometryTopologyArcPoint sourceEndpoint = sourcePoints.Rows.Single(row => row.PointKind == editedEndpointKind);
        Check(sourceEndpoint.EndpointNodeIndex == sharedEndpoint.Node,
            "ArcPoints rows expose the exact source endpoint node identity");
        int adjacentArcID = sharedEndpoint.ArcIDs.Single(fid => fid != editedArcID);
        double nextX = sourceEndpoint.X + 7.25;
        GeometryTopologySnapshot moved = await Edit(model, baseline,
            ArcCoordinateMutation(editedArcID, editedEndpointKind, sharedEndpoint.Node, null, "X", nextX));
        GeometryTopologyArcPointsSnapshot neighborPoints = await ArcPoints(model, moved, adjacentArcID);
        GeometryTopologyArcPoint sharedNeighbor = neighborPoints.Rows.Single(row => row.EndpointNodeIndex == sharedEndpoint.Node);
        Check(sharedNeighbor.X == nextX && sharedNeighbor.Y == sourceEndpoint.Y,
            "Moving one shared endpoint uses the retained node operation and updates every incident arc");

        int internalArcID = baseline.Arcs.Rows[0].FID;
        GeometryTopologyArcPointsSnapshot arcWithInternal = await ArcPoints(model, baseline, internalArcID);
        GeometryTopologyArcPoint sourceInternal = arcWithInternal.Rows.Single(row => row.PointKind == "internal");
        int internalPointIndex = sourceInternal.InternalPointIndex
            ?? throw new InvalidDataException("The retained ArcPoints internal row omitted its source index.");
        double nextY = sourceInternal.Y + 3.5;
        GeometryTopologySnapshot internalEdited = await Edit(model, baseline,
            ArcCoordinateMutation(internalArcID, "internal", null, internalPointIndex, "Y", nextY));
        GeometryTopologyArcPointsSnapshot internalAfter = await ArcPoints(model, internalEdited, internalArcID);
        GeometryTopologyArcPoint changedInternal = internalAfter.Rows.Single(row => row.PointKind == "internal");
        Check(changedInternal.InternalPointIndex == internalPointIndex
            && changedInternal.X == sourceInternal.X && changedInternal.Y == nextY,
            "An internal ArcPoints coordinate edit changes only the requested source vertex axis");

        await Expect<ArgumentException>(() => Edit(model, baseline,
            ArcCoordinateMutation(internalArcID, "internal", null, sourceInternal.InternalPointIndex, "Z", nextY)));
        await Expect<ArgumentException>(() => Edit(model, baseline,
            ArcCoordinateMutation(internalArcID, "internal", null, 9999, "X", nextX)));
        await Expect<ArgumentException>(() => Edit(model, baseline,
            ArcCoordinateMutation(editedArcID, editedEndpointKind, sharedEndpoint.Node + 9999, null, "X", nextX)));
        await Expect<ArgumentException>(() => Edit(model, baseline,
            ArcCoordinateMutation(editedArcID, editedEndpointKind, sharedEndpoint.Node, null, "X", double.NaN)));
        await Expect<ArgumentException>(() => ArcPoints(model, baseline, int.MaxValue));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBytes),
            "Shared-endpoint, internal-coordinate and rejected ArcPoints edits remain unsaved source drafts");
    }

    private static GeometryTopologyMutation ArcCoordinateMutation(int arcFID, string pointKind,
        int? endpointNodeIndex, int? internalPointIndex, string axis, double rawValue) =>
        new GeometryTopologyMutation("setArcPointCoordinate", "arc", [arcFID])
        {
            PointKind = pointKind,
            EndpointNodeIndex = endpointNodeIndex,
            InternalPointIndex = internalPointIndex,
            Axis = axis,
            RawValue = rawValue.ToString("R", CultureInfo.InvariantCulture)
        };

    private static GeometryTopologyMutation FactorMutation(string rawFactor, bool selectedOnly = false,
        int[]? arcFIDs = null, int[]? pointFIDs = null) =>
        new GeometryTopologyMutation("applyFactor", "topology", [])
        {
            ApplyToSelectedOnly = selectedOnly,
            FactorText = rawFactor,
            ArcFeatureIDs = arcFIDs ?? [],
            ControlPointFeatureIDs = pointFIDs ?? []
        };

    private static GeometryTopologyMutation RecipeMutation(int[] pointFIDs, string recipeText, bool forceSet) =>
        new GeometryTopologyMutation("applyRecipe", "region", [])
        {
            ControlPointFeatureIDs = pointFIDs,
            RecipeText = recipeText,
            ForceSet = forceSet
        };

    private static GeometryTopologyFilterClause TagClause(string tagID, string op, string? value) =>
        new("Tag", tagID, null, op, value);

    private static GeometryTopologyFilterClause PropertyClause(string columnID, string op, string? value) =>
        new("Property", null, columnID, op, value);

    private static async Task<GeometryTopologySnapshot> SetTag(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot snapshot, string kind, int fid, string tagName, string tagValue) =>
        await Edit(model, snapshot, new GeometryTopologyMutation("setTag", kind, [fid], TagName: tagName, TagValue: tagValue));

    private static async Task<GeometryTopologySnapshot> Edit(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot snapshot, GeometryTopologyMutation mutation) =>
        await ModelEditorAdapter.EditGeometryTopologyAsync(new(model, snapshot.Revision, snapshot.DraftState, mutation));

    private static async Task<GeometryTopologyRecipeSnapshot> Recipe(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot snapshot, int[] pointFIDs, string? recipeText = null) =>
        await ModelEditorAdapter.LoadGeometryTopologyRecipeAsync(new GeometryTopologyRecipeRequest(
            model, snapshot.Revision, snapshot.DraftState, pointFIDs, recipeText));

    private static async Task<GeometryTopologyArcPointsSnapshot> ArcPoints(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot snapshot, int arcFID) =>
        await ModelEditorAdapter.LoadGeometryTopologyArcPointsAsync(new GeometryTopologyArcPointsRequest(
            model, snapshot.Revision, snapshot.DraftState, arcFID));

    private static async Task<GeometryTopologyFilterSnapshot> Filter(GeometryTopologyModelRequest model,
        GeometryTopologySnapshot snapshot, string featureKind, GeometryTopologyFilterClause[] clauses) =>
        await ModelEditorAdapter.FilterGeometryTopologyAsync(new GeometryTopologyFilterRequest(
            model, snapshot.Revision, snapshot.DraftState, featureKind, clauses));

    private static int ReadInteger(GeometryTopologyFeatureRow row, string key) =>
        int.Parse(row.Values[key], NumberStyles.Integer, CultureInfo.InvariantCulture);

    private static float ReadFloat(GeometryTopologyFeatureRow row, string key) =>
        float.Parse(row.Values[key], NumberStyles.Float, CultureInfo.InvariantCulture);

    private static bool SameFloat(float expected, float actual) =>
        float.IsNaN(expected) ? float.IsNaN(actual) : expected.Equals(actual);

    private static bool SameRows(GeometryTopologyFeatureTable left, GeometryTopologyFeatureTable right) =>
        left.Rows.Length == right.Rows.Length && left.Rows.All(row =>
            right.Rows.FirstOrDefault(other => other.FID == row.FID) is { } other && SameRow(row, other));

    private static bool SameRow(GeometryTopologyFeatureRow left, GeometryTopologyFeatureRow right) =>
        left.FID == right.FID && left.ID == right.ID && left.Values.Count == right.Values.Count
        && left.Values.All(pair => right.Values.TryGetValue(pair.Key, out string? value) && value == pair.Value);

    private static string DraftIdentity(string draftState) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(draftState))).ToLowerInvariant();

    private static void CheckIds(IEnumerable<int> actual, IEnumerable<int> expected, string message)
    {
        int[] actualIDs = actual.OrderBy(fid => fid).ToArray();
        int[] expectedIDs = expected.OrderBy(fid => fid).ToArray();
        Check(actualIDs.SequenceEqual(expectedIDs), message + ". Expected ["
            + string.Join(",", expectedIDs) + "], got [" + string.Join(",", actualIDs) + "]");
    }

    private static async Task ExportFixtureIfRequested(string sourceDirectory, string projectPath,
        string assetPath, GeometryTopologySnapshot baseline)
    {
        string? configuredPath = Environment.GetEnvironmentVariable("HECRAS_TOPOLOGY_TOOLS_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configuredPath)) return;
        string destination = Path.GetFullPath(configuredPath);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The topology tools fixture destination already exists.");
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(sourceDirectory, folder)));
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(sourceDirectory, file)));

        GeometryTopologyFeatureRow[] arcs = baseline.Arcs.Rows.OrderBy(row => row.FID).ToArray();
        GeometryTopologyFeatureRow[] regions = baseline.Regions.Rows.OrderBy(row => row.FID).ToArray();
        GeometryTopologyFeatureRow[] nodes = baseline.Nodes.Rows.OrderBy(row => row.FID).ToArray();
        var sharedEndpoint = arcs.SelectMany(row => new[]
            {
                (Node: row.StartNodeID, Arc: row.FID),
                (Node: row.EndNodeID, Arc: row.FID)
            })
            .Where(item => item.Node.HasValue)
            .GroupBy(item => item.Node.GetValueOrDefault())
            .Select(group => new { Node = group.Key, ArcIDs = group.Select(item => item.Arc).Distinct().OrderBy(fid => fid).ToArray() })
            .First(group => group.ArcIDs.Length >= 2);
        GeometryTopologyArcPointsSnapshot pointRows = await ModelEditorAdapter.LoadGeometryTopologyArcPointsAsync(
            new GeometryTopologyArcPointsRequest(new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath),
                baseline.Revision, baseline.DraftState, arcs[0].FID));
        GeometryTopologyArcPoint internalPoint = pointRows.Rows.Single(row => row.PointKind == "internal");
        int internalPointIndex = internalPoint.InternalPointIndex
            ?? throw new InvalidDataException("The retained ArcPoints internal row omitted its source index.");
        string manifest = JsonSerializer.Serialize(new
        {
            fixtureVersion = "round23-topology-tools-v1",
            projectRelativePath = Path.GetRelativePath(sourceDirectory, projectPath),
            projectSHA256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(projectPath))),
            geometryRelativePath = Path.GetRelativePath(sourceDirectory, assetPath),
            geometrySHA256 = baseline.Revision,
            geometryName = "Topology tools geometry",
            arcFIDs = arcs.Select(row => row.FID).ToArray(),
            controlPointFIDs = regions.Select(row => row.FID).ToArray(),
            nodeFIDs = nodes.Select(row => row.FID).ToArray(),
            sharedEndpointNodeFID = sharedEndpoint.Node,
            sharedEndpointArcFIDs = sharedEndpoint.ArcIDs,
            internalPointArcFID = arcs[0].FID,
            internalPointIndex,
            filterTagNames = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["category"] = CategoryTag,
                ["phase"] = PhaseTag,
                ["integer"] = IntegerTag,
                ["float"] = FloatTag,
                ["flag"] = FlagTag,
                ["regionKind"] = RegionTag
            },
            recipeControlPointFIDs = regions.Take(2).Select(row => row.FID).ToArray()
        }, BackendJson.Options);
        File.WriteAllText(Path.Combine(destination, "manifest.json"), manifest, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private static async Task Expect<TException>(Func<Task> action) where TException : Exception
    {
        try { await action(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
