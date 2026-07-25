import Foundation

/// Self-contained localization for the WorldTimeAddon (pattern: `CAL()` of
/// CalendarAddon). Follows the app's current language, adds nothing to the
/// global `L()` table.
func WTL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = WorldTimeStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum WorldTimeStrings {
    static let table: [String: [AppLanguage: String]] = [
        "wt.tab": [.english: "World Time", .spanish: "Hora mundial", .russian: "Мировое время"],
        "wt.menu.open": [.english: "World Time", .spanish: "Hora mundial", .russian: "Мировое время"],
        "wt.window.title": [.english: "World Time", .spanish: "Hora mundial", .russian: "Мировое время"],

        // General tab master switch
        "wt.general.enable": [
            .english: "World Time",
            .spanish: "Hora mundial",
            .russian: "Мировое время"
        ],
        "wt.general.enable.caption": [
            .english: "A timezone comparison grid in a floating panel, opened from the menu bar. Fully on-device and free.",
            .spanish: "Una cuadrícula de comparación de husos horarios en un panel flotante, abierta desde la barra de menús. Totalmente local y gratis.",
            .russian: "Сетка сравнения часовых поясов в плавающей панели, открывается из меню-бара. Полностью локально и бесплатно."
        ],

        // Window UI
        "wt.search.placeholder": [
            .english: "Place or timezone",
            .spanish: "Lugar o huso horario",
            .russian: "Город или часовой пояс"
        ],
        "wt.search.noResults": [.english: "No matches", .spanish: "Sin coincidencias", .russian: "Ничего не найдено"],
        "wt.today": [.english: "Today", .spanish: "Hoy", .russian: "Сегодня"],
        "wt.pickDate": [.english: "Pick a date", .spanish: "Elegir fecha", .russian: "Выбрать дату"],
        "wt.row.remove": [.english: "Remove city", .spanish: "Quitar ciudad", .russian: "Убрать город"],
        "wt.row.setHome": [
            .english: "Make this the home city (grid aligns to its day)",
            .spanish: "Hacer esta la ciudad de referencia (la cuadrícula se alinea a su día)",
            .russian: "Сделать опорным городом (сетка выравнивается по его дню)"
        ],
        "wt.empty": [
            .english: "Add a city to compare timezones.",
            .spanish: "Añade una ciudad para comparar husos horarios.",
            .russian: "Добавьте город, чтобы сравнивать часовые пояса."
        ],

        "wt.openCalendar": [
            .english: "Apple Calendar",
            .spanish: "Calendario de Apple",
            .russian: "Apple Календарь"
        ],

        // Busy lane (CalendarAddon integration)
        "wt.busy.caption": [.english: "Busy", .spanish: "Ocupado", .russian: "Занятость"],
        "wt.escHint": [.english: "esc closes", .spanish: "esc cierra", .russian: "esc — закрыть"],

        // Slot composer (half-hour click → create event/reminder)
        "wt.slot.speak": [
            .english: "Say what to plan…",
            .spanish: "Di qué planificar…",
            .russian: "Скажи, что запланировать…"
        ],
        "wt.slot.placeholder": [
            .english: "What to plan?",
            .spanish: "¿Qué planificar?",
            .russian: "Что запланировать?"
        ],
        "wt.slot.typeInstead": [.english: "Type instead", .spanish: "Escribir", .russian: "Ввести текстом"],
        "wt.slot.speakInstead": [.english: "Dictate instead", .spanish: "Dictar", .russian: "Надиктовать"],
        "wt.slot.doneSpeaking": [.english: "Done — create", .spanish: "Listo — crear", .russian: "Готово — создать"],
        "wt.slot.transcribing": [.english: "Transcribing…", .spanish: "Transcribiendo…", .russian: "Распознаю…"],
        "wt.slot.creating": [.english: "Creating…", .spanish: "Creando…", .russian: "Создаю…"],
        "wt.slot.created": [.english: "Done", .spanish: "Hecho", .russian: "Готово"],
        "wt.slot.retryText": [
            .english: "Edit as text",
            .spanish: "Editar como texto",
            .russian: "Поправить текстом"
        ],
        "wt.slot.err.noAudio": [
            .english: "Couldn't hear anything — try again or type.",
            .spanish: "No se oyó nada — inténtalo de nuevo o escribe.",
            .russian: "Ничего не расслышал — попробуй ещё раз или введи текстом."
        ],
        "wt.slot.err.noCalendar": [
            .english: "No writable calendar. Check calendar access and the visible calendars in Settings.",
            .spanish: "No hay calendario con permiso de escritura. Revisa el acceso y los calendarios visibles en Ajustes.",
            .russian: "Нет календаря для записи. Проверьте доступ и видимые календари в настройках."
        ],

        // General tab hotkey row
        "wt.hotkey": [
            .english: "World Time panel",
            .spanish: "Panel de hora mundial",
            .russian: "Панель «Мировое время»"
        ],

        // Settings tab
        "wt.header": [.english: "World Time", .spanish: "Hora mundial", .russian: "Мировое время"],
        "wt.intro": [
            .english: "Cities are added and reordered in the World Time window itself. This tab holds the display options.",
            .spanish: "Las ciudades se añaden y reordenan en la propia ventana de Hora mundial. Esta pestaña contiene las opciones de visualización.",
            .russian: "Города добавляются и переставляются в самом окне «Мировое время». Здесь — настройки отображения."
        ],
        "wt.open": [.english: "Open World Time", .spanish: "Abrir Hora mundial", .russian: "Открыть «Мировое время»"],
        "wt.display.header": [.english: "Display", .spanish: "Visualización", .russian: "Отображение"],
        "wt.format": [.english: "Hour labels", .spanish: "Etiquetas de hora", .russian: "Формат часов"],
        "wt.format.system": [.english: "System", .spanish: "Sistema", .russian: "Как в системе"],
        "wt.format.12": [.english: "12-hour", .spanish: "12 horas", .russian: "12-часовой"],
        "wt.format.24": [.english: "24-hour", .spanish: "24 horas", .russian: "24-часовой"],
        "wt.work.header": [.english: "Working hours", .spanish: "Horario laboral", .russian: "Рабочие часы"],
        "wt.work.start": [.english: "Start", .spanish: "Inicio", .russian: "Начало"],
        "wt.work.end": [.english: "End", .spanish: "Fin", .russian: "Конец"],
        "wt.work.show": [.english: "Highlight working hours", .spanish: "Resaltar el horario laboral", .russian: "Выделять рабочие часы"],
        "wt.work.caption": [
            .english: "Working hours are shown as light cells, night as dark ones — the quickest way to spot a meeting slot that suits everyone. Switch it off to colour the grid by day and night alone.",
            .spanish: "Las horas laborales se muestran como celdas claras y la noche como oscuras — la forma más rápida de encontrar un hueco que convenga a todos. Desactívalo para colorear la cuadrícula solo por día y noche.",
            .russian: "Рабочие часы показаны светлыми ячейками, ночь — тёмными: так быстрее всего найти слот для встречи, удобный всем. Выключите — и сетка будет раскрашена только на день и ночь."
        ],
        "wt.settingsHelp": [.english: "World Time settings", .spanish: "Ajustes de Hora mundial", .russian: "Настройки мирового времени"],
    ]
}
