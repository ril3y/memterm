// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "memterm",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        // libproc has no Swift module; tiny C wrappers for kernel-truth capture.
        .target(
            name: "CProcShim",
            path: "Sources/CProcShim"
        ),
        // Pure logic (config, state store, adapters, restore helpers) —
        // AppKit-free so it is testable headlessly.
        .target(
            name: "MemtermCore",
            dependencies: ["CProcShim"],
            path: "Sources/MemtermCore"
        ),
        .executableTarget(
            name: "memterm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "CProcShim",
                "MemtermCore"
            ],
            path: "Sources/memterm"
        ),
        .testTarget(
            name: "MemtermCoreTests",
            dependencies: ["MemtermCore"],
            path: "Tests/MemtermCoreTests"
        )
    ]
)
