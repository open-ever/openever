// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "openever",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "openever", targets: ["OpenEver"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/open-ever/ever-liteclient-swift", from: "1.0.0"),
        .package(url: "https://github.com/open-ever/ever-tl-swift", from: "1.0.0"),
        .package(url: "https://github.com/nerzh/adnl-swift", from: "1.1.1"),
        .package(url: "https://github.com/open-ever/everscale-sdk-swift", from: "1.0.0"),
        .package(url: "https://github.com/nerzh/swift-extensions-pack", from: "2.10.0"),
        .package(url: "https://github.com/bytehubio/BigInt", from: "6.0.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.98.0"),
    ],
    targets: [
        .executableTarget(name: "OpenEver", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "EverLiteClient", package: "ever-liteclient-swift"),
            .product(name: "EverLiteClientTL", package: "ever-liteclient-swift"),
            .product(name: "EverTL", package: "ever-tl-swift"),
            .product(name: "EverscaleSdkSwift", package: "everscale-sdk-swift"),
            .product(name: "BigInt", package: "BigInt"),
            .product(name: "SwiftExtensionsPack", package: "swift-extensions-pack")
        ], plugins: [
            .plugin(name: "GitVersionPlugin")
        ]),
        .testTarget(name: "OpenEverTests", dependencies: [
            "OpenEver",
            .product(name: "adnl-swift", package: "adnl-swift"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")
        ]),
        .plugin(name: "GitVersionPlugin", capability: .buildTool())
    ]
)
