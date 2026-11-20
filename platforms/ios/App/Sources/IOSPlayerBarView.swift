import KoeAppleCore
import SwiftUI

struct IOSPlayerBarView: View {
    let store: HostSessionStore

    var body: some View {
        let playback = store.playback
        let nav = store.navigation
        if playback.asset != nil, playback.recordId == nav.detailId {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        store.send(.playback(isPlaying: !playback.isPlaying))
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: AppFontSizes.md))
                            .foregroundStyle(IOSColors.onAccent)
                            .frame(width: 36, height: 36)
                            .background(IOSColors.accent, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.isPlaying ? "暂停播放" : "开始播放")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(nav.detailTitle ?? "录音回放")
                            .font(.system(size: AppFontSizes.xs, weight: .semibold))
                            .foregroundStyle(IOSColors.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(TimeLabel.duration(playback.positionMs))
                                .monospacedDigit()
                            Text("/")
                            Text(TimeLabel.duration(nav.detailDurationMs))
                                .monospacedDigit()
                        }
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(IOSColors.textMuted)
                    }

                    Spacer(minLength: 4)

                    if playback.lanes.count > 1 {
                        Menu {
                            ForEach(playback.lanes) { lane in
                                Button(lane.label) {
                                    store.send(.selectPlaybackLane(lane: lane.id))
                                }
                                .disabled(!lane.available)
                            }
                        } label: {
                            IOSBadge(
                                playback.lanes.first(where: { $0.id == playback.lane })?.label ?? "音源",
                                tint: IOSColors.textSecondary
                            )
                        }
                    }
                }

                Slider(
                    value: Binding(
                        get: { Double(playback.positionMs) },
                        set: { store.send(.seek(positionMs: UInt64($0))) }
                    ),
                    in: 0...Double(max(nav.detailDurationMs, 1))
                )
                .tint(IOSColors.accent)
                .accessibilityLabel("播放进度")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .iosChromeSurface(IOSColors.surface1)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(IOSColors.border)
                    .frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios-player-bar")
        }
    }
}
