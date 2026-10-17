import AppKit

@main struct AccentColorTests {
    static func main() throws {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--verify-accent"), args.indices.contains(index + 1),
           let choice = AppAccent(rawValue: args[index + 1]) {
            precondition(choice.color == choice.color, "Accent identity must remain stable between view updates")
            for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let expected = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
                    let actual = choice.nativeColor.usingColorSpace(.sRGB)!
                    for (a, b) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent],
                                      [expected.redComponent, expected.greenComponent, expected.blueComponent]) {
                        precondition(abs(a - b) < 0.5 / 255, "\(choice.rawValue) differs from the native accent in \(name.rawValue)")
                    }
                    precondition(!choice.swatch.isTemplate)
                }
            }
            return
        }
        let choices: [(AppAccent, String)] = [(.blue, "4"), (.purple, "5"), (.pink, "6"), (.red, "0"),
                                              (.orange, "1"), (.yellow, "2"), (.green, "3"), (.gray, " -1")]
        for (choice, value) in choices {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            // Launch arguments override only this disposable process, not saved user preferences.
            process.arguments = ["--verify-accent", choice.rawValue, "-AppleAccentColor", value,
                                 "-AppleAquaColorVariant", choice == .gray ? "6" : "1"]
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Native accent check failed: \(choice.rawValue)")
        }
        print("PASS: all eight macOS accent colors match AppKit in light, dark and high-contrast appearances")
    }
}
