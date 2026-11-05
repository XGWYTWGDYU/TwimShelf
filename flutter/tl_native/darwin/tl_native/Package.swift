// swift-tools-version: 5.9

import Foundation
import PackageDescription

// The repository's shared MLX engine (native/TLLocalAI). Flutter reaches this manifest through
// a symbolic link in the app's ephemeral folder, so the path is taken from where the file really
// is.
let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
let localAI = here.appendingPathComponent("../../../../native/TLLocalAI").standardizedFileURL.path

let package = Package(
  name: "tl_native",
  platforms: [.iOS("17.0"), .macOS("14.0")],
  products: [.library(name: "tl-native", targets: ["tl_native"])],
  dependencies: [.package(name: "TLLocalAI", path: localAI)],
  targets: [.target(name: "tl_native", dependencies: [.product(name: "TLLocalAI", package: "TLLocalAI")])]
)
