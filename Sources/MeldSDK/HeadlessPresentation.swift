import CoreFoundation
import Foundation

/// The versioned presentation contract returned on a headless quote or order.
/// Unknown protocols remain readable; only a registered SDK adapter can present them.
public struct MeldHeadlessPresentation: Equatable {
    public let surface: String
    public let protocolName: String
    public let version: Int

    static func decode(_ raw: Any?) -> MeldHeadlessPresentation? {
        guard let value = raw as? [String: Any],
              let surface = identifier(value["surface"]),
              let protocolName = identifier(value["protocol"]),
              let version = value["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              let integer = Int(exactly: version.doubleValue), integer > 0, integer <= Int32.max
        else { return nil }
        return MeldHeadlessPresentation(surface: surface, protocolName: protocolName, version: integer)
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String,
              text.range(of: "\\A[A-Z][A-Z0-9_]{0,63}\\z", options: .regularExpression) != nil
        else { return nil }
        return text
    }
}

/// Absence permits legacy replay compatibility. A malformed declaration never does.
enum HeadlessPresentationDeclaration {
    case absent
    case malformed
    case declared(MeldHeadlessPresentation)

    static func decode(order: [String: Any]) -> HeadlessPresentationDeclaration {
        guard order.keys.contains("headlessPresentation") else { return .absent }
        guard let presentation = MeldHeadlessPresentation.decode(order["headlessPresentation"]) else {
            return .malformed
        }
        return .declared(presentation)
    }
}

/// Registration is deliberately specific: a surface alone never identifies a vendor protocol.
struct MeldAdapterPresentation: Hashable {
    let method: String
    let surface: String
    let protocolName: String
    let version: Int

    init(_ method: String, _ surface: String, _ protocolName: String, version: Int = 1) {
        self.method = method
        self.surface = surface
        self.protocolName = protocolName
        self.version = version
    }
}

struct MeldAdapterRegistry {
    enum RegistrationError: Error { case duplicatePresentation }

    let adapters: [MeldAdapter]
    private let declared: [MeldAdapterPresentation: MeldAdapter]

    init(_ adapters: [MeldAdapter]) throws {
        var declared: [MeldAdapterPresentation: MeldAdapter] = [:]
        for adapter in adapters {
            for presentation in adapter.presentations {
                guard declared.updateValue(adapter, forKey: presentation) == nil else {
                    throw RegistrationError.duplicatePresentation
                }
            }
        }
        self.adapters = adapters
        self.declared = declared
    }

    func adapter(for order: MeldOrder) -> MeldAdapter? {
        switch order.presentationDeclaration {
        case .malformed:
            return nil
        case .absent:
            if case .unrecognized = order.presentation { return nil }
            return adapters.first { $0.matches(order) }
        case .declared(let presentation):
            guard let method = order.paymentMethodType else { return nil }
            let key = MeldAdapterPresentation(method, presentation.surface, presentation.protocolName,
                                              version: presentation.version)
            guard let adapter = declared[key], adapter.acceptsDeclaredOrder(order) else { return nil }
            return adapter
        }
    }
}

/// Transport checks shared by declared protocols; each adapter supplies its own allowed origins.
enum MeldPresentationURL {
    static func https(_ raw: String?, hosts: Set<String>, subdomains: Bool = false) -> Bool {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443
        else { return false }
        return hosts.contains(host) || (subdomains && hosts.contains { host.hasSuffix("." + $0) })
    }
}

extension MeldOrder {
    func hasCompatibleLegacyPresentation(_ expected: String) -> Bool {
        guard let details = paymentMethodResponseDetails else { return false }
        guard details.raw.keys.contains("presentation") else { return true }
        return details["presentation"] as? String == expected
    }
}
