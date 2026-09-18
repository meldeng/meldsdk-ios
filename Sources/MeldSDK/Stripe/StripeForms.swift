import UIKit

/// Form values live only until the corresponding SDK call. No Codable conformance or diagnostics.
enum StripeFormField: String, CaseIterable {
    case email, name, phone, firstName, lastName, birthday, idNumber, line1, line2, city, state, postalCode

    var label: String {
        switch self {
        case .email: return "Email address"
        case .name: return "Full name (optional)"
        case .phone: return "Phone number, including country code"
        case .firstName: return "First name"
        case .lastName: return "Last name"
        case .birthday: return "Date of birth (YYYY-MM-DD)"
        case .idNumber: return "Identification number"
        case .line1: return "Street address"
        case .line2: return "Apartment or suite (optional)"
        case .city: return "City"
        case .state: return "State (two letters)"
        case .postalCode: return "ZIP code"
        }
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
    let presenter: UIViewController
    private let progress: (String) -> Void
    private var active = true
    private var form: StripeFormViewController?
    private var legalForm: LegalDisclosureViewController?
    private var navigation: UINavigationController?

    init(presenter: UIViewController, progress: @escaping (String) -> Void) {
        self.presenter = presenter; self.progress = progress
    }

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
        let values = try await collect(wanted, title: "Verify your identity")
        let birthday = values[.birthday].flatMap(StripeFormField.birthDate)
        return StripeIdentityInput(firstName: values[.firstName], lastName: values[.lastName], idNumber: values[.idNumber],
                                   birthDay: birthday?.day, birthMonth: birthday?.month, birthYear: birthday?.year,
                                   address: needsAddress ? Self.address(values) : nil)
    }

    func address() async throws -> StripeAddressInput {
        Self.address(try await collect(Self.addressFields, title: "Update your address"))
    }

    func showProgress(_ message: String) { if active { progress(message) } }

    func recoverLegalDecision(_ value: LegalDecision) async throws -> Bool {
        let decision = value.accepted ? "acceptance" : "decline"
        let disclosure = try LegalDisclosure(["requirementCode": value.code,
            "title": "Confirm your saved decision", "documentVersion": value.documentVersion,
            "locale": value.locale, "documentDigest": value.digest,
            "text": "The result of your previous \(decision) could not be confirmed. Retry sends that same decision again; it does not make a new choice or start a payment. You can also cancel and keep it saved."], code: value.code)
        return try await showDisclosure(disclosure, recovery: true)
    }

    func disclosure(_ value: LegalDisclosure) async throws -> Bool {
        try await showDisclosure(value, recovery: false)
    }

    private func showDisclosure(_ value: LegalDisclosure, recovery: Bool) async throws -> Bool {
        guard active, !Task.isCancelled, form == nil, legalForm == nil,
              presenter.presentedViewController == nil, presenter.viewIfLoaded?.window != nil
        else { throw StripeNativeError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let form = LegalDisclosureViewController(disclosure: value, recovery: recovery) { [weak self] result in
                guard let self else { continuation.resume(throwing: LegalConsentError.cancelled); return }
                let navigation = self.navigation
                self.legalForm = nil; self.navigation = nil
                guard self.active, let navigation else {
                    navigation?.dismiss(animated: false)
                    continuation.resume(throwing: LegalConsentError.cancelled)
                    return
                }
                navigation.dismiss(animated: false) {
                    continuation.resume(with: self.active ? result : .failure(LegalConsentError.cancelled))
                }
            }
            legalForm = form
            let navigation = UINavigationController(rootViewController: form)
            self.navigation = navigation
            navigation.modalPresentationStyle = .pageSheet; navigation.isModalInPresentation = true
            presenter.present(navigation, animated: true)
        }
    }

    func close() {
        guard active else { return }
        active = false
        form?.cancel()
        legalForm?.cancel()
        navigation?.dismiss(animated: false)
        navigation = nil; form = nil; legalForm = nil
    }

    private static let addressFields: [StripeFormField] = [.line1, .line2, .city, .state, .postalCode]

    private static func address(_ values: [StripeFormField: String]) -> StripeAddressInput {
        StripeAddressInput(line1: values[.line1]!, line2: values[.line2].flatMap { $0.isEmpty ? nil : $0 },
                           city: values[.city]!, state: values[.state]!.uppercased(), postalCode: values[.postalCode]!, country: "US")
    }

    private func collect(_ fields: [StripeFormField], title: String) async throws -> [StripeFormField: String] {
        guard active, !Task.isCancelled, form == nil, legalForm == nil, presenter.presentedViewController == nil,
              presenter.viewIfLoaded?.window != nil else { throw StripeNativeError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let form = StripeFormViewController(fields: fields, title: title) { [weak self] result in
                guard let self else { continuation.resume(throwing: StripeNativeError.cancelled); return }
                let navigation = self.navigation
                self.form = nil; self.navigation = nil
                guard self.active, let navigation else {
                    navigation?.dismiss(animated: false)
                    continuation.resume(throwing: StripeNativeError.cancelled)
                    return
                }
                navigation.dismiss(animated: false) {
                    continuation.resume(with: self.active ? result : .failure(StripeNativeError.cancelled))
                }
            }
            self.form = form
            let navigation = UINavigationController(rootViewController: form)
            self.navigation = navigation
            navigation.modalPresentationStyle = .pageSheet
            navigation.isModalInPresentation = true
            presenter.present(navigation, animated: true)
        }
    }
}

@MainActor
private final class StripeFormViewController: UIViewController {
    private let fields: [StripeFormField]
    private var inputs: [StripeFormField: UITextField] = [:]
    private let errorLabel = UILabel()
    private var completion: ((Result<[StripeFormField: String], Error>) -> Void)?

    init(fields: [StripeFormField], title: String, completion: @escaping (Result<[StripeFormField: String], Error>) -> Void) {
        self.fields = fields; self.completion = completion
        super.init(nibName: nil, bundle: nil); self.title = title
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Continue", style: .done, target: self, action: #selector(submit))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        for field in fields {
            let label = UILabel(); label.text = field.label; label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
            let input = UITextField(); input.borderStyle = .roundedRect; input.accessibilityLabel = field.label
            input.font = .preferredFont(forTextStyle: .body); input.adjustsFontForContentSizeCategory = true
            input.autocorrectionType = .no; input.spellCheckingType = .no; input.autocapitalizationType = .none
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            if field == .email { input.keyboardType = .emailAddress; input.textContentType = .emailAddress }
            if field == .phone { input.keyboardType = .phonePad; input.textContentType = .telephoneNumber }
            if field == .birthday { input.keyboardType = .numbersAndPunctuation }
            if field == .idNumber { input.isSecureTextEntry = true }
            inputs[field] = input; stack.addArrangedSubview(label); stack.addArrangedSubview(input)
        }
        errorLabel.textColor = .systemRed; errorLabel.numberOfLines = 0
        stack.addArrangedSubview(errorLabel)
    }

    @objc func cancel() { finish(.failure(StripeNativeError.cancelled)) }

    @objc private func submit() {
        var values: [StripeFormField: String] = [:]
        for field in fields {
            let value = (inputs[field]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard field.valid(value) else {
                errorLabel.text = "Check \(field.label.lowercased())."
                inputs[field]?.becomeFirstResponder()
                UIAccessibility.post(notification: .announcement, argument: errorLabel.text)
                return
            }
            values[field] = value
        }
        finish(.success(values))
    }

    private func finish(_ result: Result<[StripeFormField: String], Error>) {
        guard let completion else { return }
        self.completion = nil
        view.endEditing(true)
        inputs.values.forEach { $0.text = nil }
        completion(result)
    }
}
