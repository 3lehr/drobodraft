// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "drobo_kern",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DroboKern", targets: ["DroboKern"]),
        .executable(name: "drobo", targets: ["drobo"]),
    ],
    targets: [
        .target(name: "DroboKern", linkerSettings: [.linkedFramework("DiskArbitration"), .linkedFramework("IOKit")]),
        .executableTarget(name: "drobo", dependencies: ["DroboKern"]),
        .testTarget(name: "DroboKernTests", dependencies: ["DroboKern"]),
    ]
)
