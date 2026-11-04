import Foundation
import UIKit

protocol RequirementsTimer: AnyObject {
    func cancel()
}

extension DispatchWorkItem: RequirementsTimer {}

protocol RequirementsClock {
    func now() -> Date
    func schedule(after milliseconds: Int, _ work: @escaping () -> Void) -> RequirementsTimer
}

struct SystemRequirementsClock: RequirementsClock {
    func now() -> Date { Date() }
    func schedule(after milliseconds: Int, _ work: @escaping () -> Void) -> RequirementsTimer {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
        return item
    }
}

/// Hosted pages, behind the Continue prompt unless `prompted` is false. `onClose` says whether the page was opened;
/// false means Cancel.
protocol RequirementsPages {
    var available: Bool { get }
    func present(_ url: URL, prompted: Bool, onOpen: @escaping () -> Bool,
                 onClose: @escaping (Bool) -> Void) throws -> MeldProviderSession
}

struct HostedPages: RequirementsPages {
    weak var anchor: UIViewController?

    var available: Bool { HostedVerificationPresenter.top(anchor: anchor, host: nil) != nil }

    func present(_ url: URL, prompted: Bool, onOpen: @escaping () -> Bool,
                 onClose: @escaping (Bool) -> Void) throws -> MeldProviderSession {
        try HostedVerificationPresenter(url: url, prompt: prompted ? .verification : nil, anchor: anchor, host: nil,
                                        closesOnLoadFailure: true, onOpen: onOpen, onClose: onClose)
    }
}

/// `Meld.openHostedVerification`: keeps the page alive until it closes.
enum HostedVerification {
    private static var opened: [ObjectIdentifier: MeldProviderSession] = [:]

    static func open(_ url: URL, pages: RequirementsPages, onClose: @escaping () -> Void) {
        guard let url = RequirementsJSON.page(url.absoluteString) else { return DispatchQueue.main.async(execute: onClose) }
        var id: ObjectIdentifier?
        do {
            let session = try pages.present(url, prompted: true, onOpen: { true }, onClose: { _ in
                if let id { opened[id] = nil }
                onClose()
            })
            id = ObjectIdentifier(session)
            opened[ObjectIdentifier(session)] = session
        } catch { DispatchQueue.main.async(execute: onClose) }
    }
}

/// The common requirements loop. Runs on the main queue and retains itself until it resolves.
final class RequirementsLoop {
    static let refreshBeforeMs = 60_000
    static let settleWindowMs = 30_000
    static let transportBackoffMs = [1000, 2000, 4000]
    static let inFlightRetryMs = 1000
    static let inFlightRetries = 5
    static let collectRetries = 3
    static let outcomeUnknownRetries = 3
    static let renewalsPerHandle = 3

    private enum RunReply {
        case outcome(RequirementsRunOutcome)
        case fieldErrors([MeldFieldError])
        case reread
    }

    private var session: MeldRequirementsSession
    private let environment: MeldEnvironment
    private let handlers: MeldReadyHandlers
    private let options: MeldReadyOptions
    private let pages: RequirementsPages
    private let clock: RequirementsClock
    private let transport: () -> ActionTransport
    private let newKey: () -> UUID
    private var onResult: ((MeldReadyResult) -> Void)?

    private var retained: RequirementsLoop?
    private var done = false
    private var client: RequirementsActionClient?
    private var request = 0
    private var task: ActionTransportTask?
    private var sleeper: (timer: RequirementsTimer, work: () -> Void)?
    private var backoff: RequirementsTimer?
    private var snapshot: RequirementsSnapshot?
    private var attempted: [String: Data] = [:]
    private var settleUntil: [String: Date] = [:]
    private var outcomeUnknown: [String: Int] = [:]
    /// Steps other than OPEN_URL whose RUN_STEP answered OUTCOME_UNKNOWN: their write may have happened, so they are
    /// never sent again; while one is offered the run ends ACTION_REQUIRED with it.
    private var unsettled: Set<String> = []
    private var latestOutcome: (stepId: String, url: URL, expiresAt: Date?)?
    private var waitStart: Date?
    private var renewed = false
    private var renewals = 0
    private var presentation = 0
    private var page: MeldProviderSession?
    private var pollTimer: RequirementsTimer?
    private var pollTask: ActionTransportTask?
    private var polling: (() -> Void)?

    init(session: MeldRequirementsSession, environment: MeldEnvironment, handlers: MeldReadyHandlers,
         options: MeldReadyOptions, pages: RequirementsPages, clock: RequirementsClock = SystemRequirementsClock(),
         transport: @escaping () -> ActionTransport = { URLSessionActionTransport() },
         newKey: @escaping () -> UUID = UUID.init, onResult: @escaping (MeldReadyResult) -> Void) {
        self.session = session
        self.environment = environment
        self.handlers = handlers
        self.options = options
        self.pages = pages
        self.clock = clock
        self.transport = transport
        self.newKey = newKey
        self.onResult = onResult
    }

    func start() {
        retained = self
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.done else { return }
            guard self.connect(self.session) else { return self.fail(.protocol) }
            self.read()
        }
    }

    func refresh() {
        guard !done else { return }
        if let polling {
            pollTimer?.cancel()
            pollTimer = nil
            self.polling = nil
            polling()
        } else if let sleeper {
            sleeper.timer.cancel()
            self.sleeper = nil
            sleeper.work()
        }
    }

    func cancel() { finish(.cancelled) }

    // MARK: - Loop

    private func connect(_ session: MeldRequirementsSession) -> Bool {
        guard let descriptor = try? RequirementsSessionDescriptor(session: session.raw, environment: environment) else { return false }
        client?.finish()
        client = RequirementsActionClient(descriptor: descriptor, transport: transport())
        self.session = session
        return true
    }

    private func read(attempt: Int = 0, afterRenewal: (() -> Void)? = nil, then: ((RequirementsSnapshot) -> Void)? = nil) {
        progress(.reading)
        send("READ", [:], key: nil) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .success(let json):
                guard let snapshot = try? RequirementsSnapshot(json) else { return self.fail(.protocol) }
                self.renewed = false
                (then ?? self.handle)(snapshot)
            case .transport:
                guard attempt < Self.transportBackoffMs.count else { return self.fail(.transport) }
                self.sleep(Self.transportBackoffMs[attempt]) {
                    self.read(attempt: attempt + 1, afterRenewal: afterRenewal, then: then)
                }
            case let .failure(status, code, _):
                if status == 401 { return self.renew(then: afterRenewal) }
                self.fail(.http, status: status, code: code)
            case .invalid: self.fail(.protocol)
            }
        }
    }

    private func handle(_ snapshot: RequirementsSnapshot) {
        self.snapshot = snapshot
        if let status = MeldReadyStatus(rawValue: snapshot.status), [.ready, .undetermined, .blocked].contains(status) {
            return finish(status)
        }
        unsettled.formIntersection(snapshot.next.map(\.stepId))
        if let held = snapshot.next.first(where: { unsettled.contains($0.stepId) }) {
            return finish(.actionRequired, pending: [held])
        }
        guard let step = snapshot.next.first(where: canRun) else {
            if !snapshot.next.isEmpty { return finish(.actionRequired, pending: snapshot.next) }
            // Nothing to run and nothing to wait for: `providers[].open` names what is left.
            if snapshot.status == MeldReadyStatus.actionRequired.rawValue, snapshot.waitingOn.isEmpty {
                return finish(.actionRequired, pending: [])
            }
            let now = clock.now()
            let start = waitStart ?? now
            waitStart = start
            if now.timeIntervalSince(start) * 1000 > Double(options.waitTimeoutMs) { return finish(.pending) }
            return sleep(snapshot.pollAfterMs, state: .waiting) { [weak self] in self?.read() }
        }
        waitStart = nil
        if attempted[step.stepId] == snapshot.fingerprint {
            if let until = settleUntil[step.stepId], clock.now() < until {
                return sleep(snapshot.pollAfterMs, state: .waiting) { [weak self] in self?.read() }
            }
            return finish(.actionRequired, pending: [step])
        }
        attempted[step.stepId] = snapshot.fingerprint
        run(step) { [weak self] in
            guard let self, !self.done else { return }
            self.settleUntil[step.stepId] = self.clock.now().addingTimeInterval(Double(Self.settleWindowMs) / 1000)
            self.read()
        }
    }

    private func canRun(_ step: MeldReadyStep) -> Bool {
        switch step.kind {
        case "SUBMIT": return true
        case "COLLECT", "VERIFY_CONTACT": return handlers.collect != nil
        case "AGREE": return handlers.confirmAgreement != nil
        case "OPEN_URL": return handlers.presentUrl != nil || pages.available
        default: return false
        }
    }

    private func run(_ step: MeldReadyStep, then next: @escaping () -> Void) {
        switch step.kind {
        case "SUBMIT": submit(step, then: next)
        case "COLLECT": collect(step, then: next)
        case "AGREE": agree(step, then: next)
        case "OPEN_URL": openURL(step, then: next)
        case "VERIFY_CONTACT": verify(step, then: next)
        default: finish(.actionRequired, pending: [step])
        }
    }

    // MARK: - Steps

    private func submit(_ step: MeldReadyStep, then next: @escaping () -> Void) {
        if let kept = latestOutcome, kept.stepId == step.stepId, let expiresAt = kept.expiresAt, fresh(expiresAt) {
            return present(step, url: kept.url, expiresAt: expiresAt, refreshOnClose: false, then: next)
        }
        runStep(step, [:]) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case let .outcome(.openURL(url, expiresAt)):
                self.latestOutcome = (step.stepId, url, expiresAt)
                self.present(step, url: url, expiresAt: expiresAt, refreshOnClose: false, then: next)
            case .outcome(.done), .reread: next()
            case .outcome(.collect): self.fail(.protocol)
            case .fieldErrors: self.fail(.http, status: 400, code: PaymentActionFailureCode.invalidRequest.rawValue)
            }
        }
    }

    private func collect(_ step: MeldReadyStep, fieldErrors: [MeldFieldError]? = nil, retries: Int = 0,
                         then next: @escaping () -> Void) {
        ask(step, fields: step.fields ?? [], fieldErrors: fieldErrors) { [weak self] values in
            guard let self else { return }
            guard let values else { return next() }
            self.runStep(step, ["fields": values]) { reply in
                switch reply {
                case .outcome(.done), .reread: next()
                case .fieldErrors(let errors):
                    guard retries < Self.collectRetries else { return self.finish(.actionRequired, pending: [step]) }
                    self.collect(step, fieldErrors: errors, retries: retries + 1, then: next)
                case .outcome: self.fail(.protocol)
                }
            }
        }
    }

    private func agree(_ step: MeldReadyStep, then next: @escaping () -> Void) {
        guard let confirm = handlers.confirmAgreement else { return finish(.actionRequired, pending: [step]) }
        progress(.awaitingInput)
        guard !done else { return }
        let document = step.url.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? $0 : nil }
        let request = MeldAgreementRequest(stepId: step.stepId, serviceProvider: step.serviceProviders.first ?? "",
                                           code: step.code, url: document)
        confirm(request, once { [weak self] accepted in
            guard let self else { return }
            guard accepted else { return self.finish(.actionRequired, pending: [step]) }
            self.runStep(step, ["accepted": true]) { reply in
                switch reply {
                case .outcome(.done), .reread: next()
                case .outcome: self.fail(.protocol)
                case .fieldErrors: self.fail(.http, status: 400, code: PaymentActionFailureCode.invalidRequest.rawValue)
                }
            }
        })
    }

    private func openURL(_ step: MeldReadyStep, then next: @escaping () -> Void) {
        if let url = RequirementsJSON.page(step.url), step.expiresAt.map(fresh) ?? true {
            return present(step, url: url, expiresAt: step.expiresAt, refreshOnClose: true, then: next)
        }
        runStep(step, ["refresh": true]) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case let .outcome(.openURL(url, expiresAt)):
                self.present(step, url: url, expiresAt: expiresAt, refreshOnClose: true, then: next)
            case .outcome(.done), .reread: next()
            case .outcome(.collect): self.fail(.protocol)
            case .fieldErrors: self.fail(.http, status: 400, code: PaymentActionFailureCode.invalidRequest.rawValue)
            }
        }
    }

    private func verify(_ step: MeldReadyStep, body: [String: Any] = [:], asked: [MeldReadyField] = [],
                        continuation: String? = nil, retries: Int = 0, then next: @escaping () -> Void) {
        runStep(step, body) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .outcome(.done), .reread: next()
            case let .outcome(.collect(fields, continuation)):
                self.answer(step, fields: fields, continuation: continuation, fieldErrors: nil, retries: 0, then: next)
            case .fieldErrors(let errors) where !asked.isEmpty:
                guard retries < Self.collectRetries else { return self.finish(.actionRequired, pending: [step]) }
                self.answer(step, fields: asked, continuation: continuation, fieldErrors: errors, retries: retries + 1, then: next)
            case .fieldErrors: self.fail(.http, status: 400, code: PaymentActionFailureCode.invalidRequest.rawValue)
            case .outcome(.openURL): self.fail(.protocol)
            }
        }
    }

    private func answer(_ step: MeldReadyStep, fields: [MeldReadyField], continuation: String?,
                        fieldErrors: [MeldFieldError]?, retries: Int, then next: @escaping () -> Void) {
        ask(step, fields: fields, fieldErrors: fieldErrors) { [weak self] values in
            guard let self else { return }
            guard let values else { return next() }
            var body: [String: Any] = ["fields": values]
            if let continuation { body["continuation"] = continuation }
            self.verify(step, body: body, asked: fields, continuation: continuation, retries: retries, then: next)
        }
    }

    private func ask(_ step: MeldReadyStep, fields: [MeldReadyField], fieldErrors: [MeldFieldError]?,
                     then: @escaping ([String: String]?) -> Void) {
        guard let collect = handlers.collect else { return finish(.actionRequired, pending: [step]) }
        progress(.awaitingInput)
        guard !done else { return }
        collect(MeldCollectRequest(stepId: step.stepId, type: step.type, code: step.code,
                                   serviceProviders: step.serviceProviders, fields: fields, reason: step.reason,
                                   fieldErrors: fieldErrors), once(then))
    }

    // MARK: - Pages

    private func present(_ step: MeldReadyStep, url: URL, expiresAt: Date?, refreshOnClose: Bool, prompted: Bool = true,
                         then next: @escaping () -> Void) {
        presentation += 1
        let current = presentation
        let closed: (Bool) -> Void = { [weak self] cancelled in
            guard let self, !self.done, self.presentation == current else { return }
            self.endPresentation()
            if cancelled { return self.finish(.actionRequired, pending: [step]) }
            guard refreshOnClose else { return next() }
            self.refreshAfterClose(step, then: next)
        }
        progress(.presenting)
        guard !done else { return }
        if let presentUrl = handlers.presentUrl {
            presentUrl(MeldPresentUrlRequest(stepId: step.stepId, url: url, expiresAt: expiresAt), onceClosed { closed(false) })
            return
        }
        do {
            page = try pages.present(url, prompted: prompted, onOpen: { [weak self] in
                guard let self, !self.done else { return false }
                guard prompted, refreshOnClose, let expiresAt, !self.fresh(expiresAt) else { return true }
                self.refreshBehindPrompt(step, then: next)
                return false
            }, onClose: { opened in closed(!opened) })
        } catch { return finish(.actionRequired, pending: [step]) }
        poll(step, after: snapshot?.pollAfterMs ?? RequirementsSnapshot.defaultPollMs, presentation: current)
    }

    /// The link aged below `refreshBeforeMs` behind the prompt: refresh it and open the new one without asking again,
    /// also when the refresh needed a renewal.
    private func refreshBehindPrompt(_ step: MeldReadyStep, then next: @escaping () -> Void) {
        endPresentation()
        let again: () -> Void = { [weak self] in self?.refreshBehindPrompt(step, then: next) }
        runStep(step, ["refresh": true], afterRenewal: again) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case let .outcome(.openURL(url, expiresAt)):
                self.present(step, url: url, expiresAt: expiresAt, refreshOnClose: true, prompted: false, then: next)
            case .outcome(.done), .reread: next()
            case .outcome(.collect): self.fail(.protocol)
            case .fieldErrors: self.fail(.http, status: 400, code: PaymentActionFailureCode.invalidRequest.rawValue)
            }
        }
    }

    /// The customer closed the page: refresh its link once and read on. A 401 renews and sends the refresh again on the
    /// new session; the step stays attempted, so the page is not opened again.
    private func refreshAfterClose(_ step: MeldReadyStep, then next: @escaping () -> Void) {
        let again: () -> Void = { [weak self] in self?.refreshAfterClose(step, then: next) }
        runStep(step, ["refresh": true], afterRenewal: again) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .outcome(.done), .outcome(.openURL), .reread: next()
            case .outcome(.collect): self.fail(.protocol)
            case .fieldErrors: self.fail(.http, status: 400, code: PaymentActionFailureCode.invalidRequest.rawValue)
            }
        }
    }

    private func poll(_ step: MeldReadyStep, after milliseconds: Int, presentation current: Int) {
        let work = { [weak self] in
            guard let self, !self.done, self.presentation == current, let client = self.client else { return }
            self.pollTimer = nil
            self.polling = nil
            self.pollTask = client.send("READ", fields: [:], key: nil) { [weak self] reply in
                guard let self, !self.done, self.presentation == current else { return }
                self.pollTask = nil
                guard case .success(let json) = reply, let snapshot = try? RequirementsSnapshot(json) else {
                    return self.poll(step, after: milliseconds, presentation: current)
                }
                guard snapshot.next.contains(where: { $0.stepId == step.stepId }) else {
                    self.endPresentation()
                    return self.handle(snapshot)
                }
                self.snapshot = snapshot
                self.poll(step, after: snapshot.pollAfterMs, presentation: current)
            }
        }
        polling = work
        pollTimer = clock.schedule(after: milliseconds) { [weak self] in
            guard let self, self.presentation == current else { return }
            work()
        }
    }

    private func endPresentation() {
        presentation += 1
        pollTimer?.cancel()
        pollTimer = nil
        polling = nil
        pollTask?.cancel()
        pollTask = nil
        page?.unmount()
        page = nil
    }

    private func fresh(_ expiresAt: Date) -> Bool {
        expiresAt.timeIntervalSince(clock.now()) * 1000 >= Double(Self.refreshBeforeMs)
    }

    // MARK: - Transport

    /// One RUN_STEP under its own key. Transport failures and 425 retry with the same key; the cases the loop
    /// owns (401, 503 OUTCOME_UNKNOWN, anything else) never reach `then`. After a 401 the renewed session goes on
    /// with `afterRenewal`, or with a READ that may run the step again. After OUTCOME_UNKNOWN only an OPEN_URL
    /// refresh is sent again, under a new key; any other step is `unsettled`.
    private func runStep(_ step: MeldReadyStep, _ fields: [String: Any], key: UUID? = nil, attempt: Int = 0,
                         inFlight: Int = 0, afterRenewal: (() -> Void)? = nil, then: @escaping (RunReply) -> Void) {
        let key = key ?? newKey()
        var body = fields
        body["stepId"] = step.stepId
        progress(.running)
        send("RUN_STEP", body, key: key) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .success(let json):
                guard let outcome = try? RequirementsRunOutcome(json, stepId: step.stepId) else { return self.fail(.protocol) }
                self.renewed = false
                then(.outcome(outcome))
            case .transport:
                guard attempt < Self.transportBackoffMs.count else { return self.fail(.transport) }
                self.sleep(Self.transportBackoffMs[attempt]) {
                    self.runStep(step, fields, key: key, attempt: attempt + 1, inFlight: inFlight, afterRenewal: afterRenewal,
                                 then: then)
                }
            case let .failure(status, code, fieldErrors):
                if status == 401 {
                    if afterRenewal == nil { self.attempted[step.stepId] = nil }
                    return self.renew(then: afterRenewal)
                }
                switch status {
                case 400 where !fieldErrors.isEmpty: then(.fieldErrors(fieldErrors))
                case 409, 422: then(.reread)
                case 425 where inFlight < Self.inFlightRetries:
                    self.sleep(Self.inFlightRetryMs) {
                        self.runStep(step, fields, key: key, attempt: attempt, inFlight: inFlight + 1, afterRenewal: afterRenewal,
                                     then: then)
                    }
                case 425: self.fail(.http, status: status, code: PaymentActionFailureCode.operationInFlight.rawValue)
                case 503 where code == PaymentActionFailureCode.outcomeUnknown.rawValue:
                    if afterRenewal == nil { self.attempted[step.stepId] = nil }
                    if step.kind != "OPEN_URL" { self.unsettled.insert(step.stepId) }
                    self.read(afterRenewal: afterRenewal) { snapshot in
                        guard step.kind == "OPEN_URL", snapshot.next.contains(where: { $0.stepId == step.stepId }) else {
                            return self.handle(snapshot)
                        }
                        let count = (self.outcomeUnknown[step.stepId] ?? 0) + 1
                        guard count <= Self.outcomeUnknownRetries else { return self.fail(.http, status: status, code: code) }
                        self.outcomeUnknown[step.stepId] = count
                        self.snapshot = snapshot
                        self.attempted[step.stepId] = snapshot.fingerprint
                        self.runStep(step, fields, afterRenewal: afterRenewal, then: then)
                    }
                default: self.fail(.http, status: status, code: code)
                }
            case .invalid: self.fail(.protocol)
            }
        }
    }

    private func send(_ operation: String, _ fields: [String: Any], key: UUID?,
                      completion: @escaping (RequirementsReply) -> Void) {
        guard !done, let client else { return fail(.protocol) }
        request += 1
        let current = request
        task = client.send(operation, fields: fields, key: key) { [weak self] reply in
            guard let self, !self.done, self.request == current else { return }
            self.task = nil
            completion(reply)
        }
    }

    private func renew(then next: (() -> Void)? = nil) {
        guard let renewSession = handlers.renewSession, !renewed, renewals < Self.renewalsPerHandle else {
            return finish(.expired)
        }
        renewed = true
        renewals += 1
        progress(.awaitingInput)
        guard !done else { return }
        renewSession(once { [weak self] session in
            guard let self else { return }
            guard let session else { return self.finish(.expired) }
            guard self.connect(session) else { return self.fail(.protocol) }
            if let next { return next() }
            self.read()
        })
    }

    /// A wait (`state` given) is what `refresh()` wakes; a retry backoff keeps its time.
    private func sleep(_ milliseconds: Int, state: MeldReadyProgress.State? = nil, then work: @escaping () -> Void) {
        if let state { progress(state) }
        guard !done else { return }
        let wakeable = state != nil
        let timer = clock.schedule(after: milliseconds) { [weak self] in
            guard let self, !self.done else { return }
            if wakeable { self.sleeper = nil } else { self.backoff = nil }
            work()
        }
        if wakeable { sleeper = (timer, work) } else { backoff = timer }
    }

    /// An integrator completion: delivered once, on the main queue, and never after the loop resolved.
    private func once<Value>(_ then: @escaping (Value) -> Void) -> (Value) -> Void {
        var answered = false
        return { [weak self] value in
            let deliver = {
                guard let self, !self.done, !answered else { return }
                answered = true
                then(value)
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
    }

    private func onceClosed(_ then: @escaping () -> Void) -> () -> Void {
        let deliver: (Bool) -> Void = once { _ in then() }
        return { deliver(true) }
    }

    private func progress(_ state: MeldReadyProgress.State) {
        guard !done else { return }
        handlers.onProgress?(MeldReadyProgress(state: state, snapshot: snapshot?.raw))
    }

    // MARK: - Result

    private func fail(_ kind: MeldReadyError.Kind, status: Int? = nil, code: String? = nil) {
        finish(.failed, error: MeldReadyError(kind: kind, status: status, code: code))
    }

    private func finish(_ status: MeldReadyStatus, pending: [MeldReadyStep]? = nil, error: MeldReadyError? = nil) {
        guard !done else { return }
        done = true
        sleeper?.timer.cancel()
        sleeper = nil
        backoff?.cancel()
        backoff = nil
        task?.cancel()
        task = nil
        endPresentation()
        client?.finish()
        client = nil
        latestOutcome = nil
        let result = MeldReadyResult(status: status, providers: snapshot?.providers ?? [],
                                     pending: status == .actionRequired ? pending ?? [] : nil,
                                     continuation: snapshot?.continuation ?? [], error: error)
        let callback = onResult
        onResult = nil
        withExtendedLifetime(self) {
            retained = nil
            callback?(result)
        }
    }
}
