import Foundation
import SwiftUI

/// Finds what makes the screen stop answering during a run (debug builds, with `-uitest-watch-main`): a background thread asks the main thread to answer
/// every 50 ms, and a gap of more than 250 ms is a stall, recorded with the step the run was on (`MainThreadWatch.note`). The worst one is shown in a hidden
/// label (`main-stalls`) that `FixtureJourneyUITests.testTheScreenKeepsAnsweringWhileARunWorks` reads. Release builds compile it to nothing.
/// Reported: "the app tends to freeze while the automatic run is happening; I can't scroll; it's stuck for 5 seconds or so" (2026-11-23).
enum MainThreadWatch {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var step = "idle"
    private nonisolated(unsafe) static var worst: (ms: Int, step: String) = (0, "")

    /// The run's current step, for a stall's report. Cheap: a lock and a string.
    static func note(_ s: String) {
        #if DEBUG
        lock.lock(); step = s; lock.unlock()
        #endif
    }

    static var report: String { lock.lock(); defer { lock.unlock() }; return "\(worst.ms)ms \(worst.step)" }

    static func startIfAsked() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-uitest-watch-main") else { return }
        let thread = Thread {
            var answered = Date()
            let box = NSLock()
            while true {
                let asked = Date()
                lock.lock(); let during = step; lock.unlock()
                DispatchQueue.main.async { box.lock(); answered = Date(); box.unlock() }
                Thread.sleep(forTimeInterval: 0.05)
                // Wait for this question's answer, measuring how long the main thread took to get to it.
                while true {
                    box.lock(); let a = answered; box.unlock()
                    if a >= asked { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                box.lock(); let gap = answered.timeIntervalSince(asked); box.unlock()
                let ms = Int(gap * 1000)
                if ms > 250 {
                    NSLog("OOK main stall %dms during %@", ms, during)
                    // Only stalls once a run has begun count: launching the app stalls too (1.7 s on GitHub's runner), and that is not the run's doing.
                    lock.lock(); if during != "idle", ms > worst.ms { worst = (ms, during) }; lock.unlock()
                }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        #endif
    }
}

/// The hidden label with the worst stall so far, refreshed every second (only with `-uitest-watch-main`).
struct MainStallsLabel: View {
    @State private var text = ""
    var body: some View {
        Text(verbatim: text).font(.system(size: 1)).opacity(0.01).accessibilityIdentifier("main-stalls").accessibilityLabel(text)
            .task { while !Task.isCancelled { text = MainThreadWatch.report; try? await Task.sleep(nanoseconds: 1_000_000_000) } }
    }
}
