import SwiftUI

public struct PlayerBarView: View {
    let store: HostSessionStore
    public init(store: HostSessionStore) { self.store = store }
    public var body: some View {
        HStack(spacing: 16) {
            Button { store.send("playback", ["isPlaying": !store.snapshot.playback.isPlaying]) } label: {
                Image(systemName: store.snapshot.playback.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(AppColors.accent).frame(width: 34, height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).help(store.snapshot.playback.isPlaying ? "暂停" : "播放")
            Text(store.snapshot.detail?.title ?? "录音").lineLimit(1)
                .font(.system(size: AppFontSizes.xs)).frame(maxWidth: 180, alignment: .leading)
            if store.snapshot.playback.lanes.count > 1 {
                Picker("音源", selection: Binding(
                    get: { store.snapshot.playback.lane ?? "" },
                    set: { store.send("select_playback_lane", ["lane": $0]) }
                )) {
                    ForEach(store.snapshot.playback.lanes) { lane in
                        Text(lane.label).tag(lane.id).disabled(!lane.available)
                    }
                }.frame(maxWidth: 150)
            }
            Text(TimeLabel.duration(store.snapshot.playback.positionMs))
                .font(.system(size: AppFontSizes.xs)).monospacedDigit().foregroundStyle(AppColors.textMuted)
            Slider(value: Binding(
                get: { Double(store.snapshot.playback.positionMs) },
                set: { store.send("seek", ["positionMs": UInt64($0)]) }
            ), in: 0...Double(max(store.snapshot.detail?.durationMs ?? 0, 1)))
                .accessibilityLabel("播放位置")
            Text(TimeLabel.duration(store.snapshot.detail?.durationMs ?? 0))
                .font(.system(size: AppFontSizes.xs)).monospacedDigit().foregroundStyle(AppColors.textMuted)
        }.padding(.horizontal, 22).padding(.vertical, 10).background(AppColors.surface1)
            .overlay(alignment: .top) { Rectangle().fill(AppColors.border).frame(height: 1) }
    }
}
