import SwiftUI

#if targetEnvironment(macCatalyst)

/// PKToolPicker never appears on Mac Catalyst, so the Mac gets this small
/// tool strip; it drives `ToolCoordinator`'s mac tool state directly.
struct MacToolStrip: View {
    @Bindable var tools: ToolCoordinator

    private static let colors: [(name: String, color: UIColor)] = [
        ("Black", .black),
        ("Blue", .systemBlue),
        ("Red", .systemRed),
        ("Green", .systemGreen),
        ("Orange", .systemOrange),
    ]

    private static let widths: [(name: String, icon: String, width: Double)] = [
        ("Fine", "pencil.tip", 2),
        ("Medium", "pencil", 4),
        ("Bold", "paintbrush.pointed", 8),
    ]

    var body: some View {
        HStack(spacing: 14) {
            Picker("Tool", selection: $tools.macTool) {
                Image(systemName: "pencil.line").tag(ToolCoordinator.MacTool.pen)
                Image(systemName: "highlighter").tag(ToolCoordinator.MacTool.marker)
                Image(systemName: "eraser").tag(ToolCoordinator.MacTool.eraser)
                Image(systemName: "lasso").tag(ToolCoordinator.MacTool.lasso)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            HStack(spacing: 6) {
                ForEach(Self.colors, id: \.name) { entry in
                    Button {
                        tools.macColor = entry.color
                    } label: {
                        Circle()
                            .fill(Color(uiColor: entry.color))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(
                                    tools.macColor == entry.color ? Color.accentColor : .clear,
                                    lineWidth: 2
                                )
                                .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(entry.name)
                }
            }

            Picker("Width", selection: $tools.macWidth) {
                ForEach(Self.widths, id: \.width) { entry in
                    Text(entry.name).tag(entry.width)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .disabled(tools.mode != .draw)
    }
}

#endif
