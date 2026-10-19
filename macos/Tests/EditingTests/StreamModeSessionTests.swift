import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct StreamModeSessionTests {
    @Test
    func cancellationAndLateFramesKeepConnectionIdentity() {
        var store = StreamModeFrameIdentityStore()
        let firstConnection = UUID()
        store.begin(firstConnection)

        let acceptedFirstFrame = store.accept(frame(sequence: 0), operationID: firstConnection)
        #expect(acceptedFirstFrame)
        #expect(store.mapObjects.count == 1)
        let cancelledFirstConnection = store.cancel(firstConnection)
        #expect(cancelledFirstConnection)
        let acceptedLateFirstFrame = store.accept(frame(sequence: 1), operationID: firstConnection)
        #expect(!acceptedLateFirstFrame)

        let secondConnection = UUID()
        store.begin(secondConnection)
        let acceptedPriorConnectionFrame = store.accept(frame(sequence: 1), operationID: firstConnection)
        #expect(!acceptedPriorConnectionFrame)
        let acceptedSecondFrame = store.accept(frame(sequence: 0), operationID: secondConnection)
        #expect(acceptedSecondFrame)
        #expect(store.mapObjects.count == 1)
        #expect(store.mapObjects[0].operationID == secondConnection)
        #expect(store.mapObjects[0].id == secondConnection.uuidString + ":0")
    }

    @Test
    func rejectsMalformedGeometryBeforeItReachesTheMapCanvas() {
        var store = StreamModeFrameIdentityStore()
        let connection = UUID()
        store.begin(connection)
        let malformed = BackendStreamModeFrame(sequence: 0, objectType: "Polyline",
            coordinateCount: 2,
            coordinates: [BackendStreamModeCoordinate(x: 1, y: 2)],
            paths: [[0, 1]], triangles: [], isClosed: false)

        let acceptedMalformedFrame = store.accept(malformed, operationID: connection)
        #expect(!acceptedMalformedFrame)
        #expect(store.mapObjects.isEmpty)
    }

    @Test
    func retainsTINProfileZAndMReadSamples() {
        var store = StreamModeFrameIdentityStore()
        let connection = UUID()
        store.begin(connection)
        let tin = BackendStreamModeFrame(sequence: 0, objectType: "Tin", coordinateCount: 3,
            coordinates: [BackendStreamModeCoordinate(x: 0, y: 0, z: 100.25, m: -2),
                          BackendStreamModeCoordinate(x: 10, y: 0, z: 101.5, m: 0),
                          BackendStreamModeCoordinate(x: 0, y: 10, z: 102.75, m: 2)],
            paths: [], triangles: [[0, 1, 2]], isClosed: false,
            hasZ: true, hasM: true, zFillValue: nil, mFillValue: nil)

        let acceptedTINFrame = store.accept(tin, operationID: connection)
        #expect(acceptedTINFrame)
        #expect(store.mapObjects.first?.source.hasZ == true)
        #expect(store.mapObjects.first?.source.hasM == true)
        #expect(store.mapObjects.first?.source.coordinates[2].z == 102.75)
        #expect(store.mapObjects.first?.source.triangles == [[0, 1, 2]])
    }

    private func frame(sequence: Int64) -> BackendStreamModeFrame {
        BackendStreamModeFrame(sequence: sequence, objectType: "Polyline",
            coordinateCount: 2,
            coordinates: [BackendStreamModeCoordinate(x: 10, y: 20),
                          BackendStreamModeCoordinate(x: 30, y: 40)],
            paths: [[0, 1]], triangles: [], isClosed: false)
    }
}
