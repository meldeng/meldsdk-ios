import UIKit

@MainActor
final class LegalDisclosureViewController: UIViewController {
    private let recovery: Bool
    private let disclosure: LegalDisclosure
    private var completion: ((Result<Bool, Error>) -> Void)?

    init(disclosure: LegalDisclosure, recovery: Bool = false, completion: @escaping (Result<Bool, Error>) -> Void) {
        self.recovery = recovery; self.disclosure = disclosure; self.completion = completion
        super.init(nibName: nil, bundle: nil)
        title = disclosure.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        let copy = UITextView()
        copy.text = disclosure.text; copy.isEditable = false; copy.isSelectable = true
        copy.font = .preferredFont(forTextStyle: .body); copy.adjustsFontForContentSizeCategory = true
        copy.backgroundColor = .systemBackground; copy.accessibilityLanguage = disclosure.locale
        let accept = UIButton(type: .system)
        accept.configuration = .filled(); accept.setTitle(recovery ? "Retry saved decision" : "Agree and continue", for: .normal)
        accept.addTarget(self, action: #selector(acceptTapped), for: .touchUpInside)
        let decline = UIButton(type: .system)
        decline.setTitle("Decline", for: .normal)
        decline.addTarget(self, action: #selector(declineTapped), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: recovery ? [accept] : [accept, decline]); buttons.axis = .vertical; buttons.spacing = 8
        copy.translatesAutoresizingMaskIntoConstraints = false; buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(copy); view.addSubview(buttons)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            copy.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            copy.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            copy.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            copy.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16)
        ])
    }
    func cancel() { finish(.failure(LegalConsentError.cancelled)) }
    @objc private func cancelTapped() { cancel() }
    @objc private func acceptTapped() { finish(.success(true)) }
    @objc private func declineTapped() { finish(.success(false)) }
    private func finish(_ value: Result<Bool, Error>) {
        let callback = completion; completion = nil; callback?(value)
    }
}
