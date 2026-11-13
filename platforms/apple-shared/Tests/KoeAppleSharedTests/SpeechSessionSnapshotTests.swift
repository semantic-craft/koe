import Foundation
import Testing
@testable import KoeAppleShared

@Suite("Speech and all-day host snapshot contract")
struct SpeechSessionSnapshotTests {
    @Test("Host roundtrip preserves model progress and independent dictation state")
    func activeSessionRoundtrip() throws {
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(HostSnapshot.empty)) as? [String: Any])
        payload["speech"] = [
            "engine": "downloaded", "modelId": "small", "appleState": "unavailable", "appleMessage": "需要支持的 Mac",
            "models": [["id": "small", "name": "Small", "sizeBytes": 100, "downloadedBytes": 40,
                        "state": "preparing", "message": "正在下载"]]
        ]
        payload["allDay"] = ["state": "recording", "source": "microphone", "runId": "run-1", "segmentCount": 3]
        payload["dictation"] = ["active": true]
        let decoded = try JSONDecoder().decode(HostSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        let result = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let speech = try #require(result["speech"] as? [String: Any])
        let models = try #require(speech["models"] as? [[String: Any]])
        #expect(models.first?["downloadedBytes"] as? Int == 40)
        #expect(models.first?["state"] as? String == "preparing")
        #expect((result["allDay"] as? [String: Any])?["state"] as? String == "recording")
        #expect((result["dictation"] as? [String: Any])?["active"] as? Bool == true)
    }
}
