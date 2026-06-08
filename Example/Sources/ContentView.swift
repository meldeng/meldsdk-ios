import SwiftUI
import MeldSDK

/// The checkout screen, styled to match the web demo's card. The MeldSDK calls are marked
/// `// SDK:` (there are only two here — `configure` and `capabilities`); the actual mount lives
/// in Widget.swift.
struct ContentView: View {
    private let orders = OrderService()
    @StateObject private var events = EventLog()

    @State private var wallet = DemoConfig.defaultWallet
    @State private var customerId = ""
    @State private var clientIP: String?
    @State private var receiveText = "…"
    @State private var quoteNote = "fetching live quote…"
    @State private var rateText = "Credit / debit card rail"
    @State private var errorText = ""
    @State private var creating = false
    @State private var presentedOrder: PresentedOrder?

    /// The server-held customer id is preferred; show an input only when it isn't set.
    private var needsCustomerField: Bool { DemoConfig.meldCustomerId.isEmpty }
    private var buyDisabled: Bool { creating || wallet.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack {
            Color.hex(0x2b2b28).ignoresSafeArea()
            ScrollView {
                card.padding(16)
            }
        }
        .task { await load() }
        .fullScreenCover(item: $presentedOrder) { presented in
            WidgetScreen(order: presented.order, events: events) { presentedOrder = nil }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            payPanel
            receivePanel
            fieldLabel("Wallet Address")
            field($wallet)
            if needsCustomerField {
                fieldLabel("Meld Customer ID")
                field($customerId, placeholder: "customer with APPROVED KYC")
            }
            fieldLabel("Payment Method")
            methodBox
            buyButton
            if !errorText.isEmpty {
                Text(errorText).font(.footnote).foregroundStyle(Color.hex(0xb3261e))
            }
            footer
        }
        .padding(18)
        .background(Color.hex(0xf1f0ec))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 480)
    }

    // MARK: - header

    private var header: some View {
        HStack {
            Text("⬢").font(.system(size: 26)).foregroundStyle(Color.hex(0x15191f))
            Spacer()
            Text("Buy").fontWeight(.bold).foregroundStyle(.white)
                .padding(.horizontal, 24).padding(.vertical, 7)
                .background(Color.hex(0x3e6650)).clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer()
            HStack(spacing: 6) { Text("🇺🇸"); Text("US").foregroundStyle(Color.hex(0x15191f)) }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - amount panels

    private var payPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You pay").font(.system(size: 15)).foregroundStyle(Color.hex(0x6b7280))
                    Text(DemoConfig.sourceAmount).font(.system(size: 38, weight: .bold)).foregroundStyle(Color.hex(0x15191f))
                }
                Spacer()
                chip { Text("🇺🇸"); Text(DemoConfig.sourceCurrency).fontWeight(.bold).foregroundStyle(Color.hex(0x15191f)) }
            }
            .padding(16)
            presetsRow
        }
        .background(Color.hex(0xe6e5df)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var presetsRow: some View {
        HStack(spacing: 0) {
            ForEach(["15", "50", "100", "250", "500"], id: \.self) { p in
                let active = p == DemoConfig.sourceAmount
                Text(p)
                    .font(.system(size: 15, weight: active ? .bold : .regular))
                    .foregroundStyle(Color.hex(0x374151))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(active ? Color.hex(0xe0ded8) : Color.hex(0xeceae5))
            }
        }
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.hex(0xd7d6d0)), alignment: .top)
    }

    private var receivePanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You receive").font(.system(size: 15)).foregroundStyle(Color.hex(0x6b7280))
                    Text(receiveText).font(.system(size: 34, weight: .bold)).foregroundStyle(Color.hex(0x15191f))
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                Spacer()
                chip {
                    Text("₿").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Color.hex(0xf7931a)).clipShape(Circle())
                    Text("BTC").fontWeight(.bold).foregroundStyle(Color.hex(0x15191f))
                }
            }
            .padding(16)
            Text(quoteNote).font(.system(size: 13)).foregroundStyle(Color.hex(0x6b7280))
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 16).padding(.bottom, 10)
            HStack {
                Text("By ✦ Mercuryo").font(.system(size: 15)).foregroundStyle(Color.hex(0x15191f))
                Spacer()
                Text(rateText).font(.system(size: 14)).foregroundStyle(Color.hex(0x374151))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.hex(0xeceae5))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.hex(0xd7d6d0)), alignment: .top)
        }
        .background(Color.hex(0xe6e5df)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - fields

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 16)).foregroundStyle(Color.hex(0x15191f))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ binding: Binding<String>, placeholder: String = "") -> some View {
        TextField(placeholder, text: binding)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .foregroundStyle(Color.hex(0x15191f)) // black text (don't inherit the accent tint)
            .tint(Color.hex(0x3e6650))             // cursor / selection in Meld green
            .padding(14)
            .background(Color.hex(0xf7f6f2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.hex(0xd8d7d1), lineWidth: 1.5))
    }

    private var methodBox: some View {
        HStack(spacing: 10) {
            Image(systemName: "creditcard").foregroundStyle(Color.hex(0x15191f))
            Text("Credit or debit card").foregroundStyle(Color.hex(0x15191f))
            Spacer()
        }
        .padding(14)
        .background(Color.hex(0xf7f6f2))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.hex(0xd8d7d1), lineWidth: 1.5))
    }

    private var buyButton: some View {
        Button {
            Task { await buy() }
        } label: {
            Text(creating ? "Creating order…" : "Buy Bitcoin")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(buyDisabled ? Color.hex(0x9aa0a8) : .white)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(buyDisabled ? Color.hex(0xdcdad4) : Color.hex(0x3e6650))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(buyDisabled)
        .padding(.top, 8)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text("Powered by").foregroundStyle(Color.hex(0x374151))
            Text("Meld.io").fontWeight(.bold).foregroundStyle(Color.hex(0x15191f))
        }
        .font(.system(size: 13)).frame(maxWidth: .infinity).padding(.top, 8)
    }

    /// A white pill chip (currency badge).
    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 7, content: content)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - actions

    /// On appear: configure the SDK and fetch a live quote to display.
    private func load() async {
        Meld.configure(environment: .sandbox) // SDK: one-time setup

        guard !DemoConfig.meldApiKey.isEmpty else {
            receiveText = "≈ —"
            quoteNote = "MELD_API_KEY not set"
            errorText = "MELD_API_KEY is empty. Fill Example/Secrets.xcconfig (see README)."
            return
        }

        clientIP = await orders.publicIP()
        do {
            let quote = try await orders.quote()
            if let amount = quote.destinationAmount { receiveText = "≈ \(format(amount))" }
            if let fee = quote.totalFee { quoteNote = "live quote — total fees \(format(fee)) \(DemoConfig.sourceCurrency)" }
            if let rate = quote.exchangeRate { rateText = "1 BTC ≈ \(Int(rate).formatted()) \(DemoConfig.sourceCurrency)" }
        } catch {
            receiveText = "≈ —"
            quoteNote = "quote failed: \(error.localizedDescription)"
        }
    }

    /// Create the order (POC: directly; a real app calls its backend), then present the widget.
    private func buy() async {
        errorText = ""
        creating = true
        defer { creating = false }

        guard !DemoConfig.meldApiKey.isEmpty else {
            errorText = "Set MELD_API_KEY in Example/Secrets.xcconfig (see README)."
            return
        }
        let customer = needsCustomerField ? customerId.trimmingCharacters(in: .whitespaces) : DemoConfig.meldCustomerId
        guard !customer.isEmpty else { errorText = "Set a Meld customer ID."; return }

        do {
            let orderJSON = try await orders.createOrder(
                customerId: customer,
                wallet: wallet.trimmingCharacters(in: .whitespaces),
                clientIP: clientIP)

            let order = try MeldOrder.from(jsonData: orderJSON)   // SDK: decode the order
            guard Meld.capabilities(for: order).embeddable else { // SDK: can we embed it?
                errorText = "Order is not embeddable by this SDK (renderMode != IFRAME)."
                return
            }
            events.clear()
            presentedOrder = PresentedOrder(order: order)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Trim trailing zeros so amounts read cleanly (0.00021400 -> 0.000214).
    private func format(_ value: Double) -> String {
        var s = String(format: "%.8f", value)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }
}

/// A decoded order ready to present in the widget sheet.
struct PresentedOrder: Identifiable {
    let id = UUID()
    let order: MeldOrder
}

extension Color {
    /// Build a Color from a 0xRRGGBB literal (keeps the demo's hex palette readable).
    static func hex(_ rgb: UInt) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}
