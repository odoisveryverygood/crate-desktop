import SwiftUI

/// One-time sheet before the first AI request leaves the device (App Review 5.1.2(i)). RootView presents it while
/// `PrivacyChoices.shared.asking`; the waiting request runs after either answer.
struct AIConsentSheet: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Let AI arrange your beats?")
                    .font(Theme.inter(20, 600))
                    .foregroundStyle(Theme.lidInk)
                VStack(alignment: .leading, spacing: 10) {
                    point("What's sent", "What you type or say to CRATE, and a short description of the current beat (tempo, key, style, sound names).")
                    point("Not sent", "No audio, no recordings, no contacts. Speech turns into text on your device.")
                    #if os(macOS)
                    point("To whom", "OpenAI and TypeSafe. Personal keys connect directly; a CRATE proxy token connects through CRATE's server.")
                    #else
                    point("To whom", "OpenAI and TypeSafe, through CRATE's server.")
                    #endif
                    point("Why", "To understand your request and arrange the beat.")
                }
                Link(destination: AppConfig.privacyPolicyURL) {
                    Text("Privacy Policy").font(Theme.inter(13, 500)).underline()
                        .foregroundStyle(Theme.lidGrey1)
                }
                .accessibilityIdentifier("consent-privacy")
                VStack(spacing: 10) {
                    Button { PrivacyChoices.shared.answer(allow: true) } label: {
                        Text("Allow").font(Theme.inter(15, 600)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Theme.lidInk, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("consent-allow")
                    Button { PrivacyChoices.shared.answer(allow: false) } label: {
                        Text("Not now").font(Theme.inter(15, 500)).foregroundStyle(Theme.lidInk)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.lidGrey3, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("consent-not-now")
                }
                .padding(.top, 4)
                Text("Not now keeps CRATE's AI on this device, with simpler beats. Change it any time under Projects.")
                    .font(Theme.inter(12))
                    .foregroundStyle(Theme.lidGrey2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.oled)
        .interactiveDismissDisabled(true)
        .analyticsScreen("ai_consent")
    }

    private func point(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).fieldLabel(8).foregroundStyle(Theme.lidGrey2)
            Text(text).font(Theme.inter(14)).foregroundStyle(Theme.lidInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Quiet rows at the bottom of the projects sheet: AI help (the consent above, changeable) and usage analytics.
struct PrivacySettingsRows: View {
    @State private var privacy = PrivacyChoices.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            toggle("AI HELP · OPENAI + TYPESAFE", id: "settings-ai",
                   isOn: Binding(get: { privacy.aiConsent == .allowed },
                                 set: { privacy.aiConsent = $0 ? .allowed : .declined }))
            toggle("SHARE USAGE ANALYTICS", id: "settings-analytics", isOn: $privacy.analyticsOn)
            Link(destination: AppConfig.privacyPolicyURL) {
                Text("PRIVACY POLICY").font(Theme.mono(9)).tracking(0.8).foregroundStyle(Theme.lidGrey1)
                    .frame(minHeight: 32)
            }
            .accessibilityIdentifier("settings-privacy")
        }
        .padding(.top, 10)
    }

    private func toggle(_ title: String, id: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(Theme.mono(9)).tracking(0.8).foregroundStyle(Theme.lidGrey1)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.lidGrey1)
                .scaleEffect(0.7, anchor: .trailing)
                .accessibilityIdentifier(id)
        }
        .frame(minHeight: 32)
    }
}
