import Foundation
import RASWorkspaceCore

struct StoredCulvertParticleFrame: Equatable, Sendable {
    let position: MapPoint
    let diameter: Double
    let isZeroFlow: Bool
}

/// Reproduces the retained CulvertBarrelAnimationManager's particle timing,
/// direction, zero-flow marker and point sizing over stored Result arrays.
/// It never derives or interpolates hydraulic values.
enum StoredCulvertParticleAnimation {
    struct Parameters: Equatable, Sendable {
        let pointSize: Int
        let travelSpeed: Double
        let reverses: Bool
        let zeroFlow: Bool
        let spawnSkipFactor: Int
        let spawnIntervalMilliseconds: Int
    }

    static func parameters(flow: Double, outletVelocity: Double, maxAbsoluteFlow: Double,
                           lineLength: Double, cellSize: Double,
                           velocityScalar: Double) -> Parameters {
        let absoluteFlow = abs(flow)
        let zeroFlow = absoluteFlow < 0.001
        let ratio: Double
        if !zeroFlow, maxAbsoluteFlow > 0, maxAbsoluteFlow.isFinite {
            ratio = sqrt(absoluteFlow) / sqrt(maxAbsoluteFlow)
        } else {
            ratio = 0
        }
        let safeCellSize = cellSize.isFinite && cellSize > 0 ? cellSize : 1
        let cellTerm = min((2 + ratio * 8) / safeCellSize, 33)
        let cellSizeTerm = Int(cellTerm.rounded(.toNearestOrEven))
        let ordinalTerm = 3 + Int((ratio * 5).rounded(.toNearestOrEven))
        let pointSize = zeroFlow ? 8 : min(max(cellSizeTerm, ordinalTerm), 32)
        let scalar = StoredCulvertProfileSession.clampVelocityScalar(velocityScalar)
        let speed = abs(outletVelocity) * scalar
        let interval: Int
        if speed > 0.001, speed.isFinite, lineLength.isFinite, lineLength > 0 {
            interval = Int(min(max(lineLength / speed * 1_000 / 4, 100), 2_000))
        } else {
            interval = 500
        }
        let skip = safeCellSize >= 3
            ? 2 + Int(floor(log2(safeCellSize / 3)))
            : 1
        return Parameters(pointSize: pointSize, travelSpeed: speed,
            reverses: flow < 0, zeroFlow: zeroFlow,
            spawnSkipFactor: max(skip, 1), spawnIntervalMilliseconds: interval)
    }

    static func frame(barrel: MapResultCulvertBarrel, flow: Double, outletVelocity: Double,
                      maxAbsoluteFlow: Double, elapsed: TimeInterval,
                      cellSize: Double, velocityScalar: Double) -> [StoredCulvertParticleFrame] {
        guard flow.isFinite, outletVelocity.isFinite,
              elapsed.isFinite, elapsed >= 0,
              let length = polylineLength(barrel.coordinates), length > 0 else { return [] }
        let parameters = parameters(flow: flow, outletVelocity: outletVelocity,
            maxAbsoluteFlow: maxAbsoluteFlow, lineLength: length,
            cellSize: cellSize, velocityScalar: velocityScalar)
        if parameters.zeroFlow {
            guard let midpoint = point(at: length / 2, on: barrel.coordinates) else { return [] }
            return [StoredCulvertParticleFrame(position: midpoint,
                diameter: Double(parameters.pointSize), isZeroFlow: true)]
        }

        let effectiveSpawnSeconds = Double(parameters.spawnIntervalMilliseconds
            * parameters.spawnSkipFactor) / 1_000
        guard effectiveSpawnSeconds > 0, effectiveSpawnSeconds.isFinite else { return [] }
        // CulvertFlowAnimation spawns after each interval and retains particles
        // until they travel past the other endpoint. Compute the most recent
        // particle ages from the interval phase instead of converting the
        // lifetime spawn count to Int: a map may remain open far longer than
        // Int can represent as a particle ordinal.
        guard elapsed >= effectiveSpawnSeconds else { return [] }
        let speed = parameters.travelSpeed
        guard speed.isFinite, speed >= 0 else { return [] }

        // With zero outlet speed, source particles remain at their spawn
        // endpoint indefinitely. They overlap exactly, so one opaque marker
        // has the same rendered result as retaining an unbounded stack.
        if speed == 0 {
            let endpoint = parameters.reverses ? length : 0
            guard let position = point(at: endpoint, on: barrel.coordinates) else { return [] }
            return [StoredCulvertParticleFrame(position: position,
                diameter: Double(parameters.pointSize), isZeroFlow: false)]
        }

        let phase = elapsed.truncatingRemainder(dividingBy: effectiveSpawnSeconds)
        guard phase.isFinite else { return [] }
        let oldestSpawnedAge = elapsed - effectiveSpawnSeconds
        guard oldestSpawnedAge >= 0 else { return [] }
        let visibleLifetime = length / speed
        guard visibleLifetime.isFinite || visibleLifetime == .infinity,
              phase < visibleLifetime else { return [] }

        // This cap bounds only the current rendered cohort. It is independent
        // of total elapsed spawns and always starts at the newest live age.
        let maximumRenderedParticles = 256
        var frames: [StoredCulvertParticleFrame] = []
        frames.reserveCapacity(maximumRenderedParticles)
        var age = phase
        while age <= oldestSpawnedAge && age < visibleLifetime
                && frames.count < maximumRenderedParticles {
            let travelDistance = age * speed
            guard travelDistance.isFinite, travelDistance < length else { break }
            let distance = parameters.reverses ? length - travelDistance : travelDistance
            guard let position = point(at: distance, on: barrel.coordinates) else { break }
            frames.append(StoredCulvertParticleFrame(position: position,
                diameter: Double(parameters.pointSize), isZeroFlow: false))
            let nextAge = age + effectiveSpawnSeconds
            // At extreme elapsed values, adding a sub-ULP interval can stop
            // changing a Double. Exit instead of looping forever.
            guard nextAge > age else { break }
            age = nextAge
        }
        return frames
    }

    static func polylineLength(_ points: [MapResultCulvertCoordinate]) -> Double? {
        guard points.count >= 2 else { return nil }
        var length = 0.0
        for pair in zip(points, points.dropFirst()) {
            length += hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
            guard length.isFinite else { return nil }
        }
        return length
    }

    private static func point(at distance: Double,
                              on points: [MapResultCulvertCoordinate]) -> MapPoint? {
        guard distance.isFinite, distance >= 0, points.count >= 2 else { return nil }
        var consumed = 0.0
        for pair in zip(points, points.dropFirst()) {
            let segment = hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
            guard segment.isFinite else { return nil }
            if segment > 0, consumed + segment >= distance {
                let fraction = min(max((distance - consumed) / segment, 0), 1)
                return MapPoint(x: pair.0.x + (pair.1.x - pair.0.x) * fraction,
                    y: pair.0.y + (pair.1.y - pair.0.y) * fraction)
            }
            consumed += segment
        }
        guard let last = points.last else { return nil }
        return MapPoint(x: last.x, y: last.y)
    }
}
