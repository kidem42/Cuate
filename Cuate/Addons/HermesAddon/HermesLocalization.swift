import Foundation

/// Self-contained localization for the HermesAddon (pattern:
/// `CalendarLocalization.CAL`). Core AgentGateway strings live in `AGL`.
func HL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = HermesAddonStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum HermesAddonStrings {
    static let table: [String: [AppLanguage: String]] = [
        "hermes.tab": [.english: "Hermes Agent", .spanish: "Agente Hermes", .russian: "Hermes-агент"],
        "hermes.lock.switched": [
            .english: "Session model → %model% (%provider%)",
            .spanish: "Modelo de la sesión → %model% (%provider%)",
            .russian: "Модель сессии → %model% (%provider%)"
        ],
        "hermes.lock.rerouted": [
            .english: "⚠️ The gateway rerouted the lock: you asked for %requested%, but a model route in its config pins this model to %provider% — the session now runs %model% (%provider%). To really use %requested%, remove the model_routes alias on the gateway or pick a model without one.",
            .spanish: "⚠️ El gateway redirigió el bloqueo: pediste %requested%, pero una ruta de modelo en su configuración fija este modelo a %provider% — la sesión ahora usa %model% (%provider%). Para usar %requested% de verdad, elimina el alias de model_routes en el gateway o elige un modelo sin alias.",
            .russian: "⚠️ Гейтвей перенаправил лок: вы просили %requested%, но маршрут модели в его конфиге прибивает эту модель к %provider% — сессия теперь работает на %model% (%provider%). Чтобы реально использовать %requested%, уберите алиас в model_routes на гейтвее или выберите модель без алиаса."
        ],
        "hermes.lock.switchFailed": [
            .english: "Couldn't switch this session to %model%: %error%. The session keeps its previous model.",
            .spanish: "No se pudo cambiar esta sesión a %model%: %error%. La sesión mantiene su modelo anterior.",
            .russian: "Не удалось переключить сессию на %model%: %error%. Сессия остаётся на прежней модели."
        ],
        "hermes.fail.quota.hint": [
            .english: "👉 This looks like an exhausted provider quota. Pick a model from another provider in the model menu below the composer — or, if your limits have renewed, just send again: the session keeps your chosen model.",
            .spanish: "👉 Parece una cuota de proveedor agotada. Elige un modelo de otro proveedor en el menú de modelo bajo el compositor — o, si tus límites se han renovado, simplemente reenvía: la sesión mantiene tu modelo elegido.",
            .russian: "👉 Похоже, у провайдера исчерпан лимит. Выберите модель другого провайдера в меню модели под композером — или, если лимиты обновились, просто отправьте ещё раз: сессия остаётся на выбранной вами модели."
        ],
        "hermes.fail.model.hint": [
            .english: "👉 The gateway couldn't reach this session's model. Pick another one in the model menu below the composer.",
            .spanish: "👉 El gateway no pudo acceder al modelo de esta sesión. Elige otro en el menú de modelo bajo el compositor.",
            .russian: "👉 Гейтвею не удалось обратиться к модели этой сессии. Выберите другую в меню модели под композером."
        ],

        // MARK: Service-notice cards (delegation / process reports)
        "hermes.notice.delegation": [
            .english: "Subagent results",
            .spanish: "Resultados de subagentes",
            .russian: "Результаты субагентов"
        ],
        "hermes.notice.process": [
            .english: "Background process",
            .spanish: "Proceso en segundo plano",
            .russian: "Фоновый процесс"
        ],
        "hermes.notice.task": [
            .english: "Task %@",
            .spanish: "Tarea %@",
            .russian: "Задача %@"
        ],

        // MARK: General tab master switch
        "hermes.general.enable": [
            .english: "Hermes Agent (beta)",
            .spanish: "Agente Hermes (beta)",
            .russian: "Hermes-агент (бета)"
        ],
        "hermes.general.enable.caption": [
            .english: "Connect your self-hosted Hermes agent (Nous Research) as a role in the chat switcher. The agent keeps its own memory, tools and model keys; conversations continue across Telegram, CLI and this app.",
            .spanish: "Conecta tu agente Hermes autoalojado (Nous Research) como un rol en el selector del chat. El agente mantiene su propia memoria, herramientas y claves de modelos; las conversaciones continúan entre Telegram, CLI y esta app.",
            .russian: "Подключите свой самохостируемый Hermes-агент (Nous Research) как роль в свитчере чата. Агент хранит собственную память, инструменты и ключи моделей; беседы продолжаются между Telegram, CLI и этим приложением."
        ],

        // MARK: Connection section
        "hermes.conn.header": [.english: "Connection", .spanish: "Conexión", .russian: "Подключение"],
        "hermes.conn.endpoint": [.english: "Gateway address", .spanish: "Dirección del gateway", .russian: "Адрес гейтвея"],
        "hermes.conn.endpoint.help": [
            .english: "http://127.0.0.1:8642 for a gateway on this Mac; a Tailscale/LAN address for a remote one.",
            .spanish: "http://127.0.0.1:8642 para un gateway en este Mac; una dirección de Tailscale/LAN para uno remoto.",
            .russian: "http://127.0.0.1:8642 для гейтвея на этом Mac; адрес Tailscale/LAN — для удалённого."
        ],
        "hermes.conn.key": [.english: "API key", .spanish: "Clave API", .russian: "API-ключ"],
        "hermes.conn.key.placeholder": [
            .english: "API_SERVER_KEY from the gateway's .env",
            .spanish: "API_SERVER_KEY del .env del gateway",
            .russian: "API_SERVER_KEY из .env гейтвея"
        ],
        "hermes.conn.key.save": [.english: "Save", .spanish: "Guardar", .russian: "Сохранить"],
        "hermes.conn.key.remove": [.english: "Remove", .spanish: "Eliminar", .russian: "Удалить"],
        "hermes.conn.test": [.english: "Test connection", .spanish: "Probar conexión", .russian: "Проверить соединение"],
        "hermes.conn.testing": [.english: "Checking…", .spanish: "Comprobando…", .russian: "Проверяю…"],
        "hermes.conn.security": [
            .english: "The key is stored only in the Keychain. It grants full access to the agent's tools — including its terminal. For a remote gateway, prefer Tailscale/WireGuard over exposing the port.",
            .spanish: "La clave se guarda solo en el Llavero. Da acceso completo a las herramientas del agente — incluida su terminal. Para un gateway remoto, prefiere Tailscale/WireGuard antes que exponer el puerto.",
            .russian: "Ключ хранится только в Keychain. Он даёт полный доступ к инструментам агента — включая его терминал. Для удалённого гейтвея используйте Tailscale/WireGuard, а не открытый порт."
        ],

        // MARK: Host app features in agent sessions (separate opt-in)
        "hermes.appFeatures.header": [
            .english: "App features",
            .spanish: "Funciones de la app",
            .russian: "Функции приложения"
        ],
        "hermes.appFeatures.toggle": [
            .english: "Image processing and OCR in agent sessions",
            .spanish: "Procesado de imágenes y OCR en sesiones del agente",
            .russian: "Обработка изображений и OCR в сессиях агента"
        ],
        "hermes.appFeatures.caption": [
            .english: "Off: the agent handles attachments entirely on its own. On: the app's Upscale, Remove Background, Remove Objects and Extract Text actions also appear in agent chats — they run on the app's own models and keys (pick the models in the Images tab and the OCR provider in the Chat tab), and results stay in this app only, invisible to the agent's other surfaces.",
            .spanish: "Desactivado: el agente gestiona los adjuntos por su cuenta. Activado: las acciones de la app — Escalar, Quitar fondo, Eliminar objetos y Extraer texto — aparecen también en los chats del agente; usan los modelos y claves propios de la app (elige los modelos en la pestaña Imágenes y el proveedor de OCR en la pestaña Chat), y los resultados se quedan solo en esta app, invisibles para las demás superficies del agente.",
            .russian: "Выкл.: агент разбирается с вложениями полностью сам. Вкл.: действия приложения — «Апскейл», «Убрать фон», «Удалить объекты» и «Извлечь текст» — появляются и в чатах агента; они работают на собственных моделях и ключах приложения (модели — во вкладке «Изображения», провайдер OCR — во вкладке «Чат»), а результаты остаются только в этом приложении и не видны другим поверхностям агента."
        ],

        // MARK: Dashboard courier (remote files)
        "hermes.dash.header": [
            .english: "Remote files (dashboard)",
            .spanish: "Archivos remotos (dashboard)",
            .russian: "Файлы на удалённой машине (дашборд)"
        ],
        "hermes.dash.url": [
            .english: "Dashboard address",
            .spanish: "Dirección del dashboard",
            .russian: "Адрес дашборда"
        ],
        "hermes.dash.url.placeholder": [
            .english: "http://HOST:9119 (via Tailscale/SSH tunnel)",
            .spanish: "http://HOST:9119 (vía Tailscale/túnel SSH)",
            .russian: "http://ХОСТ:9119 (через Tailscale/SSH-туннель)"
        ],
        "hermes.dash.token": [
            .english: "Dashboard session token",
            .spanish: "Token de sesión del dashboard",
            .russian: "Session-токен дашборда"
        ],
        "hermes.dash.caption": [
            .english: "Only needed for a REMOTE gateway: file attachments are uploaded to the agent's machine (~/cuate-uploads) through the Hermes dashboard's files API before sending. A local gateway reads your files directly — leave empty.",
            .spanish: "Solo para un gateway REMOTO: los adjuntos se suben a la máquina del agente (~/cuate-uploads) mediante la API de archivos del dashboard antes de enviar. Un gateway local lee tus archivos directamente — déjalo vacío.",
            .russian: "Нужно только для УДАЛЁННОГО гейтвея: файлы-вложения перед отправкой загружаются на машину агента (~/cuate-uploads) через files-API дашборда Hermes. Локальный гейтвей читает файлы напрямую — оставьте пустым."
        ],
        "hermes.dash.missing": [
            .english: "The gateway is remote, but the dashboard courier is not set up (Settings → Hermes Agent → Remote files) — the agent cannot read paths from this Mac.",
            .spanish: "El gateway es remoto, pero el courier del dashboard no está configurado (Ajustes → Agente Hermes → Archivos remotos) — el agente no puede leer rutas de este Mac.",
            .russian: "Гейтвей удалённый, а курьер дашборда не настроен (Настройки → Hermes-агент → Файлы на удалённой машине) — агент не сможет прочитать пути с этого Mac."
        ],
        "hermes.dash.uploadFailed": [
            .english: "Failed to upload to the agent's machine: %@",
            .spanish: "No se pudo subir a la máquina del agente: %@",
            .russian: "Не удалось загрузить на машину агента: %@"
        ],

        // MARK: Onboarding (server-side setup)
        "hermes.setup.header": [.english: "Gateway setup", .spanish: "Configuración del gateway", .russian: "Настройка гейтвея"],
        "hermes.setup.intro": [
            .english: "On the machine running Hermes, enable the API server and start the gateway:",
            .spanish: "En la máquina donde corre Hermes, activa el servidor API y arranca el gateway:",
            .russian: "На машине с Hermes включите API-сервер и запустите гейтвей:"
        ],
        "hermes.setup.local.title": [
            .english: "Hermes on this Mac — run in Terminal once:",
            .spanish: "Hermes en este Mac — ejecuta en Terminal una vez:",
            .russian: "Hermes на этом Mac — выполните в Терминале один раз:"
        ],
        "hermes.setup.showKey": [
            .english: "The API server is already enabled? Just read the existing key:",
            .spanish: "¿El servidor API ya está activado? Solo lee la clave existente:",
            .russian: "API-сервер уже включён? Просто покажите существующий ключ:"
        ],
        "hermes.setup.remote.title": [
            .english: "Hermes on a remote machine (VPS, cloud server, home server, Mac mini) — over SSH:",
            .spanish: "Hermes en una máquina remota (VPS, servidor en la nube, servidor doméstico, Mac mini) — por SSH:",
            .russian: "Hermes на удалённой машине (VPS, облачный сервер, домашний сервер, Mac mini) — через SSH:"
        ],
        "hermes.setup.remote.caption": [
            .english: "Then set the gateway address above to http://HOST:8642. API_SERVER_HOST=0.0.0.0 is required — by default the server listens on loopback only. Prefer a Tailscale/WireGuard address over exposing the port to the internet.",
            .spanish: "Luego pon la dirección del gateway arriba como http://HOST:8642. API_SERVER_HOST=0.0.0.0 es obligatorio — por defecto el servidor escucha solo en loopback. Prefiere una dirección de Tailscale/WireGuard antes que exponer el puerto a internet.",
            .russian: "Затем укажите адрес гейтвея выше: http://ХОСТ:8642. API_SERVER_HOST=0.0.0.0 обязателен — по умолчанию сервер слушает только loopback. Для доступа используйте адрес Tailscale/WireGuard, а не открытый в интернет порт."
        ],
        "hermes.setup.copy": [.english: "Copy", .spanish: "Copiar", .russian: "Скопировать"],

        // MARK: Model routing
        "hermes.model.header": [.english: "Agent model", .spanish: "Modelo del agente", .russian: "Модель агента"],
        "hermes.model.auto": [
            .english: "Agent's own default",
            .spanish: "Predeterminado del agente",
            .russian: "Как настроено у агента"
        ],
        "hermes.model.caption": [
            .english: "The agent is a black box with its own configuration — new sessions follow its configured model unless you pick another one here.",
            .spanish: "El agente es una caja negra con su propia configuración — las sesiones nuevas siguen su modelo configurado salvo que elijas otro aquí.",
            .russian: "Агент — чёрный ящик со своей конфигурацией: новые сессии идут на его модель, если здесь не выбрана другая."
        ],

        // MARK: Sessions section
        "hermes.sessions.header": [.english: "Agent sessions", .spanish: "Sesiones del agente", .russian: "Сессии агента"],
        "hermes.sessions.caption": [
            .english: "The agent's sessions exist beyond this app (Telegram, CLI, cron). \"Continue here\" binds the role's chat to an existing session.",
            .spanish: "Las sesiones del agente existen más allá de esta app (Telegram, CLI, cron). \"Continuar aquí\" vincula el chat del rol a una sesión existente.",
            .russian: "Сессии агента существуют и без этого приложения (Telegram, CLI, крон). «Продолжить здесь» привязывает чат роли к выбранной сессии."
        ],
        "hermes.sessions.continue": [.english: "Continue here", .spanish: "Continuar aquí", .russian: "Продолжить здесь"],
        "hermes.sessions.delete": [.english: "Delete", .spanish: "Eliminar", .russian: "Удалить"],
        "hermes.sessions.refresh": [.english: "Refresh", .spanish: "Actualizar", .russian: "Обновить"],
        "hermes.sessions.empty": [.english: "No sessions on the gateway.", .spanish: "No hay sesiones en el gateway.", .russian: "На гейтвее нет сессий."],
        "hermes.sessions.working": [.english: "The agent is working in this session…", .spanish: "El agente está trabajando en esta sesión…", .russian: "Агент работает в этой сессии…"],
        "hermes.sessions.creating": [.english: "Creating session…", .spanish: "Creando sesión…", .russian: "Создаю сессию…"],
        "hermes.sessions.createFailed": [
            .english: "Couldn't create the session — the gateway didn't respond. Check the connection and try again.",
            .spanish: "No se pudo crear la sesión: el gateway no respondió. Revisa la conexión e inténtalo de nuevo.",
            .russian: "Не удалось создать сессию — гейтвей не ответил. Проверьте соединение и попробуйте ещё раз."
        ],
        "hermes.sessions.messages": [.english: "%d messages", .spanish: "%d mensajes", .russian: "%d сообщений"],

        // MARK: Formatting briefing (per-session preamble)
        "hermes.briefing.header": [
            .english: "Formatting briefing",
            .spanish: "Instrucciones de formato",
            .russian: "Брифинг по форматированию"
        ],
        "hermes.briefing.toggle": [
            .english: "Teach the agent Cuate's formatting",
            .spanish: "Enseñar al agente el formato de Cuate",
            .russian: "Обучать агента форматированию Cuate"
        ],
        "hermes.briefing.caption": [
            .english: "The first message of each session carries a hidden preamble telling the agent how to format replies for this app: rich Markdown, HTML/Mermaid blocks only for interactives and diagrams, full re-issues of edited documents. Costs ~350 tokens once per session; the agent's other surfaces are unaffected, though the preamble is visible when that session's transcript is read from Telegram or the CLI.",
            .spanish: "El primer mensaje de cada sesión lleva un preámbulo oculto que indica al agente cómo formatear las respuestas para esta app: Markdown completo, bloques HTML/Mermaid solo para interactivos y diagramas, reediciones completas de documentos corregidos. Cuesta ~350 tokens una vez por sesión; las demás superficies del agente no se ven afectadas, aunque el preámbulo es visible al leer esa sesión desde Telegram o la CLI.",
            .russian: "Первое сообщение каждой сессии несёт скрытую преамбулу — как оформлять ответы для этого приложения: полноценный Markdown, блоки HTML/Mermaid только для интерактивов и диаграмм, правки документов — полным переизданием. Стоит ~350 токенов один раз на сессию; другие поверхности агента не затрагиваются, но преамбула видна, если читать транскрипт той же сессии из Telegram или CLI."
        ],

        // MARK: Notifications
        "hermes.notif.header": [.english: "Notifications", .spanish: "Notificaciones", .russian: "Уведомления"],
        "hermes.notif.hideDetails": [
            .english: "Hide command details in banners",
            .spanish: "Ocultar detalles de comandos en los avisos",
            .russian: "Скрывать детали команд в баннерах"
        ],
        "hermes.notif.hideDetails.caption": [
            .english: "Banners say \"the agent asks permission\" without the command text — it can be visible on the lock screen.",
            .spanish: "Los avisos dicen \"el agente pide permiso\" sin el texto del comando — puede verse en la pantalla bloqueada.",
            .russian: "Баннер скажет «агент просит разрешение» без текста команды — он может быть виден на заблокированном экране."
        ],

        // MARK: Diagnostics
        "hermes.diag.header": [.english: "Diagnostics", .spanish: "Diagnóstico", .russian: "Диагностика"],
        "hermes.diag.server": [.english: "Gateway", .spanish: "Gateway", .russian: "Гейтвей"],

        // MARK: Session management (sidebar)
        "hermes.sessions.new": [.english: "New session", .spanish: "Nueva sesión", .russian: "Новая сессия"],
        "hermes.sessions.rename": [.english: "Rename", .spanish: "Renombrar", .russian: "Переименовать"],
        "hermes.sessions.pin": [.english: "Pin", .spanish: "Fijar", .russian: "Закрепить"],
        "hermes.sessions.unpin": [.english: "Unpin", .spanish: "Soltar", .russian: "Открепить"],
        "hermes.sessions.color": [.english: "Color", .spanish: "Color", .russian: "Цвет"],
        "hermes.sessions.color.red": [.english: "Red", .spanish: "Rojo", .russian: "Красный"],
        "hermes.sessions.color.orange": [.english: "Orange", .spanish: "Naranja", .russian: "Оранжевый"],
        "hermes.sessions.color.yellow": [.english: "Yellow", .spanish: "Amarillo", .russian: "Жёлтый"],
        "hermes.sessions.color.green": [.english: "Green", .spanish: "Verde", .russian: "Зелёный"],
        "hermes.sessions.color.teal": [.english: "Teal", .spanish: "Turquesa", .russian: "Бирюзовый"],
        "hermes.sessions.color.blue": [.english: "Blue", .spanish: "Azul", .russian: "Синий"],
        "hermes.sessions.color.purple": [.english: "Purple", .spanish: "Morado", .russian: "Фиолетовый"],
        "hermes.sessions.color.pink": [.english: "Pink", .spanish: "Rosa", .russian: "Розовый"],
        "hermes.sessions.color.gray": [.english: "Gray", .spanish: "Gris", .russian: "Серый"],
        "hermes.sessions.color.none": [.english: "No color", .spanish: "Sin color", .russian: "Без цвета"],
        "hermes.sidebar.openApp": [
            .english: "Configure in the Hermes app (skill toggles, backends, messengers)",
            .spanish: "Configurar en la app de Hermes (habilidades, backends, mensajeros)",
            .russian: "Настроить в приложении Hermes (тоглы скиллов, бэкенды, мессенджеры)"
        ],
        "hermes.slash.skills": [.english: "Agent skills", .spanish: "Habilidades del agente", .russian: "Скиллы агента"],
        "hermes.slash.cuate": [.english: "Cuate (local)", .spanish: "Cuate (local)", .russian: "Cuate (локально)"],
        "hermes.composer.effort": [.english: "Effort", .spanish: "Esfuerzo", .russian: "Усилие"],
        "hermes.composer.effort.default": [.english: "Agent default", .spanish: "Predeterminado", .russian: "Как у агента"],
        "hermes.vps.open": [
            .english: "VPS setup guide",
            .spanish: "Guía de instalación en VPS",
            .russian: "Гайд по установке на VPS"
        ],
        "hermes.vps.caption": [
            .english: "Full walkthrough: your own agent on a VPS over HTTPS, reachable from any network without a VPN — 4 steps, two paste-blocks. Self-sufficient: read it here, or copy and hand it to any capable LLM to be walked through.",
            .spanish: "Guía completa: tu propio agente en un VPS por HTTPS, accesible desde cualquier red sin VPN — 4 pasos, dos bloques para pegar. Autosuficiente: léela aquí, o cópiala y dásela a cualquier LLM capaz para que te acompañe.",
            .russian: "Полный проход: свой агент на VPS по HTTPS, доступен из любой сети без VPN — 4 шага, две вставки. Самодостаточный текст: читайте здесь или скопируйте и отдайте любой нейронке — она проведёт по шагам."
        ],
        "hermes.composer.context.help": [
            .english: "How full this session's context is (tokens of the last turn, against this model's own window). Click to compact it now — the gateway also compacts on its own near the limit.",
            .spanish: "Cuán lleno está el contexto de esta sesión (tokens del último turno, sobre la ventana propia de este modelo). Clic para compactarlo ahora — el gateway también compacta solo cerca del límite.",
            .russian: "Насколько заполнен контекст этой сессии (токены последнего хода от окна ЭТОЙ модели). Клик — сжать сейчас; у предела гейтвей сжимает и сам."
        ],
        "hermes.composer.model.help": [
            .english: "Model for THIS session (switches the gateway's session lock)",
            .spanish: "Modelo para ESTA sesión (cambia el bloqueo de sesión del gateway)",
            .russian: "Модель ЭТОЙ сессии (переключает session lock на гейтвее)"
        ],

        // MARK: Sidebar section tooltips (what the categories ARE)
        "hermes.sessions.help": [
            .english: "The agent's conversations across ALL its surfaces — Telegram, CLI, this app. Click one to continue it here; right-click to rename, pin, color or delete. The badge counts messages that arrived while the thread was closed.",
            .spanish: "Las conversaciones del agente en TODAS sus superficies — Telegram, CLI, esta app. Clic para continuarla aquí; clic derecho para renombrar, fijar, colorear o borrar. La insignia cuenta mensajes llegados con el hilo cerrado.",
            .russian: "Беседы агента на ВСЕХ его поверхностях — Telegram, CLI, это приложение. Клик — продолжить здесь; правый клик — переименовать, закрепить, цвет, удалить. Бейдж считает сообщения, пришедшие, пока тред был закрыт."
        ],
        "hermes.skills.help": [
            .english: "The agent's saved skills — procedures it learned (notes, arXiv, ASCII art…). Invoke one in the chat by typing /skill-name; enable/disable them in the Hermes app.",
            .spanish: "Las habilidades guardadas del agente — procedimientos aprendidos (notas, arXiv, ASCII art…). Invócalas en el chat con /nombre; se activan en la app de Hermes.",
            .russian: "Сохранённые навыки агента — его выученные процедуры (заметки, arXiv, ASCII-арт…). Вызываются в чате через /имя-скилла; включаются и выключаются в приложении Hermes."
        ],
        "hermes.toolsets.help": [
            .english: "Tool groups the agent can use on ITS host: web search, browser, terminal, files… Dimmed = disabled on the gateway; toggling lives in the Hermes app.",
            .spanish: "Grupos de herramientas que el agente usa en SU host: web, navegador, terminal, archivos… Atenuado = desactivado en el gateway; se conmutan en la app de Hermes.",
            .russian: "Группы инструментов, доступные агенту на ЕГО хосте: веб-поиск, браузер, терминал, файлы… Приглушённые — выключены на гейтвее; переключаются в приложении Hermes."
        ],
        "hermes.agent.help": [
            .english: "The agent's passport: the model it currently thinks with, and the host where its commands and tools actually execute — check it before approving anything.",
            .spanish: "El pasaporte del agente: el modelo con el que piensa ahora y el host donde se ejecutan sus comandos y herramientas — míralo antes de aprobar algo.",
            .russian: "Паспорт агента: модель, которой он сейчас думает, и хост, где реально исполняются его команды и инструменты — сверяйтесь перед тем, как что-то одобрять."
        ],

        // MARK: Sidebar (management column)
        "hermes.sidebar.skills": [.english: "Skills", .spanish: "Habilidades", .russian: "Скиллы"],
        "hermes.sidebar.toolsets": [.english: "Toolsets", .spanish: "Herramientas", .russian: "Тулсеты"],
        "hermes.sidebar.agent": [.english: "Agent", .spanish: "Agente", .russian: "Агент"],
        "hermes.sidebar.toolsetOff": [.english: "disabled", .spanish: "desactivado", .russian: "выключен"],
        "hermes.sidebar.more": [.english: "+%d more", .spanish: "+%d más", .russian: "ещё %d"],
        "hermes.sidebar.execNote": [
            .english: "Tools and commands run on this host",
            .spanish: "Las herramientas y comandos se ejecutan en este host",
            .russian: "Инструменты и команды выполняются на этом хосте"
        ],
        "hermes.sidebar.toggle": [
            .english: "Agent panel",
            .spanish: "Panel del agente",
            .russian: "Панель агента"
        ],

        // MARK: Chat-side
        "hermes.noKey": [
            .english: "No gateway key yet — paste the API_SERVER_KEY in Settings → Hermes Agent (opening it now).",
            .spanish: "Aún no hay clave del gateway — pega la API_SERVER_KEY en Ajustes → Agente Hermes (abriéndolo ahora).",
            .russian: "Ключ гейтвея ещё не введён — вставьте API_SERVER_KEY в Настройках → Hermes-агент (открываю их)."
        ],
        "hermes.setup.local.auto": [
            .english: "Hermes on this Mac needs no terminal: when the gateway is unreachable, the Connection section offers a one-click setup that configures it and installs it as a service.",
            .spanish: "Hermes en este Mac no necesita terminal: cuando el gateway no responde, la sección Conexión ofrece una configuración de un clic que lo configura y lo instala como servicio.",
            .russian: "Для Hermes на этом Маке терминал не нужен: когда гейтвей недоступен, в секции «Подключение» появляется настройка в один клик — она всё конфигурирует и ставит сервис."
        ],

        // MARK: One-click local gateway setup
        "hermes.auto.found": [
            .english: "Hermes is installed on this Mac, but its gateway (which hosts the API server) is not running. Cuate can configure it and install it as a background service that starts on login.",
            .spanish: "Hermes está instalado en este Mac, pero su gateway (que aloja el servidor API) no está en marcha. Cuate puede configurarlo e instalarlo como servicio en segundo plano que arranca al iniciar sesión.",
            .russian: "Hermes установлен на этом Маке, но его гейтвей (в нём живёт API-сервер) не запущен. Cuate может настроить его и установить как фоновый сервис с автозапуском при входе."
        ],
        "hermes.auto.run": [
            .english: "Set up and start the service",
            .spanish: "Configurar y arrancar el servicio",
            .russian: "Настроить и запустить сервис"
        ],
        "hermes.auto.running": [
            .english: "Setting up the gateway…",
            .spanish: "Configurando el gateway…",
            .russian: "Настраиваю гейтвей…"
        ],
        "hermes.auto.ok": [
            .english: "Done: the gateway is installed as a service (starts on login, listed as “Hermes Gateway (Cuate)” in Login Items), the key from .env is saved and verified.",
            .spanish: "Listo: el gateway está instalado como servicio (arranca al iniciar sesión, aparece como “Hermes Gateway (Cuate)” en Ítems de inicio), la clave de .env está guardada y verificada.",
            .russian: "Готово: гейтвей установлен как сервис (автозапуск при входе, в «Объектах входа» — «Hermes Gateway (Cuate)»), ключ из .env сохранён и проверен."
        ],
        "hermes.auto.step.env": [
            .english: "Completing ~/.hermes/.env…",
            .spanish: "Completando ~/.hermes/.env…",
            .russian: "Дозаполняю ~/.hermes/.env…"
        ],
        "hermes.auto.step.install": [
            .english: "Installing the gateway service…",
            .spanish: "Instalando el servicio del gateway…",
            .russian: "Устанавливаю сервис гейтвея…"
        ],
        "hermes.auto.step.patch": [
            .english: "Enabling the accurate context metric…",
            .spanish: "Activando la métrica de contexto precisa…",
            .russian: "Включаю точную метрику контекста…"
        ],
        "hermes.patch.found": [
            .english: "This gateway is missing Cuate's improvements: the real context fill in the API (usage.context_tokens) and mid-turn follow-ups (/steer, Hermes 0.20+). Cuate can patch the gateway's api_server.py — anchored edits, a backup saved next to the file. A Hermes update rolls this back; the offer will then reappear here.",
            .spanish: "A este gateway le faltan las mejoras de Cuate: el llenado real del contexto en la API (usage.context_tokens) y los mensajes durante el turno (/steer, Hermes 0.20+). Cuate puede parchear api_server.py del gateway: ediciones ancladas, con copia de seguridad junto al archivo. Una actualización de Hermes lo revierte; la oferta reaparecerá aquí.",
            .russian: "На этом гейтвее нет улучшений Cuate: реального заполнения контекста в API (usage.context_tokens) и досылки сообщений в работающий ход (/steer, Hermes 0.20+). Cuate может пропатчить api_server.py гейтвея — правки по якорям, бэкап останется рядом. Обновление Hermes откатит правки — предложение снова появится здесь."
        ],
        "hermes.patch.run": [
            .english: "Enable accurate context gauge",
            .spanish: "Activar medidor de contexto preciso",
            .russian: "Включить точный гейдж контекста"
        ],
        "hermes.patch.running": [
            .english: "Patching the gateway and restarting…",
            .spanish: "Parcheando el gateway y reiniciando…",
            .russian: "Патчу гейтвей и перезапускаю…"
        ],
        "hermes.patch.ok": [
            .english: "Done: the gateway now reports the real context fill and accepts mid-turn follow-ups.",
            .spanish: "Listo: el gateway ahora informa el llenado real del contexto y acepta mensajes durante el turno.",
            .russian: "Готово: гейтвей теперь отдаёт реальное заполнение контекста и принимает досылку сообщений в работающий ход."
        ],
        "hermes.patch.err": [
            .english: "Could not patch the gateway:",
            .spanish: "No se pudo parchear el gateway:",
            .russian: "Не удалось пропатчить гейтвей:"
        ],
        "hermes.setup.patch.title": [
            .english: "Gateway patch: context gauge + mid-turn follow-ups",
            .spanish: "Parche del gateway: medidor de contexto + mensajes durante el turno",
            .russian: "Патч гейтвея: гейдж контекста + досылка сообщений"
        ],
        "hermes.setup.patch.caption": [
            .english: "Paste into the remote machine's terminal AFTER updating Hermes to 0.20 (hermes update). Two anchored edits to api_server.py: usage.context_tokens (the real context fill the API otherwise omits) and POST /steer (follow-ups reach the agent mid-turn instead of waiting). Backup next to the file; refuses on unknown layouts without touching anything. Safe to re-run; repeat after every Hermes update.",
            .spanish: "Pega esto en la terminal de la máquina remota DESPUÉS de actualizar Hermes a 0.20 (hermes update). Dos ediciones ancladas en api_server.py: usage.context_tokens (el llenado real del contexto que la API omite) y POST /steer (los mensajes llegan al agente durante el turno en vez de esperar). Copia de seguridad junto al archivo; se niega ante estructuras desconocidas sin tocar nada. Se puede repetir; repítelo tras cada actualización de Hermes.",
            .russian: "Вставьте в терминал удалённой машины ПОСЛЕ обновления Hermes до 0.20 (hermes update). Две правки по якорям в api_server.py: usage.context_tokens (реальное заполнение контекста, которого нет в API) и POST /steer (сообщения доходят до агента прямо в работающий ход, а не ждут его конца). Бэкап рядом с файлом; на незнакомой структуре откажется, ничего не тронув. Повторный запуск безопасен; после каждого обновления Hermes — повторить."
        ],
        "hermes.auto.step.reload": [
            .english: "Starting the gateway…",
            .spanish: "Arrancando el gateway…",
            .russian: "Запускаю гейтвей…"
        ],
        "hermes.auto.step.health": [
            .english: "Waiting for the gateway to answer…",
            .spanish: "Esperando respuesta del gateway…",
            .russian: "Жду ответа гейтвея…"
        ],
        "hermes.auto.err.keychain": [
            .english: "Could not save the key to the Keychain — open Settings → API Keys and allow Keychain access, then try again.",
            .spanish: "No se pudo guardar la clave en el Llavero — abre Ajustes → Claves API y permite el acceso al Llavero, luego inténtalo de nuevo.",
            .russian: "Не удалось сохранить ключ в Keychain — разрешите доступ к связке ключей и попробуйте ещё раз."
        ],
        "hermes.auto.err.probe": [
            .english: "The gateway is up, but the connection test still fails — see the message above.",
            .spanish: "El gateway está en marcha, pero la prueba de conexión sigue fallando — mira el mensaje de arriba.",
            .russian: "Гейтвей поднялся, но проверка соединения всё ещё не проходит — см. сообщение выше."
        ],
        "hermes.auto.err.cli": [
            .english: "The hermes CLI was not found on this Mac.",
            .spanish: "No se encontró la CLI de hermes en este Mac.",
            .russian: "CLI hermes на этом Маке не найден."
        ],
        "hermes.auto.err.env": [
            .english: "Could not update ~/.hermes/.env:",
            .spanish: "No se pudo actualizar ~/.hermes/.env:",
            .russian: "Не удалось обновить ~/.hermes/.env:"
        ],
        "hermes.auto.err.install": [
            .english: "hermes gateway install failed:",
            .spanish: "hermes gateway install falló:",
            .russian: "hermes gateway install завершился с ошибкой:"
        ],
        "hermes.auto.err.timeout": [
            .english: "The gateway did not come up — check ~/.hermes/logs/gateway.log.",
            .spanish: "El gateway no arrancó — revisa ~/.hermes/logs/gateway.log.",
            .russian: "Гейтвей так и не поднялся — загляните в ~/.hermes/logs/gateway.log."
        ],
        "hermes.role.help": [
            .english: "Hermes agent role — the conversation lives on the agent and continues across its other surfaces",
            .spanish: "Rol del agente Hermes — la conversación vive en el agente y continúa en sus otras superficies",
            .russian: "Роль Hermes-агента — беседа живёт у агента и продолжается на других его поверхностях"
        ]
    ]
}
