// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "M0Probe",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "M0Probe", path: "Sources/M0Probe")
    ]
)
