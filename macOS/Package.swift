// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneBridgeMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PhoneBridgeMac", targets: ["PhoneBridgeMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "PhoneBridgeMac",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
