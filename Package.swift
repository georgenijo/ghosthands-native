// swift-tools-version: 6.0
import PackageDescription

// GhostHands (native) — a model-agnostic, honesty-first macOS computer-use core.
// Hands act through the Accessibility tree (cursor-less, background-safe) and
// EVERY action is verified by reading the world back — no hardcoded success.
//
// Built on AXorcist (MIT, github.com/steipete/AXorcist). See ATTRIBUTION.md.

let package = Package(
    name: "GhostHands",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ghosthands", targets: ["ghosthands"]),
        .executable(name: "ghosthands-mcp", targets: ["ghosthands-mcp"]),
        .library(name: "GhostHandsKit", targets: ["GhostHandsKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/AXorcist.git", exact: "0.1.2"),
    ],
    targets: [
        // The hands core: resolve → find → act → verify (honesty lives here).
        .target(
            name: "GhostHandsKit",
            dependencies: [
                .product(name: "AXorcist", package: "AXorcist"),
            ],
            path: "Sources/GhostHandsKit",
            linkerSettings: [
                // `shot` captures via ScreenCaptureKit (macOS 14+); CoreGraphics
                // /ImageIO come transitively, but the SCK framework is linked
                // explicitly so the capture symbols resolve.
                .linkedFramework("ScreenCaptureKit"),
            ]),

        // The CLI: `ghosthands click "<name>" <app>` — hand-rolled arg parse.
        .executableTarget(
            name: "ghosthands",
            dependencies: ["GhostHandsKit"],
            path: "Sources/ghosthands"),

        // The MCP server: exposes the same verbs over MCP-over-stdio (JSON-RPC
        // 2.0, newline-delimited) so any external brain can drive the Mac. No
        // MCP SDK dep — JSON-RPC is hand-rolled with Foundation. ScreenCaptureKit
        // reaches this exe transitively through GhostHandsKit.
        .executableTarget(
            name: "ghosthands-mcp",
            dependencies: ["GhostHandsKit"],
            path: "Sources/ghosthands-mcp"),

        // Hermetic unit tests — no live app driving.
        .testTarget(
            name: "GhostHandsKitTests",
            dependencies: ["GhostHandsKit"],
            path: "Tests/GhostHandsKitTests"),
    ],
    swiftLanguageModes: [.v5])
