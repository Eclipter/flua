// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Flua",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "Flua", targets: ["Flua"])],
    targets: [
        .executableTarget(name: "Flua", resources: [.process("Resources"), .copy("ScenePreview.metal")], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
            .linkedFramework("MetalKit"), .linkedFramework("AVFoundation"), .linkedFramework("QuartzCore"),
            .linkedFramework("IOKit"), .linkedFramework("ServiceManagement"),
            .linkedFramework("UniformTypeIdentifiers"), .linkedFramework("CoreImage"),
            // Swift Build searches an Xcode Developer tree that Command Line Tools do not ship.
            .unsafeFlags(["-Xlinker", "-w"])
        ])
    ],
    swiftLanguageVersions: [.v5]
)
