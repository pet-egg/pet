// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "ConnorPet",
    platforms: [.macOS(.v12)],
    dependencies: [
        // In-app auto-update. Sparkle verifies updates with its own EdDSA
        // signature (not Apple Developer ID), so it works for our ad-hoc-signed,
        // un-notarized DMG builds. See UpdaterManager.swift / scripts/make_app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ConnorPet",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/pets"),
                .copy("Resources/effects"),
                // Bundled copy of scripts/claude_hook_status.py so the in-app
                // "Claude Code 상태 훅 설치" menu action works from a DMG install
                // (where the repo's scripts/ dir isn't on disk). Must stay
                // byte-identical to scripts/claude_hook_status.py — see CLAUDE.md.
                .copy("Resources/hooks")
            ],
            // NotificationCenterDB reads macOS's Notification Center SQLite DB.
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "ConnorPetTests",
            dependencies: ["ConnorPet"]
        ),
    ]
)
