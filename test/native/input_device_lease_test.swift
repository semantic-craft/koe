import Foundation

@main struct LeaseTests {
    static func main() throws {
        var current = "mic"
        var disk: Data?
        var failWrite = true
        var writes = 0
        let lease = InputDeviceLease(read: { disk }, write: { value in
            if failWrite { throw NSError(domain: "disk", code: 1) }
            disk = value
        }, current: { current }, physical: { $0 == "mic" }, set: { value in
            precondition(disk != nil, "persist before switching")
            writes += 1; current = value
        })
        do { try lease.acquire(session: "one", target: "hole"); fatalError("must fail") } catch {}
        precondition(current == "mic" && writes == 0)
        failWrite = false
        try lease.acquire(session: "two", target: "hole")
        precondition(current == "hole")
        current = "user-choice"
        try lease.release()
        precondition(current == "user-choice" && disk == nil)
        current = "mic"
        try lease.acquire(session: "three", target: "hole")
        try lease.release()
        precondition(current == "mic" && disk == nil)
        try lease.acquire(session: "four", target: "hole")
        let recovery = InputDeviceLease(read: { disk }, write: { disk = $0 }, current: { current }, physical: { _ in false }, set: { current = $0 })
        do { try recovery.release(); fatalError("missing original must fail") } catch {}
        precondition(current == "hole" && disk != nil)
        try lease.release()
        try lease.acquire(session: "five", target: "hole")
        current = "user-choice"; failWrite = true
        do { try lease.relinquish(); fatalError("must fail") } catch {}
        current = "hole"; failWrite = false
        try lease.release()
        precondition(current == "hole", "revoked ownership must not restore after delete failure")
        current = "mic"
        try lease.acquire(session: "six", target: "hole")
        current = "user-choice"; failWrite = true
        do { try lease.release(); fatalError("must fail") } catch {}
        current = "hole"; failWrite = false
        try lease.release()
        precondition(current == "hole", "recovery observing user choice must revoke before deletion")
        print("Input lease behavior passed")
    }
}
