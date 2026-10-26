import Foundation

@main struct LibraryWindowLaunchPolicyTests {
    static func main() {
        let suiteName = "FluaLibraryWindowLaunchPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = LibraryWindowLaunchPolicy(defaults: defaults, isVerificationLaunch: false)
        precondition(firstLaunch.needsInitialPlacement)
        var clearedFrames = 0
        firstLaunch.prepareInitialPlacement { clearedFrames += 1 }
        precondition(clearedFrames == 1)
        firstLaunch.markLibraryWindowPresented()
        precondition(defaults.bool(forKey: LibraryWindowLaunchPolicy.openedLibraryMarker))
        precondition(firstLaunch.needsInitialPlacement, "the launch snapshot must stay unchanged after the marker is written")

        let laterLaunch = LibraryWindowLaunchPolicy(defaults: defaults, isVerificationLaunch: false)
        precondition(!laterLaunch.needsInitialPlacement)
        laterLaunch.prepareInitialPlacement { clearedFrames += 1 }
        precondition(clearedFrames == 1, "later launches must keep the saved frame")
        laterLaunch.markLibraryWindowPresented()
        precondition(defaults.bool(forKey: LibraryWindowLaunchPolicy.openedLibraryMarker))

        for argument in LibraryWindowLaunchPolicy.verificationArguments {
            precondition(LibraryWindowLaunchPolicy.isVerificationLaunch(arguments: [argument]))
        }
        precondition(!LibraryWindowLaunchPolicy.isVerificationLaunch(arguments: ["Flua", "--data-dir", "/tmp/flua-library"]))
        let verificationSuite = "FluaLibraryWindowVerificationPolicyTests.\(UUID().uuidString)"
        let verificationDefaults = UserDefaults(suiteName: verificationSuite)!
        defer { verificationDefaults.removePersistentDomain(forName: verificationSuite) }
        let verification = LibraryWindowLaunchPolicy(defaults: verificationDefaults, isVerificationLaunch: true)
        precondition(!verification.needsInitialPlacement)
        verification.prepareInitialPlacement { clearedFrames += 1 }
        precondition(clearedFrames == 1, "verification launches must not clear the saved frame")
        verification.markLibraryWindowPresented()
        precondition(verificationDefaults.object(forKey: LibraryWindowLaunchPolicy.openedLibraryMarker) == nil)

        print("PASS: initial frame clears once; first-session geometry can save; verification launches leave state untouched")
    }
}
