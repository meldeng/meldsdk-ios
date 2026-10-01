import UIKit

/// Form values live only until the corresponding SDK call. No Codable conformance or diagnostics.
enum StripeFormField: String, CaseIterable {
    case email, name, phone, firstName, lastName, birthday, idNumber, line1, line2, city, state, postalCode

    var label: String {
        switch self {
        case .email: return "Email address"
        case .name: return "Full name (optional)"
        case .phone: return "Mobile number"
        case .firstName: return "First name"
        case .lastName: return "Last name"
        case .birthday: return "Date of birth (YYYY-MM-DD)"
        case .idNumber: return "Social Security number"
        case .line1: return "Street address"
        case .line2: return "Apartment or suite (optional)"
        case .city: return "City"
        case .state: return "State (two letters)"
        case .postalCode: return "ZIP code"
        }
    }

    /// What the customer typed, in the form Stripe takes. A ten-digit US number gains its country code.
    func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self == .phone else { return self == .state ? trimmed.uppercased() : trimmed }
        // Deliberate: the Stripe flow is US-only, so ten digits without a country code are read as a US number.
        let digits = trimmed.filter(\.isNumber)
        if trimmed.hasPrefix("+") { return "+" + digits }
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return trimmed
    }

    func valid(_ text: String) -> Bool {
        if (self == .name || self == .line2) && text.isEmpty { return true }
        guard StripeNativeValue.text(text, limit: self == .email ? 254 : 255) != nil else { return false }
        switch self {
        case .email: return StripeNativeValue.matches(text, "[^\\s@]+@[^\\s@]+\\.[^\\s@]+")
        case .phone: return StripeNativeValue.matches(text, "\\+[1-9][0-9]{7,14}")
        case .birthday: return Self.birthDate(text) != nil
        case .state: return StripeNativeValue.matches(text, "[A-Za-z]{2}")
        case .postalCode: return StripeNativeValue.matches(text, "[0-9]{5}(?:-[0-9]{4})?")
        default: return true
        }
    }

    static func birthDate(_ text: String) -> DateComponents? {
        guard StripeNativeValue.matches(text, "[0-9]{4}-[0-9]{2}-[0-9]{2}") else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1900 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components), date < Date(),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return components
    }
}

@MainActor
final class StripeForms: StripeFlowPresenting {
    private let root: () -> UIViewController?
    private var active = true
    private var form: StripeFormViewController?
    private var navigation: UINavigationController?
    /// Cancel on a form that is busy with Meld or Stripe: no form call is waiting, so the session cancels.
    var onCancelWhileBusy: (() -> Void)?

    /// Forms present over the host's top-most screen only while the customer is needed; there is no host sheet.
    init(root: @escaping () -> UIViewController?) { self.root = root }

    func email() async throws -> String { try await collect([.email], title: "Sign in to Link")[.email]! }

    func registration() async throws -> StripeRegistrationInput {
        let values = try await collect([.name, .phone], title: "Create your Link account")
        return StripeRegistrationInput(name: values[.name].flatMap { $0.isEmpty ? nil : $0 }, phone: values[.phone]!)
    }

    func identity(fields: [String]) async throws -> StripeIdentityInput {
        var wanted: [StripeFormField] = []
        let all = fields.isEmpty
        for (name, field) in [("FIRST_NAME", StripeFormField.firstName), ("LAST_NAME", .lastName),
                              ("DATE_OF_BIRTH", .birthday), ("ID_NUMBER", .idNumber)] {
            if all || fields.contains(name) { wanted.append(field) }
        }
        let needsAddress = all || fields.contains { $0.hasPrefix("ADDRESS_") }
        if needsAddress { wanted += Self.addressFields }
        guard !wanted.isEmpty else { throw StripeNativeError.invalidResponse }
        let values = try await collect(wanted, title: wanted == [.idNumber] ? "Confirm your identity" : "Verify your identity")
        let birthday = values[.birthday].flatMap(StripeFormField.birthDate)
        return StripeIdentityInput(firstName: values[.firstName], lastName: values[.lastName], idNumber: values[.idNumber],
                                   birthDay: birthday?.day, birthMonth: birthday?.month, birthYear: birthday?.year,
                                   address: needsAddress ? Self.address(values) : nil)
    }

    func address() async throws -> StripeAddressInput {
        Self.address(try await collect(Self.addressFields, title: "Update your address"))
    }

    func showProgress(_ message: String) { if active { form?.showBusy(message) } }

    func handOff() async throws -> UIViewController {
        guard active else { throw StripeNativeError.cancelled }
        await dismissSheet()
        guard active, let top = top() else { throw StripeNativeError.unavailable }
        return top
    }

    func close() {
        guard active else { return }
        active = false
        form?.abandon()
        navigation?.dismiss(animated: false)
        navigation = nil; form = nil
    }

    private static let addressFields: [StripeFormField] = [.line1, .line2, .city, .state, .postalCode]

    private static func address(_ values: [StripeFormField: String]) -> StripeAddressInput {
        StripeAddressInput(line1: values[.line1]!, line2: values[.line2].flatMap { $0.isEmpty ? nil : $0 },
                           city: values[.city]!, state: values[.state]!, postalCode: values[.postalCode]!, country: "US")
    }

    private func top() -> UIViewController? {
        var top = root()
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top?.viewIfLoaded?.window == nil ? nil : top
    }

    private func dismissSheet() async {
        guard let navigation else { return }
        self.navigation = nil; form = nil
        await withCheckedContinuation { done in navigation.dismiss(animated: true) { done.resume() } }
    }

    /// A submitted form stays up, busy, until the next form replaces it or a provider screen takes over.
    private func collect(_ fields: [StripeFormField], title: String) async throws -> [StripeFormField: String] {
        guard active, !Task.isCancelled else { throw StripeNativeError.unavailable }
        let form = StripeFormViewController(fields: fields, title: title) { [weak self] in self?.onCancelWhileBusy?() }
        self.form = form
        if let navigation {
            navigation.setViewControllers([form], animated: true)
        } else {
            try await present(form)
        }
        do {
            return try await form.values()
        } catch {
            if self.form === form { await dismissSheet() }
            throw active ? error : StripeNativeError.cancelled
        }
    }

    /// Waits out a sheet that is still animating away; UIKit silently refuses to present over one.
    private func present(_ form: StripeFormViewController) async throws {
        let navigation = UINavigationController(rootViewController: form)
        navigation.navigationBar.prefersLargeTitles = true
        navigation.modalPresentationStyle = .pageSheet
        navigation.isModalInPresentation = true
        guard let presenter = await settledTop(), active else {
            self.form = nil
            throw StripeNativeError.unavailable
        }
        presenter.present(navigation, animated: true)
        guard navigation.presentingViewController != nil else {
            self.form = nil
            throw StripeNativeError.unavailable
        }
        self.navigation = navigation
    }

    private func settledTop() async -> UIViewController? {
        for _ in 0..<40 {
            if let top = top(), top.presentedViewController == nil, !top.isBeingPresented, !top.isBeingDismissed { return top }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}

@MainActor
private final class StripeFormViewController: UIViewController, UITextFieldDelegate {
    private let fields: [StripeFormField]
    private var inputs: [StripeFormField: UITextField] = [:]
    private let errorLabel = UILabel()
    private let button = UIButton(configuration: .filled())
    private var continuation: CheckedContinuation<[StripeFormField: String], Error>?
    private var early: Result<[StripeFormField: String], Error>?
    private var answered = false
    private var busy = false
    private let onBusyCancel: () -> Void

    init(fields: [StripeFormField], title: String, onBusyCancel: @escaping () -> Void) {
        self.fields = fields; self.onBusyCancel = onBusyCancel
        super.init(nibName: nil, bundle: nil); self.title = title
    }

    /// The customer's answer, once. Installed right after presentation, before any input can arrive.
    func values() async throws -> [StripeFormField: String] {
        if let early { return try early.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        var configuration = button.configuration ?? .filled()
        configuration.title = "Continue"; configuration.cornerStyle = .large
        configuration.buttonSize = .large; configuration.imagePadding = 8
        button.configuration = configuration
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(submit), for: .touchUpInside)
        view.addSubview(scroll); scroll.addSubview(stack); view.addSubview(button)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
        for (index, field) in fields.enumerated() {
            let label = UILabel(); label.text = field.label; label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel; label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
            let input = UITextField(); input.borderStyle = .none; input.accessibilityLabel = field.label
            input.backgroundColor = .secondarySystemBackground; input.layer.cornerRadius = 12
            input.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1)); input.leftViewMode = .always
            input.font = .preferredFont(forTextStyle: .body); input.adjustsFontForContentSizeCategory = true
            input.autocorrectionType = .no; input.spellCheckingType = .no; input.autocapitalizationType = .none
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
            input.returnKeyType = index == fields.count - 1 ? .done : .next; input.delegate = self
            switch field {
            case .email: input.keyboardType = .emailAddress; input.textContentType = .emailAddress
            case .phone: input.keyboardType = .phonePad; input.textContentType = .telephoneNumber; input.placeholder = "(415) 555-0123"
            case .name: input.textContentType = .name; input.autocapitalizationType = .words
            case .firstName: input.textContentType = .givenName; input.autocapitalizationType = .words
            case .lastName: input.textContentType = .familyName; input.autocapitalizationType = .words
            case .birthday: input.keyboardType = .numbersAndPunctuation; input.placeholder = "1990-03-15"
            case .idNumber: input.isSecureTextEntry = true; input.keyboardType = .numberPad
            case .line1: input.textContentType = .streetAddressLine1; input.autocapitalizationType = .words
            case .line2: input.textContentType = .streetAddressLine2; input.autocapitalizationType = .words
            case .city: input.textContentType = .addressCity; input.autocapitalizationType = .words
            case .state: input.textContentType = .addressState; input.autocapitalizationType = .allCharacters
            case .postalCode: input.textContentType = .postalCode; input.keyboardType = .numberPad
            }
            inputs[field] = input; stack.addArrangedSubview(label); stack.addArrangedSubview(input)
            stack.setCustomSpacing(16, after: input)
        }
        errorLabel.textColor = .systemRed; errorLabel.numberOfLines = 0; errorLabel.font = .preferredFont(forTextStyle: .footnote)
        stack.addArrangedSubview(errorLabel)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !answered { fields.first.flatMap { inputs[$0] }?.becomeFirstResponder() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let index = fields.firstIndex(where: { inputs[$0] === textField }) else { return true }
        if index + 1 < fields.count { inputs[fields[index + 1]]?.becomeFirstResponder() } else { submit() }
        return true
    }

    /// The button keeps the customer's place while Meld and the provider work, instead of an empty screen.
    func showBusy(_ message: String? = nil) {
        var configuration = button.configuration ?? .filled()
        configuration.showsActivityIndicator = true
        configuration.title = message ?? "Continue"
        button.configuration = configuration
        button.isUserInteractionEnabled = false
        busy = true
        inputs.values.forEach { $0.isEnabled = false }
        UIAccessibility.post(notification: .announcement, argument: message ?? "Working")
    }

    @objc func cancel() {
        if !answered { finish(.failure(StripeNativeError.cancelled)) } else if busy { onBusyCancel() }
    }

    /// Teardown: ends a pending answer without asking the session to cancel.
    func abandon() { if !answered { finish(.failure(StripeNativeError.cancelled)) } }

    @objc private func submit() {
        guard !answered else { return }
        var values: [StripeFormField: String] = [:]
        for field in fields {
            let value = field.normalized(inputs[field]?.text ?? "")
            guard field.valid(value) else {
                errorLabel.text = "Check your \(field.label.lowercased())."
                inputs[field]?.becomeFirstResponder()
                UIAccessibility.post(notification: .announcement, argument: errorLabel.text)
                return
            }
            values[field] = value
        }
        errorLabel.text = nil
        view.endEditing(true)
        showBusy()
        finish(.success(values))
    }

    private func finish(_ result: Result<[StripeFormField: String], Error>) {
        guard !answered else { return }
        answered = true
        inputs.values.forEach { $0.text = nil }
        guard let continuation else { early = result; return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
