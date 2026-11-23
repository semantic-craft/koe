import Foundation
import SwiftUI

public struct AppUpdateSettingsCard: View {
    let store: HostSessionStore

    public init(store: HostSessionStore) {
        self.store = store
    }

    public var body: some View {
        let update = store.settings.appUpdate
        KoeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("版本与软件更新", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: AppFontSizes.md, weight: .medium))
                    Spacer()
                    KoeBadge(badgeLabel(update), tint: badgeTint(update))
                    InfoTip("仅在点击检查更新时连接 GitHub Releases 查询最新发布信息，不会在后台自动联网或上传本机数据。")
                }

                HStack(spacing: 12) {
                    versionTile(label: "当前版本", value: update.versionWithBuildLabel)
                    versionTile(label: "最新发行版", value: latestVersionLabel(update))
                }

                if let message = update.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(messageColor(update))
                        .textSelection(.enabled)
                }

                if update.isUpdateAvailable {
                    availableReleaseDetails(update)
                }

                if let checkedAt = update.checkedAtEpochSec, checkedAt > 0 {
                    Text("上次检查：\(TimeLabel.date(checkedAt))")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .monospacedDigit()
                }

                HStack(spacing: 10) {
                    KoeActionButton(
                        checkButtonTitle(update),
                        systemImage: "arrow.clockwise",
                        isPrimary: !update.isUpdateAvailable
                    ) {
                        store.send(.checkAppUpdate)
                    }
                    .disabled(update.isChecking)

                    if update.isUpdateAvailable,
                       let downloadRaw = update.downloadUrl,
                       let downloadURL = URL(string: downloadRaw) {
                        KoeActionButton("下载新版本", systemImage: "arrow.down.circle", isPrimary: true) {
                            store.bridgeActions.openExternalURL(downloadURL)
                        }
                    }

                    if let releaseURL = URL(string: update.releaseUrl) {
                        KoeActionButton("查看发行页面", systemImage: "safari") {
                            store.bridgeActions.openExternalURL(releaseURL)
                        }
                    }
                }
            }
        }
    }

    private func availableReleaseDetails(_ update: AppUpdateSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(update.releaseTitle ?? "Koe v\(update.latestVersion ?? "")")
                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                if let sizeBytes = update.assetSizeBytes, sizeBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: sizeBytes), countStyle: .file))
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .monospacedDigit()
                }
            }
            if let publishedLabel = formattedPublishedDate(update.publishedAt) {
                Text("发布日期：\(publishedLabel)")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
                    .monospacedDigit()
            }
            if let assetName = update.assetName, !assetName.isEmpty {
                Text("安装包：\(assetName)")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
            }
            if let notes = update.releaseNotes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
    }

    private func versionTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
            Text(value)
                .font(.system(size: AppFontSizes.sm, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
    }

    private func latestVersionLabel(_ update: AppUpdateSnapshot) -> String {
        if let latest = update.latestVersion, !latest.isEmpty {
            return "v\(latest)"
        }
        switch update.phase {
        case "checking": return "正在查询…"
        case "unavailable": return "暂无公开版本"
        case "failed": return "查询失败"
        default: return "尚未查询"
        }
    }

    private func checkButtonTitle(_ update: AppUpdateSnapshot) -> String {
        if update.isChecking {
            return "正在检查…"
        }
        if update.phase == "failed" || update.phase == "unavailable" {
            return "重新检查"
        }
        return "检查更新"
    }

    private func badgeLabel(_ update: AppUpdateSnapshot) -> String {
        switch update.phase {
        case "checking": return "检查中"
        case "up_to_date": return "已是最新"
        case "available": return "有新版本"
        case "unavailable": return "未公开"
        case "failed": return "检查失败"
        default: return "v\(update.currentVersion)"
        }
    }

    private func badgeTint(_ update: AppUpdateSnapshot) -> Color {
        switch update.phase {
        case "up_to_date": return AppColors.success
        case "available", "checking", "unavailable": return AppColors.warning
        case "failed": return AppColors.danger
        default: return AppColors.textMuted
        }
    }

    private func formattedPublishedDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let prefix = String(raw.prefix(10))
        if prefix.count == 10 {
            let chars = Array(prefix.utf8)
            let isISODate = chars[4] == UInt8(ascii: "-")
                && chars[7] == UInt8(ascii: "-")
                && [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy { chars[$0] >= UInt8(ascii: "0") && chars[$0] <= UInt8(ascii: "9") }
            if isISODate {
                return prefix
            }
        }
        return raw
    }

    private func messageColor(_ update: AppUpdateSnapshot) -> Color {
        switch update.phase {
        case "up_to_date": return AppColors.success
        case "failed": return AppColors.danger
        default: return AppColors.textSecondary
        }
    }
}
