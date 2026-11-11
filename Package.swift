// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ip-switcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IPSwitcherCore", targets: ["IPSwitcherCore"]),
        .executable(name: "IPSwitcher", targets: ["IPSwitcherApp"]),
        .executable(name: "ipswctl", targets: ["ipswctl"]),
    ],
    targets: [
        .target(name: "IPSwitcherCore", path: "Sources/IPSwitcherCore"),
        .executableTarget(
            name: "IPSwitcherApp",
            dependencies: ["IPSwitcherCore"],
            path: "Sources/IPSwitcherApp"
        ),
        .executableTarget(
            name: "ipswctl",
            dependencies: ["IPSwitcherCore"],
            path: "Sources/ipswctl"
        ),
    ]
)
