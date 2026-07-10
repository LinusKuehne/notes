import UIKit
import PencilKit
import NotesCore

@MainActor
protocol PageViewDelegate: AnyObject {
    func pageView(_ pageView: PageView, didChangeDrawingData data: Data)
    func pageView(_ pageView: PageView, didChangeText text: String)
    /// A touch/pencil interaction started on this page — make it the active
    /// page (first responder + tool picker target).
    func pageViewDidBeginInteraction(_ pageView: PageView)
}

/// One A4 page: paper background, full-page text layer underneath, ink on
/// top. Lives in paper-point coordinates (595.28 × 841.89); the scroll
/// view's zoom does all display scaling.
///
/// PKCanvasView is Metal-backed and expensive, so a page is either `.live`
/// (real canvas, only for pages near the viewport) or `.snapshot` (bitmap of
/// the drawing).
final class PageView: UIView {
    enum Mode {
        case live
        case snapshot
    }

    let pageID: UUID
    weak var delegate: PageViewDelegate?

    private(set) var canvasView: PKCanvasView?
    private let snapshotView = UIImageView()
    private let textView = UITextView()
    private let pageNumberLabel = UILabel()

    /// The drawing and its serialized form, kept in lockstep. The Data cache
    /// makes model-echo comparisons in `configure` a cheap memcmp instead of
    /// a re-serialization on every scroll-driven reconfigure.
    private var drawing = PKDrawing()
    private var serializedDrawing = Data()

    /// Guards against the drawing-setter re-firing the delegate.
    private var isProgrammaticUpdate = false
    private var snapshotRenderTask: Task<Void, Never>?
    private(set) var mode: Mode = .snapshot

    // nonisolated: the PDF exporter reads this off the main actor.
    nonisolated static let textInset = UIEdgeInsets(top: 44, left: 44, bottom: 44, right: 44)

    // MARK: Init

    init(pageID: UUID) {
        self.pageID = pageID
        super.init(frame: CGRect(x: 0, y: 0, width: A4.width, height: A4.height))

        backgroundColor = .white
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)

        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .black
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.frame = CGRect(x: 0, y: 0, width: A4.width, height: A4.height).inset(by: Self.textInset)
        textView.autoresizingMask = []
        addSubview(textView)

        snapshotView.frame = bounds
        snapshotView.contentMode = .scaleAspectFit
        addSubview(snapshotView)

        pageNumberLabel.font = .systemFont(ofSize: 10, weight: .medium)
        pageNumberLabel.textColor = .systemGray3
        addSubview(pageNumberLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    func configure(page: Page, pageNumber: Int) {
        if textView.text != page.text {
            textView.text = page.text
        }
        pageNumberLabel.text = "\(pageNumber)"
        pageNumberLabel.sizeToFit()
        pageNumberLabel.frame.origin = CGPoint(
            x: bounds.width - pageNumberLabel.bounds.width - 12,
            y: bounds.height - pageNumberLabel.bounds.height - 10
        )

        guard page.drawingData != serializedDrawing else { return }
        serializedDrawing = page.drawingData
        drawing = (try? PKDrawing(data: page.drawingData)) ?? PKDrawing()
        if let canvasView {
            isProgrammaticUpdate = true
            canvasView.drawing = drawing
            isProgrammaticUpdate = false
        } else {
            renderSnapshot()
        }
    }

    // MARK: Live / snapshot switching

    func setMode(_ newMode: Mode, tools: ToolCoordinator) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .live:
            snapshotRenderTask?.cancel()
            let canvas = PKCanvasView(frame: bounds)
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.showsVerticalScrollIndicator = false
            canvas.showsHorizontalScrollIndicator = false
            canvas.delegate = self
            isProgrammaticUpdate = true
            canvas.drawing = drawing
            isProgrammaticUpdate = false
            tools.adopt(canvas)
            insertSubview(canvas, aboveSubview: textView)
            canvasView = canvas
            snapshotView.isHidden = true
            snapshotView.image = nil
            applyInteractionMode(tools.mode)

        case .snapshot:
            if let canvas = canvasView {
                tools.release(canvas)
                canvas.removeFromSuperview()
                canvasView = nil
            }
            snapshotView.isHidden = false
            renderSnapshot()
        }
    }

    /// Draw mode: ink gets the touches. Text mode: the text layer does.
    func applyInteractionMode(_ interaction: ToolCoordinator.InteractionMode) {
        let drawingMode = interaction == .draw
        canvasView?.isUserInteractionEnabled = drawingMode
        textView.isUserInteractionEnabled = !drawingMode
        if drawingMode, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    private func renderSnapshot() {
        snapshotRenderTask?.cancel()
        guard !drawing.strokes.isEmpty else {
            snapshotView.image = nil
            return
        }
        let drawing = drawing
        let bounds = bounds
        snapshotRenderTask = Task { [weak self] in
            // Modest scale: placeholders only need to look right at fit-width.
            let image = drawing.image(from: bounds, scale: 2)
            guard !Task.isCancelled else { return }
            self?.snapshotView.image = image
        }
    }

}

// MARK: - PKCanvasViewDelegate

extension PageView: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isProgrammaticUpdate else { return }
        drawing = canvasView.drawing
        // Stroke-end events arrive at human rate, so serializing here is fine
        // and keeps the model (and autosave) always current. A stroke-free
        // drawing must serialize to empty Data — a zero-stroke PKDrawing
        // archive is non-empty, which would defeat Page.isEmpty (trailing
        // blank trimming, PDF export skipping) forever after the first
        // touch-and-undo.
        serializedDrawing = canvasView.drawing.strokes.isEmpty
            ? Data()
            : canvasView.drawing.dataRepresentation()
        delegate?.pageView(self, didChangeDrawingData: serializedDrawing)
    }

    // Interaction begin is detected here (an actual drawing action) rather
    // than in hitTest — hitTest must stay a pure query; it fires for hover
    // and scroll touches and mutating the responder chain there causes
    // tool-picker churn.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        delegate?.pageViewDidBeginInteraction(self)
    }
}

// MARK: - UITextViewDelegate

extension PageView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        delegate?.pageView(self, didChangeText: textView.text ?? "")
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.pageViewDidBeginInteraction(self)
    }
}
