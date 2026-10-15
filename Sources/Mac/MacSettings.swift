import SwiftUI
import AppKit
import Security

/// User-supplied AI credentials stay in the login Keychain; never log their values.
enum MacPrivateConfig {
    private static let service = "com.shuhan.crate.mac.ai"
    private static let accounts = ["CRATE_APP_TOKEN": "proxy-token", "TYPESAFE_API_KEY": "jev-key", "OPENAI_API_KEY": "openai-key", "CRATE_DESKTOP_TOKEN": "desktop-token", "CRATE_INSTALLATION_ID": "installation-id"]
    static func string(_ key: String) -> String? {
        if key == "CRATE_LIBRARY_PATH" { return UserDefaults.standard.string(forKey: "crateMacLibraryPath").flatMap { $0.isEmpty ? nil : $0 } }
        guard let account = accounts[key] else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func saveToken(_ token: String) throws { try save(token, account: "proxy-token") }
    static func saveBackendToken(_ token: String) throws { try save(token, account: "desktop-token") }
    static func saveInstallationID(_ id: String) throws { try save(id, account: "installation-id") }
    static func saveOpenAIKey(_ key: String) throws { try save(key, account: "openai-key") }
    static func saveJevKey(_ key: String) throws { try save(key, account: "jev-key") }
    private static func save(_ token: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let value = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain couldn't save the connection token (\(status))."]) }
    }
}
struct MacSettingsView: View {
    @AppStorage("crateMacUsePersonalAI") private var usePersonalAI = false
    @State private var backendTesting = false
    @State private var token = ""
    @State private var jevKey = ""
    @State private var openAIKey = ""
    @State private var openAIConfigured = AppConfig.openAIKey != nil
    @State private var testingGPT = false
    @State private var jevConfigured = AppConfig.typesafeKey != nil
    @State private var testing = false
    @State private var checkingLibrary = false
    @State private var configured = AppConfig.appToken != nil
    @State private var message = ""
    @AppStorage("crateMacLibraryPath") private var libraryPath = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            Text("CRATE CONNECTION").font(Theme.inter(15, 700)).tracking(1)
            if MacHostedAI.endpoint != nil {
                Text("CRATE AI · Jev + GPT included").foregroundStyle(Theme.orange)
                Text("Enable AI help in Projects, then describe your beat. This Mac connects automatically; daily limits keep the service available.")
                    .font(Theme.inter(12, 400)).foregroundStyle(Theme.mid)
                Button(backendTesting ? "Testing…" : "Test CRATE AI") {
                    guard PrivacyChoices.aiAllowed else { message = "Enable AI help in Projects first."; return }
                    backendTesting = true
                    Task { @MainActor in
                        let ok = await MacHostedAI.shared.ensureSession()
                        backendTesting = false
                        message = ok ? "CRATE AI connected. Jev and GPT are ready." : "Could not connect. Your local sampler remains ready."
                    }
                }.disabled(backendTesting)
                Toggle("Use my own AI keys", isOn: $usePersonalAI)
                    .onChange(of: usePersonalAI) { _, _ in
                        openAIConfigured = AppConfig.openAIKey != nil
                        jevConfigured = AppConfig.typesafeKey != nil
                    }
            }
            if usePersonalAI || MacHostedAI.endpoint == nil {
            Text((configured || openAIConfigured) ? "GPT connection configured" : jevConfigured ? "Jev connected · add OpenAI for background arranging" : "Connect your AI providers")
                .foregroundStyle(configured || jevConfigured || openAIConfigured ? Theme.orange : Theme.mid)
            Text("Jev handles the fast plan. GPT refines it in the background. A personal Jev key can also be saved privately on this Mac.")
                .font(Theme.inter(12, 400)).foregroundStyle(Theme.mid)
            SecureField("CRATE proxy token", text: $token).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Connection") {
                    do {
                        try MacPrivateConfig.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                        token = ""
                        configured = true
                        message = "Saved privately. Jev will connect after AI consent."
                        Orchestrator.current?.jev.warmUp()
                    } catch { message = error.localizedDescription }
                }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            Divider()
            Text(jevConfigured ? "JEV · KEY SAVED PRIVATELY" : "JEV · PERSONAL CONNECTION")
                .font(Theme.inter(12, 600)).foregroundStyle(jevConfigured ? Theme.orange : Theme.mid)
            SecureField("Jev API key", text: $jevKey).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Jev Key") {
                    do {
                        try MacPrivateConfig.saveJevKey(jevKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        jevKey = ""
                        jevConfigured = true
                        message = "Jev key saved in Keychain. It is never bundled or displayed."
                    } catch { message = error.localizedDescription }
                }.disabled(jevKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(testing ? "Testing…" : "Test Jev") {
                    guard PrivacyChoices.aiAllowed else { message = "Enable AI help in Projects before testing Jev."; return }
                    testing = true
                    Task { @MainActor in
                        let result = await JevClient().ask("plan", state: "house drums with piano", timeout: 5)
                        testing = false
                        message = result.map { "Jev connected · \($0.ms) ms · typed plan received" }
                            ?? "Jev did not return a plan. Check the key or connection."
                    }
                }.disabled(testing || (!jevConfigured && !configured))
            }
            Divider()
            Text(openAIConfigured ? "OPENAI · KEY SAVED PRIVATELY" : "OPENAI · PERSONAL CONNECTION")
                .font(Theme.inter(12, 600)).foregroundStyle(openAIConfigured ? Theme.orange : Theme.mid)
            Text("GPT-4.1 mini · fast background arranging and sample flips")
                .font(Theme.inter(12, 400)).foregroundStyle(Theme.mid)
            SecureField("OpenAI API key", text: $openAIKey).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save OpenAI Key") {
                    do {
                        try MacPrivateConfig.saveOpenAIKey(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        openAIKey = ""; openAIConfigured = true
                        message = "OpenAI key saved in Keychain. Ready for background arranging."
                    } catch { message = error.localizedDescription }
                }.disabled(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(testingGPT ? "Testing…" : "Test GPT") {
                    guard PrivacyChoices.aiAllowed else { message = "Enable AI help in Projects before testing GPT."; return }
                    testingGPT = true
                    Task { @MainActor in
                        let result = await OpenAIClient().arrange(["prompt": "A four-bar house beat at 124 BPM in C minor",
                            "bars": 4, "bpm": 124, "style": "house"], model: OpenAIClient.arrangeModel, timeout: 14)
                        testingGPT = false
                        switch result {
                        case .success(let (_, ms)): message = "GPT-4.1 mini connected · \(ms) ms · musical pattern received"
                        case .failure(let error): message = error.description
                        }
                    }
                }.disabled(testingGPT || (!openAIConfigured && !configured))
            }
            }
            if !message.isEmpty { Text(message).font(Theme.inter(12, 400)) }
            Divider()
            Text("SAMPLE LIBRARY").font(Theme.inter(13, 700)).tracking(1)
            Text(Orchestrator.current?.library.summary ?? "Library ready").font(Theme.mono(11))
            Text(libraryPath.isEmpty ? "Bundled library" : libraryPath).font(Theme.mono(11)).lineLimit(2)
            HStack {
                Button(checkingLibrary ? "Checking Library…" : "Choose Library Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        checkingLibrary = true
                        Task { @MainActor in
                            defer { checkingLibrary = false }
                            do {
                                let report = try await Task.detached(priority: .userInitiated) { try MacLibraryValidation.inspect(url) }.value
                                message = report.message
                                if report.complete { libraryPath = url.path }
                            } catch { message = "Library not installed: \(error.localizedDescription)" }
                        }
                    }
                }
                .disabled(checkingLibrary)
                Button("Use Bundled Library") { libraryPath = ""; message = "Restart CRATE to load the bundled library." }
            }
            Text("Choose a CRATE library containing oneshots.json, loops.json and its audio files.")
                .font(Theme.inter(11, 400)).foregroundStyle(Theme.mid)
            Text("⌘L opens the sound browser for search, previews, pad loading and chopping.")
                .font(Theme.inter(11, 400)).foregroundStyle(Theme.mid)
        }
        .padding(28) }.frame(width: 520, height: 680).background(Theme.oled).preferredColorScheme(.dark)
    }
}
