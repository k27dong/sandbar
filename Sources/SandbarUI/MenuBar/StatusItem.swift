import AppKit
import SwiftUI

package final class StatusItem {
    package enum Ring: Equatable {
        case none
        case used(Double)
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onClick: () -> Void

    package init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        item.button?.target = self
        item.button?.action = #selector(clicked)
    }

    package var button: NSStatusBarButton? { item.button }

    package var isHighlighted: Bool {
        get { item.button?.isHighlighted ?? false }
        set { item.button?.highlight(newValue) }
    }

    package func show(ring: Ring, count: Int, dimmed: Bool) {
        let tone: NSColor? =
            if case .used(let share) = ring, share >= 0.8 {
                NSColor(share >= 1 ? Color.usageCritical : .usageWarning)
            } else {
                nil
            }
        let number = "\(count)"
        let side: CGFloat = 18
        let numberStart = side + 4
        let numberWidth = ceil(NSAttributedString(string: number, attributes: [.font: Self.numberFont]).size().width)
        let size = NSSize(width: numberStart + numberWidth, height: side)
        let picture = NSImage(size: size, flipped: false) { @Sendable _ in
            let ink = NSColor.textColor
            let center = NSPoint(x: side / 2, y: side / 2)
            let track = NSBezierPath()
            track.lineWidth = 2.2
            track.appendArc(
                withCenter: center, radius: 6.6, startAngle: 360, endAngle: 0,
                clockwise: true)  // from 3 o'clock, so the dashes fall where the design draws them
            switch ring {
            case .none:
                track.setLineDash([2.3, 2.5], count: 2, phase: 0)
                ink.withAlphaComponent(0.6).setStroke()
                track.stroke()
            case .used(let share):
                ink.withAlphaComponent(0.28).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                arc.appendArc(
                    withCenter: center, radius: 6.6, startAngle: 90, endAngle: 90 - 360 * min(1, max(0, share)),
                    clockwise: true)
                (tone ?? ink).setStroke()
                arc.stroke()
            }
            let font = Self.numberFont
            NSAttributedString(
                string: number,
                attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(dimmed ? 0.55 : 1)]
            ).draw(
                with: NSRect(x: numberStart, y: center.y - font.capHeight / 2, width: numberWidth, height: 0),
                options: [], context: nil)
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
