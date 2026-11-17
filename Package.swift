// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InterviewCopilot",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "InterviewCopilot",
            path: "Sources/InterviewCopilot",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
