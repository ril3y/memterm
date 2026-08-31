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
        .executableTarget(
            name: "memterm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "CProcShim"
            ],
            path: "Sources/memterm"
        )
    ]
)
