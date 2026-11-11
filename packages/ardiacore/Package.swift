// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "ArdiaVaultsCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "ArdiaVaultsCore", targets: ["ArdiaVaultsCore"])],
  targets: [
    .target(
      name: "ArdiaVaultsCore",
      path: "ios",
      sources: [
        "ChromeHandoffRules.swift", "ChromeLogins.swift", "GoogleWebImportRules.swift", "GoogleWebExportRules.swift", "ChromeProfiles.swift", "GoogleSourceRules.swift", "VaultError.swift", "VaultItem.swift", "VaultJSON.swift",
        "VaultOriginMatch.swift", "VaultPendingItems.swift", "VaultSyncSchedule.swift",
      ],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(name: "ArdiaVaultsCoreTests", dependencies: ["ArdiaVaultsCore"], path: "tests/swift"),
  ],
  swiftLanguageVersions: [.v5]
)
