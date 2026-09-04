// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClickSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClickSwitch",
            path: "Sources/ClickSwitch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
