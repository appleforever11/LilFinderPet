// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LilFinderPet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LilFinderPet", targets: ["LilFinderPet"])
    ],
    targets: [
        .executableTarget(
            name: "LilFinderPet",
            path: "Sources/LilFinderPet",
            resources: [.copy("Resources")]
        )
    ]
)
