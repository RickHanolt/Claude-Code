import SwiftUI

/// One day's weather, above that day's panels.
///
/// Per-day rather than fixed at the top of the screen, because Morning Mode
/// pages across days and a forecast that didn't move with the page would be
/// showing today's rain over tomorrow's plan.
///
/// Reads the cached forecast as raw `Data` through `@AppStorage` so a refresh
/// landing behind the screen redraws it, rather than leaving whatever it
/// happened to read first.
struct WeatherStripView: View {
    let day: Date

    @AppStorage(WeatherSettings.cacheKey, store: AppGroup.sharedDefaults)
    private var cachedData = Data()

    @AppStorage(WeatherSettings.placeKey, store: AppGroup.sharedDefaults)
    private var placeData = Data()

    private var forecast: DailyForecast? {
        WeatherSettings.forecast(fromStored: cachedData)?.day(for: day)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let forecast {
                Image(systemName: forecast.condition.symbolName)
                    .foregroundStyle(.secondary)

                Text("\(Int(forecast.highF.rounded()))° / \(Int(forecast.lowF.rounded()))°")
                    .font(.caption.weight(.semibold))

                if let chance = forecast.precipChance, chance >= 40 {
                    Text("\(chance)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // The advice, not the conditions, is what this row is for. It
                // gets the weight; the numbers behind it are the receipt.
                if let advice = ClothingAdvice.line(for: forecast) {
                    Text(advice)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(forecast.condition.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "cloud.sun")
                    .foregroundStyle(.secondary)
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Three different silences, told apart. "No town set" is a thing someone
    /// can fix in thirty seconds; "beyond the forecast" is not a fault at all.
    private var emptyMessage: String {
        guard WeatherSettings.place(fromStored: placeData) != nil else {
            return "Add your town in Settings for weather"
        }
        guard WeatherSettings.forecast(fromStored: cachedData) != nil else {
            return "Weather hasn't loaded yet"
        }
        return "No forecast this far out"
    }
}
