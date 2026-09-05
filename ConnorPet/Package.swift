// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "ConnorPet",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ConnorPet",
            resources: [
                .copy("Resources/pets"),
                .copy("Resources/effects"),
                // Bundled copy of scripts/pet_hook_status.py so the in-app
                // "Claude Code 상태 훅 설치" menu action works from a DMG install
                // (where the repo's scripts/ dir isn't on disk). Must stay
                // byte-identical to scripts/pet_hook_status.py — see CLAUDE.md.
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
