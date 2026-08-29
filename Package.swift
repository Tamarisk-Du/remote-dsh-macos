// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemoteDSHMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RemoteDSHCore", targets: ["RemoteDSHCore"]),
        .executable(name: "RemoteDSHApp", targets: ["RemoteDSHApp"]),
        .executable(name: "RemoteDSHTestRunner", targets: ["RemoteDSHTestRunner"])
    ],
    targets: [
        .target(
            name: "_Testing_Foundation",
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ]
        ),
        .target(name: "RemoteDSHCore"),
        .executableTarget(
            name: "RemoteDSHApp",
            dependencies: ["RemoteDSHCore"]
        ),
        .executableTarget(
            name: "RemoteDSHTestRunner",
            dependencies: ["RemoteDSHCore", "_Testing_Foundation"],
            path: "Tests/RemoteDSHCoreTests",
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ]),
                .linkedFramework("Testing")
            ]
        ),
        .testTarget(
            name: "RemoteDSHCoreTests",
            dependencies: ["RemoteDSHCore"],
            path: "Tests/RemoteDSHCoreSwiftPMTests"
        )
    ]
)
