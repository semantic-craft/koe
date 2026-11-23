import CKoeHostApi
import Darwin
import Foundation
import KoeAppleCore
import Testing

private final class LoopbackContractReleaseServer: @unchecked Sendable {
    let port: UInt16
    private let stateLock = NSLock()
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)

    init(statusLine: String, body: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let boundOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard boundOK, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLen) == 0
            }
        }
        guard gotName else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        self.port = UInt16(bigEndian: bound.sin_port)

        let payloadBytes = Array(body.utf8)
        let header = "HTTP/1.1 \(statusLine)\r\nContent-Type: application/json\r\nContent-Length: \(payloadBytes.count)\r\nConnection: close\r\n\r\n"
        let responseBytes = Array(header.utf8) + payloadBytes

        let worker = Thread { [self] in
            defer {
                Darwin.close(fd)
                self.finished.signal()
            }
            var clientFD: Int32 = -1
            while !self.isStopped() {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 25)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 { continue }
                if (pfd.revents & Int16(POLLIN)) != 0 {
                    var clientAddr = sockaddr()
                    var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                    clientFD = accept(fd, &clientAddr, &clientLen)
                    break
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var reqBytes: [UInt8] = []
            var reqBuf = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = read(clientFD, &reqBuf, reqBuf.count)
                if n <= 0 { break }
                reqBytes.append(contentsOf: reqBuf[0..<n])
                if reqBytes.count >= 4 {
                    var done = false
                    for idx in 0...(reqBytes.count - 4) where reqBytes[idx] == 13 && reqBytes[idx + 1] == 10 && reqBytes[idx + 2] == 13 && reqBytes[idx + 3] == 10 {
                        done = true
                        break
                    }
                    if done { break }
                }
            }
            responseBytes.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                var written = 0
                while written < responseBytes.count {
                    let n = write(clientFD, base.advanced(by: written), responseBytes.count - written)
                    if n <= 0 { break }
                    written += n
                }
            }
        }
        worker.start()
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    func close() {
        stateLock.lock()
        let shouldWait = !stopped
        stopped = true
        stateLock.unlock()
        if shouldWait {
            _ = finished.wait(timeout: .now() + 2)
        }
    }

    deinit { close() }

    var endpointURL: String {
        "http://127.0.0.1:\(port)/repos/semantic-craft/koe/releases/latest"
    }
}

@Suite("Rust to Swift AppUpdate and rich snapshot schema contract")
struct RustAppUpdateContractTests {
    @Test("Real Rust AppUpdate available/failed payloads and workflow snapshots decode cleanly into Swift models")
    @MainActor
    func realRustAppUpdateAndWorkflowContract() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let downloadURL = "https://github.com/semantic-craft/koe/releases/download/v9.9.9/Koe-9.9.9-macos-universal.zip"
        let availableServer = try LoopbackContractReleaseServer(
            statusLine: "200 OK",
            body: """
            {
              "tag_name": "v9.9.9",
              "name": "Koe 9.9.9",
              "draft": false,
              "prerelease": false,
              "published_at": "2026-11-22T00:00:00Z",
              "html_url": "https://github.com/semantic-craft/koe/releases/tag/v9.9.9",
              "body": "跨端真实契约更新说明",
              "assets": [
                {
                  "name": "Koe-9.9.9-macos-universal.zip",
                  "size": 9876543,
                  "browser_download_url": "\(downloadURL)"
                }
              ]
            }
            """
        )
        defer { availableServer.close() }

        let baseNow: UInt64 = 1_800_200_000
        store.send(
            .syncAppMetadata(
                version: "2.7.1",
                build: "17",
                updateEndpoint: availableServer.endpointURL,
                supportsSelfUpdate: true
            ),
            nowEpochSec: baseNow
        )
        store.send(.checkAppUpdate, nowEpochSec: baseNow + 1)

        let availableDeadline = ContinuousClock.now + .seconds(4)
        while store.settings.appUpdate.isChecking, ContinuousClock.now < availableDeadline {
            store.pollTimers(elapsedMs: 50, nowEpochSec: baseNow + 2)
            try? await Task.sleep(for: .milliseconds(10))
        }

        let available = store.settings.appUpdate
        #expect(available.phase == "available")
        #expect(available.isUpdateAvailable == true)
        #expect(available.latestVersion == "9.9.9")
        #expect(available.releaseTitle == "Koe 9.9.9")
        #expect(available.releaseNotes == "跨端真实契约更新说明")
        #expect(available.downloadUrl == downloadURL)
        #expect(available.assetName == "Koe-9.9.9-macos-universal.zip")
        #expect(available.assetSizeBytes == 9_876_543)
        #expect(available.message?.contains("9.9.9") == true)

        try assertRawSnapshotDecodes(handle: store.handle, now: baseNow + 3)

        store.send(.createNote(title: "Swift 契约笔记", text: "真实 Rust 快照解码校验", stayOnPage: false), nowEpochSec: baseNow + 4)
        let recordID = try #require(store.records.first(where: { $0.title == "Swift 契约笔记" })?.id)
        store.send(.selectRecord(recordId: recordID), nowEpochSec: baseNow + 5)
        #expect(store.recordDetail.detail?.id == recordID)
        try assertRawSnapshotDecodes(handle: store.handle, now: baseNow + 5)

        store.send(.trashRecord(recordId: recordID), nowEpochSec: baseNow + 6)
        #expect(store.trashRecords.contains(where: { $0.id == recordID }))
        try assertRawSnapshotDecodes(handle: store.handle, now: baseNow + 6)

        store.send(.restoreRecord(recordId: recordID), nowEpochSec: baseNow + 7)
        #expect(store.records.contains(where: { $0.id == recordID }))
        try assertRawSnapshotDecodes(handle: store.handle, now: baseNow + 7)

        let failedServer = try LoopbackContractReleaseServer(
            statusLine: "500 Internal Server Error",
            body: #"{"message":"internal error"}"#
        )
        defer { failedServer.close() }
        store.send(
            .syncAppMetadata(
                version: "2.7.1",
                build: "17",
                updateEndpoint: failedServer.endpointURL,
                supportsSelfUpdate: true
            ),
            nowEpochSec: baseNow + 8
        )
        store.send(.checkAppUpdate, nowEpochSec: baseNow + 9)

        let failedDeadline = ContinuousClock.now + .seconds(4)
        while store.settings.appUpdate.isChecking, ContinuousClock.now < failedDeadline {
            store.pollTimers(elapsedMs: 50, nowEpochSec: baseNow + 10)
            try? await Task.sleep(for: .milliseconds(10))
        }

        let failed = store.settings.appUpdate
        #expect(failed.phase == "failed")
        #expect(failed.isUpdateAvailable == false)
        #expect(failed.latestVersion == nil)
        #expect(failed.downloadUrl == nil)
        #expect(!(failed.message ?? "").isEmpty)
        try assertRawSnapshotDecodes(handle: store.handle, now: baseNow + 11)
    }

    private func assertRawSnapshotDecodes(handle: UInt64, now: UInt64) throws {
        let rawPtr = try #require(koe_host_session_snapshot_json(handle, now))
        defer { koe_host_string_free(rawPtr) }
        let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(String(cString: rawPtr).utf8))
        #expect(decoded.version == 2)
    }

    @Test("Real Rust snapshot projects authoritative canTrash, isTranscribing, reviewCounts, provider catalog, captureLanes, device transfer fields, and speech languages")
    @MainActor
    func realRustSingleSourceOfTruthSnapshotContract() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }
        let t0: UInt64 = 1_800_300_000

        let initialProvider = store.settings.provider
        let catalog = try #require(initialProvider.catalog)
        #expect(catalog.qwenAsrModels.count == 4)
        #expect(catalog.deepseekLlmModels.count == 2)
        #expect(catalog.defaultQwenHost == "dashscope.aliyuncs.com")
        #expect(catalog.qwenWorkspaceHostSuffix == ".cn-beijing.maas.aliyuncs.com")
        #expect(catalog.defaultDeepseekAsrEndpoint == "https://api.deepseek.com/v1/tools/asr")
        #expect(catalog.defaultDeepseekChatEndpoint == "https://api.deepseek.com/chat/completions")
        #expect(catalog.defaultQwenAsrModel == "qwen-audio-3.1-asr-flash-streaming")
        #expect(catalog.defaultDeepseekLlmModel == "deepseek-flash")
        #expect(initialProvider.defaultAsrEndpoint == "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
        #expect(initialProvider.defaultChatEndpoint == "https://api.deepseek.com/chat/completions")

        store.send(
            .configureProvider(
                asrProvider: "qwen",
                asrModel: "qwen-audio-3.1-asr-flash-filetrans",
                llmProvider: "deepseek",
                model: "deepseek-flash",
                qwenWorkspaceId: "ws-swift-1",
                asrEndpoint: "",
                chatEndpoint: ""
            ),
            nowEpochSec: t0 + 1
        )
        let expectedWsEndpoint = "https://ws-swift-1.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription"
        #expect(store.settings.provider.defaultAsrEndpoint == expectedWsEndpoint)
        #expect(store.settings.provider.asrEndpoint == expectedWsEndpoint)

        #expect(store.device.transferErrorCode == 0)
        #expect(store.device.audioDecryptReady == false)
        #expect(!store.settings.speech.models.isEmpty)
        #expect(store.settings.speech.models.allSatisfy { !$0.languages.isEmpty })

        store.send(.createNote(title: "单一真相笔记", text: "第一句。\n第二句。", stayOnPage: false), nowEpochSec: t0 + 2)
        let noteDetail = try #require(store.recordDetail.detail)
        let noteRow = try #require(store.records.first(where: { $0.id == noteDetail.id }))
        #expect(noteRow.canTrash == true)
        #expect(noteRow.isTranscribing == false)
        #expect(noteDetail.canTrash == true)

        store.send(.setRecordArchived(recordId: noteDetail.id, archived: true), nowEpochSec: t0 + 3)
        #expect(store.records.first(where: { $0.id == noteDetail.id })?.canTrash == false)
        #expect(store.recordDetail.detail?.canTrash == false)
        store.send(.setRecordArchived(recordId: noteDetail.id, archived: false), nowEpochSec: t0 + 4)
        #expect(store.records.first(where: { $0.id == noteDetail.id })?.canTrash == true)

        let firstSegment = try #require(noteDetail.segments.first)
        store.send(.createTask(recordId: noteDetail.id, segmentId: firstSegment.id), nowEpochSec: t0 + 5)
        store.send(.saveMemory(recordId: noteDetail.id, segmentId: firstSegment.id), nowEpochSec: t0 + 6)
        let taskID = try #require(store.tasks.first?.id)
        let memoryID = try #require(store.memories.first?.id)
        store.send(.reviewItem(itemId: taskID, decision: .reset), nowEpochSec: t0 + 7)
        store.send(.reviewItem(itemId: memoryID, decision: .reset), nowEpochSec: t0 + 8)

        let counts = try #require(store.snapshot.reviewCounts)
        #expect(counts == ReviewCountsSnapshot(
            proposedTaskCount: 1,
            proposedMemoryCount: 1,
            proposedActionCount: 2,
            activeMemoryCount: 1
        ))
        #expect(store.sidebar.proposedTaskCount == 1)
        #expect(store.sidebar.memoryCount == 1)
        #expect(store.today.proposedActionCount == 2)

        store.send(.reviewItem(itemId: memoryID, decision: .dismiss), nowEpochSec: t0 + 9)
        #expect(store.snapshot.reviewCounts?.activeMemoryCount == 0)
        #expect(store.sidebar.proposedTaskCount == 1)
        #expect(store.sidebar.memoryCount == 0)
        #expect(store.today.proposedActionCount == 1)

        store.send(.startCaptureMode(mode: .quickNote, stayOnPage: true), nowEpochSec: t0 + 10)
        let mic = try #require(store.snapshot.microphone)
        store.send(.microphonePrepared(recordId: mic.recordId, sessionId: mic.sessionId, epoch: 0, clockNs: 1_000_000_000), nowEpochSec: t0 + 10)
        store.send(.microphoneStarted(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sampleRate: 16000), nowEpochSec: t0 + 10)
        let ingest = store.ingestMicrophonePCM(
            recordId: mic.recordId,
            sessionId: mic.sessionId,
            lane: "microphone",
            sequence: 0,
            epoch: 0,
            capturedStartNs: 1_000_000_000,
            samples: [Int16](repeating: 240, count: 320),
            nowEpochSec: t0 + 10
        )
        #expect(ingest.status == .accepted)
        store.send(.selectRecord(recordId: mic.recordId), nowEpochSec: t0 + 10)
        let activeRow = try #require(store.records.first(where: { $0.id == mic.recordId }))
        #expect(activeRow.canTrash == false)
        #expect(activeRow.isTranscribing == true)
        #expect(store.recordDetail.detail?.canTrash == false)

        store.send(.captureAction(action: .end), nowEpochSec: t0 + 11)
        store.send(.microphoneStopped(recordId: mic.recordId, sessionId: mic.sessionId, lane: "microphone", sequence: 1, epoch: 0), nowEpochSec: t0 + 11)
        store.send(.selectRecord(recordId: mic.recordId), nowEpochSec: t0 + 12)
        let capturedDetail = try #require(store.recordDetail.detail)
        let micLane = try #require(capturedDetail.captureLanes.first(where: { $0.lane == "microphone" }))
        #expect(micLane.sampleRate == 16000)
        #expect(micLane.durationMs > 0)
        #expect(micLane.timeline.first?.sampleCount == 320)
        try assertRawSnapshotDecodes(handle: store.handle, now: t0 + 12)
    }
}
