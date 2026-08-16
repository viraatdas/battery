// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryScope",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BatteryCore", targets: ["BatteryCore"]),
        .executable(name: "batteryscoped", targets: ["batteryscoped"]),
        .executable(name: "BatteryScopeApp", targets: ["BatteryScopeApp"]),
    ],
    targets: [
        .target(name: "BatteryCore"),
        .executableTarget(
            name: "batteryscoped",
            dependencies: ["BatteryCore"]
        ),
        .executableTarget(
            name: "BatteryScopeApp",
            dependencies: ["BatteryCore"]
        ),
        .testTarget(
            name: "BatteryCoreTests",
            dependencies: ["BatteryCore"]
        ),
        .testTarget(
            name: "BatteryscopedTests",
            dependencies: ["batteryscoped"]
        ),
        .testTarget(
            name: "BatteryScopeAppTests",
            dependencies: ["BatteryScopeApp"]
        ),
    ]
)
