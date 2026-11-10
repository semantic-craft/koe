import Foundation

final class AudioCallbackFence: @unchecked Sendable {
    private let condition = NSCondition()
    private var accepting = true
    private var active = 0
    func enter() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard accepting else { return false }
        active += 1
        return true
    }
    func leave() {
        condition.lock(); defer { condition.unlock() }
        active -= 1
        if active == 0 { condition.broadcast() }
    }
    func closeAndWait() {
        condition.lock(); defer { condition.unlock() }
        accepting = false
        while active > 0 { condition.wait() }
    }
}
