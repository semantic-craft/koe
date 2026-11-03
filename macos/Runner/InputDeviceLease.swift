import Foundation

/// Only the app's own lease may restore an input. CoreAudio has no cross-process CAS.
final class InputDeviceLease {
    struct Record: Codable {
        var version = 1
        let session: String
        let originalUID: String
        let targetUID: String
    }
    private var revoked = false
    let read: () throws -> Data?
    let write: (Data?) throws -> Void
    let current: () throws -> String
    let physical: (String) -> Bool
    let set: (String) throws -> Void
    init(read: @escaping () throws -> Data?, write: @escaping (Data?) throws -> Void,
         current: @escaping () throws -> String, physical: @escaping (String) -> Bool,
         set: @escaping (String) throws -> Void) {
        self.read = read; self.write = write; self.current = current
        self.physical = physical; self.set = set
    }
    private func record() throws -> Record? {
        guard let data = try read() else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1 else { throw failure("输入恢复记录版本不支持") }
        return record
    }
    func acquire(session: String, target: String) throws {
        try release()
        revoked = false
        let original = try current()
        guard original != target, physical(original) else { throw failure("请选择真实默认麦克风") }
        let value = Record(session: session, originalUID: original, targetUID: target)
        try write(JSONEncoder().encode(value))
        guard try current() == original else { try relinquish(); throw failure("默认输入已改变，请重试") }
        do {
            try set(target)
            guard try current() == target else { throw failure("无法确认默认输入切换") }
        } catch { try? release(); throw error }
    }
    func release() throws {
        if revoked { try write(nil); return }
        guard let value = try record() else { return }
        guard try current() == value.targetUID else { try relinquish(); return }
        guard physical(value.originalUID) else { throw failure("原麦克风不在，请接回或自行选择默认输入后刷新") }
        guard try current() == value.targetUID else { try relinquish(); return }
        try set(value.originalUID)
        guard try current() == value.originalUID else { throw failure("无法确认输入恢复，请检查系统输入") }
        try write(nil)
    }
    /// An observed external change revokes restoration, even if the user changes back.
    func relinquish() throws { revoked = true; try write(nil) }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "KoeInterpreting", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
