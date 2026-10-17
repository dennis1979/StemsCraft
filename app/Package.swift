// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stems",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 from: "1.24.2"),
    ],
    targets: [
        .target(
            name: "StemsCore",
            dependencies: [
                .product(name: "onnxruntime",
                         package: "onnxruntime-swift-package-manager"),
            ]
        ),
        .executableTarget(
            name: "StemsCLI",
            dependencies: ["StemsCore"]
        ),
        .executableTarget(
            name: "StemsApp",
            dependencies: ["StemsCore"]
        ),
        .executableTarget(
            name: "StemsDebug",
            dependencies: ["StemsCore"]
        ),
    ]
)
