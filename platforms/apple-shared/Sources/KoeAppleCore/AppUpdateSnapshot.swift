import Foundation

public struct AppUpdateSnapshot: Codable, Equatable, Sendable {
    public static let defaultVersion = "2.7.0"
    public static let defaultBuild = "16"
    public static let defaultReleasesURL = "https://github.com/semantic-craft/koe/releases"

    public let currentVersion: String
    public let currentBuild: String
    public let phase: String
    public let checkedAtEpochSec: UInt64?
    public let latestVersion: String?
    public let releaseTitle: String?
    public let publishedAt: String?
    public let releaseNotes: String?
    public let releaseUrl: String
    public let downloadUrl: String?
    public let assetName: String?
    public let assetSizeBytes: UInt64?
    public let message: String?

    private enum CodingKeys: String, CodingKey {
        case currentVersion, currentBuild, phase, checkedAtEpochSec
        case latestVersion, releaseTitle, publishedAt, releaseNotes
        case releaseUrl, downloadUrl, assetName, assetSizeBytes, message
    }

    public init(
        currentVersion: String = AppUpdateSnapshot.defaultVersion,
        currentBuild: String = AppUpdateSnapshot.defaultBuild,
        phase: String = "idle",
        checkedAtEpochSec: UInt64? = nil,
        latestVersion: String? = nil,
        releaseTitle: String? = nil,
        publishedAt: String? = nil,
        releaseNotes: String? = nil,
        releaseUrl: String = AppUpdateSnapshot.defaultReleasesURL,
        downloadUrl: String? = nil,
        assetName: String? = nil,
        assetSizeBytes: UInt64? = nil,
        message: String? = nil
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.phase = phase
        self.checkedAtEpochSec = checkedAtEpochSec
        self.latestVersion = latestVersion
        self.releaseTitle = releaseTitle
        self.publishedAt = publishedAt
        self.releaseNotes = releaseNotes
        self.releaseUrl = releaseUrl
        self.downloadUrl = downloadUrl
        self.assetName = assetName
        self.assetSizeBytes = assetSizeBytes
        self.message = message
    }

    public var isChecking: Bool {
        phase == "checking"
    }

    public var isUpdateAvailable: Bool {
        phase == "available"
    }

    public var versionWithBuildLabel: String {
        "v\(currentVersion)（构建 \(currentBuild)）"
    }

    public var compactMenuVersionLabel: String {
        "版本 v\(currentVersion) (\(currentBuild))"
    }

    public static let empty = AppUpdateSnapshot()
}

extension AppUpdateSnapshot {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentVersion = try c.decodeIfPresent(String.self, forKey: .currentVersion) ?? Self.defaultVersion
        currentBuild = try c.decodeIfPresent(String.self, forKey: .currentBuild) ?? Self.defaultBuild
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "idle"
        checkedAtEpochSec = try c.decodeIfPresent(UInt64.self, forKey: .checkedAtEpochSec)
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        releaseTitle = try c.decodeIfPresent(String.self, forKey: .releaseTitle)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        releaseNotes = try c.decodeIfPresent(String.self, forKey: .releaseNotes)
        releaseUrl = try c.decodeIfPresent(String.self, forKey: .releaseUrl) ?? Self.defaultReleasesURL
        downloadUrl = try c.decodeIfPresent(String.self, forKey: .downloadUrl)
        assetName = try c.decodeIfPresent(String.self, forKey: .assetName)
        assetSizeBytes = try c.decodeIfPresent(UInt64.self, forKey: .assetSizeBytes)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}
