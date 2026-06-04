import SwiftUI

struct StarfieldView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                drawStars(context: &context, size: size, time: t)
                drawPlanets(context: &context, size: size, time: t)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawStars(context: inout GraphicsContext, size: CGSize, time: Double) {
        let count = 48
        for i in 0..<count {
            let seed = Double(i * 97)
            let x = (sin(seed) * 0.5 + 0.5) * size.width
            let y = (cos(seed * 1.3) * 0.5 + 0.5) * size.height
            let twinkle = 0.35 + 0.65 * abs(sin(time * 1.2 + seed))
            let r = CGFloat(1 + (i % 3))
            let path = Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r))
            context.fill(path, with: .color(.white.opacity(twinkle * 0.85)))
        }
    }

    private func drawPlanets(context: inout GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width * 0.72, y: size.height * 0.28)
        let orbitR: CGFloat = 56
        let angle = time * 0.35
        let px = center.x + cos(angle) * orbitR
        let py = center.y + sin(angle) * orbitR * 0.55
        let planet = Path(ellipseIn: CGRect(x: px - 10, y: py - 10, width: 20, height: 20))
        context.fill(planet, with: .color(AppTheme.starAccentPrimary.opacity(0.75)))

        let angle2 = time * 0.22 + 2
        let px2 = size.width * 0.22 + cos(angle2) * 40
        let py2 = size.height * 0.62 + sin(angle2) * 28
        let moon = Path(ellipseIn: CGRect(x: px2 - 6, y: py2 - 6, width: 12, height: 12))
        context.fill(moon, with: .color(AppTheme.starAccentSecondary.opacity(0.55)))
    }
}
