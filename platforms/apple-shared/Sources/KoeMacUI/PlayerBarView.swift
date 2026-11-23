import SwiftUI

public struct PlayerBarView: View {
    let store: HostSessionStore
    public init(store: HostSessionStore) { self.store = store }
    public var body: some View {
        let playback = store.playback
        let nav = store.navigation
        if playback.asset != nil, playback.recordId == nav.detailId {
            HStack(spacing: 16) {
                Button { store.send(.playback(isPlaying: !playback.isPlaying)) } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(AppColors.accent).frame(width: 34, height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain).help(playback.isPlaying ? "暂停" : "播放")
                Text(nav.detailTitle ?? "录音").lineLimit(1)
                    .font(.system(size: AppFontSizes.xs)).frame(maxWidth: 180, alignment: .leading)
                if playback.lanes.count > 1 {
                    Picker("音源", selection: Binding(
                        get: { playback.lane ?? "" },
                        set: { store.send(.selectPlaybackLane(lane: $0)) }
                    )) {
                        ForEach(playback.lanes) { lane in
                            Text(lane.label).tag(lane.id).disabled(!lane.available)
                        }
                    }.frame(maxWidth: 150)
                }
                Text(TimeLabel.duration(playback.positionMs))
                    .font(.system(size: AppFontSizes.xs)).monospacedDigit().foregroundStyle(AppColors.textMuted)
                Slider(value: Binding(
                    get: { Double(playback.positionMs) },
                    set: { store.send(.seek(positionMs: UInt64($0))) }
                ), in: 0...Double(max(nav.detailDurationMs, 1)))
                    .accessibilityLabel("播放位置")
                Text(TimeLabel.duration(nav.detailDurationMs))
                    .font(.system(size: AppFontSizes.xs)).monospacedDigit().foregroundStyle(AppColors.textMuted)
            }.padding(.horizontal, 22).padding(.vertical, 10).background(AppColors.surface1)
                .overlay(alignment: .top) { Rectangle().fill(AppColors.border).frame(height: 1) }
        }
    }
}
