// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
let package = Package(
    name: "Stillday",
    products: [
        .executable(name: "calendar-linux-core", targets: ["CalendarLinuxBridge"]),
    ],
    targets: [
        .systemLibrary(name: "CLinuxCrypto", pkgConfig: "libcrypto", providers: [.apt(["libssl-dev"])]),
        .target(name: "CalendarCore", dependencies: ["CLinuxCrypto"]),
        .target(name: "CalendarData", dependencies: ["CalendarCore"],
                exclude: ["EventKitCalendarStore.swift", "GoogleTasks.swift"]),
        .executableTarget(name: "CalendarLinuxBridge", dependencies: ["CalendarCore", "CalendarData"]),
        .testTarget(name: "CalendarCoreTests", dependencies: ["CalendarCore"]),
    ]
)
#else
let package = Package(
    name: "Stillday",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CalendarData", targets: ["CalendarData"]),
        .library(name: "CalendarCore", targets: ["CalendarCore"]),
        .executable(name: "Stillday", targets: ["Stillday"]),
    ],
    targets: [
        .target(name: "CalendarCore"),
        .target(name: "CalendarData", dependencies: ["CalendarCore"]),
        .executableTarget(name: "Stillday", dependencies: ["CalendarCore", "CalendarData"]),
        .testTarget(name: "CalendarCoreTests", dependencies: ["CalendarCore"]),
        .testTarget(name: "CalendarDataTests", dependencies: ["CalendarCore", "CalendarData"]),
        .testTarget(name: "StilldayTests", dependencies: ["Stillday", "CalendarCore", "CalendarData"]),
    ]
)
#endif
