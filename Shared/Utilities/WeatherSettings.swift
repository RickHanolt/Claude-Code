import Foundation

/// The town, and the last forecast fetched for it.
///
/// Both live in the App Group defaults as JSON, and both keys are public so a
/// view can watch them with `@AppStorage(Data)` and redraw when a refresh
/// lands. Sampling them into `@State` instead would leave the strip showing
/// whatever it read when the screen first appeared, which on this screen is the
/// difference between a forecast and a decoration.
enum WeatherSettings {
    static let placeKey = "weather.place"
    static let cacheKey = "weather.cache"

    /// Three hours. A daily forecast's high and low barely move within a
    /// morning, and the screen is opened several times before school.
    static let refreshInterval: TimeInterval = 3 * 60 * 60

    private static var defaults: UserDefaults { AppGroup.sharedDefaults ?? .standard }

    static var place: WeatherPlace? {
        get { decode(WeatherPlace.self, forKey: placeKey) }
        set {
            encode(newValue, forKey: placeKey)
            // The old town's forecast is worse than none: it would keep
            // rendering, correctly formatted and quietly wrong, until the next
            // refresh happened to succeed.
            if newValue == nil { defaults.removeObject(forKey: cacheKey) }
        }
    }

    static var cached: CachedForecast? {
        get { decode(CachedForecast.self, forKey: cacheKey) }
        set { encode(newValue, forKey: cacheKey) }
    }

    /// Decodes what a view is already watching as raw `Data`, so the view gets
    /// reactivity from `@AppStorage` and the parsing lives here.
    static func forecast(fromStored data: Data) -> CachedForecast? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(CachedForecast.self, from: data)
    }

    static func place(fromStored data: Data) -> WeatherPlace? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(WeatherPlace.self, from: data)
    }

    // MARK: -

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value, let data = try? encoder.encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
