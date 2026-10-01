import Foundation

/// Customer data Meld already holds. The flow submits it instead of asking; it never carries an ID number.
///
/// Optional data: a field this SDK cannot use is dropped and asked for instead, and only an unusable
/// email (the one Meld authorizes with Link) drops the whole prefill. Neither invalidates the response.
struct StripePrefill: CustomStringConvertible {
    let email: String
    let phone: String?
    let fullName: String?
    let identity: StripeIdentityInput?
    var description: String { "StripePrefill[REDACTED]" }

    init?(_ raw: Any) {
        guard let value = raw as? [String: Any], let email = value["email"] as? String, StripeFormField.email.valid(email)
        else { return nil }
        self.email = email
        phone = Self.text(value["phone"], .phone)
        fullName = Self.text(value["fullName"], .name)
        identity = value["identity"].flatMap(Self.identity)
    }

    private static func identity(_ raw: Any) -> StripeIdentityInput? {
        guard let value = raw as? [String: Any] else { return nil }
        var identity = StripeIdentityInput()
        identity.firstName = text(value["firstName"], .firstName)
        identity.lastName = text(value["lastName"], .lastName)
        if let raw = value["dateOfBirth"] as? String, let birthday = StripeFormField.birthDate(raw) {
            identity.birthDay = birthday.day; identity.birthMonth = birthday.month; identity.birthYear = birthday.year
        }
        identity.address = value["address"].flatMap(address)
        let empty = identity.firstName == nil && identity.lastName == nil && identity.birthYear == nil && identity.address == nil
        return empty ? nil : identity
    }

    private static func address(_ raw: Any) -> StripeAddressInput? {
        guard let value = raw as? [String: Any], value["country"] as? String == "US",
              let line1 = text(value["line1"], .line1), let city = text(value["city"], .city),
              let state = text(value["state"], .state), let postalCode = text(value["postalCode"], .postalCode)
        else { return nil }
        let line2 = value["line2"] == nil ? nil : text(value["line2"], .line2)
        if value["line2"] != nil, line2 == nil { return nil }
        return StripeAddressInput(line1: line1, line2: line2, city: city, state: state.uppercased(), postalCode: postalCode, country: "US")
    }

    private static func text(_ raw: Any?, _ field: StripeFormField) -> String? {
        guard let text = raw as? String, !text.isEmpty, field.valid(text) else { return nil }
        return text
    }
}
