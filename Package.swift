// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PasswordPie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PasswordPie", targets: ["PasswordPie"])
    ],
    targets: [
        .target(
            name: "CArgon2",
            path: "Sources/CArgon2",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["/opt/homebrew/lib/libargon2.a"]),
                .linkedLibrary("pthread")
            ]
        ),
        .target(
            name: "PasswordPieCore",
            dependencies: ["CArgon2"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication")
            ]
        ),
        .executableTarget(
            name: "PasswordPie",
            dependencies: ["PasswordPieCore"],
            path: "Sources/PasswordPieApp",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("LocalAuthentication"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PasswordPieApp/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "PasswordPieCoreTests",
            dependencies: ["PasswordPieCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PasswordPieAppTests",
            dependencies: ["PasswordPie"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
