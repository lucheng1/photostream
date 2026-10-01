import Foundation
import PhotoStreamShared

actor AuthStore {
    private(set) var pin: String
    private var tokens: [String: StreamMode] = [:]

    init() {
        self.pin = Self.makePIN()
    }

    func rotatePIN() -> String {
        pin = Self.makePIN()
        tokens.removeAll()
        return pin
    }

    func currentPIN() -> String { pin }

    /// Pairs with the 4-digit PIN (Photos library) or PIN + trailing `9` (folder mode).
    func pair(pin candidate: String, folderConfigured: Bool) -> (token: String, mode: StreamMode)? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode: StreamMode
        if trimmed == pin {
            mode = .photos
        } else if trimmed == pin + "9" {
            guard folderConfigured else { return nil }
            mode = .folder
        } else {
            return nil
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokens[token] = mode
        return (token, mode)
    }

    func isAuthorized(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return tokens[token] != nil
    }

    func mode(for token: String?) -> StreamMode? {
        guard let token else { return nil }
        return tokens[token]
    }

    private static func makePIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }
}
