using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.BoundaryConditions;
using Utility.Units;

internal static class BoundaryLineMapChecks
{
    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Boundary Map.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        BoundaryCondition boundary = project.AddNewBoundaryCondition("Map Boundary", new DateTime(2026, 10, 16, 8, 0, 0), TimeSpan.FromHours(1));
        var sourceLines = new[]
        {
            boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(12.5, -3.25), new(18.75, 4.5), new(22, 9) })),
            boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(-7, 2), new(-2, 6) }))
        };
        sourceLines[0].Name = "North reach";
        sourceLines[1].Name = "South reach";
        project.Save();
        string sourceAsset = boundary.Filename;
        boundary.Dispose();

        string fixtureDirectory = Path.Combine(temporary.FullName, "fixture-copy");
        Directory.CreateDirectory(fixtureDirectory);
        string copiedAsset = Path.Combine(fixtureDirectory, Path.GetFileName(sourceAsset));
        File.Copy(sourceAsset, copiedAsset);

        ModelRequest request = new(copiedAsset, "Boundary Conditions", projectPath);
        ModelSnapshot first = await ModelEditorAdapter.LoadAsync(request);
        BoundaryLineData[] lines = first.Boundary?.Lines ?? throw new InvalidOperationException("The copied boundary HDF did not produce boundary-line data.");
        Check(lines.Length == sourceLines.Length, "The copied HDF exposes the actual ordered boundary features.");
        Check(lines.All(line => Guid.TryParseExact(line.Id, "N", out _)) && lines.Select(line => line.Id).Distinct(StringComparer.Ordinal).Count() == lines.Length,
            "Each source line receives its exact editor-state identity rather than a name-derived map key.");

        using (var copied = new BoundaryCondition(copiedAsset, project))
        {
            BoundaryConditionLine[] actualLines = copied.BoundaryConditionLines.Features.ToArray();
            Check(lines.All(line => line.Scope == "Boundary/" + line.Id),
                "Map geometry is paired with the existing stable boundary-line scope identity.");
            for (int index = 0; index < actualLines.Length; index++)
            {
                var expected = actualLines[index].Polyline?.Points.Select(point => (point.X, point.Y)).ToArray();
                var received = lines[index].Geometry?.Select(point => (point.X, point.Y)).ToArray();
                Check(expected != null && received != null && expected.SequenceEqual(received),
                    $"Boundary map geometry {index} comes from the copied HDF Polyline in source order.");
            }
        }

        ModelSnapshot repeated = await ModelEditorAdapter.LoadAsync(request with { SourceState = first.SourceState });
        Check(repeated.Boundary?.Lines.Select(line => line.Id).SequenceEqual(lines.Select(line => line.Id)) == true,
            "Opaque line selection IDs remain stable while the parent editor state is reused.");
        Console.WriteLine("Copied boundary HDF map geometry and editor-state line identities passed.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
