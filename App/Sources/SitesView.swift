import SwiftUI
import OptOutKitCore

extension StatusSummary {
    var symbol: String {
        switch self {
        case .notStarted: return "circle"
        case .inProgress: return "circle.dotted"
        case .partial: return "circle.lefthalf.filled"
        case .complete: return "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .notStarted: return .secondary
        case .inProgress: return .orange
        case .partial: return .yellow
        case .complete: return .green
        }
    }
}

/// Every broker in the registry with its status across all profiles.
struct SitesView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", todo = "To do", done = "Opted out"
        var id: String { rawValue }
    }

    private var shown: [Broker] {
        model.brokers.filter { broker in
            let s = model.household.summary(for: broker)
            switch filter {
            case .all: break
            case .todo: if s == .complete { return false }
            case .done: if s != .complete { return false }
            }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return broker.name.lowercased().contains(q) || (broker.covers ?? []).contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sites-filter")
                }
                Section("\(shown.count) of \(model.brokers.count) sites") {
                    ForEach(shown) { broker in
                        NavigationLink(value: broker) { row(broker) }
                            .accessibilityIdentifier("site-\(broker.id)")
                    }
                }
            }
            .accessibilityIdentifier("sites-list")
            .navigationTitle("Sites")
            .searchable(text: $search, prompt: "Search by name or web address")
            .navigationDestination(for: Broker.self) { BrokerInfoView(broker: $0) }
        }
    }

    private func row(_ broker: Broker) -> some View {
        let summary = model.household.summary(for: broker)
        return HStack(alignment: .top) {
            Image(systemName: summary.symbol).foregroundStyle(summary.color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(broker.name).font(.headline)
                Text(summary.label).font(.caption).foregroundStyle(summary.color)
                if let covers = broker.covers, !covers.isEmpty {
                    Text("Clears \(covers.count) sites").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Tier \(broker.tier.rawValue)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}

/// Details about one site: what it is, what it needs, and where each person stands.
struct BrokerInfoView: View {
    @EnvironmentObject var model: AppModel
    let broker: Broker
    @State private var openFlow = false

    var body: some View {
        let summary = model.household.summary(for: broker)
        List {
            Section {
                Label(summary.label, systemImage: summary.symbol).foregroundStyle(summary.color)
                    .accessibilityIdentifier("site-summary")
                if broker.isVerified {
                    Text("Verified \(broker.verified ?? "")").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Not yet checked by a real run. Steps may be out of date.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section("Each person") {
                ForEach(model.household.statuses(for: broker), id: \.person.id) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.person.displayName)
                            Text(describe(item.status)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(buttonTitle(item.status)) { model.select(item.person.id); openFlow = true }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Section("What to expect") {
                Text(Describe.tier(broker.tier))
                ForEach(broker.signals ?? [], id: \.self) { Label(Describe.signal($0), systemImage: "info.circle") }
            }

            if let covers = broker.covers, !covers.isEmpty {
                Section("One request clears \(covers.count) sites") {
                    ForEach(covers, id: \.self) { Text($0) }
                }
            }

            if let fields = broker.fields, !fields.isEmpty {
                Section {
                    ForEach(fields, id: \.self) { field in
                        let missing = model.household.people.filter { $0.value(for: field) == nil }
                        VStack(alignment: .leading) {
                            Text(Describe.field(field))
                            if !missing.isEmpty {
                                Text("Missing for \(missing.map(\.displayName).joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("What this site will receive")
                } footer: {
                    Text("Only these details are sent, and only when you submit its form.")
                }
            }

            Section("Steps (\(broker.steps.count))") {
                ForEach(Array(broker.steps.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1). \(step.title)")
                }
            }
        }
        .navigationTitle(broker.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $openFlow) { BrokerDetailView(broker: broker) }
    }

    private func describe(_ status: PersonStatus) -> String {
        switch status {
        case .notStarted: return "Not started"
        case .inProgress(let d, let n): return "In progress: \(d) of \(n) steps"
        case .done(let on, let due):
            return "Opted out \(on.formatted(date: .abbreviated, time: .omitted)); re-check \(due.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    private func buttonTitle(_ status: PersonStatus) -> String {
        switch status {
        case .notStarted: return "Start"
        case .inProgress: return "Continue"
        case .done: return "View"
        }
    }
}
