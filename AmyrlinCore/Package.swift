// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "AmyrlinCore",
	platforms: [.macOS(.v26)],
	products: [
		.library(name: "AmyrlinCore", targets: ["AmyrlinCore"]),
	],
	targets: [
		.target(name: "AmyrlinCore"),
		.testTarget(name: "AmyrlinCoreTests", dependencies: ["AmyrlinCore"]),
	]
)
