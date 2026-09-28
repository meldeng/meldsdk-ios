import Foundation
import os

/// A submitted surface that can outlive its handle.
protocol DetachedSurface: AnyObject {
    func tearDown()
}

/// Keeps a submitted provider page running after the integrator releases its handle, so an app
/// that unmounts on `onPaymentSubmitted` does not unload the page while the provider is still
/// confirming the payment. Each surface is held until it reports an outcome or the grace period
/// ends, then torn down. Main thread only.
final class DetachedSurfaces {
    static let shared = DetachedSurfaces()
    static let gracePeriod: TimeInterval = 60

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "DetachedSurfaces")

    private var held: [ObjectIdentifier: (surface: DetachedSurface, expiry: DispatchWorkItem)] = [:]

    var count: Int { held.count }

    func keep(_ surface: DetachedSurface, for interval: TimeInterval = DetachedSurfaces.gracePeriod) {
        let key = ObjectIdentifier(surface)
        guard held[key] == nil else { return }
        let expiry = DispatchWorkItem { [weak self, weak surface] in
            guard let surface else { return }
            self?.release(surface, outcome: "grace_period_elapsed")
        }
        held[key] = (surface, expiry)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: expiry)
    }

    func release(_ surface: DetachedSurface, outcome: String) {
        guard let entry = held.removeValue(forKey: ObjectIdentifier(surface)) else { return }
        entry.expiry.cancel()
        entry.surface.tearDown()
        Self.logger.info("released a detached surface: \(outcome, privacy: .public)")
    }
}
