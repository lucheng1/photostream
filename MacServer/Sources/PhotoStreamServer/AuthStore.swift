import Foundation
import PhotoStreamShared

actor AuthStore {
    private(set) var pin: String
    private var tokens: Set<String> = []

    init() {
        self.pin = Self.makePIN()
    }

    func rotatePIN() -> String {
        pin = Self.makePIN()
        tokens.removeAll()
        return pin
    }

    func currentPIN() -> String { pin }

    func pair(pin candidate: String) -> String? {
        guard candidate == pin else { return nil }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokens.insert(token)
        return token
    }

    func isAuthorized(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return tokens.contains(token)
    }

    private static func makePIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }
}
