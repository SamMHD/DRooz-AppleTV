// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DroozKit",
    defaultLocalization: "fa",
    platforms: [.tvOS(.v17), .macOS(.v14), .iOS(.v17)],
    products: [.library(name: "DroozKit", targets: ["DroozKit"])],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "DroozKit", dependencies: ["SwiftSoup"]),
        .testTarget(
            name: "DroozKitTests",
            dependencies: ["DroozKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
