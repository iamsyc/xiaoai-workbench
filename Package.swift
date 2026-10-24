// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XiaoaiWorkbench",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "XiaoaiWorkbench", targets: ["XiaoaiWorkbench"]),
               .executable(name: "XiaoaiBluetoothProxy", targets: ["XiaoaiBluetoothProxy"])],
    targets: [
        .systemLibrary(name: "CLibusb", pkgConfig: "libusb-1.0"),
        .target(name: "USBBridge", dependencies: ["CLibusb"],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "XiaoaiCore", dependencies: ["USBBridge"]),
        .executableTarget(name: "XiaoaiWorkbench", dependencies: ["XiaoaiCore"]),
        .executableTarget(name: "XiaoaiBluetoothProxy", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                          linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("IOBluetooth")]),
        .testTarget(name: "XiaoaiCoreTests", dependencies: ["XiaoaiCore"]),
        .testTarget(name: "XiaoaiWorkbenchTests", dependencies: ["XiaoaiWorkbench"])
    ],
    swiftLanguageModes: [.v6]
)
