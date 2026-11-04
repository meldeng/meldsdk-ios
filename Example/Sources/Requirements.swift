import MeldSDK
import UIKit

/// `Meld.ensureReady` with the simplest possible handlers: an alert for terms and one for the fields a step
/// needs. A real app shows its own screens; the SDK only asks for values and never renders a form.
enum DemoRequirements {
    @MainActor
    static func ensureReady(_ session: MeldRequirementsSession) async -> MeldReadyResult {
        await withCheckedContinuation { continuation in
            Meld.ensureReady(session: session, handlers: MeldReadyHandlers(
                onProgress: { print("[demo] requirements \($0.state.rawValue)") },
                collect: { request, done in ask(request, done) },
                confirmAgreement: { agreement, done in confirm(agreement, done) }
            )) { continuation.resume(returning: $0) }
        }
    }

    static func describe(_ result: MeldReadyResult) -> String {
        let pending = (result.pending ?? []).map { "\($0.type) \($0.code)" }.joined(separator: ", ")
        let error = result.error.map { " (\($0.kind.rawValue) \($0.status.map(String.init) ?? "") \($0.code ?? ""))" } ?? ""
        return "Requirements: \(result.status.rawValue)" + (pending.isEmpty ? "" : " — \(pending)") + error
    }

    private static func confirm(_ agreement: MeldAgreementRequest, _ done: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "Terms",
            message: "Accept \(agreement.serviceProvider)'s terms?\n\(agreement.url?.absoluteString ?? agreement.code)",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Decline", style: .cancel) { _ in done(false) })
        alert.addAction(UIAlertAction(title: "Accept", style: .default) { _ in done(true) })
        present(alert) { done(false) }
    }

    private static func ask(_ request: MeldCollectRequest, _ done: @escaping ([String: String]?) -> Void) {
        let refused = (request.fieldErrors ?? []).map { "\($0.key): \($0.reason)" }.joined(separator: ", ")
        let alert = UIAlertController(title: request.code, message: refused.isEmpty ? nil : refused, preferredStyle: .alert)
        for field in request.fields {
            alert.addTextField { $0.placeholder = field.label ?? field.key; $0.autocapitalizationType = .none }
        }
        alert.addAction(UIAlertAction(title: "Skip", style: .cancel) { _ in done(nil) })
        alert.addAction(UIAlertAction(title: "Submit", style: .default) { [weak alert] _ in
            var values: [String: String] = [:]
            for (field, text) in zip(request.fields, alert?.textFields ?? []) { values[field.key] = text.text ?? "" }
            done(values)
        })
        present(alert) { done(nil) }
    }

    private static func present(_ alert: UIAlertController, otherwise: () -> Void) {
        var top = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top else { return otherwise() }
        top.present(alert, animated: true)
    }
}
