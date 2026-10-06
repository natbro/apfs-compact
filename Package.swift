// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "apfs-compact",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "apfs-compact", targets: ["apfs-compact"]),
    ],
    targets: [
        .target(name: "CApfs"),
        .target(name: "ApfsCompactCore", dependencies: ["CApfs"]),
        .executableTarget(name: "apfs-compact", dependencies: ["ApfsCompactCore"]),
        .testTarget(name: "ApfsCompactTests", dependencies: ["ApfsCompactCore", "CApfs"]),
    ]
)
