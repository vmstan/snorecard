// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SnorecardKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "SnorecardKit", targets: ["SnorecardKit"]),
        .executable(name: "snorecard-probe", targets: ["SnorecardProbe"])
    ],
    targets: [
        .target(
            name: "SnorecardKit",
            path: "Sources/SnorecardKit"
        ),
        .executableTarget(
            name: "SnorecardProbe",
            dependencies: ["SnorecardKit"],
            path: "Sources/SnorecardProbe"
        )
    ]
)
