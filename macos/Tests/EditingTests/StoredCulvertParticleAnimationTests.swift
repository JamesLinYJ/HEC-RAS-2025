import Foundation
import Testing
@testable import HECRAS2025

struct StoredCulvertParticleAnimationTests {
    @Test
    func liveParticlesContinueAfterManyTravelPeriodsWithoutTotalSpawnIntConversion() {
        let barrel = straightBarrel(from: 0, to: 100)
        let frames = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: 1, outletVelocity: 1, maxAbsoluteFlow: 1,
            elapsed: 1e300, cellSize: 1, velocityScalar: 25)

        #expect(frames.count == 4)
        #expect(frames.map { $0.position.x } == [0, 25, 50, 75])
        #expect(frames.allSatisfy { !$0.isZeroFlow })
    }

    @Test
    func reverseFlowStartsAtTheSourceEndpointAndMovesBackAlongTheBarrel() {
        let barrel = straightBarrel(from: 0, to: 100)
        let frames = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: -1, outletVelocity: 1, maxAbsoluteFlow: 1,
            elapsed: 20, cellSize: 1, velocityScalar: 25)

        #expect(frames.map { $0.position.x } == [100, 75, 50, 25])
    }

    @Test
    func onlyParticlesWhoseSpawnIntervalHasElapsedAreIncluded() {
        let barrel = straightBarrel(from: 0, to: 100)
        let justBeforeFirst = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: 1, outletVelocity: 0.25, maxAbsoluteFlow: 1,
            elapsed: 3.999, cellSize: 3, velocityScalar: 25)
        let first = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: 1, outletVelocity: 0.25, maxAbsoluteFlow: 1,
            elapsed: 4, cellSize: 3, velocityScalar: 25)
        let justBeforeSecond = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: 1, outletVelocity: 0.25, maxAbsoluteFlow: 1,
            elapsed: 7.999, cellSize: 3, velocityScalar: 25)
        let second = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: 1, outletVelocity: 0.25, maxAbsoluteFlow: 1,
            elapsed: 8, cellSize: 3, velocityScalar: 25)

        #expect(justBeforeFirst.isEmpty)
        #expect(first.count == 1)
        #expect(first[0].position.x == 0)
        #expect(justBeforeSecond.count == 1)
        #expect(second.count == 2)
        #expect(second.map { $0.position.x } == [0, 25])
    }

    @Test
    func zeroFlowUsesTheSourceMidpointMarkerAndZeroSpeedCohortStaysVisible() {
        let barrel = straightBarrel(from: 0, to: 100)
        let zeroFlow = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: 0, outletVelocity: 0, maxAbsoluteFlow: 1,
            elapsed: 0, cellSize: 1, velocityScalar: 25)
        #expect(zeroFlow.count == 1)
        #expect(zeroFlow[0].position.x == 50)
        #expect(zeroFlow[0].isZeroFlow)

        let notSpawned = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: 1, outletVelocity: 0, maxAbsoluteFlow: 1,
            elapsed: 0.49, cellSize: 1, velocityScalar: 25)
        #expect(notSpawned.isEmpty)

        let stationary = StoredCulvertParticleAnimation.frame(
            barrel: barrel, flow: 1, outletVelocity: 0, maxAbsoluteFlow: 1,
            elapsed: 20, cellSize: 1, velocityScalar: 25)
        #expect(stationary.count == 1)
        #expect(stationary[0].position.x == 0)
        #expect(!stationary[0].isZeroFlow)
    }

    private func straightBarrel(from start: Double, to end: Double) -> MapResultCulvertBarrel {
        MapResultCulvertBarrel(id: "barrel:source:0", sourceOrdinal: 0, name: "Barrel",
            coordinates: [MapResultCulvertCoordinate(x: start, y: 0),
                          MapResultCulvertCoordinate(x: end, y: 0)],
            barrelPropertyName: "Barrel Properties", upstreamInvert: "0",
            downstreamInvert: "0", upstreamOpeningName: "Opening",
            downstreamOpeningName: "Opening")
    }
}
