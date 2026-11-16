import Dispatch
import Foundation
import os

final class AudioCallbackFence: @unchecked Sendable {
    private struct State {
        var accepting = true
        var active = 0
        var waiters = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let drained = DispatchSemaphore(value: 0)

    func enter() -> Bool {
        state.withLock { state in
            guard state.accepting else { return false }
            state.active += 1
            return true
        }
    }

    func leave() {
        let count = state.withLock { state -> Int in
            state.active -= 1
            guard !state.accepting, state.active == 0 else { return 0 }
            let count = state.waiters
            state.waiters = 0
            return count
        }
        for _ in 0..<count {
            drained.signal()
        }
    }

    func closeAndWait() {
        let shouldWait = state.withLock { state in
            state.accepting = false
            guard state.active > 0 else { return false }
            state.waiters += 1
            return true
        }
        if shouldWait { drained.wait() }
    }
}
