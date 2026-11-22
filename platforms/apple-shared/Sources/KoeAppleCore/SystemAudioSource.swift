/// Result of the public-API system audio authorization canary.
public enum SystemAudioAuthResult: Equatable, Sendable {
    case authorized
    case denied(String)
    case unavailable(String)
    case cancelled

    var failureMessage: String? {
        switch self {
        case .authorized: nil
        case .denied(let message), .unavailable(let message): message
        case .cancelled: "已取消系统音频授权检测。"
        }
    }
}

/// Host adapter for the optional system audio lane. Tests inject deterministic fakes so they never
/// touch Core Audio taps or macOS permission prompts.
public protocol SystemAudioSource: AnyObject {
    func authorize(shouldAbort: @escaping @Sendable () -> Bool,
                   _ completion: @escaping @Sendable (SystemAudioAuthResult) -> Void)
    func start(expectedSampleRate: UInt32?, receive: @escaping @Sendable (CapturedPCM) -> Void,
               failed: @escaping @Sendable (String) -> Void) throws -> UInt32
    func stop()
}
