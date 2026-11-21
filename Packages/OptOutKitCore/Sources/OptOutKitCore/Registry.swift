import Foundation

public enum Queue {
    /// Easiest tier first so users bank quick wins; ties break by name. TODO: weight by family size and priority.
    public static func ordered(_ brokers: [Broker]) -> [Broker] {
        brokers.sorted { ($0.tier, $0.name) < ($1.tier, $1.name) }
    }
}
