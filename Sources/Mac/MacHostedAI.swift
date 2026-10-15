import Foundation

/// Each installation receives an expiring gateway session; provider keys stay on the server.
actor MacHostedAI {
    static let shared = MacHostedAI()
    nonisolated static var endpoint: URL? {
        guard let value = AppConfig.string("CRATE_HOSTED_AI_BASE"), let url = URL(string: value),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    private var connecting: Task<Bool, Never>?
    func ensureSession() async -> Bool {
        guard AppConfig.hostedAIEnabled, PrivacyChoices.aiAllowed, !AppConfig.offline, let base = Self.endpoint else { return false }
        if MacPrivateConfig.string("CRATE_DESKTOP_TOKEN") != nil,
           UserDefaults.standard.double(forKey: "crateDesktopSessionExpires") > Date().timeIntervalSince1970 + 60 { return true }
        if let connecting { return await connecting.value }
        let task = Task<Bool, Never> {
            do {
                let id: String
                if let existing = MacPrivateConfig.string("CRATE_INSTALLATION_ID") { id = existing }
                else { id = UUID().uuidString; try MacPrivateConfig.saveInstallationID(id) }
                var req = URLRequest(url: base.appendingPathComponent("api/session"))
                req.httpMethod = "POST"; req.timeoutInterval = 8
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["installation_id": id])
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = obj["token"] as? String, token.count < 1000,
                      let expires = obj["expires_in"] as? Double, expires > 0 else { return false }
                try MacPrivateConfig.saveBackendToken(token)
                UserDefaults.standard.set(Date().timeIntervalSince1970 + expires, forKey: "crateDesktopSessionExpires")
                return true
            } catch { return false }
        }
        connecting = task
        let ok = await task.value
        connecting = nil
        return ok
    }
    func invalidate() { UserDefaults.standard.set(0, forKey: "crateDesktopSessionExpires") }
}
