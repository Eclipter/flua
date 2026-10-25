import AppKit

func segmentedPickerTabTarget<Value: Hashable>(selection: Value, choices: [(String, Value)]) -> Value? {
    choices.contains(where: { $0.1 == selection }) ? selection : choices.first?.1
}

final class FocusClearView: NSView {
    private let configureWindow: (NSWindow) -> Void

    init(configureWindow: @escaping (NSWindow) -> Void) {
        self.configureWindow = configureWindow
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private var closeObserver: Any?
    private var becomeKeyObserver: Any?
    private var mouseMonitor: Any?

    override var canBecomeKeyView: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cleanObservers()
        guard let window = self.window else { return }
        configureWindow(window)
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
