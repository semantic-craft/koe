import Foundation
import Testing
@testable import KoeAppleShared

@Suite("Speech and all-day host snapshot contract")
struct SpeechSessionSnapshotTests {
    @Test("Host roundtrip preserves model progress and active capture state")
    func activeSessionRoundtrip() throws {
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(HostSnapshot.empty)) as? [String: Any])
        payload["speech"] = [
            "engine": "downloaded", "modelId": "small", "appleState": "unavailable", "appleMessage": "需要支持的 Mac",
            "models": [["id": "small", "name": "Small", "sizeBytes": 100, "downloadedBytes": 40,
                        "state": "preparing", "message": "正在下载"]]
        ]
        payload["activeCapture"] = [
            "mode": "all_day", "phase": "recording", "sourceLabel": "Mac 麦克风",
            "durationMs": 12000, "actions": ["pause", "end"]
        ]
        let decoded = try JSONDecoder().decode(HostSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        let result = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let speech = try #require(result["speech"] as? [String: Any])
        let models = try #require(speech["models"] as? [[String: Any]])
        #expect(models.first?["downloadedBytes"] as? Int == 40)
        #expect(models.first?["state"] as? String == "preparing")
        let activeCapture = try #require(result["activeCapture"] as? [String: Any])
        #expect(activeCapture["mode"] as? String == "all_day")
        #expect(activeCapture["phase"] as? String == "recording")
        #expect(activeCapture["actions"] as? [String] == ["pause", "end"])
    }
}
