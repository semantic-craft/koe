import Dispatch
import Foundation
import os

final class AudioCallbackFence: @unchecked Sendable {
    private struct State {
        var accepting = true
        var active = 0
        var waiting = false
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
        let shouldSignal = state.withLock { state in
            state.active -= 1
            guard !state.accepting, state.active == 0, state.waiting else { return false }
            state.waiting = false
            return true
        }
        if shouldSignal { drained.signal() }
    }

    func closeAndWait() {
        let shouldWait = state.withLock { state in
            state.accepting = false
            guard state.active > 0 else { return false }
            state.waiting = true
            return true
        }
        if shouldWait { drained.wait() }
    }
}
