import AVFoundation
import KoeAppleCore
import os

protocol AudioInputNotificationCenter: Sendable {
    func addObserver(
        forName name: NSNotification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol
    func removeObserver(_ observer: Any)
}

extension NotificationCenter: AudioInputNotificationCenter {}

@MainActor
final class IOSAudioInputMonitor {
    private let store: HostSessionStore
    private let observerBox: OSAllocatedUnfairLock<(center: any AudioInputNotificationCenter, tokens: [NSObjectProtocol])>
    private let inputs: () throws -> [HostAudioInputDescriptor]?
    private var lastInputs: [HostAudioInputDescriptor]?

    init(store: HostSessionStore, center: any AudioInputNotificationCenter = NotificationCenter.default,
         inputs: @escaping () throws -> [HostAudioInputDescriptor]?) {
        self.store = store
        self.observerBox = OSAllocatedUnfairLock(uncheckedState: (center, []))
        self.inputs = inputs
    }

    deinit { clearObservers() }

    convenience init(store: HostSessionStore, audioSession: IOSAudioSession) {
        self.init(store: store) {
            guard try audioSession.prepareInputDiscovery() else { return nil }
            return Self.availableInputs()
        }
    }

    func start() {
        stop()
        var names = [AVAudioSession.routeChangeNotification]
        if #available(iOS 26.0, *) { names.append(AVAudioSession.availableInputsChangeNotification) }
        observerBox.withLockUnchecked { state in
            for name in names {
                state.tokens.append(state.center.addObserver(forName: name, object: AVAudioSession.sharedInstance(),
                                                             queue: nil) { [weak self] _ in
                    Task { @MainActor in self?.sync() }
                })
            }
        }
        sync()
    }

    func stop() {
        clearObservers()
        lastInputs = nil
    }

    private nonisolated func clearObservers() {
        observerBox.withLockUnchecked { state in
            state.tokens.forEach(state.center.removeObserver)
            state.tokens.removeAll()
        }
    }

    private func sync() {
        guard observerBox.withLockUnchecked({ !$0.tokens.isEmpty }) else { return }
        do {
            guard let rawDevices = try inputs() else { return }
            let devices = HostAudioInputDescriptor.normalized(rawDevices)
            guard devices != lastInputs else { return }
            store.send(.syncAudioInputs(inputs: devices))
            lastInputs = devices
            IOSAudioSource.logger.info("可用麦克风数量：\(devices.count)")
        } catch {
            let message = "同步麦克风输入失败：\(error.localizedDescription)"
            IOSAudioSource.logger.error("\(message, privacy: .public)")
            store.reportNativeError(message)
        }
    }

    private nonisolated static func availableInputs() -> [HostAudioInputDescriptor] {
        let session = AVAudioSession.sharedInstance()
        let current = session.currentRoute.inputs.first?.uid
        return (session.availableInputs ?? []).map { port in
            HostAudioInputDescriptor(id: port.uid, name: port.portName,
                                     transport: transport(for: port.portType), isDefault: port.uid == current)
        }
    }

    nonisolated static func transport(for port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInMic: "built_in"
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: "bluetooth"
        case .usbAudio: "usb"
        default: "external"
        }
    }
}
