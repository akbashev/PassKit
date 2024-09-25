// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PassKit",
    platforms: [
        .macOS(.v13), .iOS(.v16)
    ],
    products: [
      .library(
        name: "PassKit",
        targets: ["PassKit"]
      ),
    ],
    dependencies: [
      .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
      .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
      .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "PassKit",
            dependencies: [
              .product(name: "Crypto", package: "swift-crypto"),
              .product(name: "NIOCore", package: "swift-nio"),
              .product(name: "NIOFoundationCompat", package: "swift-nio"),
              .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "PassKitTests",
            dependencies: ["PassKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
