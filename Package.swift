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
        // Extension architecture (option B, decision doc 496a85fe): the ONLY
        // module in-tree extension targets may depend on. Pure protocols and
        // value types — NO app-side dependencies (system AppKit only); the
        // app target implements Host. Future extension targets
        // (MemtermClaudeBrowser, MemtermTimeline) declare dependencies:
        // ["MemtermExtensionKit"] and NOTHING else — that dependency list IS
        // the import firewall (compiler-enforced; re-checked in CI by
        // scripts/check-extension-firewall.sh).
        .target(
            name: "MemtermExtensionKit",
            path: "Sources/MemtermExtensionKit"
        ),
        // First kit consumer (stage 3): the Claude Sessions browser. Its
        // dependency list — the kit and NOTHING else — IS the import
        // firewall; scripts/check-extension-firewall.sh asserts it stays so.
        .target(
            name: "MemtermClaudeBrowser",
            dependencies: ["MemtermExtensionKit"],
            path: "Sources/MemtermClaudeBrowser"
        ),
        .executableTarget(
            name: "memterm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "CProcShim",
                "MemtermCore",
                "MemtermExtensionKit",
                "MemtermClaudeBrowser"
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
        ),
        // Kit contract tests: the Host surface against a mock implementation
        // (pins the API shape and the archive-stub contract).
        .testTarget(
            name: "MemtermExtensionKitTests",
            dependencies: ["MemtermExtensionKit"],
            path: "Tests/MemtermExtensionKitTests"
        ),
        // Claude-browser extension tests: pure model logic (grouping,
        // filtering, badge planning) + the extension's host-call traffic
        // against a recording mock — headless, no app involved.
        .testTarget(
            name: "MemtermClaudeBrowserTests",
            dependencies: ["MemtermClaudeBrowser", "MemtermExtensionKit"],
            path: "Tests/MemtermClaudeBrowserTests"
        )
    ]
)
