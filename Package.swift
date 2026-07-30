// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArctisAudioSwitch",
    platforms: [
        // IOHIDManager and the CoreAudio HAL calls used here are long-standing
        // APIs; 12.0 is set by kAudioObjectPropertyElementMain.
        .macOS(.v12)
    ],
    products: [
        .executable(name: "arctis-audioswitch", targets: ["ArctisAudioSwitch"])
    ],
    targets: [
        .executableTarget(
            name: "ArctisAudioSwitch",
            path: "Sources/ArctisAudioSwitch"
        )
    ]
)
