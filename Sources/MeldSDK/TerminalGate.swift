import Foundation

/// Collapses a provider's "the user is done paying" moment into exactly one `onPaymentSubmitted`
/// per mount.
///
/// Providers disagree on how that moment arrives. Uphold's authorize widget sends only `complete`
/// and never a status. Hosted-link Apple Pay sends `commit_success` *and* `polling_start` — both
/// meaning submitted — then `polling_success` as a `completed` status later. Mercuryo's card widget
/// sends "payment finished" and a `paid` status as two unrelated messages with no ordering between
/// them. Left alone, that asymmetry lands on the integrator, who has to dedupe terminal handling or
/// watch it run twice; every one of them ends up writing the same guard.
///
/// A terminal failure or cancellation closes the gate without firing, so "payment failed" is never
/// followed by "payment submitted". A *recoverable* error leaves it open: the mount is still alive
/// and the customer may yet pay.
///
/// `onStatusChange` is untouched. A provider that genuinely reports `completed` still reports it.
struct TerminalGate {
    private var closed = false

    /// Whether this event is the one terminal moment the host should hear about as
    /// `onPaymentSubmitted`. Records the decision, so a second terminal event returns `false`.
    mutating func admit(_ event: MeldEvent) -> Bool {
        switch event {
        case .paymentSubmitted:
            return open()
        case let .statusChange(change):
            switch change.status {
            case .completed: return open()
            case .failed, .cancelled: closed = true
            case .pending: break
            }
            return false
        case .cancel:
            closed = true
            return false
        case let .error(error):
            if !error.recoverable { closed = true }
            return false
        case .ready:
            return false
        }
    }

    private mutating func open() -> Bool {
        guard !closed else { return false }
        closed = true
        return true
    }
}
