// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoStream",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PhotoStreamShared", targets: ["PhotoStreamShared"]),
        .executable(name: "PhotoStreamServer", targets: ["PhotoStreamServer"]),
    ],
    targets: [
        .target(
            name: "PhotoStreamShared",
            path: "Shared/Sources/PhotoStreamShared"
        ),
        .executableTarget(
            name: "PhotoStreamServer",
            dependencies: ["PhotoStreamShared"],
            path: "MacServer/Sources/PhotoStreamServer",
            exclude: [],
            linkerSettings: [
                .linkedFramework("Photos"),
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
