import AppKit
import Darwin
import Foundation
import KoeAppleShared
import SwiftUI
import Testing
@testable import Koe

private final class LoopbackReleaseFixture: @unchecked Sendable {
    let port: UInt16
    private let fdLock = NSLock()
    private var listenFD: Int32
    private var serverThread: Thread?

    init(statusLine: String, body: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLen)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)

        let payloadBytes = Array(body.utf8)
        let header = "HTTP/1.1 \(statusLine)\r\nContent-Type: application/json\r\nContent-Length: \(payloadBytes.count)\r\nConnection: close\r\n\r\n"
        let responseBytes = Array(header.utf8) + payloadBytes

        let thread = Thread { [weak self] in
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(fd, &clientAddr, &clientLen)
            self?.closeListenFD()
            guard clientFD >= 0 else {
                return
            }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var reqBytes: [UInt8] = []
            var reqBuf = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = read(clientFD, &reqBuf, reqBuf.count)
                if n <= 0 { break }
                reqBytes.append(contentsOf: reqBuf[0..<n])
                if reqBytes.count >= 4 {
                    var foundEnd = false
                    for idx in 0...(reqBytes.count - 4) where reqBytes[idx] == 13 && reqBytes[idx + 1] == 10 && reqBytes[idx + 2] == 13 && reqBytes[idx + 3] == 10 {
                        foundEnd = true
                        break
                    }
                    if foundEnd { break }
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
            close(clientFD)
        }
        thread.start()
        self.serverThread = thread
    }

    private func closeListenFD() {
        fdLock.lock()
        let fd = listenFD
        listenFD = -1
        fdLock.unlock()
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    deinit {
        closeListenFD()
    }

    var endpointURL: String {
        "http://127.0.0.1:\(port)/repos/semantic-craft/koe/releases/latest"
    }
}

extension SerializedMacHostSuites {
@Suite("App version display and update check host workflow", .serialized)
struct AppUpdateHostTests {
    @Test("External release URL allowlist permits GitHub Releases and loopback while rejecting untrusted schemes and hosts")
    @MainActor
    func externalReleaseURLAllowlist() throws {
        #expect(KoeAppDelegate.isAllowedExternalReleaseURL(
            try #require(URL(string: "https://github.com/semantic-craft/koe/releases"))
        ))
        #expect(KoeAppDelegate.isAllowedExternalReleaseURL(
            try #require(URL(string: "https://github.com/semantic-craft/koe/releases/tag/v2.3.0"))
        ))
        #expect(KoeAppDelegate.isAllowedExternalReleaseURL(
            try #require(URL(string: "https://github.com/semantic-craft/koe/releases/download/v2.3.0/Koe-2.3.0-macos-arm64.zip"))
        ))
        #expect(KoeAppDelegate.isAllowedExternalReleaseURL(
            try #require(URL(string: "http://127.0.0.1:9090/release"))
        ))
        #expect(KoeAppDelegate.isAllowedExternalReleaseURL(
            try #require(URL(string: "http://127.0.0.1:9090/release?asset=Koe%2Ezip"))
        ))

        for unsafeRaw in [
            "http://github.com/semantic-craft/koe/releases",
            "https://github.com:8443/semantic-craft/koe/releases",
            "https://github.com/other-org/koe/releases",
            "https://github.com/semantic-craft/koe/releases/../../other-org/koe",
            "https://github.com/semantic-craft/koe/releases/%2e%2e/other-org/koe",
            "https://github.com/semantic-craft/koe/releases/download/../../../evil/Koe.zip",
            "https://evil.example.com/semantic-craft/koe/releases",
            "https://user:pass@github.com/semantic-craft/koe/releases",
            "https://github.com/semantic-craft/koe/releases#frag",
            "file:///Applications/Koe.app",
            "javascript:alert(1)"
        ] {
            if let url = URL(string: unsafeRaw) {
                #expect(!KoeAppDelegate.isAllowedExternalReleaseURL(url), "accepted unsafe URL: \(unsafeRaw)")
            }
        }
    }

    @Test("Bundle Info.plist metadata syncs idempotently, status menu displays version, and menu update check surfaces newer release")
    @MainActor
    func bundleSyncStatusMenuAndEndToEndUpdateCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let delegate = KoeAppDelegate(playback: NativePlayback(), defaultInputsProvider: { [] }, makeDefaultStore: { store })
        delegate.store = store
        let workspaceWindow = NSWindow(
            contentRect: NSRect(x: -16000, y: -16000, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        workspaceWindow.alphaValue = 0
        workspaceWindow.collectionBehavior = [.ignoresCycle, .transient]
        KoeWindowPresenter.presentWindow(workspaceWindow, activateApp: false)
        defer {
            workspaceWindow.orderOut(nil)
            delegate.store = nil
        }

        var openedURLs: [URL] = []
        store.bridgeActions.openExternalURL = { openedURLs.append($0) }

        let initialMenu = delegate.buildStatusMenu()
        #expect(initialMenu.items.contains(where: { $0.title == "版本 v\(AppUpdateSnapshot.defaultVersion) (\(AppUpdateSnapshot.defaultBuild))" && !$0.isEnabled }))
        #expect(initialMenu.items.contains(where: { $0.title == "检查更新…" && $0.isEnabled }))

        // Matching Info.plist does not bump generation; updated Info.plist syncs once.
        let genBeforeSame = store.snapshot.generation
        delegate.syncAppMetadataIfNeeded(infoDictionary: [
            "CFBundleShortVersionString": AppUpdateSnapshot.defaultVersion,
            "CFBundleVersion": AppUpdateSnapshot.defaultBuild
        ])
        #expect(store.snapshot.generation == genBeforeSame)

        delegate.syncAppMetadataIfNeeded(infoDictionary: [
            "CFBundleShortVersionString": "2.2.0",
            "CFBundleVersion": "11"
        ])
        #expect(store.settings.appUpdate.currentVersion == "2.2.0")
        #expect(store.settings.appUpdate.currentBuild == "11")
        #expect(store.sidebar.appVersion == "2.2.0")
        let genAfterSync = store.snapshot.generation
        delegate.syncAppMetadataIfNeeded(infoDictionary: [
            "CFBundleShortVersionString": "2.2.0",
            "CFBundleVersion": "11"
        ])
        #expect(store.snapshot.generation == genAfterSync)

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let assetName = "Koe-2.10.0-macos-\(arch).zip"
        let downloadURL = "https://github.com/semantic-craft/koe/releases/download/v2.10.0/\(assetName)"
        let fixture = try LoopbackReleaseFixture(
            statusLine: "200 OK",
            body: """
            {
              "tag_name": "v2.10.0",
              "name": "Koe 2.10.0 (20)",
              "draft": false,
              "prerelease": false,
              "html_url": "https://github.com/semantic-craft/koe/releases/tag/v2.10.0",
              "body": "新增版本显示与检查更新",
              "assets": [
                {
                  "name": "\(assetName)",
                  "size": 8123456,
                  "browser_download_url": "\(downloadURL)"
                }
              ]
            }
            """
        )

        store.send(.syncAppMetadata(
            version: "2.2.0",
            build: "11",
            updateEndpoint: fixture.endpointURL
        ), nowEpochSec: 1_800_000_000)

        delegate.requestUpdateCheck()
        #expect(store.navigation.section == "settings")
        #expect(store.navigation.canGoBack == true)

        // Repeating requestUpdateCheck while already on settings does not push a duplicate settings entry onto back stack.
        delegate.requestUpdateCheck()
        store.send(.back)
        #expect(store.navigation.section == "today")
        delegate.requestUpdateCheck()
        #expect(store.navigation.section == "settings")

        let deadline = ContinuousClock.now + .seconds(4)
        while store.settings.appUpdate.isChecking, ContinuousClock.now < deadline {
            store.pollTimers(elapsedMs: 50, nowEpochSec: 1_800_000_005)
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.settings.appUpdate.phase == "available")
        #expect(store.settings.appUpdate.latestVersion == "2.10.0")
        #expect(store.settings.appUpdate.assetName == assetName)
        #expect(store.settings.appUpdate.downloadUrl == downloadURL)
        #expect(store.sidebar.hasAvailableUpdate == true)

        delegate.menuNeedsUpdate(initialMenu)
        #expect(initialMenu.items.contains(where: { $0.title == "版本 v2.2.0 (11)" }))
        #expect(initialMenu.items.contains(where: { $0.title == "检查更新…（新版本 v2.10.0）" }))

        let parsedDownload = try #require(URL(string: downloadURL))
        store.bridgeActions.openExternalURL(parsedDownload)
        #expect(openedURLs == [parsedDownload])

        // Offscreen window closure still reconciles menu version and idempotent sync without extra generation churn.
        workspaceWindow.close()
        #expect(!store.isUISlicesActive)
        delegate.syncAppMetadataIfNeeded(infoDictionary: [
            "CFBundleShortVersionString": "2.3.0",
            "CFBundleVersion": "12"
        ])
        let genAfterOffscreenSync = store.snapshot.generation
        delegate.syncAppMetadataIfNeeded(infoDictionary: [
            "CFBundleShortVersionString": "2.3.0",
            "CFBundleVersion": "12"
        ])
        #expect(store.snapshot.generation == genAfterOffscreenSync)
        delegate.menuNeedsUpdate(initialMenu)
        #expect(initialMenu.items.contains(where: { $0.title == "版本 v2.3.0 (12)" }))

        // Non-canonical Info.plist version strings sync at most once and never set an error banner.
        delegate.syncAppMetadataIfNeeded(infoDictionary: [
            "CFBundleShortVersionString": "v2.4.0-beta.1",
            "CFBundleVersion": "12_qa"
        ])
        #expect(store.navigation.effectiveError == nil)
        let genAfterPrereleaseSync = store.snapshot.generation
        delegate.syncAppMetadataIfNeeded(infoDictionary: [
            "CFBundleShortVersionString": "v2.4.0-beta.1",
            "CFBundleVersion": "12_qa"
        ])
        #expect(store.snapshot.generation == genAfterPrereleaseSync)
        delegate.menuNeedsUpdate(initialMenu)
        #expect(initialMenu.items.contains(where: { $0.title == "版本 v2.4.0 (12_qa)" }))

        // While quitting is draining an active device recording, menu disables check-for-updates
        // and requestUpdateCheck does not navigate away from the current section.
        KoeWindowPresenter.presentWindow(workspaceWindow, activateApp: false)
        store.send(.navigate(section: "today"))
        #expect(store.navigation.section == "today")
        var bleStart: [UInt8] = [0x09, 0xff, 0, 0, 1, 0x18, 0x81, 14, 0, 0x93, 0x03, 0, 0]
        bleStart.append(bleStart.reduce(0, &+))
        store.ingestBleChunk(Data(bleStart), nowEpochSec: 1_800_000_010)
        store.send(.requestQuit)
        #expect(store.lifecycle?.quitPhase == "blocked")

        delegate.menuNeedsUpdate(initialMenu)
        #expect(initialMenu.items.contains(where: { $0.title.hasPrefix("检查更新") && !$0.isEnabled }))

        delegate.requestUpdateCheck()
        #expect(store.navigation.section == "today")
        #expect(store.navigation.effectiveError != nil)

        store.send(.cancelQuit)
        store.clearError()
    }

    @Test("Sidebar header stays single-line at 196pt with multi-digit SemVer and Settings places AppUpdateSettingsCard in top viewport")
    @MainActor
    func sidebarSingleLineGeometryAndSettingsTopCardPlacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path)
        defer { store.shutdown() }

        let fixture = try LoopbackReleaseFixture(
            statusLine: "200 OK",
            body: """
            {
              "tag_name": "v99.100.200",
              "name": "Koe 99.100.200",
              "published_at": "2026-11-19T02:00:00Z",
              "html_url": "https://github.com/semantic-craft/koe/releases/tag/v99.100.200",
              "body": "支持长版本号与更新卡片置顶展示",
              "assets": []
            }
            """
        )

        let baselineSidebar = NSHostingView(rootView: SidebarView(store: store))
        baselineSidebar.frame = NSRect(x: 0, y: 0, width: 196, height: 680)
        baselineSidebar.layoutSubtreeIfNeeded()
        let baselineFittingHeight = baselineSidebar.fittingSize.height

        store.send(.syncAppMetadata(
            version: "12.34.567",
            build: "9876",
            updateEndpoint: fixture.endpointURL
        ), nowEpochSec: 1_800_000_500)
        store.send(.checkAppUpdate, nowEpochSec: 1_800_000_501)
        let deadline = Date(timeIntervalSinceNow: 3.0)
        while store.settings.appUpdate.isChecking, Date() < deadline {
            store.pollTimers(elapsedMs: 50, nowEpochSec: 1_800_000_505)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(store.sidebar.appVersion == "12.34.567")
        #expect(store.sidebar.hasAvailableUpdate == true)

        let longSidebar = NSHostingView(rootView: SidebarView(store: store))
        longSidebar.frame = NSRect(x: 0, y: 0, width: 196, height: 680)
        longSidebar.layoutSubtreeIfNeeded()
        let longFittingHeight = longSidebar.fittingSize.height
        #expect(
            abs(longFittingHeight - baselineFittingHeight) <= 4.0,
            "Sidebar fitting height grew from \(baselineFittingHeight) to \(longFittingHeight), indicating unexpected multi-line wrapping at width 196"
        )

        let settingsHosting = NSHostingView(rootView: SettingsDoctorView(store: store))
        settingsHosting.frame = NSRect(x: 0, y: 0, width: 843, height: 618)
        settingsHosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        settingsHosting.layoutSubtreeIfNeeded()
        #expect(settingsHosting.fittingSize.width > 0)
        #expect(settingsHosting.bounds.height == 618)
    }
}
}
