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
                    Text("Open any site to see its page and the screenshot of what it showed after your request was sent.")
                }
            }
        }
        .navigationTitle("Review")
        .accessibilityIdentifier("run-review")
    }

    private func row(_ item: AppModel.ReviewItem) -> some View {
        NavigationLink {
            if let entry = model.sites[id: item.id] { DirectoryInfoView(entry: entry) }
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

/// A small preview of the screenshot saved for a site; tap it to see it full size.
struct SiteScreenshot: View {
    @EnvironmentObject var model: AppModel
    let item: AppModel.ReviewItem
    let person: Person
    @State private var image: UIImage?
    @State private var enlarged = false

    var body: some View {
        Group {
            if let image {
                Button { enlarged = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                        Label("Tap to enlarge the page it showed on \(Loc.date(item.date))", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("site-screenshot")
            }
        }
        .task { if let data = model.screenshot(for: item, person: person) { image = EvidenceImage.image(from: data) } }
        .fullScreenCover(isPresented: $enlarged) {
            NavigationStack {
                ScrollView {
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
                }
                .navigationTitle(item.domain).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { enlarged = false }.accessibilityIdentifier("screenshot-close") } }
            }
        }
    }
}
