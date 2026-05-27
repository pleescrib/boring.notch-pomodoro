//
//  PomodoroBezelBar.swift
//  boringNotch
//

import SwiftUI

/// A two-tone glowing progress bar that traces around the outside edge of the notch.
/// The bright glowing segment represents time remaining; the dim segment is elapsed.
struct PomodoroBezelBar: View {
    /// Fraction of time remaining: 1.0 = full/just started, 0.0 = done.
    let progress: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let bottomCornerRadius: CGFloat

    private let barThickness: CGFloat = 3

    var body: some View {
        ZStack {
            // Elapsed (dim, flat) — full path in low-opacity accent color
            NotchOutlineShape(cornerRadius: bottomCornerRadius)
                .stroke(
                    Color.effectiveAccent.opacity(0.18),
                    style: StrokeStyle(lineWidth: barThickness, lineCap: .round)
                )

            // Remaining (bright, glowing) — trimmed from the end of the path
            if progress > 0.001 {
                NotchOutlineShape(cornerRadius: bottomCornerRadius)
                    .trim(from: max(0, 1.0 - progress), to: 1.0)
                    .stroke(
                        Color.effectiveAccent,
                        style: StrokeStyle(lineWidth: barThickness, lineCap: .round)
                    )
                    // Inner glow
                    .shadow(color: Color.effectiveAccent.opacity(0.9), radius: 3)
                    // Outer glow
                    .shadow(color: Color.effectiveAccent.opacity(0.5), radius: 7)
                    // Wide ambient glow
                    .shadow(color: Color.effectiveAccent.opacity(0.25), radius: 14)
            }
        }
        .frame(width: notchWidth, height: notchHeight)
        .allowsHitTesting(false)
    }
}

/// U-shaped path tracing the left, bottom, and right edges of the notch rectangle.
/// Starts at top-left, ends at top-right. The top edge is omitted (it's flush against the screen).
struct NotchOutlineShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, rect.height / 2, rect.width / 2)

        // Top-left → down left side → bottom-left arc → along bottom → bottom-right arc → up right side → top-right
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        return path
    }
}
