import UIKit
import PencilKit
import Observation

/// Tool state shared by every page canvas.
///
/// iPad: owns the system `PKToolPicker` (which must be strongly retained —
/// canvases only hold it weakly) and attaches it to whichever page canvas is
/// active. Mac Catalyst: `PKToolPicker` never shows there, so the SwiftUI
/// `MacToolStrip` drives `macTool`/`macColor`/`macWidth` and the notebook
/// applies `currentMacPKTool` to all live canvases.
@Observable
final class ToolCoordinator {
    enum InteractionMode: String, CaseIterable, Identifiable {
        case draw
        case text
        var id: String { rawValue }
    }

    enum MacTool: String, CaseIterable, Identifiable {
        case pen
        case marker
        case eraser
        case lasso
        var id: String { rawValue }
    }

    var mode: InteractionMode {
        didSet { onToolingChanged?() }
    }

    // MARK: Mac tool strip state

    var macTool: MacTool = .pen { didSet { onToolingChanged?() } }
    var macColor: UIColor = .black { didSet { onToolingChanged?() } }
    var macWidth: Double = 4 { didSet { onToolingChanged?() } }

    /// The notebook controller re-applies tools / interaction flags on this.
    @ObservationIgnored var onToolingChanged: (() -> Void)?

    @ObservationIgnored let toolPicker = PKToolPicker()

    /// Last tool observed on a live canvas (iPad). PKToolPicker only pushes
    /// its selection to observers on *changes*, so freshly created canvases
    /// would otherwise start with the default black pen regardless of the
    /// picker's current selection.
    @ObservationIgnored private var lastKnownPickerTool: PKTool?

    init() {
        #if targetEnvironment(macCatalyst)
        mode = .text
        #else
        mode = .draw
        #endif
    }

    var currentMacPKTool: PKTool {
        switch macTool {
        case .pen:
            return PKInkingTool(.pen, color: macColor, width: macWidth)
        case .marker:
            return PKInkingTool(.marker, color: macColor.withAlphaComponent(0.6), width: max(macWidth * 4, 12))
        case .eraser:
            return PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        }
    }

    static var preferredDrawingPolicy: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(macCatalyst)
        // There is no pencil on the Mac — anything else leaves the canvas dead.
        return .anyInput
        #else
        // Respects the system "Only Draw with Apple Pencil" setting; palm
        // rejection is automatic when drawing with the pencil.
        return .default
        #endif
    }

    /// Prepares a canvas that just became live.
    func adopt(_ canvas: PKCanvasView) {
        canvas.drawingPolicy = Self.preferredDrawingPolicy
        #if targetEnvironment(macCatalyst)
        canvas.tool = currentMacPKTool
        #else
        toolPicker.addObserver(canvas)
        if let tool = lastKnownPickerTool {
            canvas.tool = tool
        }
        #endif
    }

    /// Records the picker selection from a live canvas (called before that
    /// canvas is evicted, and when drawing begins).
    func noteCurrentTool(from canvas: PKCanvasView) {
        #if !targetEnvironment(macCatalyst)
        lastKnownPickerTool = canvas.tool
        #endif
    }

    func release(_ canvas: PKCanvasView) {
        #if !targetEnvironment(macCatalyst)
        toolPicker.removeObserver(canvas)
        #endif
    }

    /// Makes `canvas` the tool picker's first responder target (iPad).
    func activate(_ canvas: PKCanvasView) {
        guard mode == .draw else { return }
        #if !targetEnvironment(macCatalyst)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        if !canvas.isFirstResponder {
            canvas.becomeFirstResponder()
        }
        #endif
    }

    func hideToolPicker(for canvas: PKCanvasView) {
        #if !targetEnvironment(macCatalyst)
        toolPicker.setVisible(false, forFirstResponder: canvas)
        #endif
    }
}
