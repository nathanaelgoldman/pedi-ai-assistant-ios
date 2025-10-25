// swift-tools-version: 5.10
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
        // Explicitly point at the Sources/PediaShared folder
        .target(
            name: "PediaShared",
            path: "Sources/PediaShared"
        )
    ]
)
