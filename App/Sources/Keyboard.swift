import SwiftUI
import UIKit

enum Keyboard {
    /// Drops the keyboard wherever the focus is.
    static func hide() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }

    private static var installed = false

    /// Puts a Done button above the keyboard for every text field in the app. It is added to the underlying UITextField when editing
    /// begins, instead of using SwiftUI's keyboard toolbar: that toolbar re-lays-out the screen as fields gain focus and made the
    /// keyboard flicker in and out.
    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { note in
            guard let field = note.object as? UITextField, field.inputAccessoryView == nil else { return }
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            let done = UIBarButtonItem(title: Loc.t("Done"), style: .done, target: field, action: #selector(UIResponder.resignFirstResponder))
            done.accessibilityIdentifier = "keyboard-done"
            bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
            bar.sizeToFit()
            field.inputAccessoryView = bar
            field.reloadInputViews()
        }
    }
}

/// Dragging a scrolling page down puts the keyboard away. (The Done button is added to every text field by `Keyboard.install`.)
struct KeyboardDone: ViewModifier {
    func body(content: Content) -> some View { content.scrollDismissesKeyboard(.interactively) }
}

extension View { func keyboardDone() -> some View { modifier(KeyboardDone()) } }
