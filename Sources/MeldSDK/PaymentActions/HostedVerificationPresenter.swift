import SafariServices
import UIKit

/// Visible, user-confirmed continuation. The URL is passed unchanged and never becomes diagnostics.
final class HostedVerificationPresenter: NSObject, MeldProviderSession, SFSafariViewControllerDelegate,
                                         UIAdaptivePresentationControllerDelegate {
    private weak var presenter: UIViewController?
    private var presented: UIViewController?
    private var active = true
    private var opened = false
    private let onClose: (Bool) -> Void

    init(verification: WalletVerification, host: UIView?, onOpen: @escaping () -> Bool,
         onClose: @escaping (Bool) -> Void) throws {
        self.onClose = onClose
        super.init()
        let root = host?.window?.rootViewController ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
        var top = root
        while let next = top?.presentedViewController { top = next }
        guard let top, top.viewIfLoaded?.window != nil else { throw PaymentActionError.invalidResponse }
        presenter = top
        let message = verification.disposition == .resume
            ? "Complete verification to continue your existing payment."
            : "The previous attempt was not funded. Continue in the hosted checkout to verify your identity and complete payment."
        let alert = UIAlertController(title: "Continue payment", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.closed() })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self, weak alert] _ in
            guard let self, self.active, let alert else { return }
            self.afterDismissing(alert) { [weak self] in
                guard let self, self.active else { return }
                guard let presenter = self.presenter, presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil else { self.closed(); return }
                guard onOpen() else { self.unmount(); return }
                self.opened = true
                let browser = SFSafariViewController(url: verification.url)
                browser.delegate = self
                self.presented = browser
                presenter.present(browser, animated: true)
                browser.presentationController?.delegate = self
            }
        })
        presented = alert
        top.present(alert, animated: true)
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) { closed() }
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
