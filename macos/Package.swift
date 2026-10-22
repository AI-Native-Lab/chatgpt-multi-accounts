// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChatGPTMultiAccounts",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "chatgpt-multi", targets: ["chatgpt-multi"]),
        .executable(name: "ChatGPTMultiAccounts", targets: ["ChatGPTMultiAccounts"]),
    ],
    targets: [
        .target(name: "MultiAccountsCore"),
        .executableTarget(name: "chatgpt-multi", dependencies: ["MultiAccountsCore"]),
        .executableTarget(name: "ChatGPTMultiAccounts", dependencies: ["MultiAccountsCore"]),
        .testTarget(name: "MultiAccountsCoreTests", dependencies: ["MultiAccountsCore"]),
    ]
)
