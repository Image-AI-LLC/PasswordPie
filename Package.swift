// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// Two release channels come from one source tree. The default build is the direct (Developer ID) channel and
/// compiles PP_DIRECT code, such as reading Chrome's password store. `PP_MAS=1` builds the App Store channel without it,
/// so that code is not in the store binary at all.
let storeBuild = ProcessInfo.processInfo.environment["PP_MAS"] == "1"
let channelSettings: [SwiftSetting] = storeBuild ? [] : [.define("PP_DIRECT")]

let package = Package(
    name: "PasswordPie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PasswordPie", targets: ["PasswordPie"]),
        .executable(name: "PasswordPieAutoFill", targets: ["PasswordPieAutoFill"]),
        .executable(name: "PasswordPieSafari", targets: ["PasswordPieSafari"]),
        .executable(name: "PasswordPieBrowserHost", targets: ["PasswordPieBrowserHost"])
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
        // The socket, framing and peer check shared by the app, the Safari extension and the Chrome host. Foundation, Security, and
        // AppKit for starting the app (`AppLaunch`). `-Xswiftc -DPP_DEV_EXTENSION` (make install) also trusts the unpacked Chrome extension.
        .target(
            name: "PasswordPieBridge",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "PasswordPie",
            dependencies: ["PasswordPieCore", "PasswordPieBridge"],
            path: "Sources/PasswordPieApp",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)] + channelSettings,
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("SafariServices"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PasswordPieApp/Info.plist"
                ])
            ]
        ),
        // AutoFill credential provider app extension (PlugIns/PasswordPieAutoFill.appex): makes Passwords offer
        // PasswordPie for Export All Items to App. Entry point is NSExtensionMain, not main().
        .executableTarget(
            name: "PasswordPieAutoFill",
            path: "Sources/PasswordPieAutoFill",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AuthenticationServices"),
                .unsafeFlags([
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PasswordPieAutoFill/Info.plist"
                ])
            ]
        ),
        // Safari Web Extension app extension (PlugIns/PasswordPieSafari.appex). Relays the extension's native messages to
        // the app over the bridge socket. The extension's own files go in its Contents/Resources (see the Makefile).
        .executableTarget(
            name: "PasswordPieSafari",
            dependencies: ["PasswordPieBridge"],
            path: "Sources/PasswordPieSafari",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("SafariServices"),
                .unsafeFlags([
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PasswordPieSafari/Info.plist"
                ])
            ]
        ),
        // Chrome native messaging host (Contents/MacOS/PasswordPieBrowserHost). Direct channel only: `make mas-dev` does
        // not put it in the bundle.
        .executableTarget(
            name: "PasswordPieBrowserHost",
            dependencies: ["PasswordPieBridge"],
            path: "Sources/PasswordPieBrowserHost",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PasswordPieBridgeTests",
            dependencies: ["PasswordPieBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PasswordPieCoreTests",
            dependencies: ["PasswordPieCore"],
            swiftSettings: [.swiftLanguageMode(.v5)] + channelSettings
        ),
        .testTarget(
            name: "PasswordPieAppTests",
            dependencies: ["PasswordPie", "PasswordPieBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)] + channelSettings
        )
    ]
)
