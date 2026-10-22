import SwiftUI
import UIKit

enum Keyboard {
    /// Drops the keyboard wherever the focus is.
    static func hide() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

/// A way to put the keyboard away from every screen with text fields: a Done button above the keyboard, dragging the page down, and
/// dropping it automatically when the screen goes away (a new tab, page or screen).
struct KeyboardDone: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { Keyboard.hide() }.accessibilityIdentifier("keyboard-done")
                }
            }
            .onDisappear { Keyboard.hide() }
    }
}

extension View { func keyboardDone() -> some View { modifier(KeyboardDone()) } }
