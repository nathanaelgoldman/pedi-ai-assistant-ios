// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PediaShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PediaShared", targets: ["PediaShared"])
    ],
    targets: [
        .target(
            name: "PediaShared",
            path: "Sources/PediaShared",
            resources: [
                // Everything under Sources/PediaShared/Resources will be bundled
                .process("Resources")
            ]
        )
    ]
)
