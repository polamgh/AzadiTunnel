// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AzadiTunnelAdaptiveTransport",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [],
    targets: [
        .target(
            name: "AdaptiveTransportPolicy",
            path: "AzadiTunnelShared",
            sources: [
                "AdaptiveTransportPolicy.swift",
                "AppGroupConstants.swift",
                "ConnectionDiagnostics.swift",
                "NetworkProfile.swift"
            ]
        ),
        .testTarget(
            name: "AdaptiveTransportPolicyTests",
            dependencies: ["AdaptiveTransportPolicy"],
            path: "Tests",
            sources: ["AdaptiveTransportPolicyTests.swift"]
        )
    ]
)
