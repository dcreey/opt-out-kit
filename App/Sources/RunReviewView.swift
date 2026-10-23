import SwiftUI
import OptOutKitCore

/// Every site the last automatic run tried, with a picture of what the site showed at the end, so the person can confirm what happened.
struct RunReviewView: View {
    @EnvironmentObject var model: AppModel
    let person: Person

    var body: some View {
        let items = model.reviewItems(for: person)
        List {
            if items.isEmpty {
                Section { Text("Nothing to review yet. Run the automatic opt-out and each site's result appears here.").font(.footnote).foregroundStyle(.secondary) }
            }
            let attention = items.filter { !$0.worked }
            if !attention.isEmpty {
                Section("Needs you (\(attention.count))") { ForEach(attention) { row($0) } }
            }
            let done = items.filter(\.worked)
            if !done.isEmpty {
                Section {
                    ForEach(done) { row($0) }
                } header: { Text("Went through (\(done.count))") } footer: {
                    Text("Open any site to see the page it showed after your request was sent. If it does not look finished, say so and the site moves to a guide.")
                }
            }
        }
        .navigationTitle("Review")
        .accessibilityIdentifier("run-review")
    }

    private func row(_ item: AppModel.ReviewItem) -> some View {
        NavigationLink {
            EvidenceDetailView(item: item, person: person)
        } label: {
            HStack(spacing: 12) {
                Thumbnail(item: item, person: person).frame(width: 44, height: 78)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.domain).font(.headline)
                    Text(item.label).font(.caption).foregroundStyle(item.worked ? Color.green : Color.orange).fixedSize(horizontal: false, vertical: true)
                    if !item.hasScreenshot { Text("No screenshot").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .accessibilityIdentifier("review-\(item.id)")
    }
}

private struct Thumbnail: View {
    @EnvironmentObject var model: AppModel
    let item: AppModel.ReviewItem
    let person: Person
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: item.worked ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(.secondary) }
        }
        .frame(width: 44, height: 78).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 6))
        .task { if item.hasScreenshot, let data = model.screenshot(for: item, person: person) { image = EvidenceImage.image(from: data) } }
    }
}

/// One site's screenshot, full size, with what it was and a way to say it does not look right.
struct EvidenceDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: AppModel.ReviewItem
    let person: Person
    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(item.label, systemImage: item.worked ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(item.worked ? Color.green : Color.orange).fixedSize(horizontal: false, vertical: true)
                Text("\(item.domain) · \(Loc.date(item.date, time: true))").font(.footnote).foregroundStyle(.secondary)
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                        .accessibilityIdentifier("evidence-image")
                    Text("This is the page the site showed when we finished.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("There is no screenshot for this site.").font(.callout).foregroundStyle(.secondary)
                }
                if item.worked {
                    Button { dismiss() } label: { Label("Looks right", systemImage: "hand.thumbsup").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("evidence-looks-right")
                    Button(role: .destructive) { model.markLooksWrong(item, for: person); dismiss() } label: {
                        Label("This does not look finished", systemImage: "hand.thumbsdown").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("evidence-looks-wrong")
                    Text("If you say it does not look finished, this site is no longer counted as done and moves to your queue as a guided task.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(item.domain)
        .navigationBarTitleDisplayMode(.inline)
        .task { if let data = model.screenshot(for: item, person: person) { image = EvidenceImage.image(from: data) } }
    }
}
