// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "AmyrlinCore",
	// iOS for amyrlin-ios, which builds against this package from a checkout beside it.
	platforms: [.macOS(.v26), .iOS(.v26)],
	products: [
		.library(name: "AmyrlinCore", targets: ["AmyrlinCore"]),
	],
	targets: [
		.target(name: "AmyrlinCore"),
		.testTarget(name: "AmyrlinCoreTests", dependencies: ["AmyrlinCore"]),
	]
)
