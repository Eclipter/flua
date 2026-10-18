import AppKit
import SwiftUI

@main struct FocusTests {
    final class FocusClearView: NSView {
        private var closeObserver: Any?
        private var becomeKeyObserver: Any?
        private var mouseMonitor: Any?

        override var canBecomeKeyView: Bool { false }
        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            cleanObservers()
            guard let window = self.window else { return }
            clearFocus(in: window)

            becomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.clearFocus(in: window)
            }

            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                window?.makeFirstResponder(nil)
            }

            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                if let window = self?.window, event.window == window {
                    DispatchQueue.main.async { [weak window] in
                        guard let window else { return }
                        if !(window.firstResponder is NSTextView) {
                            window.makeFirstResponder(nil)
                        }
                    }
                }
                return event
            }
        }

        private func clearFocus(in window: NSWindow) {
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                if !(window.firstResponder is NSTextView) {
                    window.makeFirstResponder(nil)
                }
            }
        }

        private func cleanObservers() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            if let becomeKeyObserver {
                NotificationCenter.default.removeObserver(becomeKeyObserver)
                self.becomeKeyObserver = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }

        deinit {
            cleanObservers()
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
        let textView = NSTextView(frame: NSRect(x: 20, y: 100, width: 120, height: 30))
        content.addSubview(clearView)
        content.addSubview(control)
        content.addSubview(textView)
        window.contentView = content
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

        print("PASS: keyboard-only focus navigation: initial window focus suppression, single tab target, mouse focus reset, and Tab-triggered focus")
    }
}
