// swift-tools-version:5.9
import PackageDescription
import Foundation

// Single source of truth for the Swift package. The `Iroh` xcframework binary
// is resolved one of two ways, chosen at manifest-evaluation time:
//
//   * a locally built xcframework, when this is a source checkout that has
//     actually been built (`cargo make swift-xcframework` / `test-swift`).
//     This is what local dev, CI, and source consumers (e.g. an app pointing
//     at a local clone) get — so the binding always matches the source.
//   * otherwise (git-URL / Swift Package Index consumers): the pinned,
//     prebuilt xcframework zip attached to a GitHub release.
//
// Presence is keyed on the macOS slice's static lib. The whole xcframework
// directory is gitignored (build artifact only — Apple regenerates it from
// cargo-built static frameworks via `xcodebuild -create-xcframework`),
// so a fresh consumer checkout has nothing local to find and falls through
// to the release zip. Set IROH_FORCE_REMOTE_XCFRAMEWORK to force the release
// zip even in a built checkout.
//
// The fork deliberately keeps the last published artifact selected until its
// first fork asset exists. `cargo make prepare-swift-fork-release <V>` changes
// both repository and tag on an isolated release branch. CI then bakes the
// asset checksum there; that commit is tagged and published before it is
// merged, so the default branch never names a missing or draft-only asset.
let releaseRepository = "manaflow-ai/iroh-ffi"
let releaseTag = "v1.0.2-cmux.9-dev.1"
let releaseChecksum = "5902af2a8f45612959aedd2a1623f5f7e8e1f27326f9676221c3d9896a4a0ca7"

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localBuiltBinaries = [
    "Iroh.xcframework/macos-arm64_x86_64/Iroh.framework/Versions/A/Iroh",
    "Iroh.xcframework/macos-x86_64_arm64/Iroh.framework/Versions/A/Iroh",
    // Continue recognizing locally built artifacts from before Intel support.
    "Iroh.xcframework/macos-arm64/Iroh.framework/Versions/A/Iroh",
].map { packageDir.appendingPathComponent($0) }
let forceRemote = ProcessInfo.processInfo.environment["IROH_FORCE_REMOTE_XCFRAMEWORK"] != nil
let useLocalXcframework = !forceRemote
    && localBuiltBinaries.contains { FileManager.default.fileExists(atPath: $0.path) }

let irohBinary: Target = useLocalXcframework
    ? .binaryTarget(
        name: "Iroh",
        path: "Iroh.xcframework")
    : .binaryTarget(
        name: "Iroh",
        url: "https://github.com/\(releaseRepository)/releases/download/\(releaseTag)/IrohLib.xcframework.zip",
        checksum: releaseChecksum)

let package = Package(
    name: "IrohLib",
    platforms: [
        .iOS("17.5"),
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "IrohLib",
            targets: ["IrohLib", "Iroh"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "IrohLib",
            dependencies: [
                .byName(name: "Iroh")
            ],
            path: "IrohLib/Sources/IrohLib",
            linkerSettings: [
              .linkedFramework("SystemConfiguration"),
              // iroh's netdev uses Network.framework for interface enumeration
              // (the nw_* / nw_path_monitor_* symbols) on Apple platforms.
              .linkedFramework("Network"),
              // iroh's netwatch queries WiFi interfaces via CoreWLAN on macOS.
              .linkedFramework("CoreWLAN", .when(platforms: [.macOS]))
            ]),
        irohBinary,
        .testTarget(
            name: "IrohLibTests",
            dependencies: ["IrohLib"],
            path: "IrohLib/Tests/IrohLibTests"),
    ]
)
