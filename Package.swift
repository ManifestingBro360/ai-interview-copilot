// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "InterviewCopilot",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "InterviewCopilot", path: "Sources")],
    swiftLanguageModes: [.v5]
)
