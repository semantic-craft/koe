import Foundation

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public let recordId: String?
    public let positionMs: UInt64
    public let isPlaying: Bool
    public let requestId: UInt64
    public let lane: String?
    public let lanes: [PlaybackLaneSnapshot]
    public let asset: PlaybackAssetSnapshot?

    private enum CodingKeys: String, CodingKey {
        case recordId, positionMs, isPlaying, requestId, lane, lanes, asset
    }
}

extension PlaybackSnapshot {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recordId = try values.decodeIfPresent(String.self, forKey: .recordId)
        positionMs = try values.decode(UInt64.self, forKey: .positionMs)
        isPlaying = try values.decode(Bool.self, forKey: .isPlaying)
        requestId = try values.decodeIfPresent(UInt64.self, forKey: .requestId) ?? 0
        lane = try values.decodeIfPresent(String.self, forKey: .lane)
        lanes = try values.decodeIfPresent([PlaybackLaneSnapshot].self, forKey: .lanes) ?? []
        asset = try values.decodeIfPresent(PlaybackAssetSnapshot.self, forKey: .asset)
    }
}

public struct PlaybackLaneSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let available: Bool
    public let interruption: String?
    public var label: String {
        switch id {
        case "microphone": return "麦克风"
        case "system": return "系统音频"
        default: return "原音频"
        }
    }
}

public struct PlaybackAssetSnapshot: Codable, Equatable, Sendable {
    public let audioPath: String
    public let sampleRate: Int32?
    public let durationNs: Int64
    public let segments: [PlaybackSegmentSnapshot]
}

public struct PlaybackSegmentSnapshot: Codable, Equatable, Sendable {
    public let sourceStartSample: Int64
    public let sampleCount: Int64
    public let timelineStartNs: Int64
}

extension PlaybackSnapshot {
    public func updatingProgress(positionMs: UInt64, isPlaying: Bool) -> PlaybackSnapshot {
        PlaybackSnapshot(
            recordId: recordId,
            positionMs: positionMs,
            isPlaying: isPlaying,
            requestId: requestId,
            lane: lane,
            lanes: lanes,
            asset: asset
        )
    }
}

extension HostSnapshot {
    public func updatingPlayback(
        generation: UInt64,
        positionMs: UInt64,
        isPlaying: Bool
    ) -> HostSnapshot {
        HostSnapshot(
            speech: speech,
            liveCaption: liveCaption,
            microphone: microphone,
            capture: capture,
            lifecycle: lifecycle,
            activeCapture: activeCapture,
            workspaces: workspaces,
            version: version,
            generation: generation,
            section: section,
            canGoBack: canGoBack,
            selectedRecordId: selectedRecordId,
            focusSegmentId: focusSegmentId,
            records: records,
            trashRecords: trashRecords,
            undoTrash: undoTrash,
            detail: detail,
            tasks: tasks,
            memories: memories,
            ask: ask,
            device: device,
            provider: provider,
            playback: playback.updatingProgress(positionMs: positionMs, isPlaying: isPlaying),
            error: error,
            notice: notice
        )
    }
}
