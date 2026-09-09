import Foundation

// Quake-style drop-down terminal (founder ask 2026-09-09: "the old school
// terminal in quake2 … really nice to hide the terminal when needed"). Pure
// geometry: where the panel sits on a screen for a given edge / size /
// alignment, and where it parks while hidden so the show/hide is a slide.
// The AppKit presenter (DropdownPresenter) only animates between the two.
public enum DropdownLayout {
    public enum Edge: String, CaseIterable {
        case top, left, right
    }

    /// Horizontal placement along the top edge (side edges ignore it).
    public enum Align: String, CaseIterable {
        case left, center, right
    }

    public static let sizeRange = 0.2...1.0

    /// The panel's on-screen frame. `width` / `height` are fractions of the
    /// screen's visible frame (clamped to sizeRange). Top-edge panels hang
    /// from the top; side panels hug their edge, top-aligned.
    public static func targetFrame(screen: CGRect, edge: Edge, width: Double,
                                   height: Double, align: Align) -> CGRect {
        let w = (screen.width * clamp(width)).rounded()
        let h = (screen.height * clamp(height)).rounded()
        switch edge {
        case .top:
            let x: CGFloat
            switch align {
            case .left: x = screen.minX
            case .center: x = (screen.midX - w / 2).rounded()
            case .right: x = screen.maxX - w
            }
            return CGRect(x: x, y: screen.maxY - h, width: w, height: h)
        case .left:
            return CGRect(x: screen.minX, y: screen.maxY - h, width: w, height: h)
        case .right:
            return CGRect(x: screen.maxX - w, y: screen.maxY - h, width: w, height: h)
        }
    }

    /// Where the panel sits fully off its edge — the start of the slide-in
    /// and the end of the slide-out.
    public static func hiddenFrame(target: CGRect, screen: CGRect, edge: Edge) -> CGRect {
        switch edge {
        case .top: return target.offsetBy(dx: 0, dy: target.height)
        case .left: return target.offsetBy(dx: -target.width, dy: 0)
        case .right: return target.offsetBy(dx: target.width, dy: 0)
        }
    }

    public static func clamp(_ fraction: Double) -> Double {
        min(max(fraction, sizeRange.lowerBound), sizeRange.upperBound)
    }
}
