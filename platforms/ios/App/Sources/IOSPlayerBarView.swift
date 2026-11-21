import KoeAppleCore
import SwiftUI

struct IOSPlayerBarView: View {
    let store: HostSessionStore
    let recordId: String
    @State private var scrubbingMs: Double?

    var body: some View {
        let playback = store.playback
        let nav = store.navigation
        if playback.asset != nil, playback.recordId == recordId, nav.detailId == recordId {
            let scrubber = IOSPlaybackScrubber(draft: $scrubbingMs, positionMs: playback.positionMs) {
                guard store.playback.recordId == recordId else { return }
                store.send(.seek(positionMs: $0))
            }
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    IOSPlaybackToggle(store: store)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(nav.detailTitle ?? "录音回放")
                            .font(.system(size: AppFontSizes.xs, weight: .semibold))
                            .foregroundStyle(IOSColors.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(TimeLabel.duration(UInt64(scrubber.value.wrappedValue)))
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
                    value: scrubber.value,
                    in: 0...Double(max(nav.detailDurationMs, 1)),
                    onEditingChanged: scrubber.editingChanged
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
            .onDisappear { scrubbingMs = nil }
        }
    }
}

struct IOSPlaybackScrubber {
    let draft: Binding<Double?>
    let positionMs: UInt64
    let seek: (UInt64) -> Void

    var value: Binding<Double> {
        Binding(get: { draft.wrappedValue ?? Double(positionMs) }, set: { draft.wrappedValue = $0 })
    }

    func editingChanged(_ editing: Bool) {
        guard !editing, let position = draft.wrappedValue else { return }
        draft.wrappedValue = nil
        seek(UInt64(position))
    }
}

private struct IOSPlaybackToggle: View {
    let store: HostSessionStore

    var body: some View {
        let playback = store.playback
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
    }
}

struct IOSMiniPlayerBar: View {
    let store: HostSessionStore
    let visibleRoute: IOSDetailRoute?
    let openRecord: (String) -> Void

    static func miniPlayerRecordID(_ playback: PlaybackSnapshot, visibleRoute: IOSDetailRoute?) -> String? {
        guard playback.asset != nil, let id = playback.recordId, visibleRoute != .record(id) else { return nil }
        return id
    }

    var body: some View {
        if let recordId = Self.miniPlayerRecordID(store.playback, visibleRoute: visibleRoute) {
            bar(for: recordId)
        }
    }

    private func bar(for recordId: String) -> some View {
        let playback = store.playback
        let record = store.records.first { $0.id == recordId }
        let duration = max(record?.durationMs ?? 0, UInt64(max(0, playback.asset?.durationNs ?? 0) / 1_000_000))
        return HStack(spacing: 10) {
            IOSPlaybackToggle(store: store)
            Button { openRecord(recordId) } label: {
                HStack {
                    Text(record?.title ?? "录音回放")
                        .lineLimit(1)
                    Spacer()
                    Text("\(TimeLabel.duration(playback.positionMs)) / \(TimeLabel.duration(duration))")
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: AppFontSizes.xs))
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mini-player-open-record")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(IOSColors.surface1, in: RoundedRectangle(cornerRadius: IOSRadii.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-mini-player")
    }
}

struct IOSSegmentPlaybackButton: View {
    let store: HostSessionStore
    let recordID: String
    let segment: SegmentSnapshot

    var body: some View {
        let timed = segment.timed != false
        Button(timed ? TimeLabel.duration(segment.startMs) : "无时码") {
            guard store.navigation.detailId == recordID,
                  store.sendReturningError(.seek(positionMs: segment.startMs)) == nil else { return }
            let playback = store.playback
            if playback.recordId == recordID, playback.asset != nil, !playback.isPlaying {
                store.send(.playback(isPlaying: true))
            }
        }
        .disabled(!timed || store.navigation.detailId != recordID)
        .font(.system(size: AppFontSizes.xs, weight: .medium))
        .monospacedDigit()
    }
}
