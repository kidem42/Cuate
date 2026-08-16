import Foundation

/// Self-contained localization for the PlaudAddon (pattern: `CAL()` of
/// CalendarAddon). Follows the app's current language, adds nothing to the
/// global `L()` table.
func PLL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = PlaudAddonStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum PlaudAddonStrings {
    static let table: [String: [AppLanguage: String]] = [
        "plaud.tab": [.english: "Plaud", .spanish: "Plaud", .russian: "Plaud"],

        // General tab master switch
        "plaud.general.enable": [
            .english: "Plaud voice recorder (beta)",
            .spanish: "Grabadora Plaud (beta)",
            .russian: "Диктофон Plaud (бета)"
        ],
        "plaud.general.enable.caption": [
            .english: "Lets the assistant search your Plaud recordings and read their AI summaries and transcripts. Works with Plaud. Connect your account in the Plaud section that appears in the sidebar.",
            .spanish: "Permite al asistente buscar en tus grabaciones de Plaud y leer sus resúmenes de IA y transcripciones. Works with Plaud. Conecta tu cuenta en la sección Plaud que aparece en la barra lateral.",
            .russian: "Ассистент сможет искать по записям вашего диктофона Plaud и читать их AI-саммари и транскрипты. Works with Plaud. Подключите аккаунт в секции Plaud, которая появится в боковой панели."
        ],

        // Settings tab
        "plaud.header": [.english: "Plaud", .spanish: "Plaud", .russian: "Plaud"],
        "plaud.footer": [
            .english: "Read-only: the assistant can find recordings and read notes and transcripts, but processing a recording or assigning speakers happens in the Plaud app. Note content leaves this Mac only as part of your chat request to the selected AI provider. Cuate is an independent app that works with Plaud; PLAUD is a trademark of its owner.",
            .spanish: "Solo lectura: el asistente puede encontrar grabaciones y leer notas y transcripciones, pero procesar una grabación o asignar hablantes se hace en la app de Plaud. El contenido de las notas sale de este Mac solo como parte de tu solicitud de chat al proveedor de IA seleccionado. Cuate es una app independiente que funciona con Plaud; PLAUD es una marca de su propietario.",
            .russian: "Только чтение: ассистент находит записи и читает заметки и транскрипты, а обработка записи и назначение спикеров выполняются в приложении Plaud. Содержимое заметок покидает этот Mac только в составе вашего запроса к выбранному ИИ-провайдеру. Cuate — независимое приложение, работающее с Plaud; PLAUD — товарный знак его владельца."
        ],

        // Connection section
        "plaud.connection.header": [.english: "Account", .spanish: "Cuenta", .russian: "Аккаунт"],
        "plaud.connect": [.english: "Connect Plaud Account…", .spanish: "Conectar cuenta de Plaud…", .russian: "Подключить аккаунт Plaud…"],
        "plaud.connecting": [.english: "Waiting for browser sign-in…", .spanish: "Esperando el inicio de sesión…", .russian: "Ожидание входа в браузере…"],
        "plaud.disconnect": [.english: "Disconnect", .spanish: "Desconectar", .russian: "Отключить"],
        "plaud.connected": [.english: "Connected", .spanish: "Conectado", .russian: "Подключено"],
        "plaud.notConnected": [
            .english: "Not connected — the assistant cannot see any recordings yet.",
            .spanish: "No conectado — el asistente aún no ve ninguna grabación.",
            .russian: "Не подключено — ассистент пока не видит записи."
        ],
        "plaud.cancel": [.english: "Cancel", .spanish: "Cancelar", .russian: "Отмена"],
        "plaud.expired": [
            .english: "Plaud session expired",
            .spanish: "La sesión de Plaud ha caducado",
            .russian: "Сессия Plaud истекла"
        ],
        "plaud.expired.hint": [
            .english: "Plaud no longer accepts the stored sign-in, so the assistant cannot reach your recordings. Reconnect to restore access — nothing else is lost.",
            .spanish: "Plaud ya no acepta el inicio de sesión guardado, así que el asistente no puede acceder a tus grabaciones. Vuelve a conectar para restaurar el acceso — no se pierde nada más.",
            .russian: "Plaud больше не принимает сохранённый вход, поэтому ассистент не видит записи. Переподключитесь, чтобы вернуть доступ — остальное не потеряно."
        ],
        "plaud.reconnect": [
            .english: "Reconnect Plaud Account…",
            .spanish: "Reconectar cuenta de Plaud…",
            .russian: "Переподключить аккаунт Plaud…"
        ],
        "plaud.copyLink": [.english: "Copy Sign-in Link", .spanish: "Copiar enlace de acceso", .russian: "Скопировать ссылку входа"],
        "plaud.copyLink.hint": [
            .english: "…to sign in from a different browser.",
            .spanish: "…para iniciar sesión desde otro navegador.",
            .russian: "…чтобы войти из другого браузера."
        ],
        "plaud.connect.hint": [
            .english: "Sign-in opens in your browser; Cuate never sees the password. Access can be revoked anytime here or in the Plaud app.",
            .spanish: "El inicio de sesión se abre en tu navegador; Cuate nunca ve la contraseña. El acceso puede revocarse aquí o en la app de Plaud.",
            .russian: "Вход откроется в браузере; Cuate не видит пароль. Доступ можно отозвать здесь или в приложении Plaud."
        ],

        // Exposure section
        "plaud.exposure.header": [.english: "Availability", .spanish: "Disponibilidad", .russian: "Доступность"],

        // Handing the Hermes agent its own read-only grant.
        "plaud.grant.header": [
            .english: "Hermes agent", .spanish: "Agente Hermes", .russian: "Агент Hermes"
        ],
        "plaud.grant.action": [
            .english: "Give the agent access",
            .spanish: "Dar acceso al agente",
            .russian: "Дать доступ агенту"
        ],
        "plaud.grant.caption": [
            .english: "Copies your Plaud sign-in to the agent's host, so it can search your recordings on every surface it has — chat, messengers, scheduled jobs — not only inside this app. Access stays read-only and is revocable at any time in the Plaud app. The agent needs the cuate-plaud plugin installed.",
            .spanish: "Copia tu sesión de Plaud al host del agente, para que pueda buscar tus grabaciones en todas sus superficies — chat, mensajería, tareas programadas — y no solo dentro de esta app. El acceso sigue siendo de solo lectura y es revocable en cualquier momento en la app de Plaud. El agente necesita el plugin cuate-plaud instalado.",
            .russian: "Копирует вашу авторизацию Plaud на машину агента, чтобы он искал записи на всех своих поверхностях — в чате, мессенджерах, задачах по расписанию, — а не только внутри этого приложения. Доступ остаётся только на чтение и отзывается в любой момент в приложении Plaud. Агенту нужен установленный плагин cuate-plaud."
        ],
        "plaud.grant.ok": [
            .english: "The agent has access", .spanish: "El agente tiene acceso",
            .russian: "У агента есть доступ"
        ],
        "plaud.grant.err.notconnected": [
            .english: "Connect the Plaud account first.",
            .spanish: "Conecta primero la cuenta de Plaud.",
            .russian: "Сначала подключите аккаунт Plaud."
        ],
        "plaud.grant.err.nodashboard": [
            .english: "A remote agent needs its dashboard configured (Settings → Hermes Agent) — that is how the file reaches its host.",
            .spanish: "Un agente remoto necesita su panel configurado (Ajustes → Agente Hermes): así llega el archivo a su host.",
            .russian: "Для удалённого агента нужен настроенный дашборд (Настройки → Агент Hermes) — через него файл попадает на его машину."
        ],
        "plaud.grant.err.write": [
            .english: "Could not deliver the access file:",
            .spanish: "No se pudo entregar el archivo de acceso:",
            .russian: "Не удалось доставить файл доступа:"
        ],
        "plaud.exposure.always": [
            .english: "Assistant may use Plaud in any chat",
            .spanish: "El asistente puede usar Plaud en cualquier chat",
            .russian: "Ассистент может использовать Plaud в любом чате"
        ],
        "plaud.exposure.caption": [
            .english: "On: the assistant reaches for your recordings whenever the conversation calls for them. Off: recordings stay invisible until you explicitly start a message with /plaud.",
            .spanish: "Activado: el asistente consulta tus grabaciones cuando la conversación lo requiere. Desactivado: las grabaciones permanecen invisibles hasta que empieces un mensaje con /plaud.",
            .russian: "Вкл.: ассистент обращается к записям, когда этого требует разговор. Выкл.: записи невидимы, пока вы явно не начнёте сообщение с /plaud."
        ],

        // Open in Plaud
        "plaud.openApp": [.english: "Open Plaud Web App", .spanish: "Abrir Plaud Web", .russian: "Открыть веб-приложение Plaud"],

        // Slash command
        "plaud.slash.description": [
            .english: "Ask your Plaud recordings",
            .spanish: "Preguntar a tus grabaciones de Plaud",
            .russian: "Спросить у записей Plaud"
        ],

        // Chips (chat bubbles)
        "plaud.chip.kind.note": [.english: "Plaud note", .spanish: "Nota de Plaud", .russian: "Заметка Plaud"],
        "plaud.chip.kind.transcript": [.english: "Plaud transcript", .spanish: "Transcripción de Plaud", .russian: "Транскрипт Plaud"],
        "plaud.chip.unprocessed": [.english: "not processed", .spanish: "sin procesar", .russian: "не обработано"],
        "plaud.chip.openInPlaud": [.english: "Open in Plaud", .spanish: "Abrir en Plaud", .russian: "Открыть в Plaud"],
        "plaud.chip.help": [
            .english: "Click to preview the note. Right-click to open in Plaud.",
            .spanish: "Clic para previsualizar la nota. Clic derecho para abrir en Plaud.",
            .russian: "Клик — превью заметки. Правый клик — открыть в Plaud."
        ],
        "plaud.chip.unprocessed.help": [
            .english: "Not processed yet — click to open in Plaud and start processing there.",
            .spanish: "Aún sin procesar — clic para abrir en Plaud e iniciar el procesamiento allí.",
            .russian: "Ещё не обработано — клик откроет Plaud, обработка запускается там."
        ],

        // Preview window
        "plaud.preview.transcriptTab": [.english: "Transcript", .spanish: "Transcripción", .russian: "Транскрипт"],
        "plaud.preview.polishTab": [
            .english: "Transcript (clean)",
            .spanish: "Transcripción (limpia)",
            .russian: "Транскрипт (чистовой)"
        ],
        "plaud.preview.outlineTab": [.english: "Outline", .spanish: "Esquema", .russian: "Оглавление"],
        "plaud.preview.audio": [.english: "Play audio", .spanish: "Reproducir audio", .russian: "Воспроизвести аудио"],
        "plaud.preview.audioPending": [
            .english: "Audio is still being prepared by Plaud — tap again in a few minutes.",
            .spanish: "Plaud aún está preparando el audio; inténtalo de nuevo en unos minutos.",
            .russian: "Plaud ещё готовит аудио — нажмите ещё раз через пару минут."
        ],
        "plaud.preview.loading": [.english: "Loading from Plaud…", .spanish: "Cargando desde Plaud…", .russian: "Загрузка из Plaud…"],
        "plaud.preview.seekHelp": [
            .english: "Play from this moment",
            .spanish: "Reproducir desde este momento",
            .russian: "Слушать с этого места"
        ],
        "plaud.preview.empty": [
            .english: "No content cached for this recording yet.",
            .spanish: "Aún no hay contenido en caché para esta grabación.",
            .russian: "Для этой записи пока нет содержимого."
        ],

        // Status lines (chat panel)
        "plaud.status.listing": [.english: "Browsing Plaud recordings", .spanish: "Explorando grabaciones de Plaud", .russian: "Просматриваю записи Plaud"],
        "plaud.status.searching": [.english: "Searching Plaud", .spanish: "Buscando en Plaud", .russian: "Ищу в Plaud"],
        "plaud.status.readingNote": [.english: "Reading Plaud note", .spanish: "Leyendo nota de Plaud", .russian: "Читаю заметку Plaud"],
        "plaud.status.readingTranscript": [.english: "Reading Plaud transcript", .spanish: "Leyendo transcripción de Plaud", .russian: "Читаю транскрипт Plaud"],
    ]
}
