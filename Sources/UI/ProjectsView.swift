import SwiftUI

/// Small printed "PROJECT" chip next to the CRATE wordmark: shows the current project, tap → the projects sheet.
struct ProjectChip: View {
    let state: AppState
    @State private var store = ProjectStore.shared
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 3) {
                DeckLabel("Project", size: 6, weight: 500, tracking: 0.14)
                Text(store.currentName.uppercased())
                    .font(Deck05.font(9, 700)).tracking(9 * 0.08)
                    .foregroundStyle(Deck05.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project-chip")
        .accessibilityLabel("Project \(store.currentName)")
        .sheet(isPresented: $open) {
            ProjectsView(state: state)
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.oled)
        }
    }
}

/// Black-lid list: name · date · bpm/key; NEW, SAVE AS, OPEN, DELETE. EXPORT (audio of the beat / song) is a modal.
struct ProjectsView: View {
    let state: AppState
    @State private var store = ProjectStore.shared
    @State private var selected: String?
    @State private var busy = false
    @State private var exporting = false
    @Environment(\.dismiss) private var dismiss

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd MMM · HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROJECTS").fieldLabel(9).foregroundStyle(Theme.lidGrey1)
                Text("\(store.projects.count)").font(Theme.mono(10)).foregroundStyle(Theme.lidGrey2)
                Spacer()
                // EXPORT opens its own modal (length, format, share) so the list stays quiet.
                Button { exporting = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                        Text("EXPORT").font(Theme.inter(10, 600)).tracking(0.9)
                    }
                    .foregroundStyle(Theme.chipText)
                    .padding(.horizontal, 12).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chipStroke, lineWidth: 0.6))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HitPressStyle())
                .accessibilityIdentifier("projects-export")
            }
            .padding(.bottom, 4)
            Rectangle().fill(Theme.lidGrey3).frame(height: 0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.projects.isEmpty {
                        Text("NO PROJECTS YET").fieldLabel(8).foregroundStyle(Theme.lidGrey2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                    }
                    ForEach(store.projects) { p in row(p) }
                }
            }
            HStack(spacing: 8) {
                key("NEW") { await store.newProject(state: state); selected = store.current?.id }
                key("SAVE AS") { store.save(state: state, asNew: true); selected = store.current?.id }
                key("OPEN", enabled: selectedProject != nil && selectedProject?.id != store.current?.id) {
                    if let p = selectedProject { await store.load(p, into: state); dismiss() }
                }
                key("DELETE", tint: Theme.red, enabled: selectedProject != nil) {
                    if let p = selectedProject { store.delete(p); selected = nil }
                }
            }
            .padding(.top, 12)
            PrivacySettingsRows()
        }
        .padding(16)
        .background(Theme.oled)
        .sheet(isPresented: $exporting) {
            ExportPanel(state: state)
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
                .presentationDetents([.height(300), .medium])
                .presentationBackground(Theme.oled)
                .analyticsScreen("export")
        }
        .onAppear {
            store.refresh()
            selected = store.current?.id
        }
    }

    private var selectedProject: Project? { store.projects.first { $0.id == selected } }

    private func row(_ p: Project) -> some View {
        let isSel = p.id == selected
        let isCur = p.id == store.current?.id
        return Button { selected = p.id } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(isCur ? Theme.orange : Color.clear).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name.uppercased()).font(Theme.mono(12, bold: true))
                        .foregroundStyle(isSel ? Color.black : Theme.lidInk).lineLimit(1)
                    Text(Self.date.string(from: p.updated).uppercased()).font(Theme.mono(9))
                        .foregroundStyle(isSel ? Color.black.opacity(0.6) : Theme.lidGrey1)
                }
                Spacer(minLength: 8)
                Text("\(Int(p.bpm.rounded())) BPM · \(p.scaleKey ?? "—")").font(Theme.mono(10))
                    .foregroundStyle(isSel ? Color.black : Theme.lidGrey1)
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(isSel ? Theme.lidInk : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.lidGrey3).frame(height: 0.5) }
    }

    private func key(_ title: String, tint: Color = Theme.lidInk, enabled: Bool = true,
                     _ action: @escaping () async -> Void) -> some View {
        Button {
            guard !busy else { return }
            busy = true
            Task { await action(); busy = false }
        } label: {
            Text(title).font(Theme.mono(10, bold: true)).tracking(1)
                .foregroundStyle(enabled ? tint : Theme.lidGrey2)
                .frame(maxWidth: .infinity).frame(height: 34)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(enabled ? tint.opacity(0.6) : Theme.lidGrey3, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}
