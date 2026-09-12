// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickTodo",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "QuickTodoCore"),
        .executableTarget(name: "QuickTodo", dependencies: ["QuickTodoCore"]),
        .testTarget(name: "QuickTodoTests", dependencies: ["QuickTodoCore"]),
    ]
)
