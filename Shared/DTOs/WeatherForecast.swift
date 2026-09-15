import Foundation

/// Where the kids are. Not where the phone is.
///
/// Typed once by the owner and carried in the snapshot, so a grandparent's
/// phone shows the weather the kids will actually be standing in rather than
/// the weather outside the grandparent's window. That distinction is the whole
/// reason this isn't CoreLocation.
struct WeatherPlace: Codable, Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double

    /// "Chicago, Illinois" — enough to tell two same-named towns apart in the
    /// picker, which is the only place ambiguity can actually bite.
    var region: String?

    var label: String {
        guard let region, !region.isEmpty else { return name }
        return "\(name), \(region)"
    }
}

/// One day's forecast, already in the units this app shows.
///
/// Conversion happens at the API boundary rather than at render time: a
/// temperature that travels as "a number" and is interpreted twice is a
/// temperature that eventually gets interpreted twice differently.
struct DailyForecast: Codable, Equatable, Sendable {
    /// Midnight local to the forecast's own timezone, which is the place's,
    /// not the phone's.
    var day: Date
    var highF: Double
    var lowF: Double
    /// Nil when the API didn't supply one, which it sometimes doesn't for the
    /// far end of the range. Distinct from zero — "no chance of rain" and "no
    /// idea" should not render the same.
    var precipChance: Int?
    /// WMO code. Kept raw so the mapping below can be corrected without
    /// invalidating every cached forecast.
    var code: Int

    var condition: WeatherCondition { WeatherCondition(code: code) }
}

/// A cached forecast plus what it was for, so a stale cache for the old town
/// can be recognised as stale rather than shown.
struct CachedForecast: Codable, Sendable {
    var place: WeatherPlace
    var fetchedAt: Date
    var days: [DailyForecast]

    func day(for date: Date, calendar: Calendar = .current) -> DailyForecast? {
        days.first { calendar.isDate($0.day, inSameDayAs: date) }
    }
}

/// WMO weather codes, collapsed to the handful of cases that change what you
/// put on a child.
///
/// Deliberately coarse. The difference between "light drizzle" and "moderate
/// drizzle" changes nothing anyone does at 7am; the difference between rain and
/// snow changes the boots.
enum WeatherCondition: Sendable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, freezingRain, snow, thunderstorm, unknown

    init(code: Int) {
        switch code {
        case 0, 1: self = .clear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57, 66, 67: self = .freezingRain
        case 61, 63, 65, 80, 81, 82: self = .rain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunderstorm
        default: self = .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .clear: "sun.max"
        case .partlyCloudy: "cloud.sun"
        case .cloudy: "cloud"
        case .fog: "cloud.fog"
        case .drizzle: "cloud.drizzle"
        case .rain: "cloud.rain"
        case .freezingRain: "cloud.sleet"
        case .snow: "cloud.snow"
        case .thunderstorm: "cloud.bolt.rain"
        case .unknown: "cloud"
        }
    }

    var label: String {
        switch self {
        case .clear: "Clear"
        case .partlyCloudy: "Partly cloudy"
        case .cloudy: "Cloudy"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .freezingRain: "Freezing rain"
        case .snow: "Snow"
        case .thunderstorm: "Storms"
        case .unknown: "—"
        }
    }

    var isWet: Bool {
        switch self {
        case .drizzle, .rain, .freezingRain, .snow, .thunderstorm: true
        default: false
        }
    }
}

/// What to put on them, from the numbers alone.
///
/// Rules, not a model call. The input is two temperatures and a code, the
/// output is four words, and anyone reading this file should be able to tell
/// exactly what it will say on a given morning — which is not true of anything
/// that phones a server to decide what a five-year-old wears.
///
/// Thresholds are keyed off the LOW, not the high: the kids are outside at
/// 7:40am waiting to go in, and the afternoon high is no comfort then.
enum ClothingAdvice {
    static func line(for forecast: DailyForecast) -> String? {
        var parts: [String] = []

        switch forecast.lowF {
        case ..<20: parts.append("Winter coat, hat and gloves")
        case ..<35: parts.append("Winter coat")
        case ..<50: parts.append("Coat")
        case ..<62: parts.append("Jacket")
        default: break
        }

        switch forecast.condition {
        case .snow: parts.append("boots")
        case .rain, .drizzle, .thunderstorm:
            // Only worth saying when it's actually likely. A 10% chance every
            // day in April would train everyone to ignore the line entirely.
            if (forecast.precipChance ?? 0) >= 40 { parts.append("rain jacket") }
        case .freezingRain: parts.append("boots — ice")
        default: break
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ") + "."
    }
}
