import Foundation

extension BackgroundMapSettings {
    init(visualOptions: [String: String]) throws {
        self.init()
        func boolean(_ key: String, default fallback: Bool) throws -> Bool {
            guard let raw = visualOptions[key] else { return fallback }
            guard let value = Bool(raw.lowercased()) else {
                throw BackgroundMapSettingsError.invalid
            }
            return value
        }
        areBackgroundMapsOn = try boolean("AreBackgroundMapsOn", default: areBackgroundMapsOn)
        isOpenStreetMapOn = try boolean("UseOSM", default: isOpenStreetMapOn)
        isSatelliteImageryOn = try boolean("UseSatellite", default: isSatelliteImageryOn)
        isShadedReliefOn = try boolean("UseHillshade", default: isShadedReliefOn)
        showLabels = try boolean("OsmShowLabels", default: showLabels)
        if let value = visualOptions["OsmStyle"] { osmStyle = value }
        if let value = visualOptions["OsmDensity"] {
            guard let parsed = Int(value), (-1...5).contains(parsed) else { throw BackgroundMapSettingsError.invalid }
            density = parsed
        }
        if let value = visualOptions["SatelliteOpacity"] {
            guard let parsed = UInt8(value) else { throw BackgroundMapSettingsError.invalid }
            satelliteOpacity = Double(parsed) / 255
        }
    }

    var visualOptions: [String: String] {
        ["AreBackgroundMapsOn": String(areBackgroundMapsOn), "UseOSM": String(isOpenStreetMapOn),
         "UseSatellite": String(isSatelliteImageryOn), "UseHillshade": String(isShadedReliefOn),
         "OsmStyle": osmStyle, "OsmDensity": String(density), "OsmShowLabels": String(showLabels),
         "SatelliteOpacity": String(Int((min(max(satelliteOpacity, 0), 1) * 255).rounded()))]
    }
}

private enum BackgroundMapSettingsError: LocalizedError {
    case invalid
    var errorDescription: String? { "The saved background map settings are invalid." }
}
