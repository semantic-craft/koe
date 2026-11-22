import CKoeHostApi
import Foundation

/// Platform I/O only. The runtime owns credential selection and persistence order.
public protocol HostCredentials: AnyObject, Sendable {
    var isolated: Bool { get }
    func perform(operation: UInt32, reference: String, value: String) throws -> String?
}

let hostCredentialCallback: KoeCredentialCallback = { context, operation, reference, value, output, capacity in
    guard let context, let reference, let value, let output, capacity > 0 else { return -1 }
    let adapter = Unmanaged<AnyObject>.fromOpaque(context).takeUnretainedValue()
    guard let credentials = adapter as? HostCredentials else { return -1 }
    do {
        guard let result = try credentials.perform(operation: operation,
                                                   reference: String(cString: reference),
                                                   value: String(cString: value)) else { return 1 }
        let bytes = Array(result.utf8CString)
        guard bytes.count <= capacity else { return -1 }
        bytes.withUnsafeBufferPointer { buffer in
            output.update(from: buffer.baseAddress!, count: buffer.count)
        }
        return 0
    } catch { return -1 }
}
