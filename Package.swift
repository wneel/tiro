// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Tiro",
	platforms: [.macOS("14.4")],
	targets: [
		.executableTarget(
			name: "Tiro",
			dependencies: ["whisper"],
			path: "Sources/Tiro",
			swiftSettings: [.swiftLanguageMode(.v5)],
			linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
		),
		.binaryTarget(
			name: "whisper",
			url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
			checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
		),
	]
)
