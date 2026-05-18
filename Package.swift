// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "SmartAccessCore",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "SmartAccessCore",
            targets: ["SmartAccessCore"]
        )
    ],
    targets: [
        .target(
            name: "SmartAccessCore",
            path: "Sources/SmartAccessCore"
        ),
        .testTarget(
            name: "SmartAccessCoreTests",
            dependencies: ["SmartAccessCore"],
            path: "Tests/SmartAccessCoreTests"
        )
    ]
)
