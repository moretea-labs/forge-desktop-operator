// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgeDesktopOperator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DesktopOperatorCore", targets: ["DesktopOperatorCore"]),
        .executable(name: "desktop-operator", targets: ["DesktopOperator"])
    ],
    targets: [
        .target(
            name: "DesktopOperatorCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "DesktopOperator",
            dependencies: ["DesktopOperatorCore"]
        ),
        .testTarget(
            name: "DesktopOperatorCoreTests",
            dependencies: ["DesktopOperatorCore"]
        )
    ]
)
