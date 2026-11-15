// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FabricKit",
    platforms: [.macOS(.v15)],
    products: [
        // What iSCSIKit and NVMeKit share: the TCP transport (with interface
        // pinning), CRC32C, deadlines, big-endian wire helpers, and the block
        // device seam and session vocabulary both protocol engines report through.
        .library(name: "FabricKit", targets: ["FabricKit"]),
        // Building blocks for mock targets: a RAM disk, a TCP listener that
        // hands out transports, and fault switches. Test code only.
        .library(name: "FabricTestSupport", targets: ["FabricTestSupport"]),
    ],
    targets: [
        // CRC32C via the hardware instruction (arm64 / SSE4.2), with a
        // slice-by-8 fallback. C because Swift exposes no way to emit the
        // CRC32C instruction, and the digest covers every byte on the wire.
        .target(name: "CCRC32C"),
        // No policy and no side effects beyond the socket: everything here is
        // unit-testable, and MemoryPipe stands in for TCP in tests.
        .target(
            name: "FabricKit",
            dependencies: ["CCRC32C"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FabricTestSupport",
            dependencies: ["FabricKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FabricKitTests",
            dependencies: ["FabricKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FabricTestSupportTests",
            dependencies: ["FabricTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
