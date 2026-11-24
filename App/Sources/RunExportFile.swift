import CoreTransferable
import UniformTypeIdentifiers

/// The run export (`AppModel.runExport`) as the share sheet sees it: a zip, built only when the person picks where to send it, and handed over as data,
/// so no file is written on the phone (docs/STORAGE.md).
struct RunExportFile: Transferable {
    let build: @Sendable () async -> Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .zip) { await $0.build() }
            .suggestedFileName("exnay-run.zip")
    }
}
