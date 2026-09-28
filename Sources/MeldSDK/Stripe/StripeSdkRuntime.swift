import Foundation
import UIKit

/// One coordinator may use Stripe's shared state at a time. Release only after logout succeeds.
/// A failed cleanup quarantines this process; it must not expose one customer's state to another.
@MainActor
final class StripeSdkOwnership {
    static let shared = StripeSdkOwnership()
    private var owner: UUID?

    func acquire() throws -> UUID {
        guard owner == nil else { throw StripeNativeError.busy }
        let id = UUID(); owner = id; return id
    }

    func release(_ id: UUID) { if owner == id { owner = nil } }
}

/// Serializes native operations and invalidates callbacks on teardown. A non-cancellable provider
/// operation may finish after unmount; it retains ownership until it returns and logout completes.
/// Stripe never resumes some sheets that unmount dismisses, so the wait ends after `abandonAfter`.
@MainActor
final class StripeSdkRuntime {
    private let driver: StripeSdkDriving
    private let ownership: StripeSdkOwnership
    private let owner: UUID
    private let abandonAfter: TimeInterval
    private var active = true
    private var running = false
    private var callbackRunning = false
    private var closing = false
    private var abandon: Task<Void, Never>?

    static func open(factory: @MainActor () async throws -> StripeSdkDriving) async throws -> StripeSdkRuntime {
        try await open(ownership: .shared, factory: factory)
    }

    static func open(ownership: StripeSdkOwnership, abandonAfter: TimeInterval = 90,
                     factory: @MainActor () async throws -> StripeSdkDriving) async throws -> StripeSdkRuntime {
        let owner = try ownership.acquire()
        let driver: StripeSdkDriving
        do { driver = try await factory() }
        catch {
            // No coordinator was returned. A later explicit attempt can retry initialization.
            ownership.release(owner)
            throw Task.isCancelled ? StripeNativeError.cancelled : StripeNativeError.unavailable
        }
        let runtime = StripeSdkRuntime(driver: driver, ownership: ownership, owner: owner, abandonAfter: abandonAfter)
        if Task.isCancelled { await runtime.close(); throw StripeNativeError.cancelled }
        return runtime
    }

    private init(driver: StripeSdkDriving, ownership: StripeSdkOwnership, owner: UUID, abandonAfter: TimeInterval) {
        self.driver = driver; self.ownership = ownership; self.owner = owner; self.abandonAfter = abandonAfter
    }

    func perform<T>(_ operation: @MainActor (StripeSdkDriving) async throws -> T) async throws -> T {
        guard active, !Task.isCancelled else { throw StripeNativeError.cancelled }
        guard !running else { throw StripeNativeError.busy }
        running = true
        do {
            let value = try await operation(driver)
            running = false
            guard active, !Task.isCancelled else {
                await close(); throw StripeNativeError.cancelled
            }
            return value
        } catch {
            running = false
            if !active || Task.isCancelled { await close(); throw StripeNativeError.cancelled }
            throw error as? StripeNativeError ?? StripeNativeError.unavailable
        }
    }

    func checkout(session: String, from presenter: UIViewController,
                  secret: @escaping @MainActor (String) async throws -> String) async throws {
        guard StripeNativeValue.identifier(session, prefix: "cos_") != nil else { throw StripeNativeError.invalidResponse }
        try await perform { driver in
            try await driver.checkout(session: session, from: presenter) { [weak self] requested in
                guard let self, self.active, !Task.isCancelled else { throw StripeNativeError.cancelled }
                guard requested == session, !self.callbackRunning else { throw StripeNativeError.invalidResponse }
                self.callbackRunning = true
                defer { self.callbackRunning = false }
                let result = try await secret(requested)
                guard self.active, !Task.isCancelled else { throw StripeNativeError.cancelled }
                guard StripeNativeValue.text(result, limit: 4096) != nil else { throw StripeNativeError.invalidResponse }
                return result
            }
        }
    }

    func close() async {
        active = false
        guard !closing else { return }
        guard !running else { abandonPendingOperation(); return }
        abandon?.cancel()
        await logOut()
    }

    private func abandonPendingOperation() {
        guard abandon == nil else { return }
        let delay = UInt64(max(abandonAfter, 0) * 1_000_000_000)
        abandon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, !self.closing else { return }
            await self.logOut()
        }
    }

    private func logOut() async {
        closing = true
        do { try await driver.logOut(); ownership.release(owner) }
        catch { /* Keep ownership when provider state could not be cleared. */ }
    }

    deinit {
        guard !closing else { return }
        let driver = driver, ownership = ownership, owner = owner
        Task { @MainActor in
            do { try await driver.logOut(); ownership.release(owner) }
            catch { /* Keep ownership when provider state could not be cleared. */ }
        }
    }
}
