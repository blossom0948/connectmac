// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneBridgeMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PhoneBridgeMac", targets: ["PhoneBridgeMac"])
    ],
    targets: [
        .executableTarget(name: "PhoneBridgeMac")
    ]
)
