import Foundation

struct LibraryWindowLaunchPolicy {
    static let openedLibraryMarker = "hasOpenedMaximizedLibraryWindow"
    static let verificationArguments: Set<String> = [
        "--smoke-test", "--startup-smoke", "--scroll-benchmark",
        "--accessibility-audit", "--preview-smoke", "--fullscreen-chrome"
    ]
    static let current: LibraryWindowLaunchPolicy = {
        let arguments = ProcessInfo.processInfo.arguments
        let isVerificationLaunch = Self.isVerificationLaunch(arguments: arguments)
        return LibraryWindowLaunchPolicy(defaults: .standard, isVerificationLaunch: isVerificationLaunch)
    }()

    static func isVerificationLaunch(arguments: [String]) -> Bool {
        arguments.contains { verificationArguments.contains($0) }
    }

    let needsInitialPlacement: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults, isVerificationLaunch: Bool) {
        self.defaults = defaults
        needsInitialPlacement = !isVerificationLaunch && defaults.object(forKey: Self.openedLibraryMarker) == nil
    }

    func prepareInitialPlacement(clearSavedFrame: () -> Void) {
        guard needsInitialPlacement else { return }
        clearSavedFrame()
    }

    func markLibraryWindowPresented() {
        guard needsInitialPlacement else { return }
        defaults.set(true, forKey: Self.openedLibraryMarker)
    }
}
