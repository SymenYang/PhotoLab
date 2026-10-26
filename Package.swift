// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PhotoLab", platforms: [.macOS("26.0")], products: [.executable(name: "PhotoLab", targets: ["PhotoLab"])], targets: [
    .systemLibrary(name: "CSQLite"),
    .executableTarget(name: "PhotoLab", dependencies: ["CSQLite"])
], swiftLanguageModes: [.v5])
