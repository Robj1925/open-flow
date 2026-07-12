// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenFlow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenFlowCore", targets: ["OpenFlowCore"]),
        .executable(name: "OpenFlow", targets: ["OpenFlowApp"]),
        .executable(name: "openflow-cli", targets: ["OpenFlowCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.0"),
    ],
    targets: [
        .target(
            name: "OpenFlowCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OpenFlowApp",
            dependencies: ["OpenFlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OpenFlowCLI",
            dependencies: ["OpenFlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tests are a plain executable (swift run openflow-tests) because the
        // Command Line Tools can't execute .xctest bundles; Swift Testing's
        // entry point is called directly instead. Framework search paths cover
        // both CLT and full-Xcode environments.
        .executableTarget(
            name: "openflow-tests",
            dependencies: ["OpenFlowCore"],
            path: "Tests/OpenFlowCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks",
                ]),
            ]
        ),
    ]
)
