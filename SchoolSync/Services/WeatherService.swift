import Foundation

/// Weather from Open-Meteo.
///
/// Chosen over WeatherKit for one practical reason: WeatherKit needs a
/// capability enabled in the Apple Developer portal and regenerated
/// provisioning profiles before the app will even sign. This needs nothing —
/// no key, no entitlement, no portal visit — which means the forecast works on
/// the next build rather than on the next build plus a support ticket.
///
/// No location permission either. The place is typed once (see
/// `WeatherSettings`) and travels in the snapshot, so a viewing phone shows the
/// weather where the kids are rather than where that phone happens to be.
struct WeatherService {
    enum Failure: LocalizedError {
        case noPlace
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noPlace: "no town set — add one in Settings."
            case .badResponse: "the weather service didn't answer properly."
            }
        }
    }

    /// Open-Meteo caps the daily forecast at 16 days. Asking for more is an
    /// error rather than a truncation, so this is a hard limit, not a taste.
    private static let forecastDays = 16

    // MARK: - Finding a place

    struct PlaceMatch: Identifiable, Sendable {
        var id: Int
        var place: WeatherPlace
    }

    static func search(_ query: String) async throws -> [PlaceMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }

        struct Response: Decodable {
            // Absent entirely when nothing matches, rather than an empty array.
            var results: [Result]?
            struct Result: Decodable {
                var id: Int
                var name: String
                var latitude: Double
                var longitude: Double
                var admin1: String?
                var country: String?
            }
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.results ?? []).map { result in
            PlaceMatch(
                id: result.id,
                place: WeatherPlace(
                    name: result.name,
                    latitude: result.latitude,
                    longitude: result.longitude,
                    // Country only when it isn't the US, so the common case
                    // reads "Elmhurst, Illinois" rather than a line of noise.
                    region: [result.admin1, result.country == "United States" ? nil : result.country]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                )
            )
        }
    }

    // MARK: - The forecast

    static func forecast(for place: WeatherPlace) async throws -> [DailyForecast] {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(
                name: "daily",
                value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            ),
            // Fahrenheit at the boundary, so nothing downstream ever has to
            // know which unit it's holding.
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            // The place's timezone, not the phone's: "Tuesday" has to mean the
            // kids' Tuesday.
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }

        struct Response: Decodable {
            var timezone: String?
            var daily: Daily
            struct Daily: Decodable {
                var time: [String]
                var weather_code: [Int?]
                var temperature_2m_max: [Double?]
                var temperature_2m_min: [Double?]
                // Null at the far end of the range often enough that decoding
                // this as [Int] throws on a perfectly good response.
                var precipitation_probability_max: [Int?]?
            }
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let daily = decoded.daily

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Parsed in the forecast's own zone so the resulting Date lands on the
        // right day when compared against a local `startOfDay`.
        formatter.timeZone = decoded.timezone.flatMap(TimeZone.init(identifier:)) ?? .current

        // Open-Meteo returns parallel arrays that are *supposed* to be the same
        // length as `time`. Indexing them on that assumption is one malformed
        // response away from a crash, so each is read defensively and a day
        // missing any of its three required values is dropped rather than
        // guessed at.
        func value<T>(_ array: [T?], _ index: Int) -> T? {
            array.indices.contains(index) ? array[index] : nil
        }

        return daily.time.indices.compactMap { index -> DailyForecast? in
            guard let day = formatter.date(from: daily.time[index]),
                  let high = value(daily.temperature_2m_max, index),
                  let low = value(daily.temperature_2m_min, index),
                  let code = value(daily.weather_code, index)
            else { return nil }

            return DailyForecast(
                day: day,
                highF: high,
                lowF: low,
                precipChance: daily.precipitation_probability_max.flatMap { value($0, index) },
                code: code
            )
        }
    }

    /// Fetches and caches, unless the cache is already good enough.
    ///
    /// Refreshed on a timer rather than on every appearance, for the same
    /// reason the rest of the app is: the answer changes slowly and the screen
    /// is opened often. A failure leaves the previous forecast in place —
    /// yesterday's high is a better answer than a blank strip.
    @discardableResult
    static func refreshIfNeeded(force: Bool = false) async -> CachedForecast? {
        guard let place = WeatherSettings.place else { return nil }

        if !force, let cached = WeatherSettings.cached,
           cached.place == place,
           Date.now.timeIntervalSince(cached.fetchedAt) < WeatherSettings.refreshInterval {
            return cached
        }

        do {
            let days = try await forecast(for: place)
            let cached = CachedForecast(place: place, fetchedAt: .now, days: days)
            WeatherSettings.cached = cached
            return cached
        } catch {
            return WeatherSettings.cached
        }
    }
}
