using System.Text.Json;
using Ras.Backend;
using Utility.Units;

internal static class UnitCalculatorChecks
{
    internal static void Run()
    {
        var catalog = UnitCalculatorService.Load(new(null));
        var fromFeet = catalog.FromUnits.Single(unit => unit.UnitTypeName == nameof(Length) && unit.Name == Length.Feet.Name);
        var source = UnitCalculatorService.Load(new(fromFeet.Id));
        Check(source.FromUnitName == Length.Feet.Name && source.UnitTypeName == nameof(Length), "The selected source unit remains locked and identifies its original family");
        Check(source.ToUnits.Select(unit => unit.Name).SequenceEqual(BaseUnitType.GetAvailableTypesBase(typeof(Length)).Select(unit => unit.Name)),
            "Target choices are the original BaseUnitType family members");
        Check(source.ToUnits.All(unit => unit.UnitTypeName == nameof(Length)), "Target choices exclude incompatible source types");

        var meters = source.ToUnits.Single(unit => unit.Name == Length.Meters.Name);
        double converted = UnitCalculatorService.Convert(new(fromFeet.Id, meters.Id, 1, UnitCalculatorDirection.FromTo)).Value;
        Check(Math.Abs(converted - .3048) < 1e-12, "Forward conversion calls the source BaseUnitType converter");
        double reversed = UnitCalculatorService.Convert(new(fromFeet.Id, meters.Id, converted, UnitCalculatorDirection.ToFrom)).Value;
        Check(Math.Abs(reversed - 1) < 1e-12, "Reverse conversion uses the target source unit to recover the source value");

        var emptySource = UnitCalculatorService.Load(new(string.Empty));
        Check(emptySource.FromUnitId is null && emptySource.ToUnits.Length == 0,
            "An empty source selection loads the unit picker without resolving an invalid identifier");

        string numericDirectionJSON = JsonSerializer.Serialize(new
        {
            fromUnitId = fromFeet.Id,
            toUnitId = meters.Id,
            value = 1d,
            direction = 999
        }, BackendJson.Options);
        var numericDirection = JsonSerializer.Deserialize<UnitCalculatorConvertRequest>(numericDirectionJSON, BackendJson.Options)
            ?? throw new InvalidOperationException("Unit calculator numeric direction request was empty.");
        try
        {
            UnitCalculatorService.Convert(numericDirection);
            throw new InvalidOperationException("Unit calculator accepted an unsupported conversion direction.");
        }
        catch (ArgumentOutOfRangeException)
        {
            // Numeric JSON enum payloads are validated after deserialization.
        }

        string stringDirectionJSON = JsonSerializer.Serialize(new
        {
            fromUnitId = fromFeet.Id,
            toUnitId = meters.Id,
            value = 1d,
            direction = "sideways"
        }, BackendJson.Options);
        try
        {
            JsonSerializer.Deserialize<UnitCalculatorConvertRequest>(stringDirectionJSON, BackendJson.Options);
            throw new InvalidOperationException("Unit calculator accepted an unsupported string direction.");
        }
        catch (JsonException)
        {
            // The enum converter rejects unknown string values during protocol decoding.
        }

        var flow = catalog.FromUnits.First(unit => unit.UnitTypeName == nameof(Flow));
        var flowTarget = UnitCalculatorService.Load(new(flow.Id)).ToUnits[0];
        try
        {
            UnitCalculatorService.Convert(new(fromFeet.Id, flowTarget.Id, 1, UnitCalculatorDirection.FromTo));
        }
        catch (ArgumentException)
        {
            Console.WriteLine("Source-backed unit calculator options and bidirectional conversion checks passed.");
            return;
        }

        throw new InvalidOperationException("Unit calculator accepted units from different source families.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
