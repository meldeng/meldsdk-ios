import SwiftUI
import MeldSDK

// The MeldSDK integration. WidgetContainer wraps `Meld.mount` in a SwiftUI view:
//   1. mount the order into a UIView, passing your event handlers   (makeUIView)
//   2. handle the lifecycle events                                  (eventHandlers)
//   3. unmount when the screen goes away                            (dismantleUIView)
// Anything tagged "demo-only" (the status banner, event log, console logging, auto-close) is
// just for this example. A real app keeps steps 1–3 and reacts to the events however it likes.

/// Full-screen sheet hosting the order's surface, with a status banner + event log underneath.
/// Card orders embed the Mercuryo widget (`WidgetContainer`); Apple Pay orders present the native
/// PassKit sheet (`ApplePayHost`) — both go through `Meld.mount` and feed the same event log.
struct WidgetScreen: View {
    let order: MeldOrder
    let applePay: MeldApplePayRequest?
    @ObservedObject var events: EventLog
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let applePay {
                    ApplePayHost(order: order, request: applePay, events: events, onClose: onClose)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WidgetContainer(order: order, events: events, onClose: onClose)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(spacing: 8) { // demo-only
                    StatusBanner(status: events.status)
                    EventLogView(lines: events.lines)
                }
                .padding(12)
                .background(.thinMaterial)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(applePay == nil ? "Mercuryo" : "Apple Pay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back", action: onClose) }
            }
        }
    }
}

/// Builds the demo's event handlers — log each event, drive the status banner, and call `finish`
/// on a terminal outcome. Shared by the card widget and the Apple Pay sheet so both demos react
/// to the (identical) event model the same way.
func makeDemoHandlers(events: EventLog, finish: @escaping (String) -> Void) -> MeldEventHandlers {
    MeldEventHandlers(
        onReady: { _ in events.record("onReady") },
        onPaymentSubmitted: { _ in events.record("onPaymentSubmitted (UX hint, not settled)") },
        onStatusChange: { e in
            events.setStatus(e.status)
            events.record("onStatusChange: \(e.status.rawValue) (\(e.providerStatus ?? "-"))")
            if e.status == .completed { finish("completed") }
            if e.status == .failed { finish("failed") }
        },
        onCancel: { _ in
            events.setStatus(.cancelled)
            events.record("onCancel")
            finish("cancelled")
        },
        onError: { e in
            events.setStatus(.failed)
            events.record("onError [\(e.code)] \(e.message)")
            finish("error")
        }
    )
}

/// Bridges `Meld.mount` into SwiftUI. This is the part you adapt for your own app.
struct WidgetContainer: UIViewRepresentable {
    let order: MeldOrder
    let events: EventLog
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(events: events, onClose: onClose) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        do {
            // SDK: mount the order into the container, passing your event handlers.
            context.coordinator.handle = try Meld.mount(
                order, into: container, handlers: context.coordinator.eventHandlers())
        } catch {
            events.record("mount failed: \(error.localizedDescription)")
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.handle?.unmount() // SDK: tear down the widget when the screen goes away
    }

    /// Owns the live handle and the demo's event/close behavior.
    final class Coordinator {
        var handle: MeldWidgetHandle?
        private let events: EventLog
        private let onClose: () -> Void
        private var closed = false

        init(events: EventLog, onClose: @escaping () -> Void) {
            self.events = events
            self.onClose = onClose
        }

        // SDK: react to the widget's lifecycle. Here we log each event, drive the status banner,
        // and (for the demo) close the screen on a terminal outcome.
        func eventHandlers() -> MeldEventHandlers {
            makeDemoHandlers(events: events, finish: finish)
        }

        // demo-only: close the screen once, shortly after a terminal event, so the outcome shows.
        private func finish(_ reason: String) {
            guard !closed else { return }
            closed = true
            events.record("→ closing widget (\(reason))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: onClose)
        }
    }
}

// MARK: - demo-only views

/// Colored banner reflecting the normalized status (same labels as the web demo).
struct StatusBanner: View {
    let status: MeldStatus?

    var body: some View {
        if let status {
            let m = Self.meta(status)
            HStack(spacing: 9) {
                Circle().fill(m.color).frame(width: 9, height: 9)
                Text(m.title).font(.subheadline.weight(.semibold)).foregroundStyle(m.color)
                if !m.sub.isEmpty {
                    Text(m.sub).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(m.color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    static func meta(_ s: MeldStatus) -> (title: String, sub: String, color: Color) {
        switch s {
        case .pending: return ("Processing payment…", "", .gray)
        case .completed: return ("Order complete", "Provider confirmed — settlement via webhook", .green)
        case .failed: return ("Order failed", "", .red)
        case .cancelled: return ("Order cancelled", "", .gray)
        }
    }
}

/// Scrollable, timestamped log of the SDK events (auto-scrolls to the latest).
struct EventLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text("waiting for events…").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line).id(idx)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 120)
            .background(Color(red: 0.04, green: 0.07, blue: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { _ in
                if let last = lines.indices.last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }
}

/// demo-only: keeps the event log + latest normalized status, and mirrors events to the console.
final class EventLog: ObservableObject {
    @Published var lines: [String] = []
    @Published var status: MeldStatus?

    func record(_ line: String) {
        print("[demo] \(line)")
        let stamped = "\(Self.timestamp())  \(line)"
        run { self.lines.append(stamped) }
    }

    func setStatus(_ status: MeldStatus) { run { self.status = status } }

    func clear() { run { self.lines = []; self.status = nil } }

    private func run(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static func timestamp() -> String { formatter.string(from: Date()) }
}
