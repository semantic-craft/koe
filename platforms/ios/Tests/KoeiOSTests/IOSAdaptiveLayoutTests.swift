import KoeAppleCore
import SwiftUI
import XCTest
@testable import KoeiOSApp

@MainActor
final class IOSAdaptiveLayoutTests: XCTestCase {
    func testLaunchRegistersTheActualDeviceFamily() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = IOSLaunchSession(bridgeActions: HostBridgeActions(),
                                       arguments: ["Koe", "-koe-workspace", directory.path],
                                       environment: [:], allowsCoreBluetooth: false)
        defer { session.shutdown() }
        XCTAssertEqual(session.store.platform.hostDisplayName, UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
    }

    func testRegularMeetingLaysOutTranscriptAndMinutesInLessVerticalSpace() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostSessionStore(workspacePath: directory.path, credentials: NativeCredentialsiOS(forceIsolated: true))
        defer { store.shutdown() }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ios-rich-snapshot", withExtension: "json"))
        XCTAssertTrue(store.loadDebugSnapshotFixtureJSON(try String(contentsOf: url, encoding: .utf8)))
        let files = IOSFileActions(store: store, stagingRoot: directory.appendingPathComponent("files"))
        func height(_ sizeClass: UserInterfaceSizeClass) -> CGFloat {
            let content = VStack(spacing: 14) {
                IOSLiveMinutesWorkspaceView(store: store, onSelectRecord: { _ in }, onOpenSource: { _ in })
            }
            .environment(\.horizontalSizeClass, sizeClass)
            .environment(files)
            let host = UIHostingController(rootView: content)
            return host.sizeThatFits(in: CGSize(width: 1000, height: 5000)).height
        }
        XCTAssertLessThan(height(.regular), height(.compact) - 32)
    }

    func testChromeObscuresHighContrastContentOnModernIOS() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("需要 iOS 26 或更新版本") }
        let content = ZStack(alignment: .top) {
            HStack(spacing: 0) {
                ForEach(0..<40, id: \.self) { column in
                    (column.isMultiple(of: 2) ? Color.white : Color.black).frame(width: 2)
                }
            }
            Color.clear.frame(height: 40).iosChromeSurface()
        }
        .frame(width: 80, height: 80)
        .environment(\.colorScheme, .light)
        let host = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        host.view.frame = CGRect(x: 100, y: 120, width: 80, height: 80)
        window.addSubview(host.view)
        defer { host.view.removeFromSuperview() }
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        add(XCTAttachment(image: image))
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 80 * 80 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 80, height: 80, bitsPerComponent: 8,
                                              bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 80, height: 80))
        func contrast(y: Int) -> Int {
            let row = (20..<60).map { Int(pixels[(y * 80 + $0) * 4]) }
            return (row.max() ?? 0) - (row.min() ?? 0)
        }
        XCTAssertGreaterThan(contrast(y: 60), 180, "未遮盖的条纹应清晰可见")
        XCTAssertLessThan(contrast(y: 20), 80, "底栏下方的条纹应被材质遮盖")
    }
}
