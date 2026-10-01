import Foundation
import PhotoStreamShared

final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?
    private let name: String
    private let port: Int

    init(name: String, port: Int) {
        self.name = name
        self.port = port
    }

    func start() {
        let service = NetService(
            domain: PhotoStreamConstants.bonjourDomain,
            type: PhotoStreamConstants.bonjourType,
            name: name,
            port: Int32(port)
        )
        service.includesPeerToPeer = true
        service.delegate = self
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        print("PhotoStream Bonjour published: \(sender.name).\(sender.type)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        fputs("Bonjour publish failed: \(errorDict)\n", stderr)
    }
}
