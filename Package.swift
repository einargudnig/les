// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LES",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "LES",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "LES",
            exclude: ["Info.plist", "LES.entitlements"],
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
