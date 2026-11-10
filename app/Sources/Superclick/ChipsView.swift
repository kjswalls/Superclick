import AppKit
import SuperclickCore
import SwiftUI

/// Compact pills (20px tall, 14px tinted icons) on one line. Chips that don't
/// fit tuck from the end into a stack of overlapping icons with a count; the
/// "secret redacted" chip never tucks (DECISIONS, mockup round 4).
struct ChipsRow: View {
    let chips: [Chip]
    let width: CGFloat
    @Binding var expanded: Bool
    var onRemove: (Chip) -> Void
    var onToggle: (Chip) -> Void

    static let spacing: CGFloat = 4

    var body: some View {
        if expanded {
            FlowLayout(spacing: Self.spacing) {
                ForEach(chips) { chipView($0) }
                Button("Show less") { expanded = false }
                    .buttonStyle(StackButtonStyle())
            }
        } else {
            let result = layout
            HStack(spacing: Self.spacing) {
                ForEach(result.visible, id: \.self) { chipView(chips[$0]) }
                if !result.tucked.isEmpty {
                    Button { expanded = true } label: {
                        HStack(spacing: 5) {
                            HStack(spacing: -6) {
                                ForEach(result.tucked.prefix(3), id: \.self) { i in
                                    ChipIcon(chip: chips[i])
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.25), lineWidth: 1.5))
                                }
                            }
                            Text("+\(result.tucked.count)")
                        }
                    }
                    .buttonStyle(StackButtonStyle())
                    .help(result.tucked.map { chips[$0].label }.joined(separator: ", "))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var layout: ChipOverflow.Result {
        let widths = chips.map { Double(ChipView.width(for: $0)) }
        let pinned = Set(chips.indices.filter { chips[$0].kind == .secrets || chips[$0].kind == .blocked })
        return ChipOverflow.layout(
            widths: widths, pinned: pinned, available: Double(width), spacing: Double(Self.spacing),
            stackWidth: { n in Double(14 + 8 * CGFloat(min(n, 3) - 1) + 5 + Self.textWidth("+\(n)") + 10) })
    }

    @ViewBuilder
    private func chipView(_ chip: Chip) -> some View {
        ChipView(chip: chip, onRemove: { onRemove(chip) }, onToggle: { onToggle(chip) })
    }

    static let font = NSFont.systemFont(ofSize: 11.5)

    static func textWidth(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }
}

struct ChipView: View {
    let chip: Chip
    var onRemove: () -> Void
    var onToggle: () -> Void
    @State private var hovering = false

    static let maxLabel: CGFloat = 150

    /// Must match the layout below; the overflow logic measures with it.
    static func width(for chip: Chip) -> CGFloat {
        let icon: CGFloat = chip.thumbnailPath != nil ? 19 : 14
        let label = min(ChipsRow.textWidth(chip.label), maxLabel)
        let close: CGFloat = chip.removable ? 14 : 0
        let gaps: CGFloat = chip.removable ? 8 : 4
        return 3 + icon + gaps + label + close + (chip.removable ? 1 : 6) + 2
    }

    var body: some View {
        HStack(spacing: 4) {
            if chip.isPending {
                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
            } else {
                ChipIcon(chip: chip)
            }
            Text(chip.label)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.maxLabel, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(chip.isPending ? Color.secondary : Color.primary)
            if chip.removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0.7)
                .help("Don't send this")
            }
        }
        .padding(.leading, 3)
        .padding(.trailing, chip.removable ? 1 : 6)
        .frame(height: 20)
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .onTapGesture { if chip.toggles { onToggle() } }
        .help(chip.help ?? chip.label)
    }

    private var background: Color {
        switch chip.kind {
        case .secrets, .blocked: return Color(hex: 0xF0B04B, opacity: 0.12)
        default: return Color.primary.opacity(hovering && chip.toggles ? 0.10 : 0.06)
        }
    }

    private var border: Color {
        switch chip.kind {
        case .secrets, .blocked: return Color(hex: 0xF0B04B, opacity: 0.28)
        default: return Color.primary.opacity(0.08)
        }
    }
}

struct ChipIcon: View {
    let chip: Chip

    var body: some View {
        if let path = chip.thumbnailPath, let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 19, height: 13)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
        } else if let pid = chip.appIconPID, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: chip.symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(gradient, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private var gradient: LinearGradient {
        let (a, b): (UInt32, UInt32) = switch chip.tint {
        case .blue: (0x4C8DF6, 0x2F62D8)     // page text
        case .purple: (0xA08CF0, 0x6E5AD8)   // selection
        case .teal: (0x36B6C9, 0x1E8297)     // URL
        case .green: (0x3E4250, 0x23262F)    // terminal folder
        case .orange: (0xF0B04B, 0xD2832A)   // secrets, blocked
        case .red: (0xF0B04B, 0xD2832A)
        case .neutral: (0x8A93A8, 0x5F6779)  // file, screenshot
        }
        return LinearGradient(colors: [Color(hex: a), Color(hex: b)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct StackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 3)
            .padding(.trailing, 6)
            .frame(height: 20)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Wraps its children onto as many lines as needed (the expanded chip row).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
