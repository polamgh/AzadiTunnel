import Foundation

/// Encodes WGS84 coordinates as a geohash string for Psiphon `DeviceLocation`.
enum GeoHash {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Android Shiro defaults to coarse precision when location permission is granted.
    /// IP geolocation is less precise than GPS, so 4 (~20 km) is a reasonable default.
    static let ipGeolocationPrecision = 4

    static func encode(latitude: Double, longitude: Double, precision: Int = ipGeolocationPrecision) -> String? {
        guard (1...12).contains(precision),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }

        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        hash.reserveCapacity(precision)

        var bit = 0
        var value = 0
        var isLongitude = true

        while hash.count < precision {
            let mid: Double
            if isLongitude {
                mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid {
                    value = (value << 1) | 1
                    lonRange.0 = mid
                } else {
                    value <<= 1
                    lonRange.1 = mid
                }
            } else {
                mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid {
                    value = (value << 1) | 1
                    latRange.0 = mid
                } else {
                    value <<= 1
                    latRange.1 = mid
                }
            }

            isLongitude.toggle()
            bit += 1
            if bit == 5 {
                hash.append(alphabet[value])
                bit = 0
                value = 0
            }
        }

        return hash
    }
}
