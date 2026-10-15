import SwiftUI
import Observation
#if canImport(RevenueCat)
import RevenueCat
#endif

@MainActor
@Observable
final class CratePaywall {
    var isPresented = false
    var message: String?
    private(set) var isChecking = false
    private(set) var isPurchasing = false
    @ObservationIgnored private let allowance: DigAllowance
    @ObservationIgnored private var pending = false
    #if canImport(RevenueCat)
    var offering: Offering?
    #endif

    init(defaults: UserDefaults = .standard) {
        allowance = DigAllowance(defaults: defaults)
    }

    func observe(_ log: [LogLine]) {
        if allowance.consume(log) { pending = true }
    }

    /// `crate://paywall` (demo / RevenueCat pitch): show CRATE PRO now, regardless of the DIG count.
    func presentOnDemand() async {
        pending = true
        await presentIfNeeded(isDigging: false)
    }

    func presentIfNeeded(isDigging: Bool) async {
        guard pending, !isDigging, !isChecking, !isPresented else { return }
        pending = false
        isChecking = true
        defer { isChecking = false }
        #if canImport(RevenueCat)
        guard configure() else {
            offering = nil
            message = "CRATE PRO isn’t available yet."
            isPresented = true
            DebugLog.event("paywall_unavailable", ["reason": "sdk_or_key"])
            return
        }
        do {
            let info = try await Purchases.shared.customerInfo()
            guard !Task.isCancelled else { pending = true; return }
            if info.entitlements["pro"]?.isActive == true {
                DebugLog.event("paywall_skip", ["reason": "entitlement_active"])
                return
            }
            let current = try await Purchases.shared.offerings().current
            guard !Task.isCancelled else { pending = true; return }
            offering = current
            if current == nil || current!.availablePackages.isEmpty {
                message = "CRATE PRO isn’t available yet."
                DebugLog.event("paywall_unavailable", ["reason": "no_offering"])
            } else {
                message = nil
                DebugLog.event("paywall_show", ["packages": current!.availablePackages.count])
            }
            isPresented = true
        } catch {
            guard !Task.isCancelled else { pending = true; return }
            offering = nil
            message = "Couldn’t load plans."
            isPresented = true
            DebugLog.event("paywall_error", ["error": String(describing: error)])
        }
        #else
        message = "CRATE PRO is not available in this build."
        isPresented = true
        #endif
    }

    /// Re-runs the check from the quiet retry line (missing key/offering, or a network failure).
    func retry() async {
        isPresented = false
        pending = true
        await presentIfNeeded(isDigging: false)
    }

    /// "Not now" / swipe-to-dismiss. The next accepted DIG checks again.
    func dismiss() {
        isPresented = false
    }

    #if canImport(RevenueCat)
    private func configure() -> Bool {
        if Purchases.isConfigured { return true }
        guard let key = AppConfig.string("REVENUECAT_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return false }
        Purchases.configure(withAPIKey: key)
        return true
    }

    /// Our own "Continue" button. RevenueCat still owns the StoreKit transaction; we own the pixels.
    func purchase(_ package: Package) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard !Task.isCancelled else { return }
            if !result.userCancelled { completed(result.customerInfo) }
            DebugLog.event("paywall_purchase", ["cancelled": result.userCancelled,
                                                 "active": result.customerInfo.entitlements["pro"]?.isActive == true])
        } catch {
            guard !Task.isCancelled else { return }
            message = "Purchase failed."
            DebugLog.event("paywall_purchase_error", ["error": String(describing: error)])
        }
    }

    func restore() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            guard !Task.isCancelled else { return }
            completed(info)
            DebugLog.event("paywall_restore", ["active": info.entitlements["pro"]?.isActive == true])
        } catch {
            guard !Task.isCancelled else { return }
            message = "Restore failed."
            DebugLog.event("paywall_restore_error", ["error": String(describing: error)])
        }
    }

    /// Purchase/restore both funnel here: dismiss only when `pro` is active.
    private func completed(_ info: CustomerInfo) {
        if info.entitlements["pro"]?.isActive == true {
            pending = false
            isPresented = false
        } else {
            message = "No active CRATE PRO subscription was found for this account."
        }
    }
    #endif
}

@MainActor
private struct PaywallGateModifier: ViewModifier {
    let state: AppState
    @State private var gate = CratePaywall()

    func body(content: Content) -> some View {
        @Bindable var gate = gate
        content
            .onChange(of: ObservationKey(ids: state.log.map(\.id), digging: state.isDigging), initial: true) { _, _ in
                gate.observe(state.log)
                Task { await gate.presentIfNeeded(isDigging: state.isDigging) }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("cratePresentPaywall"))) { _ in
                Task { await gate.presentOnDemand() }
            }
            .sheet(isPresented: $gate.isPresented) {
                CrateProSheet(gate: gate)
                    .presentationDetents([.large])
                    .presentationBackground(.black)
            }
    }

    private struct ObservationKey: Equatable {
        let ids: [UUID]
        let digging: Bool
    }
}

extension View {
    /// Attach once to the stable performer root, outside the Duo pose branches.
    @MainActor
    func paywallGate(state: AppState) -> some View {
        modifier(PaywallGateModifier(state: state))
    }
}

// MARK: - Custom paywall (typography only; RevenueCat SDK supplies offerings/purchase/restore/entitlements)

private enum CrateProColor {
    static let orange = Color(red: 0xFA / 255, green: 0x5B / 255, blue: 0x1C / 255)
    static let headline = Color(red: 0xF6 / 255, green: 0xF4 / 255, blue: 0xF4 / 255)
    static let body = Color(red: 0xAF / 255, green: 0xAF / 255, blue: 0xB3 / 255)
    static let grey = Color(red: 0x79 / 255, green: 0x79 / 255, blue: 0x82 / 255)
    static let hairline = Color(red: 0x2F / 255, green: 0x2F / 255, blue: 0x36 / 255)
    static let row = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0E / 255)
}

private enum CratePlan { case yearly, monthly }

@MainActor
private struct CrateProSheet: View {
    let gate: CratePaywall
    @State private var selection: CratePlan?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                headline.padding(.top, 28)
                benefits.padding(.top, 20)
                plans.padding(.top, 24)
                if let message = gate.message {
                    retryLine(message).padding(.top, 10)
                }
                continueButton.padding(.top, 16)
                footer.padding(.top, 16)
            }
            .padding(28)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: header / headline / benefits

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("CRATE PRO")
                .font(.custom("Doto-Black", size: 18))
                .foregroundStyle(CrateProColor.orange)
            Spacer()
            Button { gate.dismiss() } label: {
                Text("Not now")
                    .font(.custom("JetBrainsMono-Regular", size: 13))
                    .foregroundStyle(CrateProColor.grey)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss CRATE PRO")
        }
    }

    private var headline: some View {
        Text("Dig without limits.")
            .font(.custom("SpaceMono-Bold", size: 30))
            .foregroundStyle(CrateProColor.headline)
            .lineSpacing(-4)
            .kerning(-0.3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 10) {
            benefitLine("Unlimited digs across your own crates")
            benefitLine("AI Perform: Jev plays fills in real time")
            benefitLine("The crowd screen on the back of your Duo")
        }
    }

    private func benefitLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("—")
                .font(.custom("JetBrainsMono-Regular", size: 13))
                .foregroundStyle(CrateProColor.orange)
            Text(text)
                .font(.custom("JetBrainsMono-Regular", size: 13))
                .foregroundStyle(CrateProColor.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: plans

    private var plans: some View {
        VStack(spacing: 10) {
            planRow(.yearly)
            planRow(.monthly)
        }
    }

    private func planRow(_ plan: CratePlan) -> some View {
        let pkg = package(for: plan)
        let isSelected = selectedPlan == plan
        return Button {
            guard pkg != nil else { return }
            withAnimation(.easeInOut(duration: 0.15)) { selection = plan }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(isSelected ? CrateProColor.orange : .clear)
                    .frame(width: 6, height: 6)
                    .frame(width: 14, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan == .yearly ? "Yearly" : "Monthly")
                        .font(.custom("SpaceMono-Bold", size: 14))
                        .foregroundStyle(CrateProColor.headline)
                    if plan == .yearly, let sub = yearlySubtitle {
                        HStack(spacing: 6) {
                            Text(sub)
                                .font(.custom("JetBrainsMono-Regular", size: 11))
                                .foregroundStyle(CrateProColor.body)
                            if let save = savePercent {
                                Text("SAVE \(save)%")
                                    .font(.custom("JetBrainsMono-Regular", size: 10))
                                    .foregroundStyle(CrateProColor.orange)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                Text(pkg?.localizedPriceString ?? "—")
                    .font(.custom("SpaceMono-Bold", size: 14))
                    .foregroundStyle(pkg == nil ? CrateProColor.grey : CrateProColor.headline)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(CrateProColor.row)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? CrateProColor.orange : CrateProColor.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(pkg == nil ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(pkg == nil)
    }

    private func retryLine(_ text: String) -> some View {
        Button { Task { await gate.retry() } } label: {
            Text("\(text) Tap to retry.")
                .font(.custom("JetBrainsMono-Regular", size: 11))
                .foregroundStyle(CrateProColor.grey)
        }
        .buttonStyle(.plain)
        .disabled(gate.isChecking)
    }

    // MARK: continue / footer

    private var continueButton: some View {
        let enabled = selectedPackage != nil && !gate.isPurchasing
        return Button {
            guard let package = selectedPackage else { return }
            Task {
                #if canImport(RevenueCat)
                await gate.purchase(package)
                #endif
            }
        } label: {
            ZStack {
                Text("Continue")
                    .font(.custom("SpaceMono-Bold", size: 15))
                    .foregroundStyle(Color.black)
                    .opacity(gate.isPurchasing ? 0 : 1)
                if gate.isPurchasing {
                    ProgressView().tint(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(CrateProColor.orange)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(selectedPackage == nil ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.15), value: gate.isPurchasing)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text("Cancel anytime")
            Text("·")
            Button { Task {
                #if canImport(RevenueCat)
                await gate.restore()
                #endif
            } } label: {
                Text("Restore purchases")
            }
            .buttonStyle(.plain)
            Text("·")
            Text("Terms")
            Text("·")
            Text("Privacy")
        }
        .font(.custom("JetBrainsMono-Regular", size: 11))
        .foregroundStyle(CrateProColor.grey)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: pricing helpers

    #if canImport(RevenueCat)
    private func package(for plan: CratePlan) -> Package? {
        switch plan {
        case .yearly: return gate.offering?.annual
        case .monthly: return gate.offering?.monthly
        }
    }
    #else
    private struct UnavailablePackage { let localizedPriceString: String }
    private func package(for plan: CratePlan) -> UnavailablePackage? { nil }
    #endif

    private var selectedPlan: CratePlan {
        if let selection, package(for: selection) != nil { return selection }
        return package(for: .yearly) != nil ? .yearly : .monthly
    }

    #if canImport(RevenueCat)
    private var selectedPackage: Package? { package(for: selectedPlan) }
    #else
    private var selectedPackage: UnavailablePackage? { nil }
    #endif

    #if canImport(RevenueCat)
    private var yearlySubtitle: String? {
        guard let annual = package(for: .yearly)?.storeProduct,
              package(for: .monthly) != nil,
              let formatter = annual.priceFormatter else { return nil }
        return (formatter.string(from: NSDecimalNumber(decimal: annual.price / 12)))
            .map { "\($0)/mo" }
    }

    private var savePercent: Int? {
        guard let annual = package(for: .yearly)?.storeProduct,
              let monthly = package(for: .monthly)?.storeProduct,
              monthly.price > 0 else { return nil }
        let annualMonthly = annual.price / 12
        let ratio = Double(truncating: NSDecimalNumber(decimal: annualMonthly / monthly.price))
        let percent = Int(((1 - ratio) * 100).rounded())
        return percent > 0 ? percent : nil
    }
    #else
    private var yearlySubtitle: String? { nil }
    private var savePercent: Int? { nil }
    #endif
}
