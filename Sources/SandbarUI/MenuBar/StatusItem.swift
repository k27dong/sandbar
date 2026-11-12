import AppKit
import SandbarCore
import SwiftUI

package final class StatusItem {
    package enum Ring: Equatable {
        case none
        case used(Double, UsageLimit.Level)
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onClick: () -> Void

    package init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        item.button?.target = self
        item.button?.action = #selector(clicked)
    }

    package var button: NSStatusBarButton? { item.button }

    /// False until the menu bar has placed the item: before that its window can sit anywhere, (0, 0) included.
    package var isPlaced: Bool {
        guard let window = item.button?.window, let screen = window.screen else { return false }
        return Self.isInMenuBar(window.frame, of: screen.frame)
    }

    package static func isInMenuBar(_ item: NSRect, of screen: NSRect) -> Bool {
        abs(item.maxY - screen.maxY) < 1 && item.minX >= screen.minX && item.maxX <= screen.maxX
    }

    package var isHighlighted: Bool {
        get { item.button?.isHighlighted ?? false }
        set { item.button?.highlight(newValue) }
    }

    package func show(ring: Ring, count: Int?, dimmed: Bool) {
        let tone: NSColor? =
            if case .used(_, let level) = ring, level != .normal { NSColor(Color.usage(level)) } else { nil }
        let side: CGFloat = 18
        let number = count.map { "\($0)" }
        let numberStart = side + 4
        let numberWidth = number.map {
            ceil(NSAttributedString(string: $0, attributes: [.font: Self.numberFont]).size().width)
        }
        let size = NSSize(width: numberWidth.map { numberStart + $0 } ?? side, height: side)
        let picture = NSImage(size: size, flipped: false) { @Sendable _ in
            let ink = NSColor.textColor
            let center = NSPoint(x: side / 2, y: side / 2)
            let radius: CGFloat = 6.6
            let lineWidth: CGFloat = 2.2
            let track = NSBezierPath()
            track.lineWidth = lineWidth
            track.appendArc(
                withCenter: center, radius: radius, startAngle: 360, endAngle: 0,
                clockwise: true)  // clockwise, as SVG strokes a circle, so the dashes fall where the design has them
            switch ring {
            case .none:
                track.setLineDash([2.3, 2.5], count: 2, phase: 0)
                ink.withAlphaComponent(0.6).setStroke()
                track.stroke()
            case .used(let share, _):
                ink.withAlphaComponent(0.28).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arc.appendArc(
                    withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * min(1, max(0, share)),
                    clockwise: true)
                (tone ?? ink).setStroke()
                arc.stroke()
            }
            if let number, let numberWidth {
                let font = Self.numberFont
                NSAttributedString(
                    string: number,
                    attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(dimmed ? 0.55 : 1)]
                ).draw(
                    with: NSRect(x: numberStart, y: center.y - font.capHeight / 2, width: numberWidth, height: 0),
                    options: [], context: nil)
            }
            return true
        }
        picture.isTemplate = tone == nil  // the menu bar inks a template itself; a colored ring brings its own ink
        item.button?.image = picture
    }

    @objc private func clicked() {
        Task { onClick() }  // one turn later: the button first ends its own click, which clears any highlight
    }

    private nonisolated static var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .semibold) }
}
