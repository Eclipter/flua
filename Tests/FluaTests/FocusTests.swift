import AppKit
import SwiftUI

@main struct FocusTests {
    final class FocusClearView: NSView {
        private var closeObserver: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            guard let window = self.window else { return }
            window.initialFirstResponder = self
            DispatchQueue.main.async { [weak window] in
                if !(window?.firstResponder is NSTextView) {
                    window?.makeFirstResponder(nil)
                }
            }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                window?.makeFirstResponder(nil)
            }
        }

        deinit {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
        }
    }

    static func main() {
        let app = NSApplication.shared
        _ = app

        // 1. Verify segmented picker single tab target logic
        let choices = [("All", "all"), ("Animated", "animated"), ("Still", "still")]
        func isTabTarget(selection: String, value: String) -> Bool {
            (selection == value) || (!choices.contains(where: { $0.1 == selection }) && choices.first?.1 == value)
        }
        precondition(isTabTarget(selection: "animated", value: "animated") == true)
        precondition(isTabTarget(selection: "animated", value: "all") == false)
        precondition(isTabTarget(selection: "animated", value: "still") == false)
        precondition(isTabTarget(selection: "nonexistent", value: "all") == true)
        precondition(isTabTarget(selection: "nonexistent", value: "animated") == false)

        final class FocusableControl: NSControl {
            override var canBecomeKeyView: Bool { true }
            override var acceptsFirstResponder: Bool { true }
        }

        // 2. Verify FocusClearView clears initial focus on window open
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let clearView = FocusClearView()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let control = FocusableControl(frame: NSRect(x: 20, y: 200, width: 120, height: 30))
        content.addSubview(clearView)
        content.addSubview(control)
        window.contentView = content
        window.recalculateKeyViewLoop()

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        precondition(window.firstResponder is NSWindow, "Window must not have focused controls upon entering")

        // 3. Verify keyboard navigation (Tab / selectNextKeyView) focuses the control
        window.selectNextKeyView(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(window.firstResponder === control, "Keyboard navigation via Tab must focus the control")

        // 4. Verify closing the window resets first responder so re-entering does not retain focus
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(window.firstResponder is NSWindow, "Closing window must reset first responder")

        print("PASS: keyboard-only focus navigation: initial window focus suppression, single tab target, and Tab-triggered focus")
    }
}
