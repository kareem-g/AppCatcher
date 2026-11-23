// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppCatcher",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "AppCatcher",
            targets: ["AppCatcher"]
        ),
    ],
    targets: [
        // worse_query + pathleak (Taj C / forcequit, GPLv3+): the container
        // query that issues kernel sandbox extensions onto other apps'
        // containers. See Core/Services/OtherAppsService.swift for use.
        .target(name: "WorseQuery"),
        .target(
            name: "AppCatcher",
            dependencies: ["WorseQuery"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
