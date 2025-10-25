// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PediaShared",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PediaShared",
            targets: ["PediaShared"]
        )
    ],
    targets: [
        .target(
            name: "PediaShared",
            resources: [
                // Put shared CSV/PDF templates/etc. under Sources/PediaCore/Resources
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PediaSharedTests",
            dependencies: ["PediaShared"]
        )
    ]
)
