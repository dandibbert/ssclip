// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSClip",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SSClip", targets: ["SSClip"])
    ],
    targets: [
        .executableTarget(
            name: "SSClip",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(name: "SSClipTests", dependencies: ["SSClip"])
    ],
    swiftLanguageModes: [.v5]
)
