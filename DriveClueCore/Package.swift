// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DriveClueCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DriveClueCore", targets: ["DriveClueCore"]),
        .executable(name: "DriveClueProbe", targets: ["DriveClueProbe"])
    ],
    targets: [
        .target(
            name: "CSMART",
            path: "Sources/CSMART",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "DriveClueCore",
            dependencies: ["CSMART"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "DriveClueProbe",
            dependencies: ["DriveClueCore"]
        ),
        .testTarget(
            name: "DriveClueCoreTests",
            dependencies: ["DriveClueCore"]
        )
    ]
)
