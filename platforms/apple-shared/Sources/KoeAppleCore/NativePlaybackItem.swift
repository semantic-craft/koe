import AVFoundation

@MainActor
public enum NativePlaybackItem {
    public static func make(_ plan: PlaybackAssetSnapshot) async throws -> AVPlayerItem {
        let source = AVURLAsset(url: URL(fileURLWithPath: plan.audioPath))
        guard !plan.segments.isEmpty || plan.durationNs > 0 else { return AVPlayerItem(asset: source) }
        guard let input = try await source.loadTracks(withMediaType: .audio).first else {
            throw CaptureError("录音文件没有可播放的音轨。")
        }
        let rate: Int32
        if let sampleRate = plan.sampleRate { rate = sampleRate } else { rate = try await input.load(.naturalTimeScale) }
        guard rate > 0 else { throw CaptureError("录音采样率无效。") }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError("无法建立分路播放音轨。")
        }
        for segment in plan.segments {
            try Task.checkCancellation()
            try track.insertTimeRange(CMTimeRange(
                start: CMTime(value: segment.sourceStartSample, timescale: rate),
                duration: CMTime(value: segment.sampleCount, timescale: rate)
            ), of: input, at: CMTime(value: segment.timelineStartNs, timescale: 1_000_000_000))
        }
        if plan.segments.isEmpty {
            try track.insertTimeRange(try await input.load(.timeRange), of: input, at: .zero)
        }
        let end = CMTime(value: plan.durationNs, timescale: 1_000_000_000)
        let item = AVPlayerItem(asset: composition)
        if end > composition.duration {
            // AVFoundation drops trailing empty ranges. This muted marker preserves the common end.
            guard let tail = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CaptureError("无法建立播放静音音轨。")
            }
            let duration = min(CMTime(value: 1, timescale: rate), end)
            try tail.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: input, at: end - duration)
            let parameters = AVMutableAudioMixInputParameters(track: tail)
            parameters.setVolume(0, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
        return item
    }
}
