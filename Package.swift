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
        .library(name: "PorscheConnect", targets: ["PorscheConnect"]),
    ],
    targets: [
        .target(
            name: "PorscheConnect",
            path: "Sources/PorscheConnect"
        ),
        .testTarget(
            name: "PorscheConnectTests",
            dependencies: ["PorscheConnect"],
            path: "Tests/PorscheConnectTests"
        ),
    ]
)
