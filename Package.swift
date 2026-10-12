// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenEver",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "openever", targets: ["OpenEver"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(path: "../ever-liteclient-swift"),
        .package(path: "../ever-tl-swift"),
        .package(path: "../everscale-sdk-swift"),
        .package(path: "../adnl-swift"),
        .package(url: "https://github.com/bytehubio/BigInt", from: "6.0.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.98.0"),
        .package(url: "https://github.com/nerzh/swift-extensions-pack", from: "2.10.0")
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
        ]),
        .testTarget(name: "OpenEverTests", dependencies: [
            "OpenEver",
            .product(name: "adnl-swift", package: "adnl-swift"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")
        ])
    ]
)
