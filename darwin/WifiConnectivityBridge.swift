import Network
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Inspect the system default path, not the mere presence of an interface.
enum WifiConnectivityBridge {
  static func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.semanticcraft.koe/wifi_connectivity", binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "isWifiConnected" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let monitor = NWPathMonitor()
      // Both completion and timeout are serialized on the main queue.
      var completed = false
      func finish(_ wifi: Bool) {
        guard !completed else { return }
        completed = true
        monitor.cancel()
        result(wifi)
      }
      monitor.pathUpdateHandler = { path in
        finish(path.status == .satisfied && path.usesInterfaceType(.wifi)
          && !path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wiredEthernet))
      }
      monitor.start(queue: .main)
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false) }
    }
  }
}
