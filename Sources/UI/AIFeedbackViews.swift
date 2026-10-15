import SwiftUI

/// 👍 / 👎 for the latest AI change, on the result line. 👎 asks why in one tap (and offers UNDO).
struct AIRatingButtons: View {
    let change: AIChange
    @State private var askWhy = false

    static let reasons = ["Changed too much", "Didn't do what I asked", "Wrong sound", "Sounds bad", "Too slow"]

    var body: some View {
        HStack(spacing: 2) {
            thumb("hand.thumbsup", on: change.rating > 0, id: "ai-thumb-up") {
                AIChangeLog.shared.rate(change.id, change.rating > 0 ? 0 : 1)
            }
            thumb("hand.thumbsdown", on: change.rating < 0, id: "ai-thumb-down") {
                if change.rating < 0 { AIChangeLog.shared.rate(change.id, 0) } else { askWhy = true }
            }
        }
        .confirmationDialog("What went wrong?", isPresented: $askWhy, titleVisibility: .visible) {
            ForEach(Self.reasons, id: \.self) { r in
                Button(r) { AIChangeLog.shared.rate(change.id, -1, reason: r) }
            }
            Button("Undo it", role: .destructive) {
                AIChangeLog.shared.rate(change.id, -1, reason: "undo")
                Task { @MainActor in await Orchestrator.current?.undo() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(change.prompt)” · \(change.summary)")
        }
    }

    private func thumb(_ icon: String, on: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? icon + ".fill" : icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Theme.orange : Theme.lidGrey1)
                .frame(width: 34, height: 16)
                .contentShape(Rectangle().inset(by: -14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// Every AI change this session, newest first: what was asked, what it touched and kept, 👍 / 👎 and a note.
struct AILogSheet: View {
    @State private var log = AIChangeLog.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI CHANGES").font(Theme.inter(11, 600)).tracking(1.3).foregroundStyle(Theme.lidInk)
                Spacer()
                Button("Done") { dismiss() }
                    .font(Theme.inter(15, 600)).foregroundStyle(Theme.lidInk)
                    .frame(minWidth: 60, minHeight: 44)
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Text("Rate each change so CRATE learns what you meant. 👎 asks why.")
                .font(Theme.inter(12)).foregroundStyle(Theme.lidGrey1)
                .padding(.horizontal, 20).padding(.bottom, 10)
            if log.items.isEmpty {
                Text("Nothing yet · type or say a change and it shows up here.")
                    .font(Theme.inter(13)).foregroundStyle(Theme.lidGrey1).padding(20)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.items.reversed()) { c in
                            AILogRow(change: c)
                            Rectangle().fill(Theme.lidGrey2.opacity(0.4)).frame(height: 0.5)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .background(Theme.oled)
        .onAppear { Analytics.shared.setScreen("ai_log") }
        .onDisappear { Analytics.shared.setScreen("main") }
    }
}

private struct AILogRow: View {
    let change: AIChange
    @State private var note = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("“\(change.prompt)”").font(Theme.inter(15, 600)).foregroundStyle(Theme.lidInk).lineLimit(2)
                Spacer(minLength: 8)
                AIRatingButtons(change: change)
            }
            Text(change.summary).font(Theme.inter(13)).foregroundStyle(Theme.lidInk.opacity(0.85))
            HStack(spacing: 8) {
                Text(change.at, style: .relative).font(Theme.mono(10)).foregroundStyle(Theme.lidGrey1)
                if change.gpt { tag("AI") }
                if change.reverted { tag("UNDONE") }
                if let r = change.reason, !r.isEmpty { tag(r.uppercased()) }
                Spacer()
                Button(editing ? "Save" : "Add note") {
                    if editing, !note.isEmpty { AIChangeLog.shared.rate(change.id, change.rating == 0 ? -1 : change.rating, reason: note) }
                    editing.toggle()
                }
                .font(Theme.inter(12, 600)).foregroundStyle(Theme.lidGrey1)
                .frame(minHeight: 36)
            }
            if editing {
                TextField("", text: $note, prompt: Text("What should it have done?").foregroundStyle(Theme.lidGrey2), axis: .vertical)
                    .font(Theme.inter(14)).foregroundStyle(Theme.lidInk)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.lidGrey2, lineWidth: 1))
                    .submitLabel(.done)
                    .onSubmit {
                        if !note.isEmpty { AIChangeLog.shared.rate(change.id, change.rating == 0 ? -1 : change.rating, reason: note) }
                        editing = false
                    }
            }
        }
        .padding(.vertical, 12)
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(Theme.mono(9)).foregroundStyle(Theme.lidGrey1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.lidGrey2, lineWidth: 0.5))
            .lineLimit(1)
    }
}
