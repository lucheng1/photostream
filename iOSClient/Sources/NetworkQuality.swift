import Foundation
import Network

/// Wi‑Fi / Ethernet → original 4K stream. Cellular / other (e.g. Tailscale over
/// 5G) → request the server's mobile proxy.
enum NetworkQuality: Sendable {
    case wifi
    case mobile

    /// Snapshot of the current path. Cheap; call when opening the player.
    static func current() async -> NetworkQuality {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "photostream.path")
            let lock = NSLock()
            var resumed = false
            let finish: (NWPath) -> Void = { path in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                monitor.cancel()
                if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                    continuation.resume(returning: .wifi)
                } else {
                    continuation.resume(returning: .mobile)
                }
            }
            monitor.pathUpdateHandler = { path in
                finish(path)
            }
            monitor.start(queue: queue)
            // Fallback if the first callback is delayed.
            queue.asyncAfter(deadline: .now() + 0.8) {
                finish(monitor.currentPath)
            }
        }
    }
}
