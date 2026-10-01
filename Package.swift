// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MouseFix",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.3.2"),
    ],
    targets: [
        .target(
            name: "MouseFixHIDBridge",
            path: "Sources/MouseFixHIDBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MouseFix",
            dependencies: ["Yams", "MouseFixHIDBridge"],
            path: "Sources/MouseFix"
        ),
        .testTarget(
            name: "MouseFixTests",
            dependencies: [
                "MouseFix",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/MouseFixTests",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
