import SwiftUI

struct WorldMapCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

enum WorldMapLocationResolver {
    static func coordinate(for statistics: TunnelStatistics) -> WorldMapCoordinate? {
        if let latitude = statistics.connectedLatitude,
           let longitude = statistics.connectedLongitude,
           (-90...90).contains(latitude),
           (-180...180).contains(longitude) {
            return WorldMapCoordinate(latitude: latitude, longitude: longitude)
        }

        let candidates = [
            statistics.connectedCountryCode,
            statistics.connectedServerRegion,
            statistics.selectedRegion,
        ]
        for candidate in candidates {
            let code = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            if let coordinate = regionCentroids[code] { return coordinate }
        }
        return nil
    }

    static func originCoordinate(for statistics: TunnelStatistics) -> WorldMapCoordinate? {
        guard let latitude = statistics.originLatitude,
              let longitude = statistics.originLongitude,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return nil }
        return WorldMapCoordinate(latitude: latitude, longitude: longitude)
    }

    /// Offline fallback for every region currently exposed by the app.
    private static let regionCentroids: [String: WorldMapCoordinate] = [
        "US": .init(latitude: 39.8, longitude: -98.6),
        "CA": .init(latitude: 56.1, longitude: -106.3),
        "GB": .init(latitude: 54.4, longitude: -2.5),
        "DE": .init(latitude: 51.2, longitude: 10.4),
        "FR": .init(latitude: 46.2, longitude: 2.2),
        "NL": .init(latitude: 52.1, longitude: 5.3),
        "CH": .init(latitude: 46.8, longitude: 8.2),
        "SE": .init(latitude: 60.1, longitude: 18.6),
        "JP": .init(latitude: 36.2, longitude: 138.3),
        "SG": .init(latitude: 1.35, longitude: 103.8),
        "AU": .init(latitude: -25.3, longitude: 133.8),
        "IR": .init(latitude: 32.4, longitude: 53.7),
        "AE": .init(latitude: 23.4, longitude: 53.8),
        "IN": .init(latitude: 20.6, longitude: 79.0),
        "BR": .init(latitude: -14.2, longitude: -51.9),
        "ZA": .init(latitude: -30.6, longitude: 22.9),
    ]
}

/// Fixed, privacy-friendly vector backdrop. It never downloads map tiles; only
/// the already-fetched IP coordinates control the route and illuminated markers.
struct VPNWorldMapBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let originCoordinate: WorldMapCoordinate?
    let destinationCoordinate: WorldMapCoordinate?
    let originCountryCode: String?
    let destinationCountryCode: String?
    let isConnected: Bool

    var body: some View {
        GeometryReader { proxy in
            let mapRect = Self.mapRect(in: proxy.size)
            ZStack {
                Canvas { context, _ in
                    drawDottedMap(in: &context, rect: mapRect)
                }

                if isConnected,
                   let originCoordinate,
                   let destinationCoordinate {
                    animatedRoute(
                        from: Self.project(originCoordinate, into: mapRect),
                        to: Self.project(destinationCoordinate, into: mapRect)
                    )
                }

                if let originCoordinate {
                    let point = Self.project(originCoordinate, into: mapRect)
                    originMarker
                        .position(point)
                        .transition(.scale.combined(with: .opacity))
                    if let flag = Self.flagEmoji(for: originCountryCode) {
                        flagBadge(flag)
                            .position(x: point.x, y: point.y - 19)
                            .transition(.opacity.combined(with: .scale))
                    }
                }

                if isConnected, let destinationCoordinate {
                    let point = Self.project(destinationCoordinate, into: mapRect)
                    destinationMarker
                        .position(point)
                        .transition(.scale.combined(with: .opacity))
                    if let flag = Self.flagEmoji(for: destinationCountryCode) {
                        flagBadge(flag)
                            .position(x: point.x, y: point.y - 28)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.45), value: originCoordinate)
        .animation(.easeInOut(duration: 0.45), value: destinationCoordinate)
        .animation(.easeInOut(duration: 0.35), value: isConnected)
    }

    private var markerBlue: Color {
        colorScheme == .dark
            ? Color(red: 0.20, green: 0.82, blue: 1.0)
            : Color(red: 0.0, green: 0.46, blue: 0.92)
    }

    private var originMarker: some View {
        ZStack {
            Circle()
                .fill(markerBlue.opacity(0.18))
                .frame(width: 24, height: 24)
            Circle()
                .fill(markerBlue)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: markerBlue.opacity(0.75), radius: 6)
        }
        .frame(width: 34, height: 34)
    }

    private var destinationMarker: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.8) / 1.8)
            ZStack {
                Circle()
                    .stroke(markerBlue.opacity(0.75 * Double(1 - phase)), lineWidth: 2)
                    .frame(width: 16 + (44 * phase), height: 16 + (44 * phase))
                Circle()
                    .fill(markerBlue.opacity(0.24))
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(markerBlue, lineWidth: 3))
                    .shadow(color: markerBlue.opacity(0.95), radius: 10)
            }
            .frame(width: 64, height: 64)
        }
        .frame(width: 64, height: 64)
    }

    private func flagBadge(_ flag: String) -> some View {
        Text(flag)
            .font(.system(size: 16))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.76))
            )
            .overlay(
                Capsule()
                    .stroke(markerBlue.opacity(0.35), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.13), radius: 2, y: 1)
    }

    private func animatedRoute(from start: CGPoint, to end: CGPoint) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let dashPhase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.4) / 1.4) * -28
            Canvas { context, _ in
                let route = Self.routePath(from: start, to: end)
                context.stroke(
                    route,
                    with: .color(markerBlue.opacity(colorScheme == .dark ? 0.26 : 0.18)),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                context.stroke(
                    route,
                    with: .color(markerBlue.opacity(0.92)),
                    style: StrokeStyle(
                        lineWidth: 2.2,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [7, 7],
                        dashPhase: dashPhase
                    )
                )
            }
        }
        .transition(.opacity)
    }

    private func drawDottedMap(in context: inout GraphicsContext, rect: CGRect) {
        let dotColor = colorScheme == .dark
            ? Color(red: 0.20, green: 0.72, blue: 1.0).opacity(0.58)
            : Color(red: 0.0, green: 0.42, blue: 0.88).opacity(0.42)
        let landPaths = Self.landmasses.compactMap { Self.path(for: $0, in: rect) }
        let spacing = max(6.5, rect.width / 58)
        let diameter = max(2.6, rect.width / 130)
        var row = 0
        var y = rect.minY

        while y <= rect.maxY {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : spacing / 2)
            while x <= rect.maxX {
                let point = CGPoint(x: x, y: y)
                if landPaths.contains(where: { $0.contains(point) }) {
                    let dotRect = CGRect(
                        x: x - diameter / 2,
                        y: y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
                }
                x += spacing
            }
            row += 1
            y += spacing
        }
    }

    private static func path(
        for landmass: [WorldMapCoordinate],
        in rect: CGRect
    ) -> Path? {
        guard let first = landmass.first else { return nil }
        var path = Path()
        path.move(to: project(first, into: rect))
        for coordinate in landmass.dropFirst() {
            path.addLine(to: project(coordinate, into: rect))
        }
        path.closeSubpath()
        return path
    }

    private static func mapRect(in size: CGSize) -> CGRect {
        let width = size.width * 1.08
        let height = width * 0.53
        // Keep the map below the compact status card, in the intentional gap
        // before the power control. Smaller screens still clamp it on-screen.
        let preferredTop = max(152, size.height * 0.27)
        let maximumTop = max(128, size.height - height - 90)
        let y = min(preferredTop, maximumTop)
        return CGRect(x: (size.width - width) / 2, y: y, width: width, height: height)
    }

    private static func project(_ coordinate: WorldMapCoordinate, into rect: CGRect) -> CGPoint {
        let longitude = min(180, max(-180, coordinate.longitude))
        let latitude = min(90, max(-90, coordinate.latitude))
        let normalizedX = CGFloat((longitude + 180) / 360)
        let normalizedY = CGFloat((90 - latitude) / 180)
        return CGPoint(
            x: rect.minX + (normalizedX * rect.width),
            y: rect.minY + (normalizedY * rect.height)
        )
    }

    private static func routePath(from start: CGPoint, to end: CGPoint) -> Path {
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let lift = min(90, max(24, distance * 0.28))
        let control = CGPoint(x: midpoint.x, y: midpoint.y - lift)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    private static func flagEmoji(for countryCode: String?) -> String? {
        let normalized = countryCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard normalized.count == 2,
              normalized.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
            return nil
        }

        var flag = ""
        for scalar in normalized.unicodeScalars {
            guard let regionalIndicator = UnicodeScalar(scalar.value + 127_397) else {
                return nil
            }
            flag.unicodeScalars.append(regionalIndicator)
        }
        return flag
    }

    private static let landmasses: [[WorldMapCoordinate]] = [
        // North America
        [
            .init(latitude: 72, longitude: -168), .init(latitude: 72, longitude: -145),
            .init(latitude: 77, longitude: -122), .init(latitude: 72, longitude: -95),
            .init(latitude: 65, longitude: -72), .init(latitude: 52, longitude: -55),
            .init(latitude: 45, longitude: -66), .init(latitude: 25, longitude: -80),
            .init(latitude: 17, longitude: -88), .init(latitude: 20, longitude: -105),
            .init(latitude: 32, longitude: -117), .init(latitude: 50, longitude: -128),
            .init(latitude: 60, longitude: -142),
        ],
        // Greenland
        [
            .init(latitude: 82, longitude: -58), .init(latitude: 82, longitude: -24),
            .init(latitude: 72, longitude: -18), .init(latitude: 60, longitude: -43),
            .init(latitude: 62, longitude: -58), .init(latitude: 73, longitude: -68),
        ],
        // Central America
        [
            .init(latitude: 21, longitude: -105), .init(latitude: 18, longitude: -87),
            .init(latitude: 9, longitude: -77), .init(latitude: 7, longitude: -82),
            .init(latitude: 14, longitude: -92),
        ],
        // South America
        [
            .init(latitude: 12, longitude: -81), .init(latitude: 9, longitude: -65),
            .init(latitude: 4, longitude: -50), .init(latitude: -8, longitude: -35),
            .init(latitude: -24, longitude: -43), .init(latitude: -37, longitude: -55),
            .init(latitude: -55, longitude: -68), .init(latitude: -39, longitude: -74),
            .init(latitude: -17, longitude: -77),
        ],
        // Europe
        [
            .init(latitude: 36, longitude: -11), .init(latitude: 44, longitude: 2),
            .init(latitude: 55, longitude: -7), .init(latitude: 71, longitude: 12),
            .init(latitude: 69, longitude: 31), .init(latitude: 55, longitude: 40),
            .init(latitude: 45, longitude: 31), .init(latitude: 36, longitude: 22),
            .init(latitude: 40, longitude: 8),
        ],
        // Africa
        [
            .init(latitude: 36, longitude: -17), .init(latitude: 37, longitude: 11),
            .init(latitude: 30, longitude: 33), .init(latitude: 12, longitude: 51),
            .init(latitude: -12, longitude: 43), .init(latitude: -34, longitude: 31),
            .init(latitude: -35, longitude: 17), .init(latitude: -20, longitude: 2),
            .init(latitude: 5, longitude: -10),
        ],
        // Asia
        [
            .init(latitude: 45, longitude: 30), .init(latitude: 61, longitude: 39),
            .init(latitude: 76, longitude: 71), .init(latitude: 72, longitude: 112),
            .init(latitude: 62, longitude: 147), .init(latitude: 50, longitude: 179),
            .init(latitude: 39, longitude: 145), .init(latitude: 20, longitude: 124),
            .init(latitude: 5, longitude: 106), .init(latitude: 8, longitude: 91),
            .init(latitude: 22, longitude: 78), .init(latitude: 13, longitude: 68),
            .init(latitude: 28, longitude: 53), .init(latitude: 39, longitude: 42),
        ],
        // Japan
        [
            .init(latitude: 46, longitude: 141), .init(latitude: 42, longitude: 146),
            .init(latitude: 31, longitude: 132), .init(latitude: 34, longitude: 129),
            .init(latitude: 40, longitude: 137),
        ],
        // Southeast Asian islands
        [
            .init(latitude: 7, longitude: 96), .init(latitude: 6, longitude: 119),
            .init(latitude: -10, longitude: 141), .init(latitude: -11, longitude: 112),
            .init(latitude: -4, longitude: 100),
        ],
        // Australia
        [
            .init(latitude: -11, longitude: 112), .init(latitude: -12, longitude: 154),
            .init(latitude: -38, longitude: 153), .init(latitude: -44, longitude: 130),
            .init(latitude: -31, longitude: 113),
        ],
        // New Zealand
        [
            .init(latitude: -34, longitude: 172), .init(latitude: -41, longitude: 178),
            .init(latitude: -47, longitude: 168), .init(latitude: -40, longitude: 166),
        ],
    ]
}
