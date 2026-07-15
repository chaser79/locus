// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "locus",
    platforms: [
        .iOS("14.0"),
    ],
    products: [
        .library(name: "locus", targets: ["locus"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "locus",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            exclude: [
                "LocusPlugin.h",
                "LocusPlugin.m",
            ],
            swiftSettings: [
                .define("LOCUS_SWIFT_PACKAGE"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
