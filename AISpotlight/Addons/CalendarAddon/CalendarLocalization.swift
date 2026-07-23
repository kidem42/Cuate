import Foundation

/// Self-contained localization for the CalendarAddon (pattern: `IAL()` of
/// ImageAddon). Follows the app's current language, adds nothing to the
/// global `L()` table.
func CAL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = CalendarAddonStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum CalendarAddonStrings {
    static let table: [String: [AppLanguage: String]] = [
        "cal.tab": [.english: "Calendar", .spanish: "Calendario", .russian: "Календарь"],

        // General tab master switch
        "cal.general.enable": [
            .english: "Calendar & Reminders (beta)",
            .spanish: "Calendario y recordatorios (beta)",
            .russian: "Календарь и напоминания (бета)"
        ],
        "cal.general.enable.caption": [
            .english: "Lets the assistant read your schedule and create events and reminders through the macOS Calendar — works with iCloud, Google, and Exchange accounts already added to the system. Free and on-device; nothing is sent anywhere until you ask a schedule-related question.",
            .spanish: "Permite al asistente leer tu agenda y crear eventos y recordatorios a través del Calendario de macOS — funciona con cuentas de iCloud, Google y Exchange ya añadidas al sistema. Gratis y en el dispositivo; no se envía nada hasta que hagas una pregunta sobre tu agenda.",
            .russian: "Ассистент сможет читать расписание и создавать события и напоминания через системный Календарь macOS — работают iCloud, Google и Exchange аккаунты, уже добавленные в систему. Бесплатно и локально; данные никуда не уходят, пока вы сами не спросите о расписании."
        ],

        // Settings tab
        "cal.header": [.english: "Calendar & Reminders", .spanish: "Calendario y recordatorios", .russian: "Календарь и напоминания"],
        "cal.footer": [
            .english: "The assistant sees only the checked calendars and lists — unchecked ones are invisible to it entirely. Calendar data leaves the device only as part of your chat request to the selected AI provider, and only when the assistant actually reads the calendar.",
            .spanish: "El asistente solo ve los calendarios y listas marcados — los no marcados le resultan totalmente invisibles. Los datos del calendario salen del dispositivo solo como parte de tu solicitud de chat al proveedor de IA seleccionado, y solo cuando el asistente realmente lee el calendario.",
            .russian: "Ассистент видит только отмеченные календари и списки — снятые для него не существуют вовсе. Данные календаря покидают устройство только в составе вашего запроса к выбранному ИИ-провайдеру, и только когда ассистент действительно читает календарь."
        ],

        // Access section
        "cal.access.header": [.english: "Access", .spanish: "Acceso", .russian: "Доступ"],
        "cal.access.events": [.english: "Calendar", .spanish: "Calendario", .russian: "Календарь"],
        "cal.access.reminders": [.english: "Reminders", .spanish: "Recordatorios", .russian: "Напоминания"],
        "cal.access.granted": [.english: "Access granted", .spanish: "Acceso concedido", .russian: "Доступ разрешён"],
        "cal.access.denied": [
            .english: "Denied — enable in System Settings",
            .spanish: "Denegado — actívalo en Ajustes del Sistema",
            .russian: "Запрещён — включите в Настройках системы"
        ],
        "cal.access.notDetermined": [.english: "Not requested yet", .spanish: "Aún no solicitado", .russian: "Ещё не запрошен"],
        "cal.access.request": [.english: "Request Access", .spanish: "Solicitar acceso", .russian: "Запросить доступ"],
        "cal.access.open": [.english: "Open Settings", .spanish: "Abrir Ajustes", .russian: "Открыть настройки"],

        // Calendars / lists sections
        "cal.calendars.header": [.english: "Calendars", .spanish: "Calendarios", .russian: "Календари"],
        "cal.reminders.header": [.english: "Reminder Lists", .spanish: "Listas de recordatorios", .russian: "Списки напоминаний"],
        "cal.visible.caption": [
            .english: "Unchecked calendars stay invisible to the assistant.",
            .spanish: "Los calendarios no marcados permanecen invisibles para el asistente.",
            .russian: "Снятые календари остаются невидимыми для ассистента."
        ],
        "cal.badge.default": [.english: "default", .spanish: "predeterminado", .russian: "по умолчанию"],
        "cal.default.picker": [
            .english: "Create events in",
            .spanish: "Crear eventos en",
            .russian: "Создавать события в"
        ],
        "cal.default.system": [
            .english: "System default (Calendar.app)",
            .spanish: "Predeterminado del sistema (Calendario.app)",
            .russian: "Как в системе (Календарь.app)"
        ],
        "cal.source.caption": [
            .english: "This list mirrors the macOS Calendar app: accounts (iCloud, Google, Exchange) are added in System Settings → Internet Accounts, and \"System default\" follows the default calendar chosen in Calendar → Settings. The assistant writes through the same database — everything syncs the way Calendar does.",
            .spanish: "Esta lista refleja la app Calendario de macOS: las cuentas (iCloud, Google, Exchange) se añaden en Ajustes del Sistema → Cuentas de Internet, y «Predeterminado del sistema» sigue el calendario elegido en Calendario → Ajustes. El asistente escribe en la misma base de datos — todo se sincroniza igual que Calendario.",
            .russian: "Этот список — зеркало системного приложения «Календарь» macOS: аккаунты (iCloud, Google, Exchange) добавляются в Настройках системы → Учётные записи Интернета, а «Как в системе» повторяет календарь по умолчанию из Календарь → Настройки. Ассистент пишет в ту же базу — всё синхронизируется так же, как сам Календарь."
        ],
        "cal.source.openApp": [
            .english: "Open Calendar App",
            .spanish: "Abrir Calendario",
            .russian: "Открыть Календарь"
        ],
        "cal.badge.readonly": [.english: "read-only", .spanish: "solo lectura", .russian: "только чтение"],
        "cal.none": [
            .english: "No calendars found. Add an account in System Settings → Internet Accounts.",
            .spanish: "No se encontraron calendarios. Añade una cuenta en Ajustes del Sistema → Cuentas de Internet.",
            .russian: "Календари не найдены. Добавьте аккаунт в Настройках системы → Учётные записи Интернета."
        ],

        // Chat panel status lines (shown while a tool call runs)
        "cal.status.reading": [.english: "Checking calendar", .spanish: "Consultando el calendario", .russian: "Смотрю календарь"],
        "cal.status.creatingEvent": [.english: "Creating event", .spanish: "Creando evento", .russian: "Создаю событие"],
        "cal.status.readingReminders": [.english: "Checking reminders", .spanish: "Consultando recordatorios", .russian: "Смотрю напоминания"],
        "cal.status.creatingReminder": [.english: "Creating reminder", .spanish: "Creando recordatorio", .russian: "Создаю напоминание"],
    ]
}
