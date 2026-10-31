// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// Two release channels come from one source tree. The default build is the direct (Developer ID) channel and
/// compiles PP_DIRECT code, such as reading Chrome's password store. `PP_MAS=1` builds the App Store channel without it,
/// so that code is not in the store binary at all.
let storeBuild = ProcessInfo.processInfo.environment["PP_MAS"] != nil
let channelSettings: [SwiftSetting] = storeBuild ? [] : [.define("PP_DIRECT")]

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
            swiftSettings: [.swiftLanguageMode(.v5)] + channelSettings,
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication")
            ]
        ),
        .executableTarget(
            name: "PasswordPie",
            dependencies: ["PasswordPieCore"],
            path: "Sources/PasswordPieApp",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)] + channelSettings,
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
            swiftSettings: [.swiftLanguageMode(.v5)] + channelSettings
        ),
        .testTarget(
            name: "PasswordPieAppTests",
            dependencies: ["PasswordPie"],
            swiftSettings: [.swiftLanguageMode(.v5)] + channelSettings
        )
    ]
)
