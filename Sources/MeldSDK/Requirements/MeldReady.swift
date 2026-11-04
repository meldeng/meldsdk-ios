import Foundation
import UIKit

public enum MeldReadyStatus: String {
    /// Create the order.
    case ready = "READY"
    /// Meld could not tell; create the order, which stays the authoritative check.
    case undetermined = "UNDETERMINED"
    /// Waiting on a review. Call `ensureReady` again later, or on `CUSTOMER_KYC_STATUS_CHANGE`.
    case pending = "PENDING"
    /// The provider refuses this customer or order; offer another provider.
    case blocked = "BLOCKED"
    /// Something needs the customer or your backend: show `pending`, then call `ensureReady` again. An empty
    /// `pending` means nothing on the device can do it; `providers[].open` names it.
    case actionRequired = "ACTION_REQUIRED"
    case cancelled = "CANCELLED"
    /// Meld refused the session with 401 (its token expired, or it was minted in another environment than
    /// `Meld.configure(environment:)`) and `renewSession` did not supply one it accepts.
    case expired = "EXPIRED"
    case failed = "FAILED"
}

/// A step the session offers: what it is, for which providers, and what it needs.
public struct MeldReadyStep: CustomStringConvertible {
    public let stepId: String
    /// `SUBMIT`, `COLLECT`, `AGREE`, `OPEN_URL` or `VERIFY_CONTACT`; an open set.
    public let kind: String
    public let type: String
    public let code: String
    public let serviceProviders: [String]
    public let level: String?
    /// The terms document for `AGREE`, the page for `OPEN_URL`.
    public let url: String?
    public let expiresAt: Date?
    public let fields: [MeldReadyField]?
    public let reason: String?
    public var description: String { "[MeldReadyStep REDACTED]" }
}

public struct MeldReadyField {
    public let key: String
    public let label: String?
    public let fieldType: String?
    public let jsonSchema: String?
    public let allowedValues: [String]?
}

public struct MeldReadyProvider {
    public let serviceProvider: String
    public let status: String
    public let eligible: Bool?
    /// Every pre-order requirement that is not yet satisfied.
    public let open: [MeldReadyRequirement]
}

public struct MeldReadyRequirement {
    public let type: String
    public let code: String
    public let status: String
    public let reason: String?
    /// The provider's codes for a share it refused, such as `PHONE_VERIFICATION_REQUIRED`; an open set. Nil when
    /// Meld sends none.
    public let errorCodes: [String]?
}

/// A step that runs inside `Meld.mount(order)`, after the order exists.
public struct MeldReadyContinuation {
    public let serviceProvider: String
    public let code: String
    public let nextStep: String?
}

public struct MeldReadyError {
    public enum Kind: String { case http, transport, `protocol` }
    public let kind: Kind
    public let status: Int?
    /// The Meld error code, when the response carried a known one.
    public let code: String?
}

public struct MeldReadyResult {
    public let status: MeldReadyStatus
    public let providers: [MeldReadyProvider]
    /// What is left for the customer or your backend. `ACTION_REQUIRED` only; empty when no step can run on the device.
    public let pending: [MeldReadyStep]?
    public let continuation: [MeldReadyContinuation]
    public let error: MeldReadyError?
}

public struct MeldReadyProgress {
    public enum State: String {
        case reading = "READING", running = "RUNNING", awaitingInput = "AWAITING_INPUT"
        case presenting = "PRESENTING", waiting = "WAITING"
    }
    public let state: State
    /// The latest READ response, as returned.
    public let snapshot: [String: Any]?
}

/// Values your app collects for a step. Answer with the values by key, or nil when your backend handled the step.
public struct MeldCollectRequest {
    public let stepId: String
    public let type: String
    public let code: String
    public let serviceProviders: [String]
    public let fields: [MeldReadyField]
    public let reason: String?
    /// Why the previous answer was refused.
    public let fieldErrors: [MeldFieldError]?
}

/// Terms the customer must accept. The SDK never accepts on its own.
public struct MeldAgreementRequest: CustomStringConvertible {
    public let stepId: String
    public let serviceProvider: String
    public let code: String
    public let url: URL?
    public var description: String { "[MeldAgreementRequest REDACTED]" }
}

/// A page to show the customer. Call the completion once it is closed.
public struct MeldPresentUrlRequest: CustomStringConvertible {
    public let stepId: String
    public let url: URL
    public let expiresAt: Date?
    public var description: String { "[MeldPresentUrlRequest REDACTED]" }
}

/// Every handler runs on the main queue. A completion may be called from any queue, once.
public struct MeldReadyHandlers {
    public var onProgress: ((MeldReadyProgress) -> Void)?
    public var collect: ((MeldCollectRequest, @escaping ([String: String]?) -> Void) -> Void)?
    public var confirmAgreement: ((MeldAgreementRequest, @escaping (Bool) -> Void) -> Void)?
    /// Replaces the SDK's own page presentation.
    public var presentUrl: ((MeldPresentUrlRequest, @escaping () -> Void) -> Void)?
    /// Mint another session when Meld refuses this one (401); answer nil to end with `EXPIRED`. Asked at most once
    /// until Meld answers again and at most three times per run; the next 401 ends `EXPIRED`.
    public var renewSession: ((@escaping (MeldRequirementsSession?) -> Void) -> Void)?

    public init(onProgress: ((MeldReadyProgress) -> Void)? = nil,
                collect: ((MeldCollectRequest, @escaping ([String: String]?) -> Void) -> Void)? = nil,
                confirmAgreement: ((MeldAgreementRequest, @escaping (Bool) -> Void) -> Void)? = nil,
                presentUrl: ((MeldPresentUrlRequest, @escaping () -> Void) -> Void)? = nil,
                renewSession: ((@escaping (MeldRequirementsSession?) -> Void) -> Void)? = nil) {
        self.onProgress = onProgress
        self.collect = collect
        self.confirmAgreement = confirmAgreement
        self.presentUrl = presentUrl
        self.renewSession = renewSession
    }
}

public struct MeldReadyOptions {
    public var waitTimeoutMs: Int = 600_000
    public init(waitTimeoutMs: Int = 600_000) { self.waitTimeoutMs = waitTimeoutMs }
}

/// The running check. It keeps running when released; `cancel()` stops it.
public final class MeldReadyHandle {
    private weak var loop: RequirementsLoop?

    init(loop: RequirementsLoop) { self.loop = loop }

    /// Stop waiting and read again now, for example when your backend relays `CUSTOMER_KYC_STATUS_CHANGE`. A retry
    /// keeps its backoff.
    public func refresh() { Self.onMain { [loop] in loop?.refresh() } }
    /// Abort the request in flight and end with `CANCELLED`.
    public func cancel() { Self.onMain { [loop] in loop?.cancel() } }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

public extension Meld {
    /// Run the session's checklist until the customer can order: read it, run each step this device can run,
    /// and wait on reviews. `onResult` runs once, on the main queue, after this call returns. Call on the main
    /// thread; `presenter` anchors the SDK's own pages (default: the key window's top controller).
    @discardableResult
    static func ensureReady(session: MeldRequirementsSession, handlers: MeldReadyHandlers,
                            options: MeldReadyOptions = .init(), presenter: UIViewController? = nil,
                            onResult: @escaping (MeldReadyResult) -> Void) -> MeldReadyHandle {
        let loop = RequirementsLoop(session: session, environment: environment, handlers: handlers, options: options,
                                    pages: HostedPages(anchor: presenter), onResult: onResult)
        loop.start()
        return MeldReadyHandle(loop: loop)
    }

    /// Show a hosted verification page a create refusal carried (for example
    /// `serviceProviderDetails.hostedVerificationUrl`), behind the same Continue prompt `ensureReady` uses. After
    /// `onClose`, create the order again with a new `externalOrderId`. `onClose` runs on the main queue, also when
    /// the URL is not https or nothing is on screen to present from.
    static func openHostedVerification(url: URL, presenter: UIViewController? = nil, onClose: @escaping () -> Void) {
        let open = { HostedVerification.open(url, pages: HostedPages(anchor: presenter), onClose: onClose) }
        if Thread.isMainThread { open() } else { DispatchQueue.main.async(execute: open) }
    }
}
