// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Flua",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Flua", targets: ["Flua"])],
    targets: [
        .executableTarget(name: "Flua", linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
            .linkedFramework("AVFoundation"), .linkedFramework("QuartzCore"),
            .linkedFramework("IOKit"), .linkedFramework("ServiceManagement"),
            .linkedFramework("UniformTypeIdentifiers"), .linkedFramework("CoreImage")
        ])
    ],
    swiftLanguageVersions: [.v5]
)
