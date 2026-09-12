// swift-tools-version: 6.0
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "JPLive",
    platforms: [.iOS("26.0")],
    products: [.iOSApplication(name: "JPLive", targets: ["JPLive"], bundleIdentifier: "local.jp.live.prototype",
        teamIdentifier: "", displayVersion: "0.1", bundleVersion: "1", appIcon: .placeholder(icon: .star),
        accentColor: .presetColor(.blue), supportedDeviceFamilies: [.pad],
        supportedInterfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown])],
    // Phase 1: Apple frameworks only. FluidAudio's mandatory remote NeMo binary
    // needs an archive tool unavailable on the tested iPad Playgrounds host.
    dependencies: [],
    targets: [.executableTarget(name: "JPLive", dependencies: [],
        path: ".", exclude: ["Package.swift"], sources: ["Sources"], resources: [.process("Resources")])],
    swiftLanguageModes: [.v5]
)
