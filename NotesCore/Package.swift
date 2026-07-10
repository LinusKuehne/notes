// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotesCore",
    platforms: [
        .iOS("26.0"),
        .macCatalyst("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "NotesCore", targets: ["NotesCore"])
    ],
    targets: [
        .target(name: "NotesCore"),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"]),
    ]
)
