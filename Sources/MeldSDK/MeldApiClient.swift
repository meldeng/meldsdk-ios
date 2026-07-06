import Foundation

/// Minimal Meld API client used to advance a two-step provider flow (Option 1) — e.g. Uphold cards,
/// where the SDK must call Meld after capturing the card to create the authorize session. The capture
/// order supplies the exact `authorizeSessionUrl` and a short-lived `continuationToken` (bearer), so
/// the SDK needs no integrator credentials or base-URL configuration. Async; the completion is
/// invoked off the main thread (callers hop to main before touching the WebView).
enum MeldApiClient {

    /// POST `{ cardId }` to the order's authorize-session endpoint; returns the authorize order.
    static func createAuthorizeSession(
        authorizeSessionUrl: String,
        continuationToken: String?,
        cardId: String,
        completion: @escaping (Result<MeldOrder, Error>) -> Void
    ) {
        guard let url = URL(string: authorizeSessionUrl) else {
            completion(.failure(MeldMountError.unsupported("Invalid authorizeSessionUrl")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = continuationToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["cardId": cardId])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, (200..<300).contains(code) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(MeldMountError.unsupported("authorize-session request failed (\(code)): \(body)")))
                return
            }
            do {
                completion(.success(try MeldOrder.from(jsonData: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
