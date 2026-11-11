import SwiftUI
import SafariServices
import OptOutKitCore

struct BrokerDetailView: View {
    @EnvironmentObject var model: AppModel
    let broker: Broker
    @State private var browserURL: URL?
    @State private var guide: GuidedRunner?

    var body: some View {
        List {
            if let issue = model.activeIssue(for: broker.id) {
                Label("You marked this site as not working: \(issue.kind.label.lowercased()).", systemImage: "exclamationmark.bubble")
                    .font(.footnote).foregroundStyle(.red).accessibilityIdentifier("reported-issue")
            }
            if !model.progress.isDone(broker.id) {
                GuideButton(title: Loc.t("Guide me through it"), subtitle: Loc.t("Full-screen browser, one step at a time")) {
                    model.requireProfile { guide = model.guidedRunner(for: broker) }
                }
            }
            if !broker.isVerified {
                Text("This flow has not been verified by a real run yet. Steps may be out of date.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(Array(broker.steps.enumerated()), id: \.offset) { index, step in
                card(index, step)
            }
            if model.progress.isDone(broker.id) {
                Button("Start over", role: .destructive) { model.reset(broker) }
            }
        }
        .navigationTitle(broker.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browserURL) { SafariView(url: $0).ignoresSafeArea() }
        .fullScreenCover(item: Binding(get: { guide.map(GuideBox.init) }, set: { if $0 == nil { guide = nil } })) { box in
            GuidedFlowView(runner: box.runner)
        }
    }

    private func card(_ index: Int, _ step: Step) -> some View {
        let done = model.progress.isStepDone(broker.id, index)
        let unlocked = model.progress.isUnlocked(broker.id, step: index)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Step \(index + 1) of \(broker.steps.count)").font(.caption).foregroundStyle(.secondary)
            Text(step.title).font(.body)
            HStack {
                if let url = step.open {
                    Button("Open in Safari") { browserURL = url }.buttonStyle(.bordered)
                }
                if let copy = step.copy {
                    // TODO: copy the vault value and clear the clipboard after 60 seconds.
                    Text("Vault value: \(copy)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(done ? "Done" : Loc.t("Mark done")) { model.complete(broker, step: index) }
                    .buttonStyle(.borderedProminent)
                    .disabled(done || !unlocked)
                    .accessibilityIdentifier("done-\(index)")
            }
        }
        .opacity(unlocked ? 1 : 0.4)
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Lets a runner be presented as a full-screen cover.
struct GuideBox: Identifiable {
    let runner: GuidedRunner
    var id: ObjectIdentifier { ObjectIdentifier(runner) }
}
