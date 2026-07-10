import UIKit
import PencilKit
import SwiftUI
import UniformTypeIdentifiers
import NotesCore

/// Renders the note to an A4 PDF: one PDF page per note page, typed text as
/// real vector text (selectable/searchable), ink composited on top.
///
/// Vector ink is not possible with public PencilKit API — the drawing is
/// rasterized via `PKDrawing.image(from:scale:)`. To keep file sizes sane the
/// raster goes through JPEG and is composited with `.multiply` (white pixels
/// are identity, so the text underneath stays visible and selectable).
nonisolated enum PDFExporter {
    nonisolated static let pageBounds = CGRect(x: 0, y: 0, width: A4.width, height: A4.height)
    nonisolated static let inkScale: CGFloat = 2

    /// Streams the PDF to `url` — memory stays flat for long notes.
    nonisolated static func writePDF(for note: Note, to url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format())
        try renderer.writePDF(to: url) { context in
            renderPages(of: note, into: context)
        }
    }

    /// In-memory variant for the file exporter.
    nonisolated static func pdfData(for note: Note) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format())
        return renderer.pdfData { context in
            renderPages(of: note, into: context)
        }
    }

    nonisolated static func defaultFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Notes \(formatter.string(from: date)).pdf"
    }

    // MARK: Rendering

    private nonisolated static func format() -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Notes",
            kCGPDFContextCreator as String: "Notes",
        ]
        return format
    }

    private nonisolated static func renderPages(of note: Note, into context: UIGraphicsPDFRendererContext) {
        // The trailing blank page (and any other trailing empties) never
        // reaches the PDF.
        let pages = note.normalizedForSave().pages
        for page in pages {
            context.beginPage()
            drawText(page.text, in: context.cgContext)
            drawInk(page.drawingData)
        }
    }

    private nonisolated static func drawText(_ text: String, in cgContext: CGContext) {
        guard !text.isEmpty else { return }
        let textRect = pageBounds.inset(by: PageView.textInset)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph,
        ])
        cgContext.saveGState()
        cgContext.clip(to: textRect)
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
        cgContext.restoreGState()
    }

    private nonisolated static func drawInk(_ drawingData: Data) {
        guard let drawing = try? PKDrawing(data: drawingData), !drawing.strokes.isEmpty else { return }
        // Force light appearance so ink stays dark-on-white in the PDF.
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: pageBounds, scale: inkScale)
        }
        guard let image else { return }
        // JPEG shrinks the embedded raster massively; multiply-blending keeps
        // the (vector) text underneath visible through JPEG's opaque white.
        if let jpeg = image.jpegData(compressionQuality: 0.8), let compressed = UIImage(data: jpeg) {
            compressed.draw(in: pageBounds, blendMode: .multiply, alpha: 1)
        } else {
            image.draw(in: pageBounds)
        }
    }
}

// MARK: - Share / export plumbing

/// Lazy PDF for `ShareLink`: the file is generated only when the share
/// actually happens.
nonisolated struct NotePDF: Transferable {
    let note: Note

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { pdf in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(PDFExporter.defaultFileName(for: Date()))
            try PDFExporter.writePDF(for: pdf.note, to: url)
            return SentTransferredFile(url)
        }
    }
}

/// Wrapper for `.fileExporter`.
nonisolated struct PDFFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
