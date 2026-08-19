// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "IrohFFIConsumerSmoke",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "IrohFFIConsumerSmoke",
            targets: ["IrohFFIConsumerSmoke"]
        ),
    ],
    dependencies: [
        // The verification script stages the FFI checkout and the freshly
        // built XCFramework beside this manifest. This keeps the fixture
        // independent of the FFI repository's own test target.
        .package(path: "iroh-ffi"),
    ],
    targets: [
        .executableTarget(
            name: "IrohFFIConsumerSmoke",
            dependencies: [
                .product(name: "IrohLib", package: "iroh-ffi"),
            ]
        ),
    ]
)
