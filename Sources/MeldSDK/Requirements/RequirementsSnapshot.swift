import CryptoKit
import Foundation

/// A READ response. Statuses, kinds and types are open sets; only the shape is checked.
struct RequirementsSnapshot {
    static let pollRangeMs = 1000...60_000
    static let defaultPollMs = 4000

    let status: String
    let pollAfterMs: Int
    let providers: [MeldReadyProvider]
    let continuation: [MeldReadyContinuation]
    let next: [MeldReadyStep]
    let waitingOn: [[String: Any]]
    let raw: [String: Any]
    /// The response without any `expiresAt` or `url` and without `pollAfterMs`, so a re-read that only rotated
    /// a page link compares equal.
    let fingerprint: Data

    init(_ json: [String: Any]) throws {
        guard PaymentActionJSON.integer(json["version"]) == 1, let status = json["status"] as? String,
              let rawProviders = json["providers"] as? [[String: Any]],
              let rawNext = json["next"] as? [[String: Any]], let waitingOn = json["waitingOn"] as? [[String: Any]]
        else { throw PaymentActionError.invalidResponse }
        var providers: [MeldReadyProvider] = []
        var continuation: [MeldReadyContinuation] = []
        for provider in rawProviders {
            guard let name = provider["serviceProvider"] as? String, let providerStatus = provider["status"] as? String,
                  provider["eligible"] == nil || provider["eligible"] is NSNull || PaymentActionJSON.boolean(provider["eligible"]) != nil,
                  let requirements = (provider["requirements"] ?? [[String: Any]]()) as? [[String: Any]]
            else { throw PaymentActionError.invalidResponse }
            var open: [MeldReadyRequirement] = []
            for requirement in requirements {
                guard let type = requirement["type"] as? String, let code = requirement["code"] as? String,
                      let state = requirement["status"] as? String else { throw PaymentActionError.invalidResponse }
                guard state != "SATISFIED" else { continue }
                switch requirement["timing"] as? String {
                case "PRE_ORDER":
                    let codes = (requirement["errorCodes"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
                    open.append(MeldReadyRequirement(type: type, code: code, status: state, reason: requirement["reason"] as? String,
                                                     errorCodes: codes))
                case "ORDER_CONTINUATION":
                    let next = (requirement["action"] as? [String: Any])?["nextStep"] as? String
                    continuation.append(MeldReadyContinuation(serviceProvider: name, code: code, nextStep: next))
                default: break
                }
            }
            providers.append(MeldReadyProvider(serviceProvider: name, status: providerStatus,
                                               eligible: PaymentActionJSON.boolean(provider["eligible"]), open: open))
        }
        self.status = status
        self.pollAfterMs = Self.poll(json["pollAfterMs"])
        self.providers = providers
        self.continuation = continuation
        self.next = try rawNext.map(Self.step)
        self.waitingOn = waitingOn
        self.raw = json
        var stable = Self.withoutVolatile(json) as? [String: Any] ?? [:]
        stable["pollAfterMs"] = nil
        let canonical = try JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys])
        self.fingerprint = Data(SHA256.hash(data: canonical))
    }

    private static func step(_ json: [String: Any]) throws -> MeldReadyStep {
        guard let stepId = json["stepId"] as? String, (1...256).contains(stepId.utf8.count),
              let kind = json["kind"] as? String, let type = json["type"] as? String, let code = json["code"] as? String,
              let providers = json["serviceProviders"] as? [String]
        else { throw PaymentActionError.invalidResponse }
        let fields = try (json["fields"] as? [Any]).map { try $0.map(field) }
        guard json["fields"] == nil || fields != nil else { throw PaymentActionError.invalidResponse }
        return MeldReadyStep(stepId: stepId, kind: kind, type: type, code: code, serviceProviders: providers,
                             level: json["level"] as? String, url: json["url"] as? String,
                             expiresAt: RequirementsJSON.date(json["expiresAt"]), fields: fields,
                             reason: json["reason"] as? String)
    }

    static func field(_ value: Any) throws -> MeldReadyField {
        guard let json = value as? [String: Any], let key = json["key"] as? String, !key.isEmpty
        else { throw PaymentActionError.invalidResponse }
        return MeldReadyField(key: key, label: json["label"] as? String, fieldType: json["fieldType"] as? String,
                              jsonSchema: json["jsonSchema"] as? String, allowedValues: json["allowedValues"] as? [String])
    }

    /// Within [1000, 60000]; 4000 when absent or not a number.
    static func poll(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
        else { return defaultPollMs }
        return Int(min(max(number.doubleValue, Double(pollRangeMs.lowerBound)), Double(pollRangeMs.upperBound)))
    }

    private static func withoutVolatile(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { $0.key != "expiresAt" && $0.key != "url" }.mapValues(withoutVolatile)
        }
        if let array = value as? [Any] { return array.map(withoutVolatile) }
        return value
    }
}

/// A RUN_STEP answer for the step that was sent.
enum RequirementsRunOutcome {
    case done
    case openURL(URL, expiresAt: Date?)
    case collect([MeldReadyField], continuation: String?)

    init(_ json: [String: Any], stepId: String) throws {
        guard json["stepId"] as? String == stepId else { throw PaymentActionError.invalidResponse }
        switch json["outcome"] as? String {
        case "DONE": self = .done
        case "OPEN_URL":
            guard let url = RequirementsJSON.page(json["url"]) else { throw PaymentActionError.invalidResponse }
            self = .openURL(url, expiresAt: RequirementsJSON.date(json["expiresAt"]))
        case "COLLECT":
            guard let raw = json["fields"] as? [Any], !raw.isEmpty else { throw PaymentActionError.invalidResponse }
            let continuation = json["continuation"] as? String
            guard json["continuation"] == nil || continuation.map({ (1...64).contains($0.utf8.count) }) == true
            else { throw PaymentActionError.invalidResponse }
            self = .collect(try raw.map(RequirementsSnapshot.field), continuation: continuation)
        default: throw PaymentActionError.invalidResponse
        }
    }
}
