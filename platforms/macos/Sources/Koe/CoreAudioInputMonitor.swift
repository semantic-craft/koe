import CoreAudio
import Foundation

public protocol CoreAudioPropertyListening: AnyObject, Sendable {
    func startListening(queue: DispatchQueue, onPropertyChanged: @escaping @Sendable () -> Void)
    func stopListening(queue: DispatchQueue)
}

public final class SystemCoreAudioPropertyListener: CoreAudioPropertyListening, @unchecked Sendable {
    typealias PropertyRegistration = @Sendable (
        AudioObjectID,
        UnsafePointer<AudioObjectPropertyAddress>,
        DispatchQueue,
        @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    private let lock = NSLock()
    private let addListener: PropertyRegistration
    private let removeListener: PropertyRegistration
    private var generation: UInt64 = 0
    private var isActive = false
    private var registeredBlock: AudioObjectPropertyListenerBlock?
    private var registeredDevices = false
    private var registeredDefaultInput = false
    private var registeredServiceRestarted = false

    public convenience init() {
        self.init(
            addListener: { object, address, queue, block in
                AudioObjectAddPropertyListenerBlock(object, address, queue, block)
            },
            removeListener: { object, address, queue, block in
                AudioObjectRemovePropertyListenerBlock(object, address, queue, block)
            }
        )
    }

    init(
        addListener: @escaping PropertyRegistration,
        removeListener: @escaping PropertyRegistration
    ) {
        self.addListener = addListener
        self.removeListener = removeListener
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var serviceRestartedAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    public func startListening(queue: DispatchQueue, onPropertyChanged: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !isActive else {
            lock.unlock()
            return
        }
        isActive = true
        generation &+= 1
        let startGeneration = generation
        lock.unlock()

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onPropertyChanged()
        }
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddr = Self.devicesAddress
        var defaultAddr = Self.defaultInputAddress
        var restartedAddr = Self.serviceRestartedAddress
        let addedDevices = addListener(systemObject, &devicesAddr, queue, block) == noErr
        let addedDefault = addListener(systemObject, &defaultAddr, queue, block) == noErr
        let addedRestarted = addListener(systemObject, &restartedAddr, queue, block) == noErr

        lock.lock()
        let stillCurrent = isActive && generation == startGeneration
        if stillCurrent {
            if addedDevices || addedDefault || addedRestarted {
                registeredBlock = block
                registeredDevices = addedDevices
                registeredDefaultInput = addedDefault
                registeredServiceRestarted = addedRestarted
            } else {
                isActive = false
            }
        }
        lock.unlock()

        if !stillCurrent {
            removeRegistered(
                block: block,
                devices: addedDevices,
                defaultInput: addedDefault,
                serviceRestarted: addedRestarted,
                queue: queue
            )
        }
    }

    public func stopListening(queue: DispatchQueue) {
        lock.lock()
        isActive = false
        generation &+= 1
        let block = registeredBlock
        let hadDevices = registeredDevices
        let hadDefault = registeredDefaultInput
        let hadRestarted = registeredServiceRestarted
        registeredBlock = nil
        registeredDevices = false
        registeredDefaultInput = false
        registeredServiceRestarted = false
        lock.unlock()
        guard let block else { return }
        removeRegistered(
            block: block,
            devices: hadDevices,
            defaultInput: hadDefault,
            serviceRestarted: hadRestarted,
            queue: queue
        )
    }

    private func removeRegistered(
        block: @escaping AudioObjectPropertyListenerBlock,
        devices: Bool,
        defaultInput: Bool,
        serviceRestarted: Bool,
        queue: DispatchQueue
    ) {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if devices {
            var devicesAddr = Self.devicesAddress
            _ = removeListener(systemObject, &devicesAddr, queue, block)
        }
        if defaultInput {
            var defaultAddr = Self.defaultInputAddress
            _ = removeListener(systemObject, &defaultAddr, queue, block)
        }
        if serviceRestarted {
            var restartedAddr = Self.serviceRestartedAddress
            _ = removeListener(systemObject, &restartedAddr, queue, block)
        }
    }
}

public final class CoreAudioInputMonitor: @unchecked Sendable {
    private let listener: CoreAudioPropertyListening
    private let queue = DispatchQueue(label: "com.koe.coreaudio.input-monitor", qos: .utility)
    private let debounceInterval: DispatchTimeInterval
    private let registrationLock = NSRecursiveLock()
    private let lock = NSLock()
    private var isListenerRegistered = false
    private var isStarted = false
    private var changeGeneration: UInt64 = 1
    private var debounceWorkItem: DispatchWorkItem?
    private var onHardwareChanged: (@MainActor @Sendable () -> Void)?

    public init(
        listener: CoreAudioPropertyListening = SystemCoreAudioPropertyListener(),
        debounceInterval: DispatchTimeInterval = .milliseconds(50)
    ) {
        self.listener = listener
        self.debounceInterval = debounceInterval
    }

    deinit {
        stop()
    }

    public var currentChangeGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return changeGeneration
    }

    public func start(onHardwareChanged: @escaping @MainActor @Sendable () -> Void) {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        lock.lock()
        self.onHardwareChanged = onHardwareChanged
        if isStarted {
            lock.unlock()
            return
        }
        isStarted = true
        changeGeneration &+= 1
        lock.unlock()

        if !isListenerRegistered {
            listener.startListening(queue: queue) { [weak self] in
                self?.handlePropertyChanged()
            }
            isListenerRegistered = true
        }

        lock.lock()
        let stillStarted = isStarted
        lock.unlock()
        if !stillStarted, isListenerRegistered {
            isListenerRegistered = false
            listener.stopListening(queue: queue)
        }
    }

    public func stop() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        lock.lock()
        isStarted = false
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        onHardwareChanged = nil
        lock.unlock()
        if isListenerRegistered {
            isListenerRegistered = false
            listener.stopListening(queue: queue)
        }
    }

    private func activeCallback() -> (@MainActor @Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return isStarted ? onHardwareChanged : nil
    }

    private func handlePropertyChanged() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        changeGeneration &+= 1
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let callback = self?.activeCallback() else { return }
                callback()
            }
        }
        debounceWorkItem = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
