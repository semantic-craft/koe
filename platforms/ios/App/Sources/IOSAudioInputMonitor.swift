import AVFoundation
import KoeAppleCore

@MainActor
final class IOSAudioInputMonitor {
    private let store: HostSessionStore
    private let center: NotificationCenter
    private let inputs: () throws -> [HostAudioInputDescriptor]
    private var observers: [NSObjectProtocol] = []
    private var lastInputs: [HostAudioInputDescriptor]?

    init(store: HostSessionStore, center: NotificationCenter = .default,
         inputs: @escaping () throws -> [HostAudioInputDescriptor] = IOSAudioInputMonitor.availableInputs) {
        self.store = store
        self.center = center
        self.inputs = inputs
    }

    func start() {
        guard observers.isEmpty else { return }
        var names = [AVAudioSession.routeChangeNotification]
        if #available(iOS 26.0, *) { names.append(AVAudioSession.availableInputsChangeNotification) }
        for name in names {
            observers.append(center.addObserver(forName: name, object: AVAudioSession.sharedInstance(),
                                                queue: nil) { [weak self] _ in
                Task { @MainActor in self?.sync() }
            })
        }
        sync()
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers.removeAll()
        lastInputs = nil
    }

    private func sync() {
        guard !observers.isEmpty else { return }
        do {
            let devices = try inputs()
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

    private nonisolated static func availableInputs() throws -> [HostAudioInputDescriptor] {
        let session = AVAudioSession.sharedInstance()
        try IOSAudioSource.configure(session)
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
