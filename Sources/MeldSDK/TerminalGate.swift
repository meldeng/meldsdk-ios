import Foundation

extension MeldEventHandlers {

    /// Collapses a provider's "the customer is done paying" moment into exactly one
    /// `onPaymentSubmitted` per mount.
    ///
    /// Providers disagree on how that moment arrives. Uphold's authorize widget sends only
    /// `complete` and never a status. Hosted-link Apple Pay sends `commit_success` *and*
    /// `polling_start` — both meaning submitted — then `polling_success` as a `completed` status
    /// later. Mercuryo's card widget sends "payment finished" and a `paid` status as two unrelated
    /// messages with no ordering between them. Left alone, that asymmetry lands on the integrator,
    /// who has to dedupe terminal handling or watch it run twice; every one of them ends up writing
    /// the same guard.
    ///
    /// A terminal failed/cancelled status, a cancel, or a non-recoverable error closes the gate
    /// without firing, so a failure is never followed by a submission. A *recoverable* error does
    /// not: the surface is still alive and the customer may yet pay.
    ///
    /// Applied by `Meld.mount` to the caller's handlers, so it covers every adapter — including the
    /// ones that invoke a handler directly rather than going through a host's event dispatch.
    ///
    /// `onStatusChange` is passed straight through, and lands before the callback synthesized from
    /// it.
    func gated() -> MeldEventHandlers {
        let source = self
        let gate = TerminalGate()

        return MeldEventHandlers(
            onReady: source.onReady,
            onPaymentSubmitted: { orderId in
                if gate.open() { source.onPaymentSubmitted?(orderId) }
            },
            onStatusChange: { change in
                source.onStatusChange?(change)
                switch change.status {
                case .completed:
                    if gate.open() { source.onPaymentSubmitted?(change.orderId) }
                case .failed, .cancelled:
                    gate.close()
                case .pending:
                    break
                }
            },
            onCancel: { orderId in
                gate.close()
                source.onCancel?(orderId)
            },
            onError: { error in
                if !error.recoverable { gate.close() }
                source.onError?(error)
            }
        )
    }
}

/// Reference box for the gate's one bit of state, so every closure in `gated()` shares it.
/// Confined to the main thread, like the handler callbacks themselves.
final class TerminalGate {
    private var closed = false

    /// `true` the first time the payment reaches a terminal point, `false` every time after.
    func open() -> Bool {
        guard !closed else { return false }
        closed = true
        return true
    }

    /// Close without firing, for a terminal state that is not a submission.
    func close() {
        closed = true
    }
}
