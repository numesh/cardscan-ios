// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CardScanKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "CardScanKit", targets: ["CardScanKit"])],
    targets: [
        .target(name: "CardScanKit"),
        .testTarget(name: "CardScanKitTests", dependencies: ["CardScanKit"])
    ]
)
