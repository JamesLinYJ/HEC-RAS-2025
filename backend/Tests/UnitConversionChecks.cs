using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class UnitConversionChecks
{
    internal static async Task Run()
    {
        // NIST SP 811, Appendix B.8: mbar -> Pa 100; ft -> m .3048;
        // in -> m .0254. Retain the source's rounded mmHg factor 133.322.
        Check(Near(AirPressure.MilliBars.ConvertTo(AirPressure.Pascals, 1013.25), 101325), "Millibar pressure converts to its physical Pascal value");
        Check(Near(AirPressure.Pascals.ConvertTo(AirPressure.MilliBars, 101325), 1013.25), "Pascal pressure converts back to millibars");
        Check(Near(AirPressure.MillimeterMercury.ConvertTo(AirPressure.Pascals, 760), 760 * 133.322)
            && Near(AirPressure.Pascals.ConvertTo(AirPressure.MillimeterMercury, 760 * 133.322), 760), "Mercury pressure source conversions are reciprocal");
        Check(ReferenceEquals(AirPressure.TryParse("mbar"), AirPressure.MilliBars) && ReferenceEquals(AirPressure.TryParse("hPa"), AirPressure.MilliBars), "Common gridded pressure metadata aliases use the same actual source unit");
        Check(Near(Length.Feet.ConvertTo(Length.Meters, 1), .3048) && Near(Length.Meters.ConvertTo(Length.Feet, .3048), 1)
            && Near(Length.Inches.ConvertTo(Length.Millimeters, 1), 25.4) && Near(Length.Kilometers.ConvertTo(Length.Meters, 1), 1000), "Source station height conversions use exact international length definitions");
        using var temporary = new TemporaryDirectory();
        foreach (var system in new[] { UnitSystem.SI, UnitSystem.USCustomary })
        {
            string projectPath = Path.Combine(temporary.FullName, system + ".ras");
            var project = Project.CreateNew(projectPath, system);
            var boundary = project.AddNewBoundaryCondition("单位" + system, new DateTime(2026, 10, 16, 8, 0, 0), TimeSpan.FromHours(1));
            project.Save(); string filename = boundary.Filename; boundary.Dispose();
            byte[] before = File.ReadAllBytes(filename);
            var data = (await ModelEditorAdapter.LoadAsync(new(filename, "Boundary Conditions", projectPath))).Boundary!.Spatial!;
            Check(data["precipitation"].ValueUnits.SourceId == (system == UnitSystem.SI ? "mm/hr" : "in/hr") && data["wind"].ValueUnits.SourceId == "m/s"
                && data["airPressure"].ValueUnits.SourceId == "mb" && data["airDensity"].ValueUnits.SourceId == "kg/m3", "Display unit families match actual source storage conventions");
            Check(data["precipitation"].HeightUnits.SourceId == (system == UnitSystem.SI ? "m" : "ft"), "Station heights retain owning project length units");
            Check(data["precipitation"].DefaultHeight == (system == UnitSystem.SI ? 20 : 70)
                && Near(data["precipitation"].IntervalUnits.Choices.Single(unit => unit.Id == Time.Hours.Name).Scale * 3600, 1),
                "Height defaults and time interval unit options retain original source definitions");
            var pressure = data["airPressure"].ValueUnits.Choices.Single(unit => unit.Id == "Pa");
            Check(pressure.Scale == 100 && pressure.Offset == 0, "Backend advertises corrected source pressure display coefficients");
            var speed = data["wind"].ValueUnits.Choices.Single(unit => unit.Id == "ft/s");
            Check(Near(speed.Scale * .3048, 1) && speed.Offset == 0, "Wind display conversion coefficients come from the source converter");
            var precip = data["precipitation"].ValueUnits.Choices.Single(unit => unit.Id == "mm/s");
            Check(Near(precip.Scale * 3600, system == UnitSystem.SI ? 1 : 25.4), "SI and US precipitation rates share correct period conversion");
            Check(File.ReadAllBytes(filename).SequenceEqual(before), "Reading unit options does not rewrite source HDF values or metadata");
        }
        Console.WriteLine("Physical source pressure/length conversions, SI/US display families and unchanged HDF checks passed.");
    }
    private static bool Near(double a, double b) => Math.Abs(a - b) <= Math.Max(1, Math.Abs(b)) * 1e-12;
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
