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
    var isConnecting = false

    var body: some View {
        GeometryReader { proxy in
            let mapRect = Self.mapRect(in: proxy.size)
            let origin = originCoordinate.map { Self.project($0, into: mapRect) }
            let destination = isConnected ? destinationCoordinate.map { Self.project($0, into: mapRect) } : nil
            ZStack {
                Canvas { context, _ in
                    drawGraticule(in: &context, rect: mapRect)
                    drawLand(in: &context, rect: mapRect, origin: origin, destination: destination)
                }
                .mask(edgeFade)

                if let origin, let destination {
                    WorldMapRoute(start: origin, end: destination, startColor: originTint, endColor: accent)
                        .transition(.opacity)
                }

                if let origin {
                    WorldMapOriginMarker(tint: originTint, isSearching: isConnecting && !isConnected)
                        .position(origin)
                        .transition(.scale.combined(with: .opacity))
                    if let label = Self.label(for: originCountryCode) {
                        WorldMapLabel(flag: label.flag, code: label.code, tint: originTint)
                            .position(x: origin.x, y: origin.y - 24)
                            .transition(.opacity)
                    }
                }

                if let destination {
                    WorldMapDestinationMarker(tint: accent)
                        .position(destination)
                        .transition(.scale.combined(with: .opacity))
                    if let label = Self.label(for: destinationCountryCode) {
                        WorldMapLabel(flag: label.flag, code: label.code, tint: accent)
                            .position(x: destination.x, y: destination.y - 26)
                            .transition(.opacity)
                    }
                }
            }
        }
        // Geography is not text: `.position` mirrors under RTL (Persian), which put
        // markers on the wrong continent, so the map always lays out left-to-right.
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.45), value: originCoordinate)
        .animation(.easeInOut(duration: 0.45), value: destinationCoordinate)
        .animation(.easeInOut(duration: 0.35), value: isConnected)
    }

    // MARK: Palette

    private var accent: Color { AppTheme.iranGreenBright }

    private var originTint: Color {
        colorScheme == .dark
            ? Color(red: 0.86, green: 0.90, blue: 0.96)
            : Color(red: 0.24, green: 0.30, blue: 0.40)
    }

    private var dotColor: Color {
        colorScheme == .dark
            ? Color(red: 0.66, green: 0.76, blue: 0.90).opacity(0.36)
            : Color(red: 0.28, green: 0.34, blue: 0.44).opacity(0.30)
    }

    private var gridColor: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.06)
    }

    /// Soft vignette so the dot field dissolves into the background instead of ending in hard edges.
    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.10),
                .init(color: .black, location: 0.90),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: Drawing

    private func drawGraticule(in context: inout GraphicsContext, rect: CGRect) {
        var grid = Path()
        for longitude in stride(from: -150.0, through: 150.0, by: 30.0) {
            let x = Self.project(.init(latitude: 0, longitude: longitude), into: rect).x
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for latitude in [-30.0, 0.0, 30.0, 60.0] {
            let y = Self.project(.init(latitude: latitude, longitude: 0), into: rect).y
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(grid, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.6, dash: [1.5, 4]))
    }

    private func drawLand(
        in context: inout GraphicsContext,
        rect: CGRect,
        origin: CGPoint?,
        destination: CGPoint?
    ) {
        let columns = WorldLandMask.columns
        let rows = WorldLandMask.rows
        let spacingX = rect.width / CGFloat(columns)
        let spacingY = rect.height / CGFloat(rows)
        let diameter = min(spacingX, spacingY) * 0.54
        let glowRadius = spacingX * 9

        var base = Path()
        var originGlow: [(CGRect, Double)] = []
        var destinationGlow: [(CGRect, Double)] = []

        for row in 0..<rows {
            let offset = row.isMultiple(of: 2) ? 0 : 0.5
            for column in 0..<columns where WorldLandMask.isLand(row: row, column: column) {
                let center = CGPoint(
                    x: rect.minX + (CGFloat(column) + 0.5 + offset) * spacingX,
                    y: rect.minY + (CGFloat(row) + 0.5) * spacingY
                )
                let dot = CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                if let destination, let weight = Self.glowWeight(center, destination, radius: glowRadius) {
                    destinationGlow.append((dot, weight))
                } else if let origin, let weight = Self.glowWeight(center, origin, radius: glowRadius * 0.8) {
                    originGlow.append((dot, weight))
                } else {
                    base.addEllipse(in: dot)
                }
            }
        }

        context.fill(base, with: .color(dotColor))
        for (dot, weight) in originGlow {
            context.fill(Path(ellipseIn: dot), with: .color(originTint.opacity(0.22 + 0.5 * weight)))
        }
        for (dot, weight) in destinationGlow {
            let grown = dot.insetBy(dx: -dot.width * 0.25 * weight, dy: -dot.height * 0.25 * weight)
            context.fill(Path(ellipseIn: grown), with: .color(accent.opacity(0.22 + 0.68 * weight)))
        }
    }

    private static func glowWeight(_ point: CGPoint, _ center: CGPoint, radius: CGFloat) -> Double? {
        let distance = hypot(point.x - center.x, point.y - center.y)
        guard distance < radius else { return nil }
        let t = Double(1 - distance / radius)
        return t * t
    }

    // MARK: Geometry

    /// The map is the dashboard's hero: centered in whatever frame the caller
    /// gives it, slightly wider than the screen, and shrunk to fit short frames.
    private static func mapRect(in size: CGSize) -> CGRect {
        let aspect = MillerProjection.aspect
        var width = size.width * 1.12
        if width * aspect > size.height * 0.94 {
            width = size.height * 0.94 / aspect
        }
        let height = width * aspect
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    private static func project(_ coordinate: WorldMapCoordinate, into rect: CGRect) -> CGPoint {
        let normalized = MillerProjection.normalized(coordinate)
        return CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }

    private static func label(for countryCode: String?) -> (flag: String, code: String)? {
        guard let flag = flagEmoji(for: countryCode), let countryCode else { return nil }
        return (flag, countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    static func flagEmoji(for countryCode: String?) -> String? {
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
}

// MARK: - Route and markers

private struct WorldMapRoute: View {
    let start: CGPoint
    let end: CGPoint
    let startColor: Color
    let endColor: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let cycle = 2.4
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let progress = CGFloat(elapsed.truncatingRemainder(dividingBy: cycle) / cycle)
            Canvas { context, _ in
                let route = Self.arc(from: start, to: end)
                let gradient = Gradient(colors: [startColor, endColor])
                var glow = context
                glow.opacity = 0.18
                glow.stroke(
                    route,
                    with: .linearGradient(gradient, startPoint: start, endPoint: end),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                var core = context
                core.opacity = 0.9
                core.stroke(
                    route,
                    with: .linearGradient(gradient, startPoint: start, endPoint: end),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )

                // Comet: a bright head travelling origin → destination with a fading tail.
                let tailSegments = 14
                let segmentLength: CGFloat = 0.014
                for index in 0..<tailSegments {
                    let to = progress - CGFloat(index) * segmentLength
                    let from = to - segmentLength
                    guard to > 0 else { break }
                    let fade = 1 - Double(index) / Double(tailSegments)
                    context.stroke(
                        route.trimmedPath(from: max(0, from), to: to),
                        with: .color(endColor.opacity(0.85 * fade)),
                        style: StrokeStyle(lineWidth: 2.6 * fade + 0.6, lineCap: .round)
                    )
                }
                if progress > 0.002, let head = route.trimmedPath(from: 0, to: progress).currentPoint {
                    context.fill(
                        Path(ellipseIn: CGRect(x: head.x - 7, y: head.y - 7, width: 14, height: 14)),
                        with: .color(endColor.opacity(0.25))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: head.x - 2.6, y: head.y - 2.6, width: 5.2, height: 5.2)),
                        with: .color(.white)
                    )
                }
            }
        }
        .shadow(color: endColor.opacity(0.35), radius: 6)
    }

    static func arc(from start: CGPoint, to end: CGPoint) -> Path {
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let lift = min(110, max(26, distance * 0.32))
        let control = CGPoint(x: midpoint.x, y: midpoint.y - lift)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}

private struct WorldMapOriginMarker: View {
    let tint: Color
    let isSearching: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isSearching)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.6) / 1.6)
            ZStack {
                if isSearching {
                    ForEach(0..<2, id: \.self) { ring in
                        let local = (phase + CGFloat(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(tint.opacity(0.6 * Double(1 - local)), lineWidth: 1.2)
                            .frame(width: 10 + 54 * local, height: 10 + 54 * local)
                    }
                }
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 22, height: 22)
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(tint, lineWidth: 2))
                    .shadow(color: tint.opacity(0.5), radius: 4)
            }
            .frame(width: 70, height: 70)
        }
        .frame(width: 70, height: 70)
    }
}

private struct WorldMapDestinationMarker: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 2.0) / 2.0)
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.7 * Double(1 - phase)), lineWidth: 1.5)
                    .frame(width: 14 + 40 * phase, height: 14 + 40 * phase)
                Circle()
                    .fill(tint.opacity(0.22))
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(tint)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: tint.opacity(0.9), radius: 8)
            }
            .frame(width: 64, height: 64)
        }
        .frame(width: 64, height: 64)
    }
}

private struct WorldMapLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let flag: String
    let code: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(flag)
                .font(.system(size: 12))
            Text(code)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.75))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 3, y: 1)
    }
}

// MARK: - Projection and land data

/// Miller cylindrical projection, cropped to 80°N…58°S: less polar stretching than
/// Mercator and no Antarctica, which reads as a calmer, more "atlas" silhouette.
enum MillerProjection {
    static let northLatitude = 80.0
    static let southLatitude = -58.0

    private static func y(_ latitude: Double) -> Double {
        let phi = latitude * .pi / 180
        return 1.25 * log(tan(.pi / 4 + 0.4 * phi))
    }

    private static let yTop = y(northLatitude)
    private static let yBottom = y(southLatitude)

    static let aspect = CGFloat((yTop - yBottom) / (2 * .pi))

    static func normalized(_ coordinate: WorldMapCoordinate) -> CGPoint {
        let longitude = min(180, max(-180, coordinate.longitude))
        let latitude = min(northLatitude, max(southLatitude, coordinate.latitude))
        return CGPoint(
            x: CGFloat((longitude + 180) / 360),
            y: CGFloat((yTop - y(latitude)) / (yTop - yBottom))
        )
    }

    static func latitude(forNormalizedY normalizedY: Double) -> Double {
        let value = yTop - normalizedY * (yTop - yBottom)
        return (atan(exp(value / 1.25)) - .pi / 4) / 0.4 * 180 / .pi
    }
}

/// A precomputed dot-matrix land mask (hex-packed rows), built once from the
/// coastline outlines below so drawing is a cheap table lookup.
enum WorldLandMask {
    static let columns = 150
    static let rows = Int((CGFloat(columns) * MillerProjection.aspect).rounded())

    static func isLand(row: Int, column: Int) -> Bool {
        cells[row * columns + column]
    }

    private static let cells: [Bool] = {
        let path = CGMutablePath()
        for polygon in WorldCoastlines.land + WorldCoastlines.inlandSeas {
            guard let first = polygon.first else { continue }
            path.move(to: CGPoint(x: first.1, y: first.0))
            for point in polygon.dropFirst() {
                path.addLine(to: CGPoint(x: point.1, y: point.0))
            }
            path.closeSubpath()
        }
        var result = [Bool](repeating: false, count: rows * columns)
        for row in 0..<rows {
            let latitude = MillerProjection.latitude(forNormalizedY: (Double(row) + 0.5) / Double(rows))
            let offset = row.isMultiple(of: 2) ? 0 : 0.5
            for column in 0..<columns {
                let longitude = (Double(column) + 0.5 + offset) / Double(columns) * 360 - 180
                result[row * columns + column] = path.contains(
                    CGPoint(x: longitude, y: latitude),
                    using: .evenOdd
                )
            }
        }
        return result
    }()
}

/// Simplified coastlines as (latitude, longitude) rings. Inland seas are listed
/// separately and punched out with the even-odd rule.
private enum WorldCoastlines {
    static let land: [[(Double, Double)]] = [
        // North America
        [(65.5, -168), (68.9, -166), (70.5, -161), (71.3, -156.5), (70.6, -152), (70.1, -145), (69.6, -141),
         (69.4, -134), (69.6, -129), (70.2, -125), (69.0, -115), (68.3, -108), (68.0, -98), (68.8, -94),
         (69.5, -90), (67.5, -87), (66.5, -84), (64.5, -87), (62.0, -93), (58.8, -94.5), (57.0, -92.5),
         (55.0, -82.5), (52.0, -80.5), (54.5, -79.5), (58.0, -77), (60.5, -78), (62.5, -77.5), (62.2, -73.5),
         (60.0, -69.5), (58.5, -67.5), (60.3, -64.5), (57.5, -61.8), (55.0, -59.5), (52.5, -55.7), (51.5, -57),
         (50.2, -60.5), (50.0, -66), (49.2, -65), (47.5, -65.5), (46.0, -61.0), (45.0, -61.0), (44.5, -63.5),
         (43.6, -66), (44.8, -67), (43.5, -70.2), (42.0, -70.2), (41.6, -69.9), (41.3, -71.5), (40.6, -74),
         (39.0, -74.8), (38.0, -75.3), (36.9, -76), (35.2, -75.5), (34.0, -77.8), (32.5, -80.3), (31.0, -81.4),
         (29.5, -81.1), (27.0, -80.0), (25.2, -80.4), (25.9, -81.7), (27.8, -82.7), (29.8, -83.6), (30.1, -85.4),
         (30.4, -88), (29.3, -89.3), (29.6, -91.5), (29.7, -93.8), (28.6, -96.2), (26.0, -97.2), (23.5, -97.7),
         (21.5, -97.3), (19.5, -96.3), (18.6, -94.5), (18.2, -91.5), (19.0, -90.7), (21.2, -90.3), (21.5, -87.2),
         (18.5, -87.8), (16.0, -88.5), (15.8, -86), (15.0, -83.3), (11.0, -83.7), (9.6, -82.3), (9.2, -79.5),
         (8.6, -77.4), (7.2, -78.2), (8.2, -80.4), (7.5, -80.8), (8.1, -82.9), (9.6, -85.2), (11.1, -85.7),
         (12.5, -87.5), (13.3, -89.5), (14.5, -92.3), (15.7, -94.5), (16.2, -97.8), (17.6, -101.5), (19.3, -105),
         (21.0, -105.5), (23.0, -106.4), (25.5, -108.8), (28.0, -111.3), (31.0, -113.2), (31.7, -114.8),
         (30.0, -114.6), (27.5, -112.6), (24.7, -110.7), (22.9, -109.9), (24.5, -112.1), (27.0, -114.3),
         (30.0, -115.8), (32.5, -117.1), (34.0, -118.5), (34.5, -120.6), (36.6, -121.9), (38.0, -123),
         (40.4, -124.4), (43.0, -124.5), (46.2, -124), (48.4, -124.7), (49.5, -126.5), (51.0, -127.8),
         (54.0, -130.5), (56.5, -133.5), (58.4, -136.5), (59.5, -139.7), (60.1, -144), (60.9, -147.7),
         (59.4, -151.7), (57.5, -155), (55.5, -160), (54.7, -164.7), (57.0, -158.5), (58.6, -157), (58.8, -162),
         (60.4, -165), (62.5, -165.4), (64.5, -163.5), (64.5, -166.5)],
        // Baffin Island
        [(73.5, -80), (72.5, -71), (70.5, -68), (68.5, -66), (66.5, -62), (64.5, -64.5), (63.5, -65), (62.3, -70),
         (63.5, -72), (64.8, -75.5), (65.5, -74), (66.5, -73), (68.0, -74.5), (69.5, -78), (70.5, -80), (72.0, -82)],
        // Victoria and Banks Islands
        [(73.0, -115), (73.2, -106), (71.0, -104), (69.2, -101.5), (68.8, -106), (69.0, -113.5), (70.5, -117.5),
         (72.0, -118.5)],
        [(74.3, -124.5), (73.5, -115.5), (71.6, -117.5), (71.8, -125)],
        // Ellesmere and Devon Islands
        [(82.5, -80), (83.0, -65), (81.0, -62), (79.0, -74), (77.0, -80), (75.5, -80), (74.5, -90), (76.5, -90),
         (77.5, -96), (79.5, -93), (81.5, -90)],
        // Greenland
        [(83.5, -35), (82.0, -22), (80.5, -17.5), (78.0, -19), (75.5, -19), (72.5, -22), (70.5, -22), (68.5, -27),
         (66.0, -35), (65.0, -40), (62.0, -42), (60.0, -44), (61.0, -48.5), (64.0, -51.5), (66.5, -53.5),
         (69.0, -51), (70.5, -54.5), (72.5, -55.5), (75.0, -58.5), (76.5, -68), (77.8, -72.5), (79.5, -66),
         (81.0, -62), (82.3, -50)],
        // Newfoundland, Cuba, Hispaniola
        [(51.6, -55.5), (49.5, -53.5), (46.7, -53.0), (47.6, -59.3), (49.0, -58.5), (50.6, -57.4)],
        [(23.2, -84.9), (23.1, -82), (23.2, -80), (22.1, -77.5), (20.7, -74.2), (19.9, -75.5), (19.9, -77.7),
         (21.6, -79.8), (21.9, -82.5), (22.6, -84)],
        [(19.9, -73.4), (19.7, -70), (18.5, -68.4), (18.2, -71), (18.3, -74.4)],
        // South America
        [(12.4, -71.7), (11.0, -74.3), (9.5, -75.8), (8.6, -77.4), (7.2, -77.9), (4.0, -77.4), (1.5, -79),
         (-1.0, -80.5), (-2.5, -80), (-4.2, -81.3), (-6.0, -81.1), (-9.0, -79.0), (-12.5, -76.8), (-15.5, -75.0),
         (-18.5, -70.4), (-23.5, -70.5), (-27.5, -70.9), (-32.0, -71.5), (-37.0, -73.6), (-41.0, -73.9),
         (-44.0, -73.6), (-47.0, -75.5), (-50.0, -75.4), (-52.5, -74.5), (-54.0, -71.5), (-55.0, -68.5),
         (-54.8, -65.2), (-52.5, -68.4), (-50.5, -69.0), (-48.0, -65.8), (-46.0, -67.5), (-45.0, -65.7),
         (-42.5, -64.0), (-40.8, -62.3), (-38.8, -62.3), (-38.0, -57.6), (-36.3, -56.7), (-34.8, -57.0),
         (-34.4, -54.0), (-32.0, -52.1), (-28.5, -48.7), (-25.5, -48.4), (-23.0, -43.2), (-22.0, -41.0),
         (-18.0, -39.6), (-13.0, -38.5), (-10.0, -36.0), (-7.0, -34.8), (-5.0, -36.5), (-3.0, -40.0),
         (-2.5, -44.0), (-1.0, -48.5), (0.5, -50.0), (2.0, -50.8), (4.5, -51.7), (5.8, -54.5), (6.8, -58.3),
         (8.5, -60.0), (10.0, -61.8), (10.7, -63.5), (10.5, -66.0), (11.5, -68.5), (12.0, -70.2)],
        // Eurasia
        [(36.0, -5.6), (37.0, -8.9), (38.7, -9.5), (41.2, -8.7), (43.2, -9.3), (43.6, -6), (43.4, -2), (46.0, -1.2),
         (47.3, -2.5), (48.6, -4.7), (48.7, -1.5), (49.6, -1.3), (50.0, 1.5), (51.0, 2.5), (52.5, 4.6), (53.3, 6.0),
         (54.0, 8.5), (55.5, 8.1), (57.6, 10.4), (56.0, 10.9), (54.5, 10.9), (54.2, 13.5), (54.5, 18.5),
         (55.0, 21.0), (56.5, 21.0), (57.6, 21.6), (58.9, 23.4), (59.5, 25), (59.9, 29.5), (60.5, 27.5),
         (61.0, 21.5), (63.0, 21.3), (65.0, 24.5), (65.8, 23.5), (64.5, 21.3), (62.5, 17.5), (60.5, 17.3),
         (59.3, 18.5), (58.0, 16.6), (56.2, 16.0), (55.4, 13.0), (56.5, 12.6), (58.5, 11.3), (59.0, 10.5),
         (58.0, 8.0), (58.5, 5.6), (60.5, 5.0), (62.5, 6.0), (64.0, 9.5), (66.0, 12.5), (68.5, 15.0), (70.0, 19.5),
         (71.1, 25.8), (70.5, 30.5), (69.3, 33.0), (68.0, 39.0), (66.5, 40.5), (67.5, 41.0), (66.0, 43.5),
         (68.2, 44.0), (68.5, 46.5), (67.6, 53.0), (68.8, 57.0), (69.5, 60.5), (68.5, 68.0), (70.0, 66.7),
         (72.8, 69.5), (71.5, 72.5), (72.5, 74.5), (73.5, 80.0), (72.5, 83.0), (74.0, 86.5), (75.5, 89.0),
         (76.5, 96), (77.7, 104.3), (76.0, 112), (73.5, 113.5), (73.8, 118), (72.8, 126.5), (71.5, 128.5),
         (72.5, 140), (71.0, 152), (70.0, 160), (69.6, 167.5), (70.0, 170.5), (68.8, 180), (66.5, 180),
         (64.5, 177.5), (62.5, 179), (60.0, 170.5), (60.5, 163), (57.5, 163.0), (55.0, 162.0), (51.3, 156.6),
         (54.0, 155.5), (57.5, 156.5), (59.5, 159.5), (61.5, 160.5), (59.3, 154), (59.5, 149), (59.0, 143),
         (54.5, 137.5), (53.5, 141.4), (51.0, 140.5), (47.5, 138.8), (43.0, 132.0), (42.5, 130.7), (39.5, 127.5),
         (38.0, 128.6), (35.5, 129.4), (34.7, 127.0), (35.5, 126.4), (37.5, 126.6), (39.0, 125.2), (40.0, 124.3),
         (39.5, 121.5), (40.5, 122.3), (41.0, 121.0), (40.0, 119.5), (39.0, 117.8), (37.5, 119.0), (37.4, 122.6),
         (36.0, 120.5), (34.8, 119.5), (33.0, 120.9), (31.3, 121.9), (30.0, 122.0), (27.0, 120.2), (25.0, 119.0),
         (23.0, 116.5), (22.3, 114.0), (21.5, 111.0), (21.7, 108.5), (19.5, 105.8), (17.0, 107.2), (14.5, 109.2),
         (12.0, 109.2), (10.5, 107.5), (8.6, 104.8), (10.4, 104.4), (11.5, 103.0), (12.6, 101.0), (13.5, 100.2),
         (10.8, 99.3), (8.0, 100.4), (6.8, 100.4), (5.0, 103.4), (2.6, 103.8), (1.3, 104.1), (1.4, 103.4),
         (2.6, 101.4), (4.5, 100.5), (6.5, 99.7), (8.5, 98.3), (11.5, 98.7), (13.5, 98.2), (16.0, 97.6),
         (16.5, 94.4), (18.5, 94.3), (20.5, 92.8), (22.5, 91.8), (21.8, 89.5), (21.8, 87.0), (20.0, 86.6),
         (17.7, 83.5), (15.8, 81.1), (13.0, 80.3), (10.3, 79.8), (8.1, 77.5), (8.9, 76.5), (12.0, 74.8),
         (15.5, 73.8), (19.0, 72.8), (21.0, 72.7), (22.3, 70.0), (23.6, 68.4), (25.0, 66.6), (25.4, 61.6),
         (25.7, 58.0), (27.2, 56.3), (26.6, 54.5), (27.8, 51.5), (29.9, 48.6), (29.3, 48.0), (27.0, 50.0),
         (24.8, 51.6), (24.0, 53.5), (24.3, 54.6), (25.8, 56.3), (23.6, 58.7), (22.4, 59.8), (20.5, 58.5),
         (18.0, 56.5), (16.8, 53.2), (15.0, 50.0), (13.0, 45.0), (12.7, 43.5), (15.0, 42.7), (18.0, 41.2),
         (21.5, 39.1), (24.5, 37.5), (27.8, 35.2), (29.5, 34.9), (31.5, 34.3), (33.0, 35.1), (35.0, 35.9),
         (36.8, 36.2), (36.6, 34.0), (36.2, 30.5), (36.7, 28.0), (38.5, 26.5), (40.0, 26.2), (40.9, 26.0),
         (40.8, 24.0), (40.2, 23.7), (39.5, 22.9), (38.0, 23.5), (37.0, 22.8), (36.5, 22.5), (37.5, 21.6),
         (38.4, 21.2), (39.5, 20.2), (40.8, 19.4), (42.0, 19.2), (43.5, 16.0), (44.6, 14.5), (45.3, 13.6),
         (45.7, 13.8), (45.6, 12.3), (44.3, 12.4), (43.6, 13.5), (42.0, 15.5), (41.6, 16.1), (40.8, 17.2),
         (40.1, 18.5), (39.8, 16.6), (38.9, 17.1), (38.0, 16.0), (38.9, 15.8), (40.0, 15.6), (41.0, 13.6),
         (41.7, 12.4), (42.5, 11.0), (43.8, 10.2), (44.4, 8.8), (43.7, 7.2), (43.3, 5.3), (43.5, 3.4), (42.4, 3.2),
         (41.4, 2.2), (40.5, 0.6), (39.4, -0.3), (38.4, -0.4), (37.6, -0.7), (36.7, -2.2), (36.7, -4.4)],
        // Chukotka east of the antimeridian
        [(68.8, -180), (67.8, -174), (66.0, -169.8), (64.5, -172.5), (65.5, -180)],
        // Africa and Madagascar
        [(35.8, -5.9), (35.2, -2.0), (36.9, 3.0), (36.9, 8.6), (37.3, 10.2), (36.5, 11.1), (35.2, 11.0),
         (33.5, 10.5), (32.9, 12.6), (32.5, 15.3), (30.5, 19.0), (32.0, 20.1), (32.9, 22.5), (31.9, 25.0),
         (31.4, 27.3), (30.9, 29.6), (31.3, 32.3), (29.9, 32.6), (27.5, 33.6), (24.0, 35.6), (21.0, 37.2),
         (18.0, 38.6), (15.5, 39.6), (12.8, 43.2), (11.5, 43.5), (11.8, 51.2), (10.5, 51.0), (7.0, 49.5),
         (2.0, 45.5), (-1.5, 41.6), (-4.5, 39.5), (-7.0, 39.4), (-10.5, 40.4), (-15.0, 40.6), (-19.0, 35.4),
         (-21.5, 35.4), (-24.8, 35.0), (-26.0, 32.9), (-29.5, 31.2), (-32.5, 28.6), (-34.0, 25.5), (-34.4, 22.0),
         (-34.8, 20.0), (-34.2, 18.4), (-32.0, 18.2), (-28.6, 16.4), (-25.0, 14.6), (-20.5, 13.2), (-17.0, 11.8),
         (-12.5, 13.6), (-9.0, 13.0), (-6.0, 12.2), (-3.5, 10.8), (-1.0, 9.0), (1.5, 9.5), (4.0, 9.0), (4.3, 7.0),
         (6.4, 3.4), (5.9, 0.9), (4.8, -2.0), (5.1, -4.0), (4.4, -7.5), (6.3, -10.8), (7.5, -13.0), (9.5, -13.6),
         (11.0, -15.4), (12.5, -16.8), (14.7, -17.5), (16.5, -16.3), (19.5, -16.4), (21.0, -17.0), (23.5, -16.0),
         (26.5, -14.5), (28.0, -12.5), (29.5, -10.0), (31.5, -9.8), (33.5, -7.8)],
        [(-12.0, 49.3), (-15.5, 50.5), (-20.0, 48.9), (-25.0, 47.2), (-25.5, 45.0), (-21.5, 43.5), (-17.0, 44.2),
         (-15.5, 46.5), (-13.5, 48.0)],
        // European islands
        [(58.6, -3.0), (57.7, -1.8), (56.0, -2.6), (55.0, -1.5), (53.6, 0.1), (52.9, 1.6), (51.8, 1.3), (51.1, 1.4),
         (50.8, 0.1), (50.6, -2.0), (50.1, -5.6), (51.2, -4.5), (51.7, -5.2), (52.8, -4.5), (53.4, -3.0),
         (54.5, -3.6), (54.9, -5.0), (56.0, -5.6), (57.5, -5.8), (58.6, -5.0)],
        [(55.3, -7.3), (54.3, -5.6), (52.2, -6.4), (51.5, -9.6), (52.6, -9.9), (54.2, -10.1), (55.2, -8.3)],
        [(66.5, -22.5), (66.2, -15.0), (64.8, -13.5), (63.5, -18.5), (64.0, -22.5), (65.0, -24.0)],
        [(38.3, 12.4), (38.2, 15.6), (36.7, 15.1), (37.6, 12.4)],
        [(41.2, 9.2), (39.0, 9.6), (38.9, 8.4), (40.9, 8.2)],
        [(80.0, 10.6), (78.5, 12.0), (76.5, 16.5), (77.5, 22.0), (79.0, 22.5), (80.0, 27.0)],
        [(76.9, 68.5), (74.2, 58.5), (71.0, 52.3), (70.7, 57.3), (73.0, 57.0), (75.5, 64.0)],
        // East Asian islands
        [(41.5, 141.3), (40.0, 142.0), (38.3, 141.5), (36.0, 140.7), (35.0, 139.9), (34.6, 138.2), (33.5, 135.5),
         (33.3, 133.0), (31.0, 131.0), (31.3, 130.2), (33.5, 129.6), (34.4, 131.0), (35.5, 133.0), (36.0, 136.0),
         (37.4, 136.8), (37.8, 138.7), (39.8, 140.0), (41.2, 140.2)],
        [(45.5, 141.9), (44.0, 145.3), (43.0, 145.6), (42.0, 143.3), (41.6, 140.5), (43.0, 140.3)],
        [(54.3, 142.7), (51.5, 143.3), (46.0, 143.5), (46.2, 141.9), (50.0, 142.0), (53.0, 141.5)],
        [(25.3, 121.6), (22.0, 120.8), (23.0, 120.1), (24.7, 120.8)],
        [(20.1, 110.6), (18.3, 109.6), (19.4, 108.6)],
        [(9.8, 80.1), (7.0, 81.9), (6.0, 80.6), (7.7, 79.8)],
        [(18.5, 120.9), (16.0, 122.2), (13.8, 124.2), (13.3, 122.6), (14.4, 120.6), (16.4, 119.8)],
        [(9.8, 125.5), (7.0, 126.6), (5.6, 125.3), (6.9, 122.0), (8.5, 123.0)],
        // Maritime Southeast Asia
        [(5.6, 95.3), (3.5, 98.5), (1.0, 102.5), (-3.0, 106.0), (-5.9, 105.8), (-4.0, 102.3), (-1.0, 100.3),
         (2.0, 98.7)],
        [(-6.0, 106.0), (-6.9, 111.0), (-7.7, 114.5), (-8.7, 114.4), (-8.2, 110.0), (-7.5, 106.4)],
        [(7.0, 116.8), (5.0, 119.3), (1.0, 118.8), (-1.5, 116.5), (-4.0, 115.9), (-3.3, 111.8), (-2.9, 110.2),
         (0.0, 109.0), (1.8, 109.6), (2.8, 111.4), (4.5, 113.9), (5.6, 115.4)],
        [(1.4, 125.0), (0.9, 120.5), (-0.9, 120.0), (-3.7, 119.5), (-5.6, 119.5), (-5.5, 122.6), (-3.5, 122.4),
         (-1.0, 123.3), (0.4, 124.0)],
        [(-0.8, 131.0), (-2.3, 134.0), (-2.6, 138.0), (-2.6, 141.0), (-4.0, 145.0), (-6.0, 147.6), (-8.0, 148.2),
         (-10.4, 150.5), (-9.0, 146.5), (-8.0, 144.0), (-9.1, 142.5), (-8.4, 138.5), (-6.5, 138.0), (-4.6, 136.0),
         (-3.8, 132.8), (-2.5, 132.0)],
        // Oceania
        [(-10.7, 142.5), (-14.5, 143.7), (-16.5, 145.5), (-19.2, 146.8), (-22.5, 150.5), (-25.5, 153.1),
         (-28.6, 153.6), (-32.5, 152.5), (-35.0, 150.8), (-37.5, 149.9), (-38.4, 145.5), (-38.0, 140.5),
         (-35.5, 138.5), (-32.0, 134.0), (-31.6, 131.0), (-32.3, 125.0), (-34.0, 123.5), (-35.0, 118.0),
         (-34.4, 115.1), (-31.5, 115.6), (-27.8, 114.2), (-24.0, 113.5), (-21.8, 114.2), (-20.3, 118.8),
         (-18.0, 122.2), (-16.5, 123.0), (-14.0, 126.5), (-15.0, 129.5), (-12.5, 130.6), (-11.2, 132.6),
         (-12.2, 136.7), (-14.9, 135.5), (-17.6, 140.6), (-15.0, 141.6), (-12.5, 141.7)],
        [(-40.8, 144.7), (-40.9, 148.3), (-43.6, 147.0), (-43.4, 145.9)],
        [(-34.4, 172.7), (-37.5, 175.9), (-39.4, 178.0), (-41.6, 175.2), (-39.0, 174.0), (-36.5, 174.4)],
        [(-40.5, 172.8), (-41.8, 174.3), (-44.0, 171.3), (-46.6, 169.0), (-46.0, 166.5), (-43.5, 170.0),
         (-41.5, 171.9)]
    ]

    static let inlandSeas: [[(Double, Double)]] = [
        // Black Sea
        [(46.5, 30.7), (45.3, 29.6), (43.0, 27.9), (41.6, 28.1), (41.2, 31.4), (41.8, 33.5), (42.0, 35.2),
         (41.3, 37.5), (41.0, 40.0), (41.6, 41.6), (43.0, 41.0), (44.6, 37.6), (45.3, 36.8), (45.0, 33.5),
         (44.4, 33.7), (45.2, 32.5), (46.6, 31.8)],
        // Caspian Sea
        [(47.0, 51.0), (46.5, 49.0), (44.5, 47.0), (42.0, 48.0), (40.3, 49.6), (38.4, 48.9), (37.0, 50.3),
         (36.6, 53.8), (37.3, 54.0), (39.5, 53.2), (41.0, 53.0), (42.0, 52.5), (44.5, 50.3), (46.5, 53.0)]
    ]
}
