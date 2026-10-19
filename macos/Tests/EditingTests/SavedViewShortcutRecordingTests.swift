import AppKit
import Testing
@testable import HECRAS2025

@MainActor
struct SavedViewShortcutRecordingTests {
    @Test func retainedVirtualKeyNamesSurviveNativeConversion() throws {
        for key in ["Number0", "A", "Space", "Enter", "Tab", "Back", "Delete", "Up", "PageDown", "F1", "F24"] {
            let shortcut = try #require(ViewShortcut.decode("Control+" + key))
            #expect(ViewShortcut.decode(shortcut.wireValue)?.wireValue == shortcut.wireValue)
            _ = shortcut.keyboardShortcut
        }
        #expect(ViewShortcut.decode("Win+Number1")?.wireValue == ViewShortcut.decode("Command+1")?.wireValue)
        #expect(ViewShortcut.decode("Alt+A")?.wireValue == ViewShortcut.decode("Menu+A")?.wireValue)
        #expect(ViewShortcut.decode("Control+Shift+A") == nil)
        #expect(ViewShortcut.decode("F25") == nil)
    }

    @Test func recordingUsesUnmodifiedKeyAndPreservesSourceModifierFormat() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "å", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(ViewShortcut.recording(event)?.wireValue == "Menu+A")
        let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .function], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{f700}", charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126))
        #expect(ViewShortcut.recording(arrow)?.wireValue == "Control+Up")
        let chord = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "A", charactersIgnoringModifiers: "A", isARepeat: false, keyCode: 0))
        #expect(ViewShortcut.recording(chord) == nil)
    }
}
