import UIKit
import PencilKit
import NotesCore

/// The scrolling stack of A4 pages.
///
/// - Layout/geometry comes from `NotesCore.NotebookLayout`; everything is in
///   paper points and the scroll view's `zoomScale` does display scaling
///   (minimum zoom = fit-width).
/// - Page views exist only for pages near the viewport (visible ± 1 gets a
///   live `PKCanvasView`, the next ring gets bitmap snapshots, everything
///   else is drawn as blank paper by `PageStackBackgroundView`). Keeping
///   many Metal-backed canvases alive causes documented GPU memory failures.
/// - Notability-style paging: one empty page always trails the content; ink
///   or text on it promotes it into the document and a new blank appears.
final class NotebookViewController: UIViewController {
    private let document: NoteDocument
    private let tools: ToolCoordinator
    private let layout = NotebookLayout()

    private let scrollView = UIScrollView()
    private let contentView = PageStackBackgroundView()

    /// The trailing, not-yet-persisted blank page.
    private var pendingBlankPage = Page()
    /// Pages currently shown: `document.note.pages + [pendingBlankPage]`.
    private var displayedPages: [Page] = []
    private var pageViews: [UUID: PageView] = [:]

    /// The page whose canvas is the tool picker's first-responder target.
    private weak var activePageView: PageView?

    private var lastKnownSize: CGSize = .zero
    /// Zoom-compensated scale applied to live canvases (0 = display default).
    /// Freshly materialized canvases must get it too, or their ink renders
    /// blurrier than neighbors while zoomed in.
    private var canvasContentScale: CGFloat = 0

    init(document: NoteDocument, tools: ToolCoordinator) {
        self.document = document
        self.tools = tools
        super.init(nibName: nil, bundle: nil)
        tools.onToolingChanged = { [weak self] in self?.toolingChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .automatic
        view.addSubview(scrollView)

        contentView.layout = layout
        scrollView.addSubview(contentView)

        reloadFromDocument()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastKnownSize else { return }
        lastKnownSize = view.bounds.size
        scrollView.frame = view.bounds
        updateZoomLimits()
        layoutContent()
    }

    // MARK: Model → view

    /// Rebuilds everything from the document (open, conflict merge, revert).
    func reloadFromDocument() {
        pendingBlankPage = Page()
        rebuildDisplayedPages()
        for (_, pageView) in pageViews {
            pageView.removeFromSuperview()
        }
        pageViews = [:]
        activePageView = nil
        layoutContent()
    }

    private func rebuildDisplayedPages() {
        displayedPages = document.note.pages + [pendingBlankPage]
        contentView.pageCount = displayedPages.count
    }

    private func layoutContent() {
        let height = layout.contentHeight(pageCount: displayedPages.count)
        let zoom = scrollView.zoomScale
        // bounds + center are transform-safe; setting `frame` is undefined
        // while the scroll view's zoom transform is applied to contentView
        // and would corrupt the paper-point coordinate space.
        contentView.bounds = CGRect(x: 0, y: 0, width: A4.width, height: height)
        scrollView.contentSize = CGSize(width: A4.width * zoom, height: height * zoom)
        contentView.center = CGPoint(
            x: scrollView.contentSize.width / 2,
            y: scrollView.contentSize.height / 2
        )
        contentView.setNeedsDisplay()
        centerContent()
        positionPageViews()
        updateVisibleWindow()
    }

    private func updateZoomLimits() {
        // Compute the new fit BEFORE comparing — UIScrollView does not clamp
        // zoomScale when the limits change, and the initial zoomScale (1.0)
        // is below fit-width on every iPad.
        let fit = NotebookLayout.fitScale(containerWidth: Double(view.bounds.width), margin: 12)
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = fit * 3
        if scrollView.zoomScale < fit {
            scrollView.zoomScale = fit
        }
    }

    private func positionPageViews() {
        for (pageID, pageView) in pageViews {
            guard let index = displayedPages.firstIndex(where: { $0.id == pageID }) else { continue }
            pageView.frame = CGRect(
                x: 0,
                y: layout.pageOriginY(at: index),
                width: A4.width,
                height: A4.height
            )
        }
    }

    /// Keeps the page stack horizontally centered when the viewport is wider
    /// than the zoomed page (typical on the Mac).
    private func centerContent() {
        let excessX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        scrollView.contentInset.left = excessX
        scrollView.contentInset.right = 0
    }

    // MARK: Virtualization

    private func updateVisibleWindow() {
        guard !displayedPages.isEmpty, scrollView.zoomScale > 0 else { return }
        let zoom = scrollView.zoomScale
        let minY = Double((scrollView.contentOffset.y) / zoom)
        let maxY = Double((scrollView.contentOffset.y + scrollView.bounds.height) / zoom)

        let visible = layout.visiblePageIndices(minY: minY, maxY: maxY, pageCount: displayedPages.count)
        guard !visible.isEmpty else { return }

        // Pages that keep a view at all: visible ± 2. Live canvas: visible ± 1.
        let materialized = max(visible.lowerBound - 2, 0)..<min(visible.upperBound + 2, displayedPages.count)
        let live = max(visible.lowerBound - 1, 0)..<min(visible.upperBound + 1, displayedPages.count)

        let neededIDs = Set(materialized.map { displayedPages[$0].id })

        for (pageID, pageView) in pageViews where !neededIDs.contains(pageID) {
            if let canvas = pageView.canvasView {
                // Remember the picker selection so freshly created canvases
                // don't fall back to the default black pen.
                tools.noteCurrentTool(from: canvas)
            }
            if pageView === activePageView { activePageView = nil }
            pageView.setMode(.snapshot, tools: tools)
            pageView.removeFromSuperview()
            pageViews.removeValue(forKey: pageID)
        }

        for index in materialized {
            let page = displayedPages[index]
            let pageView = pageViews[page.id] ?? {
                let created = PageView(pageID: page.id)
                created.delegate = self
                pageViews[page.id] = created
                contentView.addSubview(created)
                return created
            }()
            pageView.frame = CGRect(
                x: 0,
                y: layout.pageOriginY(at: index),
                width: A4.width,
                height: A4.height
            )
            pageView.configure(page: page, pageNumber: index + 1)
            pageView.setMode(live.contains(index) ? .live : .snapshot, tools: tools)
            pageView.applyInteractionMode(tools.mode)
            if let canvas = pageView.canvasView {
                canvas.contentScaleFactor = max(canvasContentScale, traitCollection.displayScale)
            }
        }

        // Keep the tool picker anchored to a live canvas: without a first
        // responder it slides away (e.g. after its page was evicted above).
        if tools.mode == .draw, activePageView == nil,
           let pageView = mostVisiblePageView(), let canvas = pageView.canvasView {
            activePageView = pageView
            tools.activate(canvas)
        }
    }

    // MARK: View → model

    private func commitChange(from pageView: PageView, mutate: (inout Page) -> Void) {
        let pageID = pageView.pageID
        guard let index = displayedPages.firstIndex(where: { $0.id == pageID }) else { return }

        var page = displayedPages[index]
        mutate(&page)
        displayedPages[index] = page

        if page.id == pendingBlankPage.id {
            if page.isEmpty {
                pendingBlankPage = page
                return
            }
            // The trailing blank just got content: promote it into the
            // document and grow a fresh blank below it.
            pendingBlankPage = Page()
            var note = document.note
            note.pages.append(page)
            document.updateNote(note)
            rebuildDisplayedPages()
            layoutContent()
            updateVisibleWindow()
        } else {
            var note = document.note
            note.updatePage(page)
            if page.isEmpty, note.pages.last?.id == page.id {
                // The last persisted page was fully emptied: trim trailing
                // empties (matching what a save would persist) and reuse the
                // emptied page as the view-only trailing blank, so screen and
                // disk never diverge.
                note = note.normalizedForSave()
                pendingBlankPage = page
                document.updateNote(note)
                rebuildDisplayedPages()
                layoutContent()
                return
            }
            document.updateNote(note)
        }
    }

    private func toolingChanged() {
        for (_, pageView) in pageViews {
            pageView.applyInteractionMode(tools.mode)
            #if targetEnvironment(macCatalyst)
            pageView.canvasView?.tool = tools.currentMacPKTool
            #endif
        }
        if tools.mode == .draw {
            if let canvas = (activePageView ?? mostVisiblePageView())?.canvasView {
                tools.activate(canvas)
            }
        } else if let canvas = activePageView?.canvasView {
            tools.hideToolPicker(for: canvas)
        }
    }

    private func mostVisiblePageView() -> PageView? {
        let zoom = scrollView.zoomScale
        guard zoom > 0, !displayedPages.isEmpty else { return nil }
        let midY = Double((scrollView.contentOffset.y + scrollView.bounds.height / 2) / zoom)
        let index = layout.pageIndex(atY: midY, pageCount: displayedPages.count)
        return pageViews[displayedPages[index].id]
    }
}

// MARK: - UIScrollViewDelegate

extension NotebookViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisibleWindow()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateVisibleWindow()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // A canvas zoomed by a *parent* scroll view renders blurry: its Metal
        // layer's scale doesn't track the parent's zoom. Bump the content
        // scale (capped — GPU memory grows with scale²).
        let displayScale = traitCollection.displayScale
        canvasContentScale = min(displayScale * scale, 3 * displayScale, 6)
        for (_, pageView) in pageViews {
            pageView.canvasView?.contentScaleFactor = max(canvasContentScale, displayScale)
        }
    }
}

// MARK: - PageViewDelegate

extension NotebookViewController: PageViewDelegate {
    func pageView(_ pageView: PageView, didChangeDrawingData data: Data) {
        commitChange(from: pageView) { page in
            page.drawingData = data
            page.drawingModified = Date()
        }
    }

    func pageView(_ pageView: PageView, didChangeText text: String) {
        commitChange(from: pageView) { page in
            page.text = text
            page.textModified = Date()
        }
    }

    func pageViewDidBeginInteraction(_ pageView: PageView) {
        if let canvas = pageView.canvasView {
            tools.noteCurrentTool(from: canvas)
        }
        guard pageView !== activePageView else { return }
        activePageView = pageView
        if tools.mode == .draw, let canvas = pageView.canvasView {
            tools.activate(canvas)
        }
    }
}

// MARK: - PageStackBackgroundView

/// Draws blank paper rectangles for every page so that pages beyond the
/// materialized window still look like paper while scrolling fast.
final class PageStackBackgroundView: UIView {
    var layout = NotebookLayout()
    var pageCount = 0 {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.white.cgColor)
        for index in 0..<pageCount {
            let frame = CGRect(x: 0, y: layout.pageOriginY(at: index), width: A4.width, height: A4.height)
            if frame.intersects(rect) {
                context.fill(frame)
            }
        }
    }
}
