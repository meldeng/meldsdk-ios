import UIKit

/// Fails a system payment sheet that never appeared. Armed when the SDK asks for the sheet;
/// disarmed when the app resigns active for it, or by the caller. Main thread only.
final class PresentationDeadline {
    static let defaultInterval: TimeInterval = 8

    private let interval: TimeInterval
    private let notifications: NotificationCenter
    private var expiry: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    init(interval: TimeInterval = PresentationDeadline.defaultInterval, notifications: NotificationCenter = .default) {
        self.interval = interval
        self.notifications = notifications
    }

    var armed: Bool { expiry != nil }

    func arm(onExpired: @escaping () -> Void) {
        disarm()
        observer = notifications.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                             queue: nil) { [weak self] _ in self?.disarm() }
        let expiry = DispatchWorkItem { [weak self] in
            self?.disarm()
            onExpired()
        }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: expiry)
    }

    func disarm() {
        expiry?.cancel()
        expiry = nil
        if let observer { notifications.removeObserver(observer) }
        observer = nil
    }

    deinit { disarm() }
}

/// Bounds how long a presented payment may run without an outcome. Only time the app is active
/// counts: the system sheet holds the app inactive while the customer pays. Main thread only.
final class PresentationCeiling {
    static let defaultInterval: TimeInterval = 180

    private let interval: TimeInterval
    private let notifications: NotificationCenter
    private var onExpired: (() -> Void)?
    private var remaining: TimeInterval = 0
    private var resumedAt: TimeInterval = 0
    private var expiry: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(interval: TimeInterval = PresentationCeiling.defaultInterval, notifications: NotificationCenter = .default) {
        self.interval = interval
        self.notifications = notifications
    }

    var armed: Bool { onExpired != nil }
    var paused: Bool { armed && expiry == nil }

    func arm(onExpired: @escaping () -> Void) {
        disarm()
        self.onExpired = onExpired
        remaining = interval
        observers = [
            notifications.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                      queue: nil) { [weak self] _ in self?.pause() },
            notifications.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                      queue: nil) { [weak self] _ in self?.resume() },
        ]
        resume()
    }

    func disarm() {
        expiry?.cancel()
        expiry = nil
        onExpired = nil
        observers.forEach(notifications.removeObserver)
        observers = []
    }

    private func pause() {
        guard let expiry else { return }
        expiry.cancel()
        self.expiry = nil
        remaining -= ProcessInfo.processInfo.systemUptime - resumedAt
    }

    private func resume() {
        guard armed, expiry == nil else { return }
        resumedAt = ProcessInfo.processInfo.systemUptime
        let expiry = DispatchWorkItem { [weak self] in
            let onExpired = self?.onExpired
            self?.disarm()
            onExpired?()
        }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + max(remaining, 0), execute: expiry)
    }

    deinit { disarm() }
}
