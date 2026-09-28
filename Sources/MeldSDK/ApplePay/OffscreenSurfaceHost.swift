import UIKit

/// An invisible, window-attached container for a provider page that presents its own payment
/// sheet. WebKit only runs a page that is laid out in a window, but the customer should only ever
/// see the sheet, so the page is hosted full-size over the top view controller at zero alpha.
///
/// The integrator's host view is not the anchor: for a surface the SDK presents itself it may be
/// 0x0 or absent. When one is given it only locates the window, and the surface ends when the host
/// leaves that window. Main thread only.
final class OffscreenSurfaceHost {
    let container = UIView()
    /// Called once, when the integrator's host leaves the window it was in.
    var onHostLeftWindow: (() -> Void)?

    private let observer: WindowObserverView?

    init?(host: UIView?) {
        guard let presenter = Self.presenter(for: host) else { return nil }
        observer = host == nil ? nil : WindowObserverView(frame: .zero)
        container.frame = presenter.view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.alpha = 0
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
        presenter.view.addSubview(container)

        if let host, let observer {
            observer.onLeftWindow = { [weak self] in self?.onHostLeftWindow?() }
            host.addSubview(observer)
        }
    }

    /// The view controller on screen, as Stripe's surface finds it: the top of the presentation
    /// chain in the host's window, else in the single foreground key window, stepping back from one
    /// that is being dismissed.
    static func presenter(for host: UIView?) -> UIViewController? {
        var top = (host?.window ?? keyWindow())?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if let dismissing = top, dismissing.isBeingDismissed { top = dismissing.presentingViewController }
        guard let top, top.viewIfLoaded?.window != nil else { return nil }
        return top
    }

    func remove() {
        onHostLeftWindow = nil
        observer?.removeFromSuperview()
        container.removeFromSuperview()
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).filter(\.isKeyWindow)
        return windows.count == 1 ? windows.first : nil
    }
}

/// Zero-size marker in the integrator's host that reports the host leaving its window.
final class WindowObserverView: UIView {
    var onLeftWindow: (() -> Void)?
    private var hadWindow = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            hadWindow = true
        } else if hadWindow {
            hadWindow = false
            onLeftWindow?()
        }
    }
}
