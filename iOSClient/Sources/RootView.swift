import Network
import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        Group {
            if model.isPaired, let client = model.client {
                GridHost(client: client)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                PairingView(model: model)
            }
        }
        .onAppear { model.startBrowsing() }
        .onDisappear {
            model.stopBrowsing()
            SessionImageCache.shared.clear()
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var services: [DiscoveredService] = []
    @Published var selected: DiscoveredService?
    @Published var pin: String = ""
    @Published var manualHost: String = ""
    @Published var status: String = "Looking for Mac…"
    @Published var isPaired = false
    @Published var client: PhotoStreamAPIClient?

    private var browser: NWBrowser?
    private let defaultsKey = "photostream.token"

    struct DiscoveredService: Identifiable, Hashable {
        var id: String { "\(name)|\(host)|\(port)" }
        var name: String
        var host: String
        var port: Int
    }

    func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: PhotoStreamConstants.bonjourBrowserType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .failed(let error):
                    self?.status = "Browse failed: \(error)"
                case .ready:
                    self?.status = "Select your Mac, enter PIN"
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.services = results.compactMap { result in
                    switch result.endpoint {
                    case .service(let name, _, _, _):
                        // Resolve via NWConnection later; store service name for now
                        return DiscoveredService(name: name, host: name, port: Int(PhotoStreamConstants.defaultPort))
                    default:
                        return nil
                    }
                }
                if self?.selected == nil {
                    self?.selected = self?.services.first
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    func pair() {
        status = "Pairing…"
        Task {
            do {
                let host: String
                let port: Int
                if !manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
                    port = Int(PhotoStreamConstants.defaultPort)
                } else if let selected {
                    host = try await resolveHost(serviceName: selected.name)
                    port = selected.port
                } else {
                    status = "No Mac selected"
                    return
                }
                let url = URL(string: "http://\(host):\(port)")!
                let api = PhotoStreamAPIClient(baseURL: url)
                _ = try await api.pair(pin: pin.trimmingCharacters(in: .whitespacesAndNewlines))
                UserDefaults.standard.set(host, forKey: "photostream.host")
                self.client = api
                self.isPaired = true
                self.status = "Connected"
                stopBrowsing()
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func resolveHost(serviceName: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let params = NWParameters.tcp
            let endpoint = NWEndpoint.service(
                name: serviceName,
                type: PhotoStreamConstants.bonjourBrowserType,
                domain: "local",
                interface: nil
            )
            let connection = NWConnection(to: endpoint, using: params)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        connection.cancel()
                        let hostString: String
                        switch host {
                        case .ipv4(let addr):
                            hostString = addr.debugDescription
                        case .ipv6(let addr):
                            hostString = "[\(addr.debugDescription)]"
                        case .name(let name, _):
                            hostString = name
                        @unknown default:
                            continuation.resume(throwing: URLError(.cannotFindHost))
                            return
                        }
                        // Prefer resolved port when available
                        _ = port
                        continuation.resume(returning: hostString)
                    } else {
                        connection.cancel()
                        continuation.resume(throwing: URLError(.cannotFindHost))
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }
}

struct PairingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac on this Wi‑Fi") {
                    if model.services.isEmpty {
                        Text(model.status)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Server", selection: $model.selected) {
                            ForEach(model.services) { service in
                                Text(service.name).tag(Optional(service))
                            }
                        }
                    }
                }
                Section("Or enter Mac IP") {
                    TextField("e.g. 192.168.1.20", text: $model.manualHost)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                }
                Section("PIN from Mac menu bar") {
                    TextField("4-digit PIN", text: $model.pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button("Connect") { model.pair() }
                        .disabled(model.pin.count < 4 || (model.selected == nil && model.manualHost.isEmpty))
                }
                if !model.status.isEmpty {
                    Section {
                        Text(model.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("PhotoStream")
        }
    }
}

struct GridHost: UIViewControllerRepresentable {
    let client: PhotoStreamAPIClient

    func makeUIViewController(context: Context) -> UINavigationController {
        let grid = GridViewController(client: client)
        return UINavigationController(rootViewController: grid)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
