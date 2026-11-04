import XCTest
@testable import MeldSDK

/// The shared contract fixtures (`requirements-fixtures/`), read from the source tree.
enum RequirementsFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/requirements-fixtures")

    struct Run {
        let at: Date
        let key: String
        let request: [String: Any]
        let status: Int
        let response: [String: Any]
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(path))
    }

    /// Every `requirements-session/*.json`, by name.
    static func sessionNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("requirements-session").path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func session(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data("requirements-session/\(name).json")) as? [String: Any])
    }

    static func mint(_ name: String) throws -> [String: Any] {
        try XCTUnwrap((try session(name)["mint"] as? [String: Any])?["response"] as? [String: Any])
    }

    static func exchanges(_ name: String, _ operation: String) throws -> [[String: Any]] {
        try XCTUnwrap(try session(name)["exchanges"] as? [[String: Any]]).filter { $0["operation"] as? String == operation }
    }

    static func reads(_ name: String) throws -> [[String: Any]] {
        try exchanges(name, "READ").map { try XCTUnwrap($0["response"] as? [String: Any]) }
    }

    static func runs(_ name: String) throws -> [Run] {
        try exchanges(name, "RUN_STEP").map {
            Run(at: date(try XCTUnwrap($0["at"] as? String)), key: try XCTUnwrap($0["idempotencyKey"] as? String),
                request: try XCTUnwrap($0["request"] as? [String: Any]), status: try XCTUnwrap($0["status"] as? Int),
                response: try XCTUnwrap($0["response"] as? [String: Any]))
        }
    }

    static func firstAt(_ name: String) throws -> Date {
        date(try XCTUnwrap((try session(name)["exchanges"] as? [[String: Any]])?.first?["at"] as? String))
    }

    static func date(_ raw: String) -> Date { RequirementsJSON.date(raw)! }

    /// A READ with the named steps gone from `next[]`, as the server answers once they ran.
    static func read(_ read: [String: Any], without stepIds: Set<String>) -> [String: Any] {
        var copy = read
        copy["next"] = (read["next"] as? [[String: Any]] ?? []).filter { !stepIds.contains($0["stepId"] as? String ?? "") }
        return copy
    }

    /// A READ's providers as `MeldReadyResult.providers` reports them: `open` is every PRE_ORDER requirement
    /// that is not SATISFIED, with its `reason` and a non-empty `errorCodes`.
    static func reported(_ read: [String: Any]) -> [[String: Any]] {
        (read["providers"] as? [[String: Any]] ?? []).map { provider in
            let open = (provider["requirements"] as? [[String: Any]] ?? [])
                .filter { $0["status"] as? String != "SATISFIED" && $0["timing"] as? String == "PRE_ORDER" }
                .map { requirement -> [String: Any] in
                    var open = ["type", "code", "status", "reason"].reduce(into: [String: Any]()) { $0[$1] = requirement[$1] }
                    if let codes = requirement["errorCodes"] as? [String], !codes.isEmpty { open["errorCodes"] = codes }
                    return open
                }
            return ["serviceProvider": provider["serviceProvider"] ?? NSNull(), "status": provider["status"] ?? NSNull(),
                    "eligible": provider["eligible"] ?? NSNull(), "open": open]
        }
    }

    static func reported(_ providers: [MeldReadyProvider]) -> [[String: Any]] {
        providers.map { provider in
            let open = provider.open.map { requirement -> [String: Any] in
                var open: [String: Any] = ["type": requirement.type, "code": requirement.code, "status": requirement.status]
                open["reason"] = requirement.reason
                open["errorCodes"] = requirement.errorCodes
                return open
            }
            return ["serviceProvider": provider.serviceProvider, "status": provider.status,
                    "eligible": provider.eligible.map { $0 as Any } ?? NSNull(), "open": open]
        }
    }

    static func read(_ read: [String: Any], changing stepId: String, _ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var copy = read
        copy["next"] = (read["next"] as? [[String: Any]] ?? []).map { step in
            guard step["stepId"] as? String == stepId else { return step }
            var changed = step
            change(&changed)
            return changed
        }
        return copy
    }
}

/// An ActionTransport that answers from fixtures: READs in order (the last one repeats), RUN_STEPs by body.
final class FixtureTransport: ActionTransport {
    struct Call {
        let operation: String
        let body: [String: Any]
        let key: String?
        let request: URLRequest
        var stepId: String? { body["stepId"] as? String }
    }

    final class Task: ActionTransportTask {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    var reads: [[String: Any]] = []
    var runs: [(request: [String: Any], status: Int, response: Any)] = []
    /// Answers a call before the fixtures do; nil falls through.
    var respond: ((Call) -> ActionTransportResult?)?
    var hold = false
    private(set) var calls: [Call] = []
    private(set) var held: [(Task, (ActionTransportResult) -> Void)] = []
    private(set) var finished = 0
    private(set) var postsAfterFinish = 0
    var operations: [String] { calls.map(\.operation) }
    var runCalls: [Call] { calls.filter { $0.operation == "RUN_STEP" } }
    var unmatched: [[String: Any]] = []

    func add(_ fixtureRuns: [RequirementsFixtures.Run]) {
        runs += fixtureRuns.map { ($0.request, $0.status, $0.response) }
    }

    @discardableResult
    func post(_ request: URLRequest, responseLimit: Int,
              completion: @escaping (ActionTransportResult) -> Void) -> ActionTransportTask {
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let call = Call(operation: body["operation"] as? String ?? "", body: body,
                        key: request.value(forHTTPHeaderField: "X-Idempotency-Key"), request: request)
        calls.append(call)
        if finished > 0 { postsAfterFinish += 1 }
        let result = respond?(call) ?? answer(call)
        let task = Task()
        if hold { held.append((task, completion)); return task }
        DispatchQueue.main.async { completion(task.cancelled ? .transportFailed : result) }
        return task
    }

    func release(_ result: ActionTransportResult) {
        let pending = held
        held = []
        for (task, completion) in pending { completion(task.cancelled ? .transportFailed : result) }
    }

    func finish() { finished += 1 }

    private func answer(_ call: Call) -> ActionTransportResult {
        if call.operation == "READ" {
            guard let read = reads.first else { return .response(status: 599, body: nil) }
            if reads.count > 1 { reads.removeFirst() }
            return Self.json(200, read)
        }
        guard let index = runs.firstIndex(where: { NSDictionary(dictionary: $0.request).isEqual(to: call.body) }) else {
            unmatched.append(call.body)
            return .response(status: 599, body: nil)
        }
        let run = runs.remove(at: index)
        return Self.json(run.status, run.response)
    }

    static func json(_ status: Int, _ body: Any) -> ActionTransportResult {
        .response(status: status, body: try? JSONSerialization.data(withJSONObject: body))
    }
}

/// Virtual time. Timers fire on the next main-queue turn with the clock moved to their deadline, unless `manual`.
final class FixtureClock: RequirementsClock {
    final class Timer: RequirementsTimer {
        let at: Date
        let work: () -> Void
        var cancelled = false
        init(at: Date, work: @escaping () -> Void) { self.at = at; self.work = work }
        func cancel() { cancelled = true }
    }

    var current: Date
    var manual = false
    private(set) var timers: [Timer] = []
    private(set) var delays: [Int] = []
    var live: [Timer] { timers.filter { !$0.cancelled } }

    init(_ start: Date) { current = start }

    func now() -> Date { current }

    func schedule(after milliseconds: Int, _ work: @escaping () -> Void) -> RequirementsTimer {
        let timer = Timer(at: current.addingTimeInterval(Double(milliseconds) / 1000), work: work)
        delays.append(milliseconds)
        timers.append(timer)
        if !manual { DispatchQueue.main.async { [weak self] in self?.fire(timer) } }
        return timer
    }

    /// Fire the earliest live timer; false when there is none.
    @discardableResult
    func fireNext() -> Bool {
        guard let timer = timers.filter({ !$0.cancelled }).min(by: { $0.at < $1.at }) else { return false }
        fire(timer)
        return true
    }

    private func fire(_ timer: Timer) {
        timers.removeAll { $0 === timer }
        guard !timer.cancelled else { return }
        current = max(current, timer.at)
        timer.work()
    }
}

/// Pages the test opens and closes by hand.
final class FixturePages: RequirementsPages {
    final class Page: MeldProviderSession {
        let url: URL
        let prompted: Bool
        let onOpen: () -> Bool
        let onClose: (Bool) -> Void
        var unmounted = false
        init(url: URL, prompted: Bool, onOpen: @escaping () -> Bool, onClose: @escaping (Bool) -> Void) {
            self.url = url; self.prompted = prompted; self.onOpen = onOpen; self.onClose = onClose
        }
        func unmount() { unmounted = true }
    }

    enum Behaviour { case stayOpen, closeAfterOpening, cancelPrompt }

    var available = true
    var behaviour = Behaviour.stayOpen
    var beforeOpen: (() -> Void)?
    private(set) var pages: [Page] = []
    var opened: [URL] = []

    func present(_ url: URL, prompted: Bool, onOpen: @escaping () -> Bool,
                 onClose: @escaping (Bool) -> Void) throws -> MeldProviderSession {
        let page = Page(url: url, prompted: prompted, onOpen: onOpen, onClose: onClose)
        pages.append(page)
        let behaviour = behaviour
        DispatchQueue.main.async { [weak self] in
            guard !page.unmounted else { return }
            if behaviour == .cancelPrompt, prompted { return onClose(false) }
            self?.beforeOpen?()
            guard onOpen() else { return }
            self?.opened.append(url)
            if behaviour == .closeAfterOpening { DispatchQueue.main.async { if !page.unmounted { onClose(true) } } }
        }
        return page
    }
}

/// One loop over fixtures, with every collaborator recorded.
final class LoopHarness {
    let transport = FixtureTransport()
    let clock: FixtureClock
    let pages = FixturePages()
    var handlers = MeldReadyHandlers()
    var options = MeldReadyOptions()
    var environment = MeldEnvironment.sandbox
    var session: MeldRequirementsSession
    private(set) var results: [MeldReadyResult] = []
    private(set) var progress: [MeldReadyProgress.State] = []
    private(set) var keys: [UUID] = []
    private(set) var loop: RequirementsLoop?
    private(set) var mainThreadOnly = true

    init(_ fixture: String, start: Date? = nil) throws {
        session = try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: RequirementsFixtures.mint(fixture)))
        clock = FixtureClock(try start ?? RequirementsFixtures.firstAt(fixture))
    }

    @discardableResult
    func start() -> RequirementsLoop {
        var handlers = self.handlers
        let progressHandler = handlers.onProgress
        handlers.onProgress = { [weak self] event in
            self?.mainThreadOnly = (self?.mainThreadOnly ?? true) && Thread.isMainThread
            self?.progress.append(event.state)
            progressHandler?(event)
        }
        let loop = RequirementsLoop(session: session, environment: environment, handlers: handlers, options: options,
            pages: pages, clock: clock, transport: { [transport] in transport },
            newKey: { [weak self] in let key = UUID(); self?.keys.append(key); return key },
            onResult: { [weak self] result in
                self?.mainThreadOnly = (self?.mainThreadOnly ?? true) && Thread.isMainThread
                self?.results.append(result)
            })
        self.loop = loop
        loop.start()
        return loop
    }

    func waitForResult(_ test: XCTestCase, timeout: TimeInterval = 5, file: StaticString = #filePath,
                       line: UInt = #line) throws -> MeldReadyResult {
        let deadline = Date().addingTimeInterval(timeout)
        while results.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        let result = try XCTUnwrap(results.first, "no result", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(results.count, 1, "one result", file: file, line: line)
        return result
    }

    func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
}

/// One session fixture through the real loop, as the web SDK replays them: READs in the fixture's order (between two
/// of them, the last READ without the steps a RUN_STEP finished), RUN_STEPs matched by body, `collect` answered with
/// the values the fixture sends next for that step, terms accepted and pages closed at once. A RUN_STEP the fixture
/// does not script cancels the run.
final class FixtureReplay {
    struct Exchange {
        let operation: String
        let request: [String: Any]
        let status: Int
        let response: [String: Any]
        var used = false
    }

    let name: String
    let harness: LoopHarness
    let mint: [String: Any]
    private(set) var exchanges: [Exchange]
    private(set) var unscripted: [[String: Any]] = []
    /// The READ the loop was last answered.
    private(set) var current: [String: Any] = [:]
    private var finished: Set<String> = []

    init(_ name: String) throws {
        self.name = name
        harness = try LoopHarness(name)
        mint = try RequirementsFixtures.mint(name)
        exchanges = try XCTUnwrap(try RequirementsFixtures.session(name)["exchanges"] as? [[String: Any]]).map {
            Exchange(operation: try XCTUnwrap($0["operation"] as? String), request: try XCTUnwrap($0["request"] as? [String: Any]),
                     status: try XCTUnwrap($0["status"] as? Int), response: try XCTUnwrap($0["response"] as? [String: Any]))
        }
        harness.options.waitTimeoutMs = 30_000
        harness.handlers.confirmAgreement = { $1(true) }
        harness.handlers.presentUrl = { _, closed in DispatchQueue.main.async(execute: closed) }
        harness.handlers.collect = { [weak self] request, done in done(self?.fields(for: request.stepId)) }
        harness.transport.respond = { [weak self] call in self?.answer(call) }
    }

    /// RUN_STEPs for a step no READ of the fixture offers (a refused run the loop never sends).
    var neverOffered: Int {
        let offered = Set(exchanges.filter { $0.operation == "READ" }
            .flatMap { ($0.response["next"] as? [[String: Any]] ?? []).compactMap { $0["stepId"] as? String } })
        return exchanges.filter { $0.operation == "RUN_STEP" && !offered.contains($0.request["stepId"] as? String ?? "") }.count
    }

    private func fields(for stepId: String) -> [String: String]? {
        exchanges.first { !$0.used && $0.operation == "RUN_STEP" && $0.request["stepId"] as? String == stepId
            && $0.request["fields"] != nil }?.request["fields"] as? [String: String]
    }

    private func answer(_ call: FixtureTransport.Call) -> ActionTransportResult {
        if call.operation == "READ" {
            if let index = exchanges.firstIndex(where: { !$0.used }), exchanges[index].operation == "READ" {
                exchanges[index].used = true
                current = exchanges[index].response
                finished = []
                return FixtureTransport.json(exchanges[index].status, current)
            }
            var read = current
            read["next"] = (current["next"] as? [[String: Any]] ?? []).filter { !finished.contains($0["stepId"] as? String ?? "") }
            return FixtureTransport.json(200, read)
        }
        guard let index = exchanges.firstIndex(where: {
            !$0.used && $0.operation == "RUN_STEP" && NSDictionary(dictionary: $0.request).isEqual(to: call.body)
        }) else {
            unscripted.append(call.body)
            DispatchQueue.main.async { [weak harness] in harness?.loop?.cancel() }
            return .response(status: 599, body: nil)
        }
        exchanges[index].used = true
        let exchange = exchanges[index]
        if exchange.status == 200, exchange.response["outcome"] as? String == "DONE", let stepId = exchange.request["stepId"] as? String {
            finished.insert(stepId)
        }
        return FixtureTransport.json(exchange.status, exchange.response)
    }
}

func XCTAssertJSONEqual(_ actual: [String: Any]?, _ expected: [String: Any]?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(NSDictionary(dictionary: actual ?? [:]).isEqual(to: expected ?? [:]),
                  "\(actual ?? [:]) != \(expected ?? [:])", file: file, line: line)
}
