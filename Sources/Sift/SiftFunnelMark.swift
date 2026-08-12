import SwiftUI

/// A resolution-independent interpretation of the two-piece Sift funnel mark.
struct SiftFunnelMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 18
        let sy = rect.height / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()

        // Rounded filtering bowl.
        path.move(to: point(2.55, 2.75))
        path.addCurve(
            to: point(1.67, 4.10),
            control1: point(1.83, 2.75),
            control2: point(1.40, 3.43)
        )
        path.addCurve(
            to: point(6.31, 9.89),
            control1: point(2.49, 6.18),
            control2: point(4.45, 8.71)
        )
        path.addCurve(
            to: point(8.17, 10.42),
            control1: point(6.87, 10.24),
            control2: point(7.51, 10.42)
        )
        path.addLine(to: point(9.83, 10.42))
        path.addCurve(
            to: point(11.69, 9.89),
            control1: point(10.49, 10.42),
            control2: point(11.13, 10.24)
        )
        path.addCurve(
            to: point(16.33, 4.10),
            control1: point(13.55, 8.71),
            control2: point(15.51, 6.18)
        )
        path.addCurve(
            to: point(15.45, 2.75),
            control1: point(16.60, 3.43),
            control2: point(16.17, 2.75)
        )
        path.closeSubpath()

        // Separate tapered stem; the gap is part of the brand mark.
        path.move(to: point(6.18, 10.98))
        path.addLine(to: point(11.82, 10.98))
        path.addCurve(
            to: point(10.84, 12.28),
            control1: point(11.45, 11.48),
            control2: point(11.08, 11.96)
        )
        path.addLine(to: point(10.06, 15.32))
        path.addCurve(
            to: point(9.0, 16.25),
            control1: point(9.99, 15.89),
            control2: point(9.58, 16.25)
        )
        path.addCurve(
            to: point(7.94, 15.32),
            control1: point(8.42, 16.25),
            control2: point(8.01, 15.89)
        )
        path.addLine(to: point(7.16, 12.28))
        path.addCurve(
            to: point(6.18, 10.98),
            control1: point(6.92, 11.96),
            control2: point(6.55, 11.48)
        )
        path.closeSubpath()

        return path
    }
}
