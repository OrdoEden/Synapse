// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Synapse",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Synapse", targets: ["Synapse"])],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", exact: "5.11.1")
    ],
    targets: [
        .target(name: "Synapse", dependencies: ["Alamofire"]),
        .testTarget(name: "SynapseTests", dependencies: ["Synapse"])
    ]
)
