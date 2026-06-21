import SwiftUI
import CuwatchCore

/// 48pt mini replica of the menu bar dial, used in the popover header to
/// confirm "this number you're reading IS what's in the menu bar."
///
/// Uses the same `DialModel` math as the NSView, but renders in SwiftUI for
/// consistency with the rest of the popover.
struct MiniDialView: View {

    let fraction: Double
    let colorState: DialColorState
    let palette: Palette

    private var model: DialModel {
        DialModel(fraction: fraction, state: colorState, appearance: .darkMenuBar)
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let inset: CGFloat = 4
            let radius = (min(size.width, size.height) / 2) - inset
            let arcStart = CGFloat(DialModel.arcStartDegrees * .pi / 180)
            let arcEnd = CGFloat(DialModel.arcEndDegrees * .pi / 180)
            let tickAng = CGFloat(DialModel.tickAngleRadians)

            // SwiftUI Canvas uses a flipped y-axis (origin top-left, y down).
            // Mirror angle math accordingly.
            func point(angle: CGFloat, radius: CGFloat) -> CGPoint {
                CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y - sin(angle) * radius
                )
            }

            // ---- Arc ----
            var arcPath = Path()
            arcPath.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(-arcStart),
                endAngle: .radians(-arcEnd),
                clockwise: false
            )
            context.stroke(
                arcPath,
                with: .color(arcStrokeColor),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )

            // ---- Tick (75% redline) ----
            var tickPath = Path()
            tickPath.move(to: point(angle: tickAng, radius: radius - 4))
            tickPath.addLine(to: point(angle: tickAng, radius: radius + 1))
            context.stroke(
                tickPath,
                with: .color(tickStrokeColor),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )

            // ---- Needle ----
            let needleAng = CGFloat(model.needleAngleRadians)
            var needlePath = Path()
            needlePath.move(to: center)
            needlePath.addLine(to: point(angle: needleAng, radius: radius - 3))
            context.stroke(
                needlePath,
                with: .color(needleStrokeColor),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )

            // ---- Center cap ----
            let capRadius: CGFloat = 3.5
            let capRect = CGRect(
                x: center.x - capRadius,
                y: center.y - capRadius,
                width: capRadius * 2,
                height: capRadius * 2
            )
            context.fill(Path(ellipseIn: capRect), with: .color(palette.surface))
            context.stroke(Path(ellipseIn: capRect), with: .color(arcStrokeColor), lineWidth: 1.2)
        }
        .frame(width: Tokens.Layout.dialBigSize, height: Tokens.Layout.dialBigSize)
        .animation(.easeOut(duration: Tokens.Motion.needleSettle), value: fraction)
    }

    // MARK: - Color helpers

    private var arcStrokeColor: SwiftUI.Color {
        // Same logic as DialModel.arcColor but routed through the palette so
        // light / dark switches without recomputing the model.
        switch colorState {
        case .neutralGrey: return palette.inkDim
        case .brass, .burntOrange: return palette.inkMute
        case .oxidizedRed: return palette.danger
        }
    }

    private var needleStrokeColor: SwiftUI.Color {
        switch colorState {
        case .neutralGrey: return palette.inkMute
        case .brass, .burntOrange: return palette.ink
        case .oxidizedRed: return palette.danger
        }
    }

    private var tickStrokeColor: SwiftUI.Color {
        palette.brass
    }
}
