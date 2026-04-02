// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SwiftPorscheConnect",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "SwiftPorscheConnect", targets: ["SwiftPorscheConnect"]),
    ],
    targets: [
        .target(
            name: "SwiftPorscheConnect",
            path: "Sources/SwiftPorscheConnect"
        ),
        .testTarget(
            name: "SwiftPorscheConnectTests",
            dependencies: ["SwiftPorscheConnect"],
            path: "Tests/SwiftPorscheConnectTests"
        ),
    ]
)
