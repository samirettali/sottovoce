// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sottovoce",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device ASR: Parakeet TDT v3 on CoreML / Apple Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "Sottovoce",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Sottovoce"
        )
    ]
)
