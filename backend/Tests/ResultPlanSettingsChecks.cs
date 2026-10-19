using System.Security.Cryptography;
using System.Text.Json;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

/// <summary>
/// Verifies the read-only Plan Settings endpoint against the actual Plan HDF
/// embedded by Result.PrepareResult, including description and image bytes.
/// </summary>
internal static class ResultPlanSettingsChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Nested Result Plan settings.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        string resultPath;
        string planPath;
        string geometryPath;
        string boundaryPath;
        const string planName = "Source Plan";
        const string planDescription = "Description stored in the embedded Result Plan.";
        const string imageName = "plan-image.png";
        const string imageDescription = "Original plan image.";
        byte[] imageBytes = Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6LkAAAAASUVORK5CYII=");
        try
        {
            Terrain terrain = project.AddNewTerrain("Terrain");
            NValueLayer nValues = project.AddNewNValueLayer("Manning n");
            Geometry geometry = project.AddNewGeometry("Embedded Geometry", terrain, nValues);
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Embedded Boundary",
                new DateTime(2026, 10, 19), TimeSpan.FromHours(2));
            Plan plan = project.AddNewPlan(planName, geometry, boundary);
            plan.Description = planDescription;
            EmbeddedImage image = plan.EmbeddedImages.Add(imageName, imageDescription, imageBytes);
            image.X = 12.5;
            image.Y = -4.25;
            foreach (CoreLayerBase layer in Layers(project)) layer.Save();
            project.Save();

            planPath = plan.Filename;
            geometryPath = geometry.Filename;
            boundaryPath = boundary.Filename;
            resultPath = project.GetUniqueResultFilename(plan.Name);
            using (Result prepared = Result.PrepareResult(resultPath, plan, geometry, boundary, null!))
                Check(File.Exists(prepared.Filename), "The retained Result writer creates the selected Result HDF.");

            // The project Plan may later diverge. Plan Settings for a Result
            // must still read only the Plan snapshot stored in that Result.
            plan.Description = "Changed project Plan description.";
            plan.Save();
            project.Save();
        }
        finally { DisposeProject(project); }

        string projectXml = XElement.Load(projectPath).ToString(SaveOptions.DisableFormatting);
        string expectedResultName = Path.GetFileNameWithoutExtension(resultPath);
        using (var writer = new H5Assist.H5Writer(resultPath))
        {
            writer.CreateGroup("/Result Plan Untouched");
            writer.WriteDataset("/Result Plan Untouched/Values", new double[] { 1.25, -2.5, 8.75 });
        }
        string[] protectedPaths = [projectPath, resultPath, planPath, geometryPath, boundaryPath];
        byte[][] before = protectedPaths.Select(File.ReadAllBytes).ToArray();
        string revision = Hash(resultPath);

        ResultPlanSettingsSnapshot snapshot = await ResultPlanSettingsService.InspectAsync(
            new ResultPlanSettingsRequest(projectPath, projectXml, resultPath, revision));
        Check(SourceFilePaths.SameSourceFile(snapshot.ProjectPath, projectPath)
            && SourceFilePaths.SameSourceFile(snapshot.ResultPath, resultPath)
            && snapshot.Revision == revision && snapshot.ResultName == expectedResultName
            && snapshot.HasPlan && snapshot.PlanName == planName,
            "The endpoint returns the exact selected saved Result and its nested Plan identity.");
        Check(snapshot.PlanDescription == planDescription
            && snapshot.GeometryName == "Embedded Geometry"
            && snapshot.BoundaryConditionName == "Embedded Boundary",
            "Description and associations come from the embedded Plan after its project Plan has changed.");
        ResultPlanEmbeddedImage copiedImage = snapshot.Images.Single();
        Check(copiedImage.Id == "/Plan Data/Images/" + imageName
            && copiedImage.Name == imageName && copiedImage.Description == imageDescription
            && copiedImage.X == 12.5 && copiedImage.Y == -4.25
            && copiedImage.ByteCount == imageBytes.LongLength
            && copiedImage.Data.SequenceEqual(imageBytes),
            "Image dataset identity, metadata, byte count and original HDF bytes are preserved in the read-only response.");
        CheckUnchanged(protectedPaths, before);

        const string editedDescription = "Edited embedded Result Plan description.";
        const string addedImageName = "Added image";
        const string addedImageDescription = "Imported from /fixture/Added image.png";
        const string addedImageDate = "2026-10-19 11:22:33";
        byte[] addedImageBytes = Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6LkAAAAASUVORK5CYII=");
        ResultPlanSettingsImageDraft[] editImages = snapshot.Images.Select(image =>
            new ResultPlanSettingsImageDraft(image.Id, image.Name, image.Description,
                image.DateLastModified, image.X, image.Y, image.Data))
            .Append(new ResultPlanSettingsImageDraft("draft:" + Guid.NewGuid().ToString("N"),
                addedImageName, addedImageDescription, addedImageDate, 0, 0, addedImageBytes))
            .ToArray();
        ResultPlanSettingsSaveReceipt saved = await ResultPlanSettingsService.SaveAsync(
            new ResultPlanSettingsSaveRequest(projectPath, projectXml, snapshot.ProjectRevision,
                resultPath, snapshot.Revision, planName, editedDescription, editImages));
        ResultPlanEmbeddedImage appended = saved.Snapshot.Images.Single(image => image.Name == addedImageName);
        Check(SourceFilePaths.SameSourceFile(saved.ResultPath, resultPath)
            && saved.PreviousRevision == revision && saved.Revision != revision
            && saved.PlanName == planName && saved.PlanDescription == editedDescription,
            "The parent-save receipt identifies the exact edited Result revision and embedded Plan.");
        Check(saved.Snapshot.PlanDescription == editedDescription
            && saved.Snapshot.Images.Length == 2
            && saved.Snapshot.GeometryName == snapshot.GeometryName
            && saved.Snapshot.BoundaryConditionName == snapshot.BoundaryConditionName
            && JsonSerializer.Serialize(saved.Snapshot.EmbeddedPlanGroups)
                == JsonSerializer.Serialize(snapshot.EmbeddedPlanGroups)
            && saved.Snapshot.Images.Single(image => image.Name == imageName).Data.SequenceEqual(imageBytes)
            && appended.Id == "/Plan Data/Images/" + addedImageName
            && appended.Description == addedImageDescription
            && appended.DateLastModified == addedImageDate
            && appended.X == 0 && appended.Y == 0
            && appended.Data.SequenceEqual(addedImageBytes),
            "The staged parent save updates Description, retains the original image metadata/bytes, and appends the selected image.");
        using (var reader = new H5Assist.H5Reader(resultPath))
        {
            reader.ReadDataset("/Result Plan Untouched/Values", out double[] untouchedValues);
            Check(untouchedValues.SequenceEqual(new double[] { 1.25, -2.5, 8.75 }),
                "Saving the embedded Plan preserves unrelated Result HDF datasets.");
        }
        Check(File.ReadAllBytes(projectPath).SequenceEqual(before[0])
            && File.ReadAllBytes(planPath).SequenceEqual(before[2])
            && File.ReadAllBytes(geometryPath).SequenceEqual(before[3])
            && File.ReadAllBytes(boundaryPath).SequenceEqual(before[4]),
            "The nested Result Plan save leaves the project, source Plan, Geometry and Boundary Condition untouched.");

        byte[] committedResult = File.ReadAllBytes(resultPath);
        await Expect<SourceFileChangedException>(() => ResultPlanSettingsService.SaveAsync(
            new ResultPlanSettingsSaveRequest(projectPath, projectXml, snapshot.ProjectRevision,
                resultPath, snapshot.Revision, planName, editedDescription, editImages)));
        Check(File.ReadAllBytes(resultPath).SequenceEqual(committedResult),
            "A stale Result Plan draft is rejected without modifying the committed Result.");
        await Expect<SourceFileChangedException>(() => ResultPlanSettingsService.SaveAsync(
            new ResultPlanSettingsSaveRequest(projectPath, projectXml, new string('0', snapshot.ProjectRevision.Length),
                resultPath, saved.Revision, planName, editedDescription, saved.Snapshot.Images.Select(image =>
                    new ResultPlanSettingsImageDraft(image.Id, image.Name, image.Description,
                        image.DateLastModified, image.X, image.Y, image.Data)).ToArray())));
        Check(File.ReadAllBytes(resultPath).SequenceEqual(committedResult),
            "A stale project editor context is rejected without modifying the Result.");

        ResultPlanSettingsImageDraft[] missingOriginalImage = saved.Snapshot.Images
            .Where(image => image.Name == addedImageName)
            .Select(image => new ResultPlanSettingsImageDraft(image.Id, image.Name,
                image.Description, image.DateLastModified, image.X, image.Y, image.Data)).ToArray();
        await Expect<ArgumentException>(() => ResultPlanSettingsService.SaveAsync(
            new ResultPlanSettingsSaveRequest(projectPath, projectXml, saved.Snapshot.ProjectRevision,
                resultPath, saved.Revision, planName, editedDescription, missingOriginalImage)));
        Check(File.ReadAllBytes(resultPath).SequenceEqual(committedResult),
            "An edit cannot remove an existing image because the retained source surface only adds images.");

        await Expect<SourceFileChangedException>(() => ResultPlanSettingsService.InspectAsync(
            new ResultPlanSettingsRequest(projectPath, projectXml, resultPath, new string('0', revision.Length))));
        await Expect<ArgumentException>(() => ResultPlanSettingsService.InspectAsync(
            new ResultPlanSettingsRequest(projectPath, projectXml, planPath, Hash(planPath))));
        Check(File.ReadAllBytes(projectPath).SequenceEqual(before[0])
            && File.ReadAllBytes(planPath).SequenceEqual(before[2])
            && File.ReadAllBytes(geometryPath).SequenceEqual(before[3])
            && File.ReadAllBytes(boundaryPath).SequenceEqual(before[4]),
            "Stale and invalid requests leave the non-Result source files unchanged.");

        Console.WriteLine("Embedded Result Plan description and images read and parent-saved through a staged Result HDF transaction.");
    }

    private static IEnumerable<CoreLayerBase> Layers(Project project) => project.Plans.Cast<CoreLayerBase>()
        .Concat(project.Geometries).Concat(project.Terrains).Concat(project.BoundaryConditions)
        .Concat(project.NValues).Concat(project.ClassificationLayers);

    private static void DisposeProject(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in Layers(project)) layer.Dispose();
    }

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void CheckUnchanged(string[] paths, byte[][] before)
    {
        for (int index = 0; index < paths.Length; index++)
            Check(File.ReadAllBytes(paths[index]).SequenceEqual(before[index]),
                "Read-only Result Plan inspection must not change " + Path.GetFileName(paths[index]) + ".");
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
