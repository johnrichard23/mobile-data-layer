// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DataLayer",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DataLayer", targets: ["DataLayer"]),
    ],
    targets: [
        .target(name: "DataLayer"),
        .testTarget(name: "DataLayerTests", dependencies: ["DataLayer"]),
    ]
)
