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
            name: "ChromeScriptingGlue",
            path: "Sources/ChromeScriptingGlue",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("ScriptingBridge")]
        ),
        .target(
            name: "DesktopOperatorCore",
            dependencies: ["ChromeScriptingGlue"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Security"),
                .linkedFramework("ScriptingBridge")
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
