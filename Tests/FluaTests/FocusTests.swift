import AppKit

@main struct FocusTests {
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent("scripts/system-test-lock.py")
        let check = Process()
        check.executableURL = helper
        check.arguments = ["--is-locked"]
        try check.run()
        check.waitUntilExit()
        if check.terminationStatus != 0 {
            let locked = Process()
            locked.executableURL = helper
            locked.arguments = ["focus verification", URL(fileURLWithPath: CommandLine.arguments[0]).path] + CommandLine.arguments.dropFirst()
            try locked.run()
            locked.waitUntilExit()
            exit(locked.terminationStatus)
        }
        let app = NSApplication.shared
        _ = app

        // 1. Verify segmented picker single tab target logic
        let choices = [("All", "all"), ("Animated", "animated"), ("Still", "still")]
        for selection in ["all", "animated", "still"] {
            precondition(segmentedPickerTabTarget(selection: selection, choices: choices) == selection)
        }
        precondition(segmentedPickerTabTarget(selection: "nonexistent", choices: choices) == "all")
        precondition(segmentedPickerTabTarget(selection: "all", choices: []) == nil)

        let optionalChoices: [(String, String?)] = [("Mixed", nil), ("Animated", "animated"), ("Still", "still")]
        let mixedTarget = segmentedPickerTabTarget(selection: String?.none, choices: optionalChoices)
        precondition(mixedTarget == .some(nil), "A selected nil value must remain a tab target")
        precondition(optionalChoices.filter { mixedTarget == $0.1 }.map(\.0) == ["Mixed"])
        let animatedTarget = segmentedPickerTabTarget(selection: String?.some("animated"), choices: optionalChoices)
        precondition(optionalChoices.filter { animatedTarget == $0.1 }.map(\.0) == ["Animated"])

        final class FocusableControl: NSControl {
            override var canBecomeKeyView: Bool { true }
            override var acceptsFirstResponder: Bool { true }
        }

        // 2. Verify FocusClearView clears initial focus on window open
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        weak var configuredWindow: NSWindow?
        let clearView = FocusClearView { configuredWindow = $0 }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let control = FocusableControl(frame: NSRect(x: 20, y: 200, width: 120, height: 30))
        let textView = NSTextView(frame: NSRect(x: 20, y: 100, width: 120, height: 30))
        content.addSubview(clearView)
        content.addSubview(control)
        content.addSubview(textView)
        window.contentView = content
        precondition(configuredWindow === window, "Attaching the view must configure its window")
        window.recalculateKeyViewLoop()

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        precondition(window.firstResponder is NSWindow, "Window must not have focused controls upon entering")

        // 3. Verify keyboard navigation (Tab / selectNextKeyView) focuses the control
        window.selectNextKeyView(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(window.firstResponder === control, "Keyboard navigation via Tab must focus the control")

        // 4. Verify mouse click resets focus back to NSWindow when non-text control is focused
        let clickEvent = NSEvent.mouseEvent(with: .leftMouseDown,
                                            location: NSPoint(x: 10, y: 10),
                                            modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber,
                                            context: nil,
                                            eventNumber: 1,
                                            clickCount: 1,
                                            pressure: 1.0)!
        app.sendEvent(clickEvent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(window.firstResponder is NSWindow, "Mouse interaction must clear control focus outline")

        // 5. Verify mouse click does not clear focus when an NSTextView has first responder
        window.makeFirstResponder(textView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(window.firstResponder === textView, "NSTextView must receive first responder")
        app.sendEvent(clickEvent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(window.firstResponder === textView, "Mouse interaction must preserve NSTextView focus")

        // 6. Verify closing the window resets first responder so re-entering does not retain focus
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(window.firstResponder is NSWindow, "Closing window must reset first responder")

        var removals = 0
        clearView.onDelete = { removals += 1; return true }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: (target ?? window).windowNumber, context: nil,
                            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        window.makeFirstResponder(nil)
        precondition(clearView.handleDelete(key(51)), "Backspace must remove a selected wallpaper with window focus")
        precondition(clearView.handleDelete(key(117)), "Forward Delete must use the same confirmation path")
        precondition(removals == 2)
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            precondition(!clearView.handleDelete(key(51, flags: modifier)))
        }
        precondition(!clearView.handleDelete(key(0)), "Other keys must remain untouched")
        window.makeFirstResponder(textView)
        precondition(!clearView.handleDelete(key(51)), "Text editing must keep Delete")
        window.makeFirstResponder(nil)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        precondition(!clearView.handleDelete(key(51, in: otherWindow)), "Other windows must keep their Delete events")
        precondition(removals == 2, "Rejected events must not invoke removal")
        clearView.onDelete = { false }
        precondition(!clearView.handleDelete(key(51)), "A missing or hidden selection must leave Delete unhandled")

        print("PASS: keyboard-only focus navigation: initial window focus suppression, single tab target, mouse focus reset, and Tab-triggered focus")
    }
}
