import Foundation
import Testing
@testable import HECRAS2025

@Suite struct WorkspaceLaunchConfigurationTests {
    @Test func parsesRetainedLaunchOptionsAndInitialRasArgument() {
        let configuration = WorkspaceLaunchConfiguration(arguments: [
            "/Applications/HEC-RAS 2025.app/Contents/MacOS/HECRAS2025",
            "/Projects/Reach.ras",
            "-safemode",
            "-stream=render-pipe",
            "-crashed",
            "--first-launch",
            "-debug"
        ])

        #expect(configuration.safeMode)
        #expect(configuration.streamPipeName == "render-pipe")
        #expect(configuration.hasStreamMode)
        #expect(configuration.initialProjectURL?.path == "/Projects/Reach.ras")
        #expect(configuration.postCrashLaunch)
        #expect(configuration.testFirstLaunch)
        #expect(configuration.debugMode)
    }

    @Test func malformedStreamSwitchIsStillAnExplicitStreamRequest() {
        let configuration = WorkspaceLaunchConfiguration(arguments: ["/app/HECRAS2025", "-stream="])
        #expect(configuration.hasStreamMode)
        #expect(configuration.streamPipeName == "")
        #expect(configuration.initialProjectURL == nil)
    }

    @Test func nonRasArgumentDoesNotBecomeAnInitialProject() {
        let configuration = WorkspaceLaunchConfiguration(arguments: ["/app/HECRAS2025", "/data/geometry.h5"])
        #expect(configuration.initialProjectURL == nil)
        #expect(!configuration.hasStreamMode)
    }
}
