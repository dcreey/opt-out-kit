import Foundation

/// The shape a US phone number is shown in while it is typed: (773) 633-1564. Only for display in the profile; forms get plain digits (see FORM-FILLING.md).
public enum PhoneFormat {
    /// Formats what has been typed so far. A number that starts with + (international), or has more digits than a US number, is left as typed.
    public static func display(_ typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") && !t.hasPrefix("+1") { return typed }
        var d = typed.filter(\.isNumber)
        if t.hasPrefix("+1") || (d.count == 11 && d.hasPrefix("1")) || (d.hasPrefix("1") && t.hasPrefix("1") && d.count > 10) { d.removeFirst() }
        if d.count > 10 { return typed }
        switch d.count {
        case 0: return ""
        case 1...3: return d
        case 4...6: return "(\(d.prefix(3))) \(d.dropFirst(3))"
        default: return "(\(d.prefix(3))) \(d.dropFirst(3).prefix(3))-\(d.dropFirst(6))"
        }
    }
}
