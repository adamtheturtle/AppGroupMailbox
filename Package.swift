// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "AppGroupMailbox",
  platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
  products: [
    .library(name: "AppGroupMailbox", targets: ["AppGroupMailbox"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.5")
  ],
  targets: [
    .target(
      name: "AppGroupMailbox",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "MailboxTestWorker",
      dependencies: ["AppGroupMailbox"],
      path: "Tests/MailboxTestWorker",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "AppGroupMailboxTests",
      dependencies: ["AppGroupMailbox", "MailboxTestWorker"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
