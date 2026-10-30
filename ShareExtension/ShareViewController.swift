import UIKit
import UniformTypeIdentifiers

/// "Share → Exnay" from a mail app: takes the link that was shared and hands it to Exnay, which opens it on the Email links tab.
/// No screen of its own unless Exnay cannot be opened from here; then the link is on the clipboard and a short message says so.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { await handOver() }
    }

    private func handOver() async {
        guard let link = await sharedLink(), var parts = URLComponents(string: "exnay://link") else { return finish(message: "There was no link to open.") }
        parts.queryItems = [URLQueryItem(name: "u", value: link.absoluteString)]
        if let url = parts.url, open(url) { return done() }
        UIPasteboard.general.string = link.absoluteString
        finish(message: "The link is copied. Open Exnay, go to Email links and tap Paste.")
    }

    /// The first web address among what was shared, whether it came as a link or as text that contains one.
    private func sharedLink() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let item = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier), let url = item as? URL, url.scheme?.hasPrefix("http") == true { return url }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let item = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier), let text = item as? String,
               let match = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let url = match.url, url.scheme?.hasPrefix("http") == true { return url }
        }
        return nil
    }

    /// An extension has no direct way to open its app; the system's own open call is reached through the responder chain.
    private func open(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if r is UIApplication, r.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], ((Bool) -> Void)?) -> Void
                unsafeBitCast(r.method(for: selector), to: Open.self)(r, selector, url, [:], nil)
                return true
            }
            responder = r.next
        }
        return false
    }

    private func done() { extensionContext?.completeRequest(returningItems: nil) }

    private func finish(message: String) {
        let label = UILabel()
        label.text = message; label.numberOfLines = 0; label.textAlignment = .center; label.font = .preferredFont(forTextStyle: .headline)
        var config = UIButton.Configuration.filled(); config.title = "OK"
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.done() })
        let stack = UIStackView(arrangedSubviews: [label, button]); stack.axis = .vertical; stack.spacing = 20; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: view.centerYAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
    }
}
