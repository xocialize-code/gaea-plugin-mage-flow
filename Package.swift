// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-mage-flow: Microsoft's Mage-Flow family (MIT) as a Gaea research plugin. One worker executable built on
// GaeaPluginKit over mage-flow-swift, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// mage-inproc is not part of the plugin: it runs the same packages in-process through MLXServeEngine, with the same
// dependency resolution, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-mage-flow",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.3.0"),
        .package(url: "https://github.com/xocialize/mage-flow-swift.git", exact: "0.12.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.72.0"),
    ],
    targets: [
        .target(
            name: "MagePlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXMageFlow", package: "mage-flow-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-mage-flow-worker",
            dependencies: [
                "MagePlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "mage-inproc",
            dependencies: [
                "MagePlugin",
                .product(name: "MLXMageFlow", package: "mage-flow-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
