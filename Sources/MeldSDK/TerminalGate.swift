import Foundation
import os

extension MeldEventHandlers {

    /// Delivers exactly one terminal callback per mount — `onPaymentSubmitted`, `onCancel` or a
    /// non-recoverable `onError` — and drops every callback after it.
    ///
    /// Providers disagree on how "the customer is done paying" arrives: a finished message, a
    /// `completed` status, or both in either order. All of them collapse into one
    /// `onPaymentSubmitted`, which a `failed` or `cancelled` status blocks. `onStatusChange` lands
    /// before the callback synthesized from it.
    ///
    /// Applied by `Meld.mount` to the caller's handlers, so it covers every adapter — including the
    /// ones that invoke a handler directly rather than going through a host's event dispatch.
    func gated(by gate: TerminalGate = TerminalGate()) -> MeldEventHandlers {
        let source = self
        let onError: (MeldError) -> Void = { error in
            guard error.recoverable ? gate.admits("onError") : gate.terminal("onError") else { return }
            source.onError?(error)
        }

        var handlers = MeldEventHandlers(
            onReady: { orderId in
                if gate.admits("onReady") { source.onReady?(orderId) }
            },
            onPaymentSubmitted: { orderId in
                if gate.submission() { source.onPaymentSubmitted?(orderId) }
            },
            onStatusChange: { change in
                guard gate.admits("onStatusChange") else { return }
                source.onStatusChange?(change)
                gate.observe(change.status)
                if change.status == .completed, gate.submission() { source.onPaymentSubmitted?(change.orderId) }
            },
            onCancel: { orderId in
                if gate.terminal("onCancel") { source.onCancel?(orderId) }
            },
            onError: onError
        )
        handlers.sessionEnded = { orderId in
            if let error = gate.unannouncedEnd(orderId: orderId) { onError(error) }
        }
        return handlers
    }
}

/// State shared by every closure in `gated()` and by the handle that owns the mount.
/// Confined to the main thread, like the handler callbacks themselves.
final class TerminalGate {
    private static let logger = Logger(subsystem: "io.meld.sdk", category: "TerminalGate")

    private var terminalDelivered = false
    private var submissionBlocked = false
    private var failedSeen = false
    private var released = false

    /// `false` once the terminal callback has been delivered; the dropped callback is logged.
    func admits(_ callback: String) -> Bool {
        guard terminalDelivered else { return true }
        Self.logger.info("dropped \(callback, privacy: .public) after the terminal callback")
        return false
    }

    /// `true` only for the first terminal callback of the mount.
    func terminal(_ callback: String) -> Bool {
        guard admits(callback) else { return false }
        terminalDelivered = true
        return true
    }

    func submission() -> Bool {
        guard !submissionBlocked else {
            Self.logger.info("dropped onPaymentSubmitted after a failed or cancelled status")
            return false
        }
        return terminal("onPaymentSubmitted")
    }

    func observe(_ status: MeldStatus) {
        switch status {
        case .failed:
            failedSeen = true
            submissionBlocked = true
        case .cancelled:
            submissionBlocked = true
        case .pending, .completed:
            break
        }
    }

    /// The integrator unmounted or dropped the handle, so a later teardown owes no callback.
    func release() {
        released = true
    }

    /// The terminal error owed by a session that ended without delivering one.
    func unannouncedEnd(orderId: String?) -> MeldError? {
        guard !terminalDelivered, !released else { return nil }
        if failedSeen {
            return MeldError(orderId: orderId, code: MeldErrorCode.paymentRejected,
                             message: "The payment failed. Choose another payment option.",
                             detail: "session_ended", recoverable: false)
        }
        return MeldError(orderId: orderId, code: MeldErrorCode.paymentOutcomeUnknown,
                         message: "The payment session ended without an outcome. Track the existing order without paying again.",
                         detail: "session_ended", recoverable: false)
    }
}
