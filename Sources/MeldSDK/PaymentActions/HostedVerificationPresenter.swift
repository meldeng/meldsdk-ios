import SafariServices
import UIKit

/// Visible, user-confirmed continuation. The URL is passed unchanged and never becomes diagnostics.
final class HostedVerificationPresenter: NSObject, MeldProviderSession, SFSafariViewControllerDelegate,
                                         UIAdaptivePresentationControllerDelegate {
    struct Prompt {
        let title: String
        let message: String

        static func payment(_ disposition: WalletVerification.Disposition) -> Prompt {
            Prompt(title: "Continue payment", message: disposition == .resume
                ? "Complete verification to continue your existing payment."
                : "The previous attempt was not funded. Continue in the hosted checkout to verify your identity and complete payment.")
        }

        static let verification = Prompt(title: "Continue verification",
            message: "Continue in a secure page to complete the steps your provider needs.")
    }

    private weak var presenter: UIViewController?
    private var presented: UIViewController?
    private var active = true
    private var opened = false
    private let url: URL
    private let closesOnLoadFailure: Bool
    private let onOpen: () -> Bool
    private let onClose: (Bool) -> Void

    convenience init(verification: WalletVerification, host: UIView?, onOpen: @escaping () -> Bool,
                     onClose: @escaping (Bool) -> Void) throws {
        try self.init(url: verification.url, prompt: .payment(verification.disposition), anchor: nil, host: host,
                      onOpen: onOpen, onClose: onClose)
    }

    /// Without a prompt the page opens on the next main-queue turn.
    init(url: URL, prompt: Prompt?, anchor: UIViewController?, host: UIView?, closesOnLoadFailure: Bool = false,
         onOpen: @escaping () -> Bool, onClose: @escaping (Bool) -> Void) throws {
        self.url = url
        self.closesOnLoadFailure = closesOnLoadFailure
        self.onOpen = onOpen
        self.onClose = onClose
        super.init()
        guard let top = Self.top(anchor: anchor, host: host) else { throw PaymentActionError.invalidResponse }
        presenter = top
        guard let prompt else {
            DispatchQueue.main.async { [weak self] in self?.open() }
            return
        }
        let alert = UIAlertController(title: prompt.title, message: prompt.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.closed() })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in self?.proceed() })
        presented = alert
        top.present(alert, animated: true)
    }

    /// The visible controller a presenter would anchor on, or nil when nothing is on screen.
    static func top(anchor: UIViewController?, host: UIView?) -> UIViewController? {
        let root = anchor ?? host?.window?.rootViewController ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
        var top = root
        while let next = top?.presentedViewController { top = next }
        guard let top, top.viewIfLoaded?.window != nil else { return nil }
        return top
    }

    /// The prompt's Continue: opens the page once the prompt is gone.
    func proceed() {
        guard active, let alert = presented as? UIAlertController else { return }
        afterDismissing(alert) { [weak self] in self?.open() }
    }

    private func open() {
        guard active else { return }
        guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            closed()
            return
        }
        guard onOpen() else { unmount(); return }
        opened = true
        let browser = SFSafariViewController(url: url)
        browser.delegate = self
        presented = browser
        presenter.present(browser, animated: true)
        browser.presentationController?.delegate = self
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) { closed() }
    func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
        if !didLoadSuccessfully, closesOnLoadFailure { closed() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { closed() }

    private func afterDismissing(_ controller: UIViewController, completion: @escaping () -> Void) {
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in completion() }
        } else if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: completion)
        } else { DispatchQueue.main.async(execute: completion) }
    }

    private func closed() {
        guard active else { return }
        active = false
        let callback = onClose
        let didOpen = opened
        if let presented {
            self.presented = nil
            afterDismissing(presented) { callback(didOpen) }
        } else { callback(didOpen) }
    }

    func unmount() {
        active = false
        presented?.dismiss(animated: false)
        presented = nil
    }
}
