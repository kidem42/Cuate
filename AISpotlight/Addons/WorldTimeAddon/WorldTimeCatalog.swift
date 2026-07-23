import Foundation

/// A searchable city entry backed by an IANA timezone. Built from
/// `TimeZone.knownTimeZoneIdentifiers` — no bundled database: ICU supplies
/// the localized exemplar-city name ("Москва", "Nueva York"), the system's
/// `zone.tab` supplies the country.
struct WorldTimeCity: Identifiable, Hashable {
    let zoneID: String
    /// Localized exemplar city, e.g. "Mérida".
    let name: String
    /// Localized country/region name, e.g. "Mexico". Empty when unknown.
    let country: String
    /// Pre-folded haystack for diacritic/case-insensitive search: localized
    /// name + English name + country + the raw identifier.
    fileprivate let searchKey: String

    var id: String { zoneID }
}

/// City catalog + search. All lookups are cached per interface language —
/// building 400+ localized names costs a few ms and happens once.
/// Main-actor: only the World Time window ever touches it.
@MainActor
enum WorldTimeCatalog {

    // MARK: - Public

    /// Full catalog for the current interface language, sorted by name.
    static func cities() -> [WorldTimeCity] {
        cities(for: Localization.currentLanguage)
    }

    /// Catalog entry for a single zone (used for row headers). Falls back to
    /// a bare identifier-derived name for zones missing from the catalog.
    static func city(for zoneID: String) -> WorldTimeCity {
        if let hit = cities().first(where: { $0.zoneID == zoneID }) {
            return hit
        }
        let name = zoneID.split(separator: "/").last.map {
            $0.replacingOccurrences(of: "_", with: " ")
        } ?? zoneID
        return WorldTimeCity(zoneID: zoneID, name: name, country: "", searchKey: fold(name))
    }

    /// Diacritic/case-insensitive search; prefix matches rank first.
    static func search(_ query: String, limit: Int = 12) -> [WorldTimeCity] {
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return [] }
        var prefix: [WorldTimeCity] = []
        var contains: [WorldTimeCity] = []
        for city in cities() {
            if fold(city.name).hasPrefix(needle) {
                prefix.append(city)
            } else if city.searchKey.contains(needle) {
                contains.append(city)
            }
            if prefix.count >= limit { break }
        }
        return Array((prefix + contains).prefix(limit))
    }

    // MARK: - Cache

    private static var cache: [AppLanguage: [WorldTimeCity]] = [:]

    private static func cities(for language: AppLanguage) -> [WorldTimeCity] {
        if let cached = cache[language] { return cached }
        let locale = Locale(identifier: language.rawValue)
        let english = Locale(identifier: "en")
        let countryCodes = zoneCountryCodes()

        let cityFormatter = DateFormatter()
        cityFormatter.locale = locale
        cityFormatter.dateFormat = "VVV" // ICU exemplar city
        let englishFormatter = DateFormatter()
        englishFormatter.locale = english
        englishFormatter.dateFormat = "VVV"
        let now = Date()

        var result: [WorldTimeCity] = []
        for id in TimeZone.knownTimeZoneIdentifiers {
            // Skip the non-geographic entries (GMT, UTC aliases without a
            // continent/city shape) — they only add noise to search.
            guard id.contains("/"), !id.hasPrefix("Etc/"), let zone = TimeZone(identifier: id) else { continue }
            cityFormatter.timeZone = zone
            englishFormatter.timeZone = zone
            let name = cityFormatter.string(from: now)
            let englishName = englishFormatter.string(from: now)
            let country = countryCodes[id].flatMap {
                locale.localizedString(forRegionCode: $0)
            } ?? ""
            let key = fold("\(name) \(englishName) \(country) \(id.replacingOccurrences(of: "_", with: " "))")
            result.append(WorldTimeCity(zoneID: id, name: name, country: country, searchKey: key))
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cache[language] = result
        return result
    }

    /// zoneID → ISO country code from the system tz database. Missing file
    /// (or future macOS layout change) degrades to empty countries — search
    /// and display still work.
    private static func zoneCountryCodes() -> [String: String] {
        if let cached = countryCache { return cached }
        var map: [String: String] = [:]
        if let text = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let cols = line.split(separator: "\t")
                if cols.count >= 3 {
                    map[String(cols[2])] = String(cols[0])
                }
            }
        }
        countryCache = map
        return map
    }

    private static var countryCache: [String: String]?

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }
}
