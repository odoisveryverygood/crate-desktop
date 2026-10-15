import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main struct CrateMacApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var projectsOpen = false
    @State private var libraryOpen = false
    @State private var state: AppState
    private let orchestrator: Orchestrator
    private let hinge: HingeFX
    init() {
        let engine = AudioEngine()
        let s = AppState(engine: engine)
        do { try engine.start() } catch { s.addLog("ERR", "Audio: \(error.localizedDescription)", tint: .red) }
        _state = State(initialValue: s)
        hinge = HingeFX(state: s)
        let fx = hinge
        CrateUI.shared.onPunch = { fx.apply($0) }
        CrateUI.shared.sampler = MicSampler(state: s)
        orchestrator = Orchestrator(state: s, library: LibraryStore())
        orchestrator.wire()
        if !AppConfig.devFlag("crateMacStudioVerify") && !AppConfig.devFlag("crateMacGPTVerify") { delegate.state = s }
        Analytics.shared.start()
    }
    var body: some Scene {
        WindowGroup("CRATE") {
            MacRootView(state: state)
                .sheet(isPresented: $projectsOpen) { ProjectsView(state: state).frame(width: 600, height: 520) }
                .sheet(isPresented: $libraryOpen) { MacSoundLibrary(state: state, orchestrator: orchestrator) }
                .task {
                    #if DEBUG
                    if AppConfig.devFlag("crateMacGPTVerify") {
                        await MacGPTVerification.run(state: state, orchestrator: orchestrator)
                        return
                    }
                    if AppConfig.devFlag("crateMacStudioVerify") {
                        await MacStudioVerification.run(state: state, orchestrator: orchestrator)
                        return
                    }
                    #endif
                    if AppConfig.hostedAIEnabled && PrivacyChoices.aiAllowed { _ = await MacHostedAI.shared.ensureSession() }
                    await ProjectStore.shared.boot(state: state)
                    #if DEBUG
                    if AppConfig.devFlag("crateMacVerify") { await MacVerification.run(state: state) }
                    #endif
                    await SpeechService.shared.prepare()
                }
        }
        .defaultSize(width: 1220, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Beat") { Task { await ProjectStore.shared.newProject(state: state) } }.keyboardShortcut("n")
                Button("Import Audio…") { importAudio() }.keyboardShortcut("o")
                Button("Sound Library…") { libraryOpen = true }.keyboardShortcut("l")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Beat") { _ = ProjectStore.shared.save(state: state) }.keyboardShortcut("s")
                Button("Projects & Export…") { projectsOpen = true }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { Task { await orchestrator.undo() } }.keyboardShortcut("z")
                Button("Redo") { Task { await orchestrator.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Performance") {
                Button("Play / Pause") { CrateUI.shared.playPausePressed(state) }.keyboardShortcut(" ", modifiers: [])
                Button("Record") { CrateUI.shared.recPressed(state) }
                Button("DIG") { CrateUI.shared.focusRequest += 1 }.keyboardShortcut("/", modifiers: .command)
                Button("Drop") { hinge.released(); state.engine.drop() }
                Button("Audience Display") { openWindow(id: "audience") }
            }
        }
        Window("CRATE Audience", id: "audience") {
            CrowdStageView(state: state).frame(minWidth: 640, minHeight: 360).preferredColorScheme(.dark)
        }.defaultSize(width: 900, height: 500)
        Settings { MacSettingsView() }
    }
    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await AudioImport.importPicked(url, state: state) }
        }
    }
}
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { if let state { _ = ProjectStore.shared.save(state: state); state.engine.stop() } }
}
struct MacRootView: View {
    let state: AppState
    @State private var privacy = PrivacyChoices.shared
    var body: some View {
        GeometryReader { g in
            Group {
                if g.size.width > g.size.height * 1.25 {
                    HStack(spacing: 1) {
                        LidDisplayView(state: state).frame(width: g.size.width * 0.5)
                        DeckView(state: state)
                    }
                } else {
                    VStack(spacing: 1) {
                        LidDisplayView(state: state).frame(height: g.size.height * 0.5)
                        DeckView(state: state)
                    }
                }
            }
            .overlay { VoicePullPanel(state: state) }
        }
        .background(Color.black)
        .background(KeyboardControl(state: state).frame(width: 0, height: 0))
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .analytics(state)
        .sheet(isPresented: $privacy.asking) { AIConsentSheet().frame(width: 480, height: 470) }
    }
}
