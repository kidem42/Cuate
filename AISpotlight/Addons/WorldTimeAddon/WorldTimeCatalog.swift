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
    /// Just this entry's OWN names, in every language. Ranking leans on it:
    /// an alias inherits its zone's whole haystack, so without this "Москва"
    /// scored Kazan and Krasnodar (same zone) level with Moscow itself.
    fileprivate let ownKey: String
    /// For an aliased city (San Francisco), the exemplar city of the zone it
    /// rides on (Los Angeles) — shown in search as context. `nil` for a zone's
    /// own exemplar.
    var aliasOf: String?
    /// Stable English key of the alias, stored on the row so its label can be
    /// re-localized later. `nil` for a zone's own exemplar.
    var aliasKey: String?

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
        return WorldTimeCity(zoneID: zoneID, name: name, country: "",
                             searchKey: fold(name), ownKey: fold(name),
                             aliasOf: nil, aliasKey: nil)
    }

    /// Diacritic/case-insensitive search; prefix matches rank first.
    ///
    /// Searches the zone exemplars PLUS the alias table: the IANA database
    /// names one city per zone, so searching for any other city on earth —
    /// San Francisco, Munich, Osaka, Boston — found nothing at all.
    static func search(_ query: String, limit: Int = 12) -> [WorldTimeCity] {
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return [] }
        // Three tiers, best first: the displayed name starts with the query;
        // one of the entry's OWN names in any language contains it; anything
        // else in its haystack (country, identifier, or — for an alias — the
        // zone it rides on) contains it.
        var prefix: [WorldTimeCity] = []
        var ownMatch: [WorldTimeCity] = []
        var contains: [WorldTimeCity] = []
        for city in searchIndex() {
            if fold(city.name).hasPrefix(needle) {
                prefix.append(city)
            } else if city.ownKey.contains(needle) {
                ownMatch.append(city)
            } else if city.searchKey.contains(needle) {
                contains.append(city)
            }
            if prefix.count >= limit { break }
        }
        return Array((prefix + ownMatch + contains).prefix(limit))
    }

    // MARK: - Alias index

    /// What `search` actually looks through: every zone exemplar, plus one
    /// entry per aliased city. Aliases are deliberately kept OUT of `cities()`
    /// — that list backs `city(for:)`, and an alias winning there would label
    /// a Los Angeles row "San Francisco" for someone who added Los Angeles.
    /// Picking an alias adds its zone, so the row header still reads with the
    /// zone's own exemplar city.
    private static func searchIndex() -> [WorldTimeCity] {
        let language = Localization.currentLanguage
        if let cached = searchCache[language] { return cached }
        let zones = cities(for: language)
        let byZone = Dictionary(zones.map { ($0.zoneID, $0) }, uniquingKeysWith: { first, _ in first })
        var index = zones
        for alias in aliases {
            // An alias for a zone the system doesn't know (tzdata moves on)
            // is simply dropped rather than offering a dead entry.
            guard let host = byZone[alias.zone] else { continue }
            index.append(WorldTimeCity(
                zoneID: alias.zone,
                name: alias.name(for: language),
                country: host.country,
                // EVERY spelling is searchable whatever the interface language
                // — the host zone's haystack already covers all three, and the
                // alias adds its own three on top.
                searchKey: fold("\(alias.en) \(alias.ru) \(alias.spanish) \(host.searchKey)"),
                ownKey: fold("\(alias.en) \(alias.ru) \(alias.spanish)"),
                aliasOf: host.name,
                aliasKey: alias.en
            ))
        }
        index.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        searchCache[language] = index
        return index
    }

    private static var searchCache: [AppLanguage: [WorldTimeCity]] = [:]

    /// Display name for a stored row's alias key, in the current language.
    /// Falls back to the key itself (which is the English name) if the alias
    /// ever leaves the table.
    static func aliasDisplayName(_ key: String) -> String {
        aliases.first { $0.en == key }?.name(for: Localization.currentLanguage) ?? key
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

        // Every interface language gets indexed, not just the active one:
        // people type city names in whatever language they think in, and an
        // English UI that cannot find "Москва" or "Ginebra" is a dead end.
        let allLocales = AppLanguage.allCases.map { Locale(identifier: $0.rawValue) }
        let nameFormatters = allLocales.map { loc -> DateFormatter in
            let f = DateFormatter()
            f.locale = loc
            f.dateFormat = "VVV"
            return f
        }

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
            var ownNames = "\(name) \(englishName)"
            var haystack = "\(country) \(id.replacingOccurrences(of: "_", with: " "))"
            for (index, formatter) in nameFormatters.enumerated() {
                formatter.timeZone = zone
                ownNames += " " + formatter.string(from: now)
                if let code = countryCodes[id],
                   let localizedCountry = allLocales[index].localizedString(forRegionCode: code) {
                    haystack += " " + localizedCountry
                }
            }
            result.append(WorldTimeCity(zoneID: id, name: name, country: country,
                                        searchKey: fold(ownNames + " " + haystack),
                                        ownKey: fold(ownNames),
                                        aliasOf: nil, aliasKey: nil))
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

// MARK: - Aliases

/// Cities that are NOT the exemplar of their IANA zone, and therefore could
/// not be found at all before: the tz database names exactly one city per
/// zone (`America/Los_Angeles`), so searching for San Francisco, Munich,
/// Osaka or Boston returned nothing. Each entry maps a city to the zone that
/// actually keeps its clock; picking one adds that zone.
///
/// Both spellings are indexed regardless of interface language.
private extension WorldTimeCatalog {
    struct CityAlias {
        let en: String
        let ru: String
        let zone: String
        /// Spanish spelling, only where it differs beyond accents. Diacritics
        /// are folded away before matching, so "Múnich" already finds "Munich"
        /// — this is for the names that genuinely diverge (Nápoles, Ginebra,
        /// La Haya). Empty means "the English spelling serves".
        let es: String

        var spanish: String { es.isEmpty ? en : es }

        init(_ en: String, _ ru: String, _ zone: String, es: String = "") {
            self.en = en; self.ru = ru; self.zone = zone; self.es = es
        }

        func name(for language: AppLanguage) -> String {
            switch language {
            case .russian: return ru
            case .spanish: return spanish
            default: return en
            }
        }
    }

    static let aliases: [CityAlias] = [
        // United States
        CityAlias("San Francisco", "Сан-Франциско", "America/Los_Angeles"),
        CityAlias("San Jose", "Сан-Хосе", "America/Los_Angeles"),
        CityAlias("San Diego", "Сан-Диего", "America/Los_Angeles"),
        CityAlias("Oakland", "Окленд", "America/Los_Angeles"),
        CityAlias("Sacramento", "Сакраменто", "America/Los_Angeles"),
        CityAlias("Seattle", "Сиэтл", "America/Los_Angeles"),
        CityAlias("Portland", "Портленд", "America/Los_Angeles"),
        CityAlias("Las Vegas", "Лас-Вегас", "America/Los_Angeles"),
        CityAlias("Palo Alto", "Пало-Альто", "America/Los_Angeles"),
        CityAlias("Cupertino", "Купертино", "America/Los_Angeles"),
        CityAlias("Salt Lake City", "Солт-Лейк-Сити", "America/Denver"),
        CityAlias("Albuquerque", "Альбукерке", "America/Denver"),
        CityAlias("Colorado Springs", "Колорадо-Спрингс", "America/Denver"),
        CityAlias("Tucson", "Тусон", "America/Phoenix"),
        CityAlias("Houston", "Хьюстон", "America/Chicago"),
        CityAlias("Dallas", "Даллас", "America/Chicago"),
        CityAlias("Austin", "Остин", "America/Chicago"),
        CityAlias("San Antonio", "Сан-Антонио", "America/Chicago"),
        CityAlias("Nashville", "Нэшвилл", "America/Chicago"),
        CityAlias("New Orleans", "Новый Орлеан", "America/Chicago", es: "Nueva Orleans"),
        CityAlias("Memphis", "Мемфис", "America/Chicago"),
        CityAlias("Milwaukee", "Милуоки", "America/Chicago"),
        CityAlias("Kansas City", "Канзас-Сити", "America/Chicago"),
        CityAlias("St. Louis", "Сент-Луис", "America/Chicago"),
        CityAlias("Minneapolis", "Миннеаполис", "America/Chicago"),
        CityAlias("Oklahoma City", "Оклахома-Сити", "America/Chicago"),
        CityAlias("Omaha", "Омаха", "America/Chicago"),
        CityAlias("Boston", "Бостон", "America/New_York"),
        CityAlias("Philadelphia", "Филадельфия", "America/New_York", es: "Filadelfia"),
        CityAlias("Washington", "Вашингтон", "America/New_York"),
        CityAlias("Atlanta", "Атланта", "America/New_York"),
        CityAlias("Miami", "Майами", "America/New_York"),
        CityAlias("Orlando", "Орландо", "America/New_York"),
        CityAlias("Tampa", "Тампа", "America/New_York"),
        CityAlias("Charlotte", "Шарлотт", "America/New_York"),
        CityAlias("Pittsburgh", "Питтсбург", "America/New_York"),
        CityAlias("Cleveland", "Кливленд", "America/New_York"),
        CityAlias("Cincinnati", "Цинциннати", "America/New_York"),
        CityAlias("Columbus", "Колумбус", "America/New_York"),
        CityAlias("Baltimore", "Балтимор", "America/New_York"),
        CityAlias("Buffalo", "Буффало", "America/New_York"),
        CityAlias("Raleigh", "Роли", "America/New_York"),
        CityAlias("Jacksonville", "Джэксонвилл", "America/New_York"),
        CityAlias("Brooklyn", "Бруклин", "America/New_York"),
        // Canada
        CityAlias("Ottawa", "Оттава", "America/Toronto"),
        CityAlias("Montreal", "Монреаль", "America/Toronto", es: "Montreal"),
        CityAlias("Quebec City", "Квебек", "America/Toronto", es: "Quebec"),
        CityAlias("Calgary", "Калгари", "America/Edmonton"),
        CityAlias("Victoria", "Виктория", "America/Vancouver"),
        // Latin America
        CityAlias("Guadalajara", "Гвадалахара", "America/Mexico_City"),
        CityAlias("Puebla", "Пуэбла", "America/Mexico_City"),
        CityAlias("Rio de Janeiro", "Рио-де-Жанейро", "America/Sao_Paulo", es: "Río de Janeiro"),
        CityAlias("Brasilia", "Бразилиа", "America/Sao_Paulo", es: "Brasilia"),
        CityAlias("Belo Horizonte", "Белу-Оризонти", "America/Sao_Paulo"),
        CityAlias("Curitiba", "Куритиба", "America/Sao_Paulo"),
        CityAlias("Porto Alegre", "Порту-Алегри", "America/Sao_Paulo"),
        CityAlias("Rosario", "Росарио", "America/Argentina/Buenos_Aires"),
        CityAlias("Medellin", "Медельин", "America/Bogota"),
        CityAlias("Cali", "Кали", "America/Bogota"),
        CityAlias("Cartagena", "Картахена", "America/Bogota"),
        CityAlias("Quito", "Кито", "America/Guayaquil", es: "Quito"),
        CityAlias("Arequipa", "Арекипа", "America/Lima"),
        CityAlias("Cusco", "Куско", "America/Lima", es: "Cuzco"),
        CityAlias("Valparaiso", "Вальпараисо", "America/Santiago"),
        CityAlias("Maracaibo", "Маракайбо", "America/Caracas"),
        // Western Europe
        CityAlias("Munich", "Мюнхен", "Europe/Berlin", es: "Múnich"),
        CityAlias("Frankfurt", "Франкфурт", "Europe/Berlin"),
        CityAlias("Hamburg", "Гамбург", "Europe/Berlin", es: "Hamburgo"),
        CityAlias("Cologne", "Кёльн", "Europe/Berlin", es: "Colonia"),
        CityAlias("Stuttgart", "Штутгарт", "Europe/Berlin"),
        CityAlias("Dusseldorf", "Дюссельдорф", "Europe/Berlin"),
        CityAlias("Leipzig", "Лейпциг", "Europe/Berlin"),
        CityAlias("Dresden", "Дрезден", "Europe/Berlin"),
        CityAlias("Nuremberg", "Нюрнберг", "Europe/Berlin", es: "Núremberg"),
        CityAlias("Hannover", "Ганновер", "Europe/Berlin"),
        CityAlias("Milan", "Милан", "Europe/Rome", es: "Milán"),
        CityAlias("Naples", "Неаполь", "Europe/Rome", es: "Nápoles"),
        CityAlias("Turin", "Турин", "Europe/Rome", es: "Turín"),
        CityAlias("Florence", "Флоренция", "Europe/Rome", es: "Florencia"),
        CityAlias("Venice", "Венеция", "Europe/Rome", es: "Venecia"),
        CityAlias("Bologna", "Болонья", "Europe/Rome"),
        CityAlias("Genoa", "Генуя", "Europe/Rome", es: "Génova"),
        CityAlias("Palermo", "Палермо", "Europe/Rome"),
        CityAlias("Barcelona", "Барселона", "Europe/Madrid"),
        CityAlias("Valencia", "Валенсия", "Europe/Madrid"),
        CityAlias("Seville", "Севилья", "Europe/Madrid", es: "Sevilla"),
        CityAlias("Malaga", "Малага", "Europe/Madrid"),
        CityAlias("Bilbao", "Бильбао", "Europe/Madrid"),
        CityAlias("Zaragoza", "Сарагоса", "Europe/Madrid"),
        CityAlias("Palma", "Пальма", "Europe/Madrid"),
        CityAlias("Lyon", "Лион", "Europe/Paris", es: "Lyon"),
        CityAlias("Marseille", "Марсель", "Europe/Paris", es: "Marsella"),
        CityAlias("Toulouse", "Тулуза", "Europe/Paris"),
        CityAlias("Nice", "Ницца", "Europe/Paris"),
        CityAlias("Bordeaux", "Бордо", "Europe/Paris", es: "Burdeos"),
        CityAlias("Nantes", "Нант", "Europe/Paris"),
        CityAlias("Lille", "Лилль", "Europe/Paris"),
        CityAlias("Strasbourg", "Страсбург", "Europe/Paris", es: "Estrasburgo"),
        CityAlias("Cannes", "Канны", "Europe/Paris"),
        CityAlias("Manchester", "Манчестер", "Europe/London"),
        CityAlias("Birmingham", "Бирмингем", "Europe/London"),
        CityAlias("Liverpool", "Ливерпуль", "Europe/London"),
        CityAlias("Leeds", "Лидс", "Europe/London"),
        CityAlias("Glasgow", "Глазго", "Europe/London", es: "Glasgow"),
        CityAlias("Edinburgh", "Эдинбург", "Europe/London", es: "Edimburgo"),
        CityAlias("Bristol", "Бристоль", "Europe/London"),
        CityAlias("Cardiff", "Кардифф", "Europe/London"),
        CityAlias("Oxford", "Оксфорд", "Europe/London"),
        CityAlias("Cambridge", "Кембридж", "Europe/London"),
        CityAlias("Rotterdam", "Роттердам", "Europe/Amsterdam"),
        CityAlias("The Hague", "Гаага", "Europe/Amsterdam", es: "La Haya"),
        CityAlias("Utrecht", "Утрехт", "Europe/Amsterdam"),
        CityAlias("Eindhoven", "Эйндховен", "Europe/Amsterdam"),
        CityAlias("Antwerp", "Антверпен", "Europe/Brussels", es: "Amberes"),
        CityAlias("Ghent", "Гент", "Europe/Brussels", es: "Gante"),
        CityAlias("Bruges", "Брюгге", "Europe/Brussels", es: "Brujas"),
        CityAlias("Geneva", "Женева", "Europe/Zurich", es: "Ginebra"),
        CityAlias("Basel", "Базель", "Europe/Zurich", es: "Basilea"),
        CityAlias("Bern", "Берн", "Europe/Zurich", es: "Berna"),
        CityAlias("Lausanne", "Лозанна", "Europe/Zurich", es: "Lausana"),
        CityAlias("Salzburg", "Зальцбург", "Europe/Vienna"),
        CityAlias("Graz", "Грац", "Europe/Vienna"),
        CityAlias("Innsbruck", "Инсбрук", "Europe/Vienna"),
        CityAlias("Porto", "Порту", "Europe/Lisbon"),
        CityAlias("Faro", "Фару", "Europe/Lisbon"),
        CityAlias("Gothenburg", "Гётеборг", "Europe/Stockholm", es: "Gotemburgo"),
        CityAlias("Malmo", "Мальмё", "Europe/Stockholm"),
        CityAlias("Bergen", "Берген", "Europe/Oslo", es: "Bergen"),
        CityAlias("Aarhus", "Орхус", "Europe/Copenhagen"),
        CityAlias("Tampere", "Тампере", "Europe/Helsinki"),
        CityAlias("Cork", "Корк", "Europe/Dublin"),
        // Central & Eastern Europe
        CityAlias("Krakow", "Краков", "Europe/Warsaw", es: "Cracovia"),
        CityAlias("Gdansk", "Гданьск", "Europe/Warsaw"),
        CityAlias("Wroclaw", "Вроцлав", "Europe/Warsaw"),
        CityAlias("Poznan", "Познань", "Europe/Warsaw"),
        CityAlias("Lodz", "Лодзь", "Europe/Warsaw"),
        CityAlias("Brno", "Брно", "Europe/Prague"),
        CityAlias("Thessaloniki", "Салоники", "Europe/Athens", es: "Salónica"),
        CityAlias("Cluj", "Клуж", "Europe/Bucharest"),
        CityAlias("Novi Sad", "Нови-Сад", "Europe/Belgrade"),
        CityAlias("Split", "Сплит", "Europe/Zagreb"),
        CityAlias("Dubrovnik", "Дубровник", "Europe/Zagreb"),
        CityAlias("Kharkiv", "Харьков", "Europe/Kyiv"),
        CityAlias("Odesa", "Одесса", "Europe/Kyiv"),
        CityAlias("Lviv", "Львов", "Europe/Kyiv"),
        CityAlias("Dnipro", "Днепр", "Europe/Kyiv"),
        // Russia & neighbours
        CityAlias("Saint Petersburg", "Санкт-Петербург", "Europe/Moscow", es: "San Petersburgo"),
        CityAlias("Nizhny Novgorod", "Нижний Новгород", "Europe/Moscow"),
        CityAlias("Kazan", "Казань", "Europe/Moscow", es: "Kazán"),
        CityAlias("Rostov-on-Don", "Ростов-на-Дону", "Europe/Moscow"),
        CityAlias("Krasnodar", "Краснодар", "Europe/Moscow"),
        CityAlias("Sochi", "Сочи", "Europe/Moscow"),
        CityAlias("Voronezh", "Воронеж", "Europe/Moscow"),
        CityAlias("Perm", "Пермь", "Asia/Yekaterinburg"),
        CityAlias("Chelyabinsk", "Челябинск", "Asia/Yekaterinburg"),
        CityAlias("Ufa", "Уфа", "Asia/Yekaterinburg"),
        CityAlias("Tyumen", "Тюмень", "Asia/Yekaterinburg"),
        CityAlias("Astana", "Астана", "Asia/Almaty"),
        CityAlias("Shymkent", "Шымкент", "Asia/Almaty"),
        CityAlias("Samarkand", "Самарканд", "Asia/Tashkent"),
        // Middle East
        CityAlias("Abu Dhabi", "Абу-Даби", "Asia/Dubai"),
        CityAlias("Sharjah", "Шарджа", "Asia/Dubai"),
        CityAlias("Jeddah", "Джидда", "Asia/Riyadh"),
        CityAlias("Mecca", "Мекка", "Asia/Riyadh", es: "La Meca"),
        CityAlias("Medina", "Медина", "Asia/Riyadh", es: "Medina"),
        CityAlias("Tel Aviv", "Тель-Авив", "Asia/Jerusalem"),
        CityAlias("Haifa", "Хайфа", "Asia/Jerusalem"),
        CityAlias("Ankara", "Анкара", "Europe/Istanbul"),
        CityAlias("Izmir", "Измир", "Europe/Istanbul"),
        CityAlias("Antalya", "Анталья", "Europe/Istanbul"),
        CityAlias("Bursa", "Бурса", "Europe/Istanbul"),
        CityAlias("Mashhad", "Мешхед", "Asia/Tehran"),
        CityAlias("Isfahan", "Исфахан", "Asia/Tehran"),
        // Africa
        CityAlias("Alexandria", "Александрия", "Africa/Cairo", es: "Alejandría"),
        CityAlias("Giza", "Гиза", "Africa/Cairo"),
        CityAlias("Abuja", "Абуджа", "Africa/Lagos"),
        CityAlias("Cape Town", "Кейптаун", "Africa/Johannesburg", es: "Ciudad del Cabo"),
        CityAlias("Durban", "Дурбан", "Africa/Johannesburg"),
        CityAlias("Pretoria", "Претория", "Africa/Johannesburg"),
        CityAlias("Marrakech", "Марракеш", "Africa/Casablanca", es: "Marrakech"),
        CityAlias("Rabat", "Рабат", "Africa/Casablanca"),
        CityAlias("Tangier", "Танжер", "Africa/Casablanca", es: "Tánger"),
        CityAlias("Mombasa", "Момбаса", "Africa/Nairobi"),
        // East & South-East Asia
        CityAlias("Osaka", "Осака", "Asia/Tokyo", es: "Osaka"),
        CityAlias("Kyoto", "Киото", "Asia/Tokyo", es: "Kioto"),
        CityAlias("Yokohama", "Иокогама", "Asia/Tokyo"),
        CityAlias("Nagoya", "Нагоя", "Asia/Tokyo"),
        CityAlias("Sapporo", "Саппоро", "Asia/Tokyo"),
        CityAlias("Fukuoka", "Фукуока", "Asia/Tokyo"),
        CityAlias("Kobe", "Кобе", "Asia/Tokyo"),
        CityAlias("Hiroshima", "Хиросима", "Asia/Tokyo"),
        CityAlias("Busan", "Пусан", "Asia/Seoul"),
        CityAlias("Incheon", "Инчхон", "Asia/Seoul"),
        CityAlias("Daegu", "Тэгу", "Asia/Seoul"),
        CityAlias("Beijing", "Пекин", "Asia/Shanghai", es: "Pekín"),
        CityAlias("Shenzhen", "Шэньчжэнь", "Asia/Shanghai"),
        CityAlias("Guangzhou", "Гуанчжоу", "Asia/Shanghai"),
        CityAlias("Chengdu", "Чэнду", "Asia/Shanghai"),
        CityAlias("Hangzhou", "Ханчжоу", "Asia/Shanghai"),
        CityAlias("Wuhan", "Ухань", "Asia/Shanghai"),
        CityAlias("Xian", "Сиань", "Asia/Shanghai"),
        CityAlias("Nanjing", "Нанкин", "Asia/Shanghai"),
        CityAlias("Tianjin", "Тяньцзинь", "Asia/Shanghai"),
        CityAlias("Chongqing", "Чунцин", "Asia/Shanghai"),
        CityAlias("Qingdao", "Циндао", "Asia/Shanghai"),
        CityAlias("Kaohsiung", "Гаосюн", "Asia/Taipei"),
        CityAlias("Penang", "Пенанг", "Asia/Kuala_Lumpur"),
        CityAlias("Chiang Mai", "Чиангмай", "Asia/Bangkok"),
        CityAlias("Phuket", "Пхукет", "Asia/Bangkok"),
        CityAlias("Pattaya", "Паттайя", "Asia/Bangkok"),
        CityAlias("Hanoi", "Ханой", "Asia/Ho_Chi_Minh", es: "Hanói"),
        CityAlias("Da Nang", "Дананг", "Asia/Ho_Chi_Minh"),
        CityAlias("Bandung", "Бандунг", "Asia/Jakarta"),
        CityAlias("Surabaya", "Сурабая", "Asia/Jakarta"),
        CityAlias("Bali", "Бали", "Asia/Makassar", es: "Bali"),
        CityAlias("Denpasar", "Денпасар", "Asia/Makassar"),
        CityAlias("Cebu", "Себу", "Asia/Manila"),
        CityAlias("Davao", "Давао", "Asia/Manila"),
        // South Asia
        CityAlias("Mumbai", "Мумбаи", "Asia/Kolkata", es: "Bombay"),
        CityAlias("Delhi", "Дели", "Asia/Kolkata", es: "Delhi"),
        CityAlias("New Delhi", "Нью-Дели", "Asia/Kolkata", es: "Nueva Delhi"),
        CityAlias("Bengaluru", "Бангалор", "Asia/Kolkata"),
        CityAlias("Bangalore", "Бенгалуру", "Asia/Kolkata"),
        CityAlias("Chennai", "Ченнаи", "Asia/Kolkata", es: "Chennai"),
        CityAlias("Hyderabad", "Хайдарабад", "Asia/Kolkata"),
        CityAlias("Pune", "Пуна", "Asia/Kolkata"),
        CityAlias("Ahmedabad", "Ахмадабад", "Asia/Kolkata"),
        CityAlias("Jaipur", "Джайпур", "Asia/Kolkata"),
        CityAlias("Goa", "Гоа", "Asia/Kolkata"),
        CityAlias("Kochi", "Кочи", "Asia/Kolkata"),
        CityAlias("Lahore", "Лахор", "Asia/Karachi"),
        CityAlias("Islamabad", "Исламабад", "Asia/Karachi"),
        CityAlias("Rawalpindi", "Равалпинди", "Asia/Karachi"),
        CityAlias("Chittagong", "Читтагонг", "Asia/Dhaka"),
        // Oceania
        CityAlias("Canberra", "Канберра", "Australia/Sydney"),
        CityAlias("Newcastle", "Ньюкасл", "Australia/Sydney"),
        CityAlias("Wollongong", "Вуллонгонг", "Australia/Sydney"),
        CityAlias("Gold Coast", "Голд-Кост", "Australia/Brisbane"),
        CityAlias("Cairns", "Кэрнс", "Australia/Brisbane"),
        CityAlias("Geelong", "Джилонг", "Australia/Melbourne"),
        CityAlias("Wellington", "Веллингтон", "Pacific/Auckland"),
        CityAlias("Christchurch", "Крайстчерч", "Pacific/Auckland"),
        CityAlias("Queenstown", "Куинстаун", "Pacific/Auckland"),
        CityAlias("Suva", "Сува", "Pacific/Fiji"),
    ]
}
