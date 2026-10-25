// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickDeck",
            path: "Sources/QuickDeck"
        )
    ]
)
