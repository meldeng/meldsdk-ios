import SwiftUI
import MeldSDK

// The Apple Pay side of the demo. Unlike the card widget, Apple Pay isn't mounted into a view —
// PassKit presents its own sheet — so there's no UIView to host. We just call the same
// `Meld.mount` with `applePay:` instead of `into:`, and react to the same events. This screen
// shows a brief explainer behind the system sheet and the shared status banner + event log.

/// Triggers the native Apple Pay sheet on appear and relays events into the demo's `EventLog`.
struct ApplePayHost: View {
    let order: MeldOrder
    let request: MeldApplePayRequest
    @ObservedObject var events: EventLog
    let onClose: () -> Void

    @StateObject private var runner = ApplePayRunner()

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "applelogo").font(.system(size: 40)).foregroundStyle(.primary)
            Text("Apple Pay").font(.title2.weight(.semibold))
            Text("The system Apple Pay sheet is presented over this screen. Authorize to pay; the "
                + "result is relayed through the same events as the card flow.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // SDK: present Apple Pay for this order. `applePay:` carries what the order doesn't
            // (amount/currency/country/wallet/IP); `into:` is unused for this surface.
            runner.start(order: order, request: request, events: events, onClose: onClose)
        }
        .onDisappear { runner.stop() }
    }
}

/// Owns the live Apple Pay handle and the demo's close-on-terminal behavior. A class so the handle
/// survives view re-renders; mirrors `WidgetContainer.Coordinator` for the sheet surface.
final class ApplePayRunner: ObservableObject {
    private var handle: MeldWidgetHandle?
    private var started = false
    private var closed = false

    func start(order: MeldOrder, request: MeldApplePayRequest, events: EventLog, onClose: @escaping () -> Void) {
        guard !started else { return }
        started = true

        let finish: (String) -> Void = { [weak self] reason in
            guard let self, !self.closed else { return }
            self.closed = true
            events.record("→ closing (\(reason))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: onClose)
        }

        do {
            handle = try Meld.mount(order, applePay: request, handlers: makeDemoHandlers(events: events, finish: finish))
        } catch {
            events.record("mount failed: \(error.localizedDescription)")
            finish("error")
        }
    }

    func stop() {
        handle?.unmount() // SDK: dismiss the sheet if the screen goes away first
        handle = nil
    }
}
