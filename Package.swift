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
            // SwiftTerm is here for the SCROLL UX stage's headless
            // Terminal-layer tests (SelectionScrollAnchoringTests): selection
            // coordinates must stay anchored to buffer content across
            // feed-driven scroll/trim, which is a SwiftTerm truth the AppKit
            // probe legs build on.
            dependencies: [
                "MemtermCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Tests/MemtermCoreTests"
        )
    ]
)
