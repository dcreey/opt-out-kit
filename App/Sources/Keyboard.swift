import SwiftUI
import UIKit

enum Keyboard {
    /// Drops the keyboard wherever the focus is.
    static func hide() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }

    private static var installed = false

    /// Shows a Done button just above the keyboard whenever it is up, over every screen (sheets and full-screen covers included) and
    /// for every kind of input, including the text fields of a site in the guide's browser. It is drawn on the app's window by UIKit
    /// instead of using SwiftUI's keyboard toolbar or an input accessory view: those depend on each field's configuration, and the
    /// toolbar made the keyboard flicker.
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        // Kept for the app's whole life (the overlay is shared and never goes away), so they are never removed.
        observers = [center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let screen = UIScreen.main.bounds
            if end.minY >= screen.height - 1 || end.height < 100 { DoneOverlay.shared.hide() } else { DoneOverlay.shared.show(above: end.minY) }
        },
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in DoneOverlay.shared.hide() }]
    }
}

@MainActor
private final class DoneOverlay {
    static let shared = DoneOverlay()
    private let button = UIButton(type: .system)

    private init() {
        var config = UIButton.Configuration.filled()
        config.title = Loc.t("Done")
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        button.configuration = config
        button.accessibilityIdentifier = "keyboard-done"
        button.accessibilityLabel = Loc.t("Done")
        button.addAction(UIAction { _ in Keyboard.hide() }, for: .touchUpInside)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.2; button.layer.shadowRadius = 4; button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.alpha = 0
    }

    private var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    func show(above keyboardTop: CGFloat) {
        guard let window else { return }
        button.configuration?.title = Loc.t("Done")
        if button.superview !== window { window.addSubview(button) }
        window.bringSubviewToFront(button)
        let size = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        button.frame = CGRect(x: window.bounds.width - size.width - 16, y: keyboardTop - size.height - 8, width: size.width, height: size.height)
        UIView.animate(withDuration: 0.15) { self.button.alpha = 1 }
    }

    func hide() {
        UIView.animate(withDuration: 0.15, animations: { self.button.alpha = 0 }, completion: { _ in
            if self.button.alpha == 0 { self.button.removeFromSuperview() }
        })
    }
}
