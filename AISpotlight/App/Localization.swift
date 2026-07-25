import Foundation

/// Interface languages. English is the default and the fallback for any
/// missing translation.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case spanish = "es"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .russian: return "Русский"
        }
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

/// Lightweight in-app localization independent of the system language.
/// `L("key")` returns the string for the current language, falling back to
/// English. Views re-render because they read `AppSettings.language`
/// (a @Published property) in their body.
func L(_ key: String) -> String {
    let lang = Localization.currentLanguage
    if let table = Localization.strings[key] {
        return table[lang] ?? table[.english] ?? key
    }
    return key
}

enum Localization {
    /// Cached so `L()` (called from many non-@MainActor spots) stays cheap and
    /// synchronous; updated whenever the language changes.
    static var currentLanguage: AppLanguage = .english

    static let strings: [String: [AppLanguage: String]] = [
        // MARK: Tabs
        "tab.chat": [.english: "Chat", .spanish: "Chat", .russian: "Чат"],
        "tab.keys": [.english: "API Keys", .spanish: "Claves API", .russian: "Ключи API"],
        "tab.voice": [.english: "Voice", .spanish: "Voz", .russian: "Голос"],
        "tab.general": [.english: "General", .spanish: "General", .russian: "Общие"],
        "tab.appearance": [.english: "Appearance", .spanish: "Apariencia", .russian: "Внешний вид"],
        "tab.prompts": [.english: "Prompts", .spanish: "Prompts", .russian: "Промпты"],
        "sidebar.addons": [.english: "Add-ons", .spanish: "Complementos", .russian: "Аддоны"],
        "tab.costs": [.english: "Costs", .spanish: "Costes", .russian: "Расходы"],

        // MARK: Local models (Ollama)
        "tab.localModels": [.english: "Local models", .spanish: "Modelos locales", .russian: "Локальные модели"],
        "local.enable": [.english: "Enable local models", .spanish: "Activar modelos locales", .russian: "Локальные модели"],
        "local.enable.caption": [.english: "Run models on your Mac via Ollama or another OpenAI-compatible server. Free, offline, no API key.", .spanish: "Ejecuta modelos en tu Mac con Ollama u otro servidor compatible con OpenAI. Gratis, sin conexión, sin clave API.", .russian: "Запуск моделей на вашем Mac через Ollama или другой OpenAI-совместимый сервер. Бесплатно, офлайн, без ключа API."],
        "local.online.enable": [.english: "Enable online (cloud) models", .spanish: "Activar modelos en línea (nube)", .russian: "Онлайн-модели (облако)"],
        "local.online.enable.caption": [.english: "Turn off to use local models only (fully offline).", .spanish: "Desactívalo para usar solo modelos locales (sin conexión).", .russian: "Выключите, чтобы использовать только локальные модели (полностью офлайн)."],
        "local.header": [.english: "Local models", .spanish: "Modelos locales", .russian: "Локальные модели"],
        "local.compat": [.english: "Connects to any server speaking the OpenAI-compatible API (OpenAI v1, /v1/chat/completions). Chat works with Ollama, LM Studio, llama.cpp, vLLM, LocalAI. The model management below is available for Ollama only.", .spanish: "Se conecta a cualquier servidor con API compatible con OpenAI (OpenAI v1, /v1/chat/completions). El chat funciona con Ollama, LM Studio, llama.cpp, vLLM, LocalAI. La gestión de modelos de abajo es solo para Ollama.", .russian: "Подключается к любому серверу с OpenAI-совместимым API (OpenAI v1, /v1/chat/completions). Чат работает с Ollama, LM Studio, llama.cpp, vLLM, LocalAI. Управление моделями ниже доступно только для Ollama."],
        "local.installHint": [.english: "No Ollama yet? Install it, then pull a model (e.g. \"gemma3\") below or with: ollama pull gemma3", .spanish: "¿Aún no tienes Ollama? Instálalo y descarga un modelo (p. ej. \"gemma3\") abajo o con: ollama pull gemma3", .russian: "Нет Ollama? Установите его и скачайте модель (напр. «gemma3») ниже или командой: ollama pull gemma3"],
        "local.install": [.english: "Install Ollama", .spanish: "Instalar Ollama", .russian: "Установить Ollama"],
        "local.connection": [.english: "Connection", .spanish: "Conexión", .russian: "Подключение"],
        "local.endpoint": [.english: "Endpoint URL", .spanish: "URL del endpoint", .russian: "Адрес эндпоинта"],
        "local.reset": [.english: "Reset", .spanish: "Restablecer", .russian: "Сброс"],
        "local.test": [.english: "Test connection", .spanish: "Probar conexión", .russian: "Проверить подключение"],
        "local.testing": [.english: "Testing…", .spanish: "Probando…", .russian: "Проверка…"],
        "local.status.ok": [.english: "Connected to Ollama", .spanish: "Conectado a Ollama", .russian: "Подключено к Ollama"],
        "local.status.okGeneric": [.english: "Endpoint reachable (not Ollama — model management unavailable)", .spanish: "Endpoint accesible (no es Ollama; gestión de modelos no disponible)", .russian: "Эндпоинт доступен (не Ollama — управление моделями недоступно)"],
        "local.status.fail": [.english: "Could not reach the endpoint", .spanish: "No se pudo acceder al endpoint", .russian: "Не удалось подключиться к эндпоинту"],
        "local.installed": [.english: "Installed models", .spanish: "Modelos instalados", .russian: "Установленные модели"],
        "local.noModels": [.english: "No models installed yet.", .spanish: "Aún no hay modelos instalados.", .russian: "Модели ещё не установлены."],
        "local.refresh": [.english: "Refresh", .spanish: "Actualizar", .russian: "Обновить"],
        "local.loaded": [.english: "In memory", .spanish: "En memoria", .russian: "В памяти"],
        "local.start": [.english: "Start", .spanish: "Iniciar", .russian: "Запустить"],
        "local.stop": [.english: "Stop", .spanish: "Detener", .russian: "Остановить"],
        "local.delete": [.english: "Delete", .spanish: "Eliminar", .russian: "Удалить"],
        "local.delete.confirm": [.english: "Delete this model from disk?", .spanish: "¿Eliminar este modelo del disco?", .russian: "Удалить эту модель с диска?"],
        "local.vision": [.english: "vision", .spanish: "visión", .russian: "зрение"],
        "local.tools": [.english: "tools", .spanish: "herramientas", .russian: "инструменты"],
        "local.pull": [.english: "Download a model", .spanish: "Descargar un modelo", .russian: "Скачать модель"],
        "local.pull.placeholder": [.english: "Model name, e.g. gemma3", .spanish: "Nombre del modelo, p. ej. gemma3", .russian: "Имя модели, напр. gemma3"],
        "local.download": [.english: "Download", .spanish: "Descargar", .russian: "Скачать"],
        "local.cancel": [.english: "Cancel", .spanish: "Cancelar", .russian: "Отмена"],
        "local.manageExternally": [.english: "Manage models in your server's own tool.", .spanish: "Gestiona los modelos con la herramienta de tu servidor.", .russian: "Управляйте моделями в инструменте вашего сервера."],
        "menu.localModel": [.english: "Local model", .spanish: "Modelo local", .russian: "Локальная модель"],
        "local.notLoaded": [.english: "Not loaded", .spanish: "No cargado", .russian: "Не загружена"],
        "local.generation": [.english: "Generation", .spanish: "Generación", .russian: "Генерация"],
        "local.maxTokens": [.english: "Max tokens per reply", .spanish: "Máximo de tokens por respuesta", .russian: "Максимум токенов на ответ"],
        "local.maxTokens.off": [.english: "No limit", .spanish: "Sin límite", .russian: "Без лимита"],
        "local.maxTokens.caption": [.english: "Applies to local models only; cloud providers use the chat limit. Local tokens are free — a limit only bounds how long a reply can take. \"No limit\" lets the model finish on its own (recommended for thinking models, whose reasoning also draws from this budget).", .spanish: "Solo se aplica a los modelos locales; los proveedores en la nube usan el límite del chat. Los tokens locales son gratis: un límite solo acota la duración de la respuesta. «Sin límite» deja que el modelo termine por sí solo (recomendado para modelos con razonamiento, que también consume este presupuesto).", .russian: "Действует только для локальных моделей; облачные используют лимит чата. Локальные токены бесплатны — лимит ограничивает лишь время ответа. «Без лимита» даёт модели закончить самой (рекомендуется для думающих моделей: их размышления тратят этот же бюджет)."],
        "local.start.confirm.title": [.english: "No model is running", .spanish: "Ningún modelo está activo", .russian: "Ни одна модель не запущена"],
        "local.start.confirm.message": [.english: "No local model is in memory right now. Start \"%@\" and send your message? It will be loaded temporarily and unloaded again after about 5 minutes of inactivity. To keep it running permanently, start it in Settings → Local models.", .spanish: "Ahora mismo no hay ningún modelo local en memoria. ¿Iniciar «%@» y enviar tu mensaje? Se cargará temporalmente y se descargará tras unos 5 minutos de inactividad. Para mantenerlo activo de forma permanente, inícialo en Ajustes → Modelos locales.", .russian: "Сейчас в памяти нет ни одной локальной модели. Запустить «%@» и отправить сообщение? Она загрузится временно и примерно через 5 минут простоя выгрузится. Чтобы модель работала постоянно, запустите её в Настройках → Локальные модели."],
        "local.start.confirm.yes": [.english: "Start and send", .spanish: "Iniciar y enviar", .russian: "Запустить и отправить"],
        "local.start.confirm.no": [.english: "Cancel", .spanish: "Cancelar", .russian: "Отмена"],
        "local.start.confirm.declined": [.english: "Cancelled. Switch the provider or pick a model that's already loaded, then send again.", .spanish: "Cancelado. Cambia el proveedor o elige un modelo que ya esté cargado y envía de nuevo.", .russian: "Отменено. Смените провайдера или выберите уже загруженную модель и отправьте снова."],
        "menu.localStart": [.english: "Start current model", .spanish: "Iniciar modelo actual", .russian: "Запустить текущую модель"],
        "menu.localStop": [.english: "Stop current model", .spanish: "Detener modelo actual", .russian: "Остановить текущую модель"],

        // MARK: Costs tab
        "costs.header": [.english: "Spending", .spanish: "Gastos", .russian: "Расходы"],
        "costs.session": [.english: "This session", .spanish: "Esta sesión", .russian: "За сессию"],
        "costs.sessionHelp": [.english: "Spending since the app was launched.", .spanish: "Gastos desde que se inició la aplicación.", .russian: "Расходы с момента запуска приложения."],
        "costs.today": [.english: "Today", .spanish: "Hoy", .russian: "Сегодня"],
        "costs.todayHelp": [.english: "Spending since midnight, all providers.", .spanish: "Gastos desde la medianoche, todos los proveedores.", .russian: "Расходы с полуночи по всем провайдерам."],
        "costs.month": [.english: "This month", .spanish: "Este mes", .russian: "За месяц"],
        "costs.monthHelp": [.english: "Spending in the current calendar month.", .spanish: "Gastos del mes natural en curso.", .russian: "Расходы за текущий календарный месяц."],
        "costs.progressHelp": [.english: "Progress toward the monthly limit.", .spanish: "Progreso hacia el límite mensual.", .russian: "Прогресс к месячному лимиту."],
        "costs.avgPerMessage": [.english: "Avg. tokens per message", .spanish: "Tokens promedio por mensaje", .russian: "Ø токенов на сообщение"],
        "costs.avgHelp": [.english: "Average over %d chat messages in the selected month. Input includes the full sent context (with cache).", .spanish: "Promedio de %d mensajes de chat del mes seleccionado. La entrada incluye todo el contexto enviado (con caché).", .russian: "Среднее по %d сообщениям чата за выбранный месяц. Вход включает весь отправленный контекст (с кэшем)."],
        "costs.byProviders": [.english: "By provider", .spanish: "Por proveedor", .russian: "По провайдерам"],
        "costs.byModels": [.english: "By model", .spanish: "Por modelo", .russian: "По моделям"],
        "costs.dimensionHelp": [.english: "Slice the daily chart by provider or by model.", .spanish: "Divide el gráfico diario por proveedor o por modelo.", .russian: "Разбивка графика по провайдерам или по моделям."],
        "costs.groupHelp": [.english: "Provider total for the selected month. Expand for models and services.", .spanish: "Total del proveedor en el mes seleccionado. Despliega para ver modelos y servicios.", .russian: "Итог провайдера за выбранный месяц. Раскройте для моделей и сервисов."],
        "costs.dailyChart": [.english: "Daily spend", .spanish: "Gasto diario", .russian: "Расходы по дням"],
        "costs.period": [.english: "Period", .spanish: "Período", .russian: "Период"],
        "costs.dailyHelp": [.english: "Daily spend for the selected month, stacked by provider.", .spanish: "Gasto diario del mes seleccionado, apilado por proveedor.", .russian: "Расходы по дням выбранного месяца, с разбивкой по провайдерам."],
        "costs.prevMonth": [.english: "Previous month", .spanish: "Mes anterior", .russian: "Предыдущий месяц"],
        "costs.nextMonth": [.english: "Next month", .spanish: "Mes siguiente", .russian: "Следующий месяц"],
        "costs.byModel": [.english: "By model", .spanish: "Por modelo", .russian: "По моделям"],
        "costs.byModelHelp": [.english: "Top models by cost in the selected month.", .spanish: "Modelos con mayor coste en el mes seleccionado.", .russian: "Топ моделей по стоимости за выбранный месяц."],
        "costs.breakdown": [.english: "Breakdown", .spanish: "Desglose", .russian: "Детализация"],
        "costs.rowHelp": [.english: "Tokens and cost for this model in the selected month.", .spanish: "Tokens y coste de este modelo en el mes seleccionado.", .russian: "Токены и стоимость этой модели за выбранный месяц."],
        "costs.tokensIn": [.english: "in", .spanish: "entrada", .russian: "вход"],
        "costs.tokensOut": [.english: "out", .spanish: "salida", .russian: "выход"],
        "costs.cache": [.english: "cached", .spanish: "caché", .russian: "кэш"],
        "costs.noPrice": [.english: "no price", .spanish: "sin precio", .russian: "нет цены"],
        "costs.estimated": [.english: "estimated (stream was interrupted before the provider reported usage)", .spanish: "estimado (el stream se interrumpió antes de recibir el uso)", .russian: "оценка (стрим прервался до получения usage от провайдера)"],
        "costs.ocrLine": [.english: "OCR, pages", .spanish: "OCR, páginas", .russian: "OCR, страниц"],
        "costs.sttLine": [.english: "Speech-to-text, min", .spanish: "Voz a texto, min", .russian: "Распознавание речи, мин"],
        "costs.searchLine": [.english: "Web search, queries", .spanish: "Búsqueda web, consultas", .russian: "Веб-поиск, запросов"],
        "costs.imageLine": [.english: "Image operations", .spanish: "Operaciones de imagen", .russian: "Операции с картинками"],
        "costs.empty": [.english: "No data yet — spending will appear after your first request.", .spanish: "Aún no hay datos: los gastos aparecerán tras la primera solicitud.", .russian: "Данных пока нет — расходы появятся после первого запроса."],
        "costs.footer": [.english: "Counted locally from the usage each API reports, priced by a built-in table (auto-refreshed weekly). Stored only on this Mac.", .spanish: "Calculado localmente a partir del uso que informa cada API, con una tabla de precios integrada (actualizada semanalmente). Se guarda solo en este Mac.", .russian: "Считается локально из usage-отчётов API по встроенной таблице цен (обновляется раз в неделю). Хранится только на этом Mac."],
        "costs.budgetHeader": [.english: "Budget", .spanish: "Presupuesto", .russian: "Бюджет"],
        "costs.budget": [.english: "Monthly limit, $", .spanish: "Límite mensual, $", .russian: "Месячный лимит, $"],
        "costs.budgetHelp": [.english: "Soft limit: warns in the chat at 80% and 100%, never blocks requests. 0 turns it off.", .spanish: "Límite blando: avisa en el chat al 80% y al 100%, nunca bloquea. 0 lo desactiva.", .russian: "Мягкий лимит: предупреждение в чате на 80% и 100%, запросы не блокируются. 0 — выключено."],
        "costs.budgetNote": [.english: "Warnings only — requests are never blocked.", .spanish: "Solo avisos: las solicitudes nunca se bloquean.", .russian: "Только предупреждения — запросы не блокируются."],
        "costs.budgetNear": [.english: "💸 Monthly API spend reached %@ — 80%% of your %@ limit.", .spanish: "💸 El gasto mensual de API alcanzó %@: el 80%% de tu límite de %@.", .russian: "💸 Расходы на API за месяц достигли %@ — это 80%% лимита %@."],
        "costs.budgetHit": [.english: "💸 Monthly API budget exceeded: %@ of %@.", .spanish: "💸 Presupuesto mensual de API superado: %@ de %@.", .russian: "💸 Месячный бюджет на API превышен: %@ из %@."],
        "prompts.resizeHelp": [.english: "Drag to resize the editor", .spanish: "Arrastra para cambiar el tamaño del editor", .russian: "Потяните, чтобы изменить высоту редактора"],

        // MARK: Chat tab
        "chat.header": [.english: "Chat", .spanish: "Chat", .russian: "Чат"],
        "chat.provider": [.english: "Provider", .spanish: "Proveedor", .russian: "Провайдер"],
        "chat.model": [.english: "Model", .spanish: "Modelo", .russian: "Модель"],
        "chat.loadModels": [.english: "Load Models", .spanish: "Cargar modelos", .russian: "Загрузить модели"],
        "chat.loading": [.english: "Loading…", .spanish: "Cargando…", .russian: "Загрузка…"],
        "chat.noModels": [.english: "No models loaded yet — add an API key below and press “Load Models”.", .spanish: "Aún no hay modelos — añade una clave API abajo y pulsa “Cargar modelos”.", .russian: "Модели не загружены — добавьте ключ API ниже и нажмите «Загрузить модели»."],
        "chat.addKeyFirst": [.english: "Add an API key first", .spanish: "Añade una clave API primero", .russian: "Сначала добавьте ключ API"],

        "params.header": [.english: "Model Parameters", .spanish: "Parámetros del modelo", .russian: "Параметры модели"],
        "params.reasoning": [.english: "Reasoning", .spanish: "Razonamiento", .russian: "Рассуждение"],
        "params.reasoning.na": [.english: "Not tunable for the selected model", .spanish: "No ajustable para el modelo seleccionado", .russian: "Недоступно для выбранной модели"],
        "params.reasoning.deepseek": [.english: "Pick deepseek-reasoner for reasoning", .spanish: "Elige deepseek-reasoner para razonar", .russian: "Выберите deepseek-reasoner"],
        "params.reasoning.mistral": [.english: "Pick a magistral-* model for reasoning", .spanish: "Elige un modelo magistral-* para razonar", .russian: "Выберите модель magistral-*"],
        "params.reasoning.openrouter": [.english: "Depends on the model — pick a reasoning-capable one", .spanish: "Depende del modelo — elige uno con razonamiento", .russian: "Зависит от модели — выберите модель с рассуждением"],
        "params.reasoning.kimi": [.english: "Kimi models manage thinking depth automatically", .spanish: "Los modelos Kimi gestionan el razonamiento automáticamente", .russian: "Модели Kimi управляют глубиной рассуждения автоматически"],

        // MARK: OpenRouter manual model entry
        "or.placeholder": [.english: "e.g. openai/gpt-4o", .spanish: "p. ej. openai/gpt-4o", .russian: "напр. openai/gpt-4o"],
        "or.browse": [.english: "Browse models on openrouter.ai ↗", .spanish: "Explorar modelos en openrouter.ai ↗", .russian: "Каталог моделей на openrouter.ai ↗"],
        "or.valid": [.english: "Model found in the OpenRouter catalog", .spanish: "Modelo encontrado en el catálogo de OpenRouter", .russian: "Модель найдена в каталоге OpenRouter"],
        "or.notFound": [.english: "Not in the OpenRouter catalog — double-check the slug", .spanish: "No está en el catálogo de OpenRouter — revisa el identificador", .russian: "Нет в каталоге OpenRouter — проверьте идентификатор"],
        "or.recent": [.english: "Recent models", .spanish: "Modelos recientes", .russian: "Недавние модели"],
        "or.clear": [.english: "Clear history", .spanish: "Borrar historial", .russian: "Очистить историю"],
        // MARK: HTML artifacts
        "artifact.untitled": [.english: "Interactive page", .spanish: "Página interactiva", .russian: "Интерактивная страница"],
        "artifact.generating": [.english: "Generating page…", .spanish: "Generando página…", .russian: "Страница создаётся…"],
        "artifact.interactive": [.english: "Interactive page", .spanish: "Página interactiva", .russian: "Интерактивная страница"],
        "artifact.mdDoc": [.english: "Markdown document", .spanish: "Documento Markdown", .russian: "Markdown-документ"],
        "artifact.truncated": [.english: "May be cut off — raise Max response tokens", .spanish: "Puede estar cortado — sube el máx. de tokens", .russian: "Возможно, обрезан — увеличьте лимит токенов ответа"],
        "artifact.open": [.english: "Open preview", .spanish: "Abrir vista previa", .russian: "Открыть превью"],
        "artifact.preview": [.english: "Preview", .spanish: "Vista previa", .russian: "Превью"],
        "artifact.code": [.english: "Code", .spanish: "Código", .russian: "Код"],
        "artifact.copy": [.english: "Copy code", .spanish: "Copiar código", .russian: "Копировать код"],
        "artifact.save": [.english: "Save…", .spanish: "Guardar…", .russian: "Сохранить…"],
        "artifact.openBrowser": [.english: "Open in Browser", .spanish: "Abrir en el navegador", .russian: "Открыть в браузере"],
        "artifact.diagram": [.english: "Diagram", .spanish: "Diagrama", .russian: "Диаграмма"],
        "artifact.diagramGenerating": [.english: "Drawing diagram…", .spanish: "Dibujando el diagrama…", .russian: "Диаграмма рисуется…"],
        "artifact.diagramError": [.english: "Diagram syntax error, showing source", .spanish: "Error de sintaxis del diagrama, se muestra el código", .russian: "Ошибка синтаксиса диаграммы, показан исходник"],
        "artifact.savePng": [.english: "Export PNG…", .spanish: "Exportar PNG…", .russian: "Экспорт PNG…"],

        "cap.vision": [.english: "Vision", .spanish: "Visión", .russian: "Картинки"],
        "cap.tools": [.english: "Tools", .spanish: "Herramientas", .russian: "Инструменты"],
        "cap.reasoning": [.english: "Reasoning", .spanish: "Razonamiento", .russian: "Рассуждение"],
        "params.maxTokens": [.english: "Max response tokens", .spanish: "Tokens máx. de respuesta", .russian: "Макс. токенов ответа"],
        "params.footer": [.english: "Reasoning maps to each provider's native control. It is shown only for models that support it.", .spanish: "El razonamiento usa el control nativo de cada proveedor. Solo se muestra en modelos compatibles.", .russian: "Рассуждение отображается только для моделей, которые его поддерживают, и использует нативный механизм провайдера."],
        "reasoning.auto": [.english: "Auto", .spanish: "Auto", .russian: "Авто"],
        "reasoning.fast": [.english: "Fast", .spanish: "Rápido", .russian: "Быстро"],
        "reasoning.deep": [.english: "Deep", .spanish: "Profundo", .russian: "Глубоко"],

        // MARK: API Keys tab
        "keys.header": [.english: "API Keys", .spanish: "Claves API", .russian: "Ключи API"],
        "keys.footer": [.english: "Keys are stored in the macOS Keychain on this device only. They are never written to preferences, logs, or synced to iCloud.", .spanish: "Las claves se guardan en el Llavero de macOS solo en este dispositivo. Nunca se escriben en preferencias, registros ni se sincronizan con iCloud.", .russian: "Ключи хранятся только в Связке ключей macOS на этом устройстве. Они не попадают в настройки, логи и не синхронизируются с iCloud."],
        "keys.paste": [.english: "Paste API key", .spanish: "Pega la clave API", .russian: "Вставьте ключ API"],
        "keys.save": [.english: "Save", .spanish: "Guardar", .russian: "Сохранить"],
        "keys.remove": [.english: "Remove", .spanish: "Quitar", .russian: "Удалить"],
        "keys.recheck": [.english: "Recheck", .spanish: "Revalidar", .russian: "Проверить"],
        "keys.get": [.english: "Get key ↗", .spanish: "Obtener clave ↗", .russian: "Получить ключ ↗"],
        "keys.valid": [.english: "Key is valid", .spanish: "La clave es válida", .russian: "Ключ действителен"],
        "keys.checkFailed": [.english: "Key check failed", .spanish: "Fallo al validar la clave", .russian: "Проверка ключа не удалась"],

        // MARK: Web
        "web.header": [.english: "Web Access", .spanish: "Acceso web", .russian: "Доступ в интернет"],
        "web.allow": [.english: "Allow web access (search & page reading)", .spanish: "Permitir acceso web (búsqueda y lectura de páginas)", .russian: "Разрешить доступ в интернет (поиск и чтение страниц)"],
        "web.toolBudget": [.english: "Tool calls per reply", .spanish: "Llamadas a herramientas por respuesta", .russian: "Вызовов инструментов на ответ"],
        "web.toolBudgetHelp": [.english: "How many rounds of tool calls (web search, page reads, calendar) one reply may spend. When the budget runs out, the model must write its final answer from what it has gathered. Higher values help data-hungry asks (stats, tables) but cost more tokens.", .spanish: "Cuántas rondas de herramientas (búsqueda, lectura de páginas, calendario) puede gastar una respuesta. Al agotarse, el modelo debe escribir la respuesta final con lo reunido. Valores altos ayudan con datos (estadísticas, tablas) pero cuestan más tokens.", .russian: "Сколько раундов инструментов (веб-поиск, чтение страниц, календарь) может потратить один ответ. Когда бюджет исчерпан, модель обязана написать финальный ответ из собранного. Больше — лучше для запросов данных (статистика, таблицы), но дороже по токенам."],
        "web.brave": [.english: "Brave Search", .spanish: "Brave Search", .russian: "Brave Search"],
        "web.pasteBrave": [.english: "Paste Brave API key", .spanish: "Pega la clave de Brave", .russian: "Вставьте ключ Brave"],
        "web.footer": [.english: "With a Brave Search API key, every chat model gains a web_search tool and can look up current information on its own. Free tier: api-dashboard.search.brave.com", .spanish: "Con una clave de Brave Search, cada modelo obtiene una herramienta web_search y puede buscar información actual por sí mismo. Plan gratuito: api-dashboard.search.brave.com", .russian: "С ключом Brave Search каждая модель получает инструмент web_search и может сама искать актуальную информацию. Бесплатный тариф: api-dashboard.search.brave.com"],

        // MARK: Voice
        "voice.header": [.english: "Voice", .spanish: "Voz", .russian: "Голос"],
        "voice.transcription": [.english: "Transcription", .spanish: "Transcripción", .russian: "Распознавание"],
        "voice.sttModel": [.english: "STT model", .spanish: "Modelo STT", .russian: "Модель STT"],
        "voice.footer": [.english: "Voice messages are transcribed with this provider, then the text is sent to the chat model.", .spanish: "Los mensajes de voz se transcriben con este proveedor y el texto se envía al modelo de chat.", .russian: "Голосовые сообщения распознаются этим провайдером, затем текст отправляется в чат-модель."],
        "voice.needKey": [.english: "No API key for this provider — add it in the API Keys tab.", .spanish: "No hay clave API para este proveedor — añádela en la pestaña Claves API.", .russian: "Нет ключа API для этого провайдера — добавьте его во вкладке «Ключи API»."],
        "ocr.header": [.english: "OCR (Text from Images)", .spanish: "OCR (texto de imágenes)", .russian: "OCR (текст с изображений)"],
        "ocr.provider": [.english: "Provider", .spanish: "Proveedor", .russian: "Провайдер"],
        "ocr.model": [.english: "OCR model", .spanish: "Modelo OCR", .russian: "Модель OCR"],
        "ocr.needKey": [.english: "Add a Mistral API key (in the API Keys tab) to enable OCR.", .spanish: "Añade una clave de Mistral (pestaña Claves API) para activar OCR.", .russian: "Добавьте ключ Mistral (вкладка «Ключи API»), чтобы включить OCR."],
        "ocr.apple.note": [
            .english: "Runs on-device — free, private, no key, works offline. Recognizes plain text well (screenshots, photos) in many languages including Cyrillic. It does not reconstruct complex layout: tables, columns and Markdown structure come out as flat lines. For documents with layout, switch to Mistral OCR.",
            .spanish: "Se ejecuta en el dispositivo — gratis, privado, sin clave y sin conexión. Reconoce bien el texto plano (capturas, fotos) en muchos idiomas, incluido el cirílico. No reconstruye el diseño complejo: tablas, columnas y estructura Markdown salen como líneas planas. Para documentos con maquetación, usa Mistral OCR.",
            .russian: "Работает на устройстве — бесплатно, приватно, без ключа, офлайн. Хорошо распознаёт обычный текст (скриншоты, фото) на многих языках, включая кириллицу. Сложную вёрстку не восстанавливает: таблицы, колонки и Markdown-структура выйдут плоским текстом. Для документов с вёрсткой выберите Mistral OCR."
        ],
        "ocr.footer": [.english: "Used by “Extract Text” on screenshots and as a fallback that lets non-vision chat models read images.", .spanish: "Se usa en “Extraer texto” de capturas y como respaldo para que modelos sin visión lean imágenes.", .russian: "Используется кнопкой «Извлечь текст» на скриншотах и как запасной путь, чтобы модели без зрения могли читать изображения."],
        "dictation.header": [.english: "Dictation", .spanish: "Dictado", .russian: "Диктовка"],
        "dictation.enable": [.english: "System-wide dictation", .spanish: "Dictado en todo el sistema", .russian: "Диктовка во всей системе"],
        "dictation.cleanup": [.english: "Clean up fillers & punctuation", .spanish: "Limpiar muletillas y puntuación", .russian: "Убирать слова-паразиты и пунктуацию"],
        "dictation.chunked": [.english: "Insert by phrases (pause detection)", .spanish: "Insertar por frases (detección de pausas)", .russian: "Вставлять по фразам (детекция пауз)"],
        "dictation.mic": [.english: "Microphone", .spanish: "Micrófono", .russian: "Микрофон"],
        "dictation.mic.auto": [.english: "System default", .spanish: "Predeterminado del sistema", .russian: "Системный (авто)"],
        "dictation.mic.offline": [.english: "Selected mic (not connected)", .spanish: "Micrófono elegido (no conectado)", .russian: "Выбранный (не подключён)"],
        "dictation.warm": [.english: "Keep mic ready after dictation", .spanish: "Mantener el micrófono listo tras dictar", .russian: "Держать микрофон готовым"],
        "dictation.warm.off": [.english: "Off", .spanish: "No", .russian: "Выкл"],
        "dictation.warm.minutes": [.english: "%d min", .spanish: "%d min", .russian: "%d мин"],
        "dictation.warm.caption": [.english: "While the mic is kept ready, the next dictation starts instantly — no hardware spin-up, no lost first words (Bluetooth mics take seconds to wake). macOS shows the orange mic indicator for that time; audio is discarded, nothing is recorded.", .spanish: "Mientras el micrófono se mantiene listo, el siguiente dictado empieza al instante — sin arranque del hardware ni primeras palabras perdidas (los micros Bluetooth tardan segundos en despertar). macOS muestra el indicador naranja durante ese tiempo; el audio se descarta, no se graba nada.", .russian: "Пока микрофон наготове, следующая диктовка стартует мгновенно — без раскрутки железа и потери первых слов (Bluetooth-микрофоны просыпаются секунды). macOS показывает оранжевый индикатор микрофона на это время; звук отбрасывается, ничего не записывается."],
        "dictation.translateTo": [.english: "Translate to", .spanish: "Traducir a", .russian: "Переводить на"],
        "dictation.footer": [.english: "Press the dictation hotkey anywhere to record; a small pill appears under the camera. Press it again (or click the pill) to stop — the recognized text is typed into the focused field. Requires Accessibility permission.", .spanish: "Pulsa la tecla de dictado en cualquier lugar para grabar; aparece una pastilla bajo la cámara. Púlsala de nuevo (o haz clic) para parar — el texto se escribe en el campo activo. Requiere permiso de Accesibilidad.", .russian: "Нажмите горячую клавишу диктовки где угодно, чтобы записать; под камерой появится пилюля. Нажмите снова (или кликните по ней), чтобы остановить — распознанный текст впечатается в активное поле. Нужно разрешение «Универсальный доступ»."],

        // MARK: General / Hotkeys
        "hotkeys.header": [.english: "Hotkeys", .spanish: "Atajos", .russian: "Горячие клавиши"],
        "hotkeys.openPanel": [.english: "Open panel", .spanish: "Abrir panel", .russian: "Открыть панель"],
        "hotkeys.fullShot": [.english: "Full screenshot + panel", .spanish: "Captura completa + panel", .russian: "Скриншот экрана + панель"],
        "hotkeys.areaShot": [.english: "Area screenshot + panel", .spanish: "Captura de área + panel", .russian: "Скриншот области + панель"],
        "hotkeys.dictate": [.english: "Dictate", .spanish: "Dictar", .russian: "Диктовка"],
        "hotkeys.dictateTranslate": [.english: "Dictate + translate", .spanish: "Dictar + traducir", .russian: "Диктовка + перевод"],
        "hotkeys.reset": [.english: "Reset to Defaults", .spanish: "Restablecer valores", .russian: "Сбросить по умолчанию"],
        "hotkeys.footer": [.english: "Click a shortcut, then press the new combination (must include ⌘, ⌃ or ⌥). Changes apply immediately, system-wide.", .spanish: "Haz clic en un atajo y pulsa la nueva combinación (debe incluir ⌘, ⌃ u ⌥). Los cambios se aplican al instante, en todo el sistema.", .russian: "Кликните по шорткату и нажмите новую комбинацию (обязательно с ⌘, ⌃ или ⌥). Изменения применяются сразу и во всей системе."],

        // MARK: General
        "general.launchAtLogin": [.english: "Launch at login", .spanish: "Abrir al iniciar sesión", .russian: "Запускать при входе в систему"],
        "general.prefillSelection": [.english: "Open panel with the selected text", .spanish: "Abrir el panel con el texto seleccionado", .russian: "Открывать панель с выделенным текстом"],
        // MARK: Permissions
        "perm.header": [.english: "Permissions", .spanish: "Permisos", .russian: "Разрешения"],
        "perm.accessibility": [.english: "Accessibility", .spanish: "Accesibilidad", .russian: "Универсальный доступ"],
        "perm.screen": [.english: "Screen Recording", .spanish: "Grabación de pantalla", .russian: "Запись экрана"],
        "perm.mic": [.english: "Microphone", .spanish: "Micrófono", .russian: "Микрофон"],
        "perm.granted": [.english: "granted", .spanish: "concedido", .russian: "выдано"],
        "perm.grant": [.english: "Grant…", .spanish: "Conceder…", .russian: "Выдать…"],
        "perm.footer": [.english: "Accessibility powers dictation typing, selection capture and LayoutFix; Screen Recording — screenshots; Microphone — voice input. After an update macOS may require granting again — the app cleans up stale entries automatically on first launch.", .spanish: "Accesibilidad impulsa la escritura del dictado, la captura de selección y LayoutFix; Grabación de pantalla — las capturas; Micrófono — la entrada de voz. Tras una actualización, macOS puede exigir concederlos de nuevo; la app limpia las entradas obsoletas automáticamente al primer arranque.", .russian: "«Универсальный доступ» нужен впечатыванию диктовки, захвату выделения и LayoutFix; «Запись экрана» — скриншотам; «Микрофон» — голосовому вводу. После обновления macOS может потребовать выдать разрешения заново — протухшие записи приложение чистит автоматически при первом запуске."],
        "general.prefillSelection.caption": [.english: "When you summon the panel, the text selected in the current app lands in the input field — Enter runs the active preset on it.", .spanish: "Al invocar el panel, el texto seleccionado en la app actual aparece en el campo de entrada; Intro le aplica el preajuste activo.", .russian: "При вызове панели выделенный в текущем приложении текст попадёт в поле ввода — Enter применит к нему активный пресет."],
        "general.prefillSelection.help": [.english: "When you summon the panel, the text selected in the current app lands in the input field — press Enter to run the active preset on it (e.g. instant translation). Requires the Accessibility permission.", .spanish: "Al invocar el panel, el texto seleccionado en la app actual aparece en el campo de entrada; pulsa Intro para aplicarle el preajuste activo (p. ej. traducción instantánea). Requiere el permiso de Accesibilidad.", .russian: "При вызове панели выделенный в текущем приложении текст подставляется в поле ввода — Enter применит к нему активный пресет (например, мгновенный перевод). Нужно разрешение «Универсальный доступ»."],

        // MARK: Diagnostics
        "diag.header": [.english: "Diagnostics", .spanish: "Diagnóstico", .russian: "Диагностика"],
        "diag.enable": [.english: "Logging & freeze detection", .spanish: "Registro y detección de bloqueos", .russian: "Логи и мониторинг зависаний"],
        "diag.export": [.english: "Export Logs to Downloads", .spanish: "Exportar registros a Descargas", .russian: "Экспортировать логи в «Загрузки»"],
        "diag.open": [.english: "Open Logs Folder", .spanish: "Abrir carpeta de registros", .russian: "Открыть папку логов"],
        "diag.exported": [.english: "Logs exported to Downloads", .spanish: "Registros exportados a Descargas", .russian: "Логи выгружены в «Загрузки»"],
        "diag.footer": [.english: "Writes an event log on this Mac and, if the interface freezes for over 2 seconds, saves a report with stack traces. No message texts, prompts or API keys are ever recorded. Export the archive and attach it to a bug report.", .spanish: "Guarda un registro de eventos en este Mac y, si la interfaz se congela más de 2 segundos, crea un informe con trazas de pila. Nunca se registran textos de mensajes, prompts ni claves API. Exporta el archivo y adjúntalo a un informe de error.", .russian: "Ведёт журнал событий на этом Mac и при зависании интерфейса дольше 2 секунд сохраняет отчёт со стеками потоков. Тексты сообщений, промпты и ключи API никогда не записываются. Выгрузите архив и приложите его к сообщению об ошибке."],

        // MARK: About (app version)
        "about.header": [.english: "About", .spanish: "Acerca de", .russian: "О приложении"],
        "about.version": [.english: "Version", .spanish: "Versión", .russian: "Версия"],

        // MARK: Panel placement
        "panel.header": [.english: "Panel", .spanish: "Panel", .russian: "Панель"],
        "panel.followMouse": [.english: "Open panel on the screen with the cursor", .spanish: "Abrir el panel en la pantalla con el cursor", .russian: "Открывать панель на экране с курсором"],
        "panel.resetPosition": [.english: "Reset Panel Position", .spanish: "Restablecer posición del panel", .russian: "Сбросить положение панели"],
        "panel.footer": [.english: "The panel opens Spotlight-style (centered) until you drag it — then your position is remembered. With the cursor option on, the same position is reproduced on whichever screen the mouse is on.", .spanish: "El panel se abre estilo Spotlight (centrado) hasta que lo arrastres — entonces se recuerda tu posición. Con la opción del cursor activada, la misma posición se reproduce en la pantalla donde esté el ratón.", .russian: "Панель открывается по центру (как Spotlight), пока вы её не перетащите — тогда позиция запоминается. С опцией курсора та же позиция воспроизводится на экране, где сейчас мышь."],

        // MARK: Appearance / Language
        "appearance.header": [.english: "Appearance", .spanish: "Apariencia", .russian: "Оформление"],
        "appearance.theme": [.english: "Theme", .spanish: "Tema", .russian: "Тема"],
        "appearance.themes.header": [.english: "Themes", .spanish: "Temas", .russian: "Темы"],
        "appearance.holidayThemes": [.english: "Holiday themes", .spanish: "Temas festivos", .russian: "Праздничные темы"],
        "appearance.holidayThemes.caption": [
            .english: "Halloween (Oct 31) and Día de Muertos (Nov 1–2) switch on automatically and the previous theme comes back afterwards. A manual change always wins.",
            .spanish: "Halloween (31 oct) y Día de Muertos (1–2 nov) se activan solos y después vuelve el tema anterior. Un cambio manual siempre gana.",
            .russian: "Хеллоуин (31 окт) и День мёртвых (1–2 ноя) включаются сами, после праздника возвращается прежняя тема. Ручной выбор всегда в приоритете."
        ],
        "appearance.mode": [.english: "Mode", .spanish: "Modo", .russian: "Режим"],
        "appearance.language": [.english: "Language", .spanish: "Idioma", .russian: "Язык"],
        "theme.auto": [.english: "Auto", .spanish: "Auto", .russian: "Авто"],
        "theme.light": [.english: "Light", .spanish: "Claro", .russian: "Светлая"],
        "theme.dark": [.english: "Dark", .spanish: "Oscuro", .russian: "Тёмная"],

        // MARK: Prompts
        "prompts.header": [.english: "System Prompt", .spanish: "Prompt del sistema", .russian: "Системный промпт"],
        "prompts.preset": [.english: "Preset", .spanish: "Preajuste", .russian: "Пресет"],
        "prompts.custom": [.english: "custom", .spanish: "personalizado", .russian: "свой"],
        "prompts.builtInNoDelete": [.english: "Built-in presets can't be deleted", .spanish: "Los preajustes integrados no se pueden borrar", .russian: "Встроенные пресеты нельзя удалить"],
        "prompts.deleteThis": [.english: "Delete this preset", .spanish: "Borrar este preajuste", .russian: "Удалить этот пресет"],
        "prompts.edited": [.english: "Edited — changes apply immediately", .spanish: "Editado — los cambios se aplican al instante", .russian: "Изменено — применяется сразу"],
        "prompts.revertTo": [.english: "Revert to", .spanish: "Revertir a", .russian: "Вернуть"],
        "prompts.savePlaceholder": [.english: "Save current text as a new preset…", .spanish: "Guardar el texto actual como nuevo preajuste…", .russian: "Сохранить текущий текст как новый пресет…"],
        "prompts.savePreset": [.english: "Save Preset", .spanish: "Guardar preajuste", .russian: "Сохранить пресет"],
        "prompts.footer": [.english: "Pick a preset, edit the text freely (an “Edited” marker appears), revert anytime, or save your edits under a new name.", .spanish: "Elige un preajuste, edita el texto libremente (aparece un marcador “Editado”), revierte cuando quieras o guarda con un nombre nuevo.", .russian: "Выберите пресет, свободно правьте текст (появится метка «Изменено»), в любой момент откатывайте или сохраняйте под новым именем."],
        "prompts.styleMenu": [.english: "Menu", .spanish: "Menú", .russian: "Меню"],
        "prompts.styleButtons": [.english: "Buttons", .spanish: "Botones", .russian: "Кнопки"],

        // MARK: Panel switcher section
        "switcher.header": [.english: "Panel Switcher", .spanish: "Selector del panel", .russian: "Переключатель в панели"],
        "switcher.style": [.english: "Style", .spanish: "Estilo", .russian: "Вид"],
        "switcher.footer": [.english: "How presets appear in the panel header and which of them are offered there. Hidden presets stay fully usable on this tab; the active preset is always shown in the panel.", .spanish: "Cómo se muestran los preajustes en la cabecera del panel y cuáles se ofrecen ahí. Los preajustes ocultos siguen totalmente disponibles en esta pestaña; el preajuste activo siempre se muestra en el panel.", .russian: "Как пресеты выглядят в шапке панели и какие из них там доступны. Скрытые пресеты остаются полностью рабочими на этой вкладке; активный пресет всегда виден в панели."],
        "switcher.colShow": [.english: "In panel", .spanish: "En el panel", .russian: "В панели"],
        "switcher.colChat": [.english: "Own chat", .spanish: "Chat propio", .russian: "Свой чат"],
        "switcher.isolatedHelp": [.english: "This preset keeps its own separate conversation", .spanish: "Este preajuste mantiene su propia conversación separada", .russian: "У этого пресета своя отдельная переписка"],
        "switcher.isolatedFooter": [.english: "Presets with “Own chat” keep a separate conversation with its own history and context. Switching to such a preset opens its chat; switching to a regular preset returns to the shared chat. Turning the toggle off keeps the history and brings it back when re-enabled. Deleting a custom preset deletes its chat.", .spanish: "Los preajustes con «Chat propio» mantienen una conversación separada con su propio historial y contexto. Al cambiar a un preajuste así se abre su chat; al cambiar a uno normal se vuelve al chat compartido. Desactivar el interruptor conserva el historial y lo restaura al reactivarlo. Eliminar un preajuste personalizado elimina su chat.", .russian: "Пресеты со «Своим чатом» ведут отдельную переписку со своей историей и контекстом. Переключение на такой пресет открывает его чат; переключение на обычный возвращает в общий чат. Выключение тогла сохраняет историю и вернёт её при повторном включении. Удаление кастомного пресета удаляет его чат."],
        "prompts.iconHelp": [.english: "Preset icon — click to pick an emoji, right-click to reset", .spanish: "Icono del preajuste: clic para elegir un emoji, clic derecho para restablecer", .russian: "Иконка пресета — клик открывает выбор эмодзи, правый клик сбрасывает"],
        "prompts.iconClear": [.english: "Reset icon", .spanish: "Restablecer icono", .russian: "Сбросить иконку"],

        // MARK: Status menu
        "menu.open": [.english: "Open Assistant", .spanish: "Abrir asistente", .russian: "Открыть ассистента"],
        "menu.fullShot": [.english: "Screenshot + Panel", .spanish: "Captura + panel", .russian: "Скриншот + панель"],
        "menu.areaShot": [.english: "Area Screenshot + Panel", .spanish: "Captura de área + panel", .russian: "Скриншот области + панель"],
        "menu.dictate": [.english: "Dictate", .spanish: "Dictar", .russian: "Диктовка"],
        "menu.dictateTranslate": [.english: "Dictate + Translate", .spanish: "Dictar + traducir", .russian: "Диктовка + перевод"],
        "menu.followMouse": [.english: "Open on Screen with Cursor", .spanish: "Abrir en la pantalla con el cursor", .russian: "Открывать на экране с курсором"],
        "menu.appearance": [.english: "Appearance", .spanish: "Apariencia", .russian: "Оформление"],
        "menu.settings": [.english: "Settings…", .spanish: "Ajustes…", .russian: "Настройки…"],
        "menu.quit": [.english: "Quit AI Spotlight", .spanish: "Salir de AI Spotlight", .russian: "Выйти из AI Spotlight"],

        // MARK: Chat panel
        "panel.typeMessage": [.english: "Type your message...", .spanish: "Escribe tu mensaje...", .russian: "Введите сообщение..."],
        "panel.newChat": [.english: "New chat", .spanish: "Nuevo chat", .russian: "Новый чат"],
        "panel.presetHelp": [.english: "System prompt preset (applies to the next message)", .spanish: "Preajuste de prompt (se aplica al próximo mensaje)", .russian: "Пресет промпта (применится к следующему сообщению)"],
        "panel.providerHelp": [.english: "Chat provider (only providers with a key are shown)", .spanish: "Proveedor de chat (solo se muestran los que tienen clave)", .russian: "Провайдер чата (показаны только те, у кого есть ключ)"],
        "panel.settingsHelp": [.english: "Settings", .spanish: "Ajustes", .russian: "Настройки"],
        "panel.welcome": [.english: "Hi! I'm your AI assistant. How can I help you today?", .spanish: "¡Hola! Soy tu asistente de IA. ¿En qué puedo ayudarte hoy?", .russian: "Привет! Я ваш ИИ-ассистент. Чем могу помочь?"],
        "panel.thinking": [.english: "Thinking…", .spanish: "Pensando…", .russian: "Думаю…"],
        "panel.searching": [.english: "Searching", .spanish: "Buscando", .russian: "Поиск"],
        "panel.fetchingPage": [.english: "Reading page", .spanish: "Leyendo la página", .russian: "Читаю страницу"],
        "panel.retry": [.english: "Retry last message", .spanish: "Reintentar último mensaje", .russian: "Повторить сообщение"],
        "panel.jumpLatest": [.english: "Jump to the latest message", .spanish: "Ir al mensaje más reciente", .russian: "К последнему сообщению"],
        "panel.recordingCancelled": [.english: "Recording cancelled.", .spanish: "Grabación cancelada.", .russian: "Запись отменена."],
        "recording.hint": [.english: "Space to send · ×2 to cancel", .spanish: "Espacio para enviar · ×2 para cancelar", .russian: "Пробел — отправить · ×2 — отмена"],
        "panel.recordLimitSent": [.english: "Recording reached the limit of %d minutes and was sent automatically.", .spanish: "La grabación alcanzó el límite de %d minutos y se envió automáticamente.", .russian: "Запись достигла лимита в %d минут и была отправлена автоматически."],
        "panel.recordLimitStopped": [.english: "Recording reached the limit of %d minutes and was stopped.", .spanish: "La grabación alcanzó el límite de %d minutos y se detuvo.", .russian: "Запись достигла лимита в %d минут и была остановлена."],
        "panel.recordStartFailed": [.english: "Failed to start recording. Please check microphone permissions in System Settings.", .spanish: "No se pudo iniciar la grabación. Revisa los permisos del micrófono en Ajustes del Sistema.", .russian: "Не удалось начать запись. Проверьте доступ к микрофону в Системных настройках."],
        "panel.transcribing": [.english: "Transcribing voice message…", .spanish: "Transcribiendo el mensaje de voz…", .russian: "Распознаю голосовое сообщение…"],
        "panel.noSpeech": [.english: "The recording contained no recognizable speech.", .spanish: "La grabación no contenía voz reconocible.", .russian: "В записи не распознано речи."],
        "panel.transcriptionFailed": [.english: "Transcription failed: %@", .spanish: "Falló la transcripción: %@", .russian: "Ошибка расшифровки: %@"],
        "panel.emptyReply": [.english: "(empty reply)", .spanish: "(respuesta vacía)", .russian: "(пустой ответ)"],
        "panel.ocrDone": [.english: "Extracted with OCR — text copied to the clipboard.", .spanish: "Extraído con OCR — texto copiado al portapapeles.", .russian: "Распознано через OCR — текст скопирован в буфер обмена."],
        "panel.ocrFailed": [.english: "OCR failed: %@", .spanish: "Falló el OCR: %@", .russian: "Ошибка OCR: %@"],

        // MARK: Tooltips
        "tooltip.input": [.english: "Enter — send, Shift+Enter — new line", .spanish: "Intro — enviar, Mayús+Intro — nueva línea", .russian: "Enter — отправить, Shift+Enter — новая строка"],
        "tooltip.attach": [.english: "Attach an image (or paste one with ⌘V)", .spanish: "Adjuntar una imagen (o pégala con ⌘V)", .russian: "Прикрепить изображение (или вставьте через ⌘V)"],
        "chat.mediaExpired": [.english: "(media removed — retention limit)", .spanish: "(multimedia eliminado — límite de retención)", .russian: "(медиа удалено — истёк срок хранения)"],
        "tooltip.send": [.english: "Send message (Enter)", .spanish: "Enviar mensaje (Intro)", .russian: "Отправить сообщение (Enter)"],
        "tooltip.voice.start": [.english: "Record a voice message. While recording: Space — send, double Space / Esc — cancel", .spanish: "Grabar un mensaje de voz. Durante la grabación: Espacio — enviar, doble Espacio / Esc — cancelar", .russian: "Записать голосовое. Во время записи: Пробел — отправить, двойной Пробел / Esc — отмена"],
        "tooltip.voice.stop": [.english: "Stop and send (or press Space)", .spanish: "Detener y enviar (o pulsa Espacio)", .russian: "Остановить и отправить (или Пробел)"],
        "tooltip.play": [.english: "Play / pause the voice message", .spanish: "Reproducir / pausar el mensaje de voz", .russian: "Воспроизвести / пауза"],
        "tooltip.attachment": [.english: "Click to open in the default app", .spanish: "Haz clic para abrir en la app predeterminada", .russian: "Клик — открыть в приложении по умолчанию"],
        "tooltip.extract": [.english: "Recognize the text (OCR): shown in the chat, raw Markdown goes to the clipboard", .spanish: "Reconocer el texto (OCR): se muestra en el chat y el Markdown se copia al portapapeles", .russian: "Распознать текст (OCR): результат в чате, Markdown — в буфере обмена"],
        "tooltip.removeAttachment": [.english: "Remove the attachment", .spanish: "Quitar el adjunto", .russian: "Убрать вложение"],
        "tooltip.copy": [.english: "Copy message", .spanish: "Copiar mensaje", .russian: "Скопировать сообщение"],
        "tooltip.shortcut.record": [.english: "Click to record a new shortcut (Esc — cancel)", .spanish: "Haz clic para grabar un nuevo atajo (Esc — cancelar)", .russian: "Клик — записать новое сочетание (Esc — отмена)"],
        "tooltip.dictation.stop": [.english: "Click or press the dictation hotkey to stop", .spanish: "Haz clic o pulsa el atajo de dictado para detener", .russian: "Клик или хоткей диктовки — остановить"],
        "tooltip.dictation.language": [.english: "Translation language — click to change", .spanish: "Idioma de traducción — haz clic para cambiar", .russian: "Язык перевода — клик, чтобы сменить"],
        "copy.copied": [.english: "Copied", .spanish: "Copiado", .russian: "Скопировано"],
        "tooltip.copyTable": [.english: "Copy table (text and spreadsheet cells)", .spanish: "Copiar tabla (texto y celdas)", .russian: "Скопировать таблицу (текстом и ячейками)"],
        "tooltip.tapToCopy": [.english: "Click to copy", .spanish: "Haz clic para copiar", .russian: "Клик — скопировать"],
        "tooltip.insertIntoTerminal": [.english: "Insert into Terminal — press Enter there to run", .spanish: "Insertar en Terminal — pulsa Intro allí para ejecutar", .russian: "Вставить в Терминал — выполнение по Enter"],
        "tooltip.runInTerminal": [.english: "Run in Terminal", .spanish: "Ejecutar en Terminal", .russian: "Выполнить в Терминале"],

        // MARK: Terminal commands (▶ on shell code blocks)
        "terminal.mode.off": [.english: "Off", .spanish: "Desactivado", .russian: "Выключено"],
        "terminal.mode.insert": [.english: "Insert into Terminal", .spanish: "Insertar en Terminal", .russian: "Вставлять в Терминал"],
        "terminal.mode.autorun": [.english: "Run immediately", .spanish: "Ejecutar inmediatamente", .russian: "Выполнять сразу"],
        "general.terminalRun": [.english: "▶ on terminal commands", .spanish: "▶ en comandos de terminal", .russian: "▶ у команд терминала"],
        "general.terminalRun.help": [.english: "What the ▶ button on shell code blocks does", .spanish: "Qué hace el botón ▶ en los bloques de código shell", .russian: "Что делает кнопка ▶ на блоках с shell-командами"],
        "general.terminalRun.caption": [.english: "Shell commands in answers get a ▶ button: it opens Terminal with the command typed in — you press Enter. \"Run immediately\" executes it right away (macOS asks for the Automation permission once).", .spanish: "Los comandos de shell en las respuestas tienen un botón ▶: abre Terminal con el comando escrito — tú pulsas Intro. «Ejecutar inmediatamente» lo ejecuta al instante (macOS pide el permiso de Automatización una vez).", .russian: "У shell-команд в ответах появляется кнопка ▶: она открывает Терминал с уже введённой командой — Enter нажимаете вы. «Выполнять сразу» запускает её немедленно (macOS один раз спросит разрешение «Автоматизация»)."],

        // MARK: Onboarding
        "ob.next": [.english: "Next", .spanish: "Siguiente", .russian: "Далее"],
        "ob.back": [.english: "Back", .spanish: "Atrás", .russian: "Назад"],
        "ob.done": [.english: "Get Started", .spanish: "Empezar", .russian: "Начать"],
        "ob.skip": [.english: "Skip", .spanish: "Omitir", .russian: "Пропустить"],
        "ob.showTour": [.english: "Show Welcome Tour", .spanish: "Mostrar el tour de bienvenida", .russian: "Показать обзор функций"],
        // Page captions — features only, no provider or model names.
        "ob.tour.chat.title": [
            .english: "Ask anything, anywhere",
            .spanish: "Pregunta lo que sea, donde sea",
            .russian: "Спросите что угодно, где угодно"
        ],
        "ob.tour.chat.body": [
            .english: "AISpotlight lives in the menu bar and opens over any app. Ask, read the answer, press Esc.",
            .spanish: "AISpotlight vive en la barra de menús y se abre sobre cualquier app. Pregunta, lee la respuesta y pulsa Esc.",
            .russian: "AISpotlight живёт в строке меню и открывается поверх любого приложения. Спросили — получили ответ — Esc."
        ],
        "ob.tour.shot.title": [
            .english: "Capture a table, get a table",
            .spanish: "Captura una tabla y obtén una tabla",
            .russian: "Сняли таблицу — получили таблицу"
        ],
        "ob.tour.shot.body": [
            .english: "Drag a region and it lands in the chat. “Extract Text” turns a screenshot of a table into a real table — then just ask about the numbers.",
            .spanish: "Arrastra una zona y aparecerá en el chat. “Extraer texto” convierte la captura de una tabla en una tabla real, y luego solo pregunta por los números.",
            .russian: "Выделите кусок экрана: он попадёт в чат. «Извлечь текст» превращает снимок таблицы в настоящую таблицу — и по ней сразу можно спрашивать."
        ],
        "ob.tour.dict.title": [
            .english: "You speak English, it types Spanish",
            .spanish: "Hablas en inglés, se escribe en español",
            .russian: "Говорите по-английски — пишется по-испански"
        ],
        "ob.tour.dict.body": [
            .english: "A pill drops under the camera and the translation is typed where the cursor is, phrase by phrase, while you speak. The other app never notices.",
            .spanish: "Una pastilla aparece bajo la cámara y la traducción se escribe donde está el cursor, frase a frase, mientras hablas. La otra app no nota nada.",
            .russian: "Пилюля появляется под камерой, а перевод впечатывается туда, где стоит курсор, — фраза за фразой, пока вы говорите. Чужое приложение ничего не замечает."
        ],
        "ob.tour.world.title": [
            .english: "One moment, every city",
            .spanish: "Un instante, todas las ciudades",
            .russian: "Один момент — сразу во всех городах"
        ],
        "ob.tour.world.body": [
            .english: "A 24-hour grid across your cities: one vertical slice is the same instant everywhere. Click a half-hour and say what to plan — the event lands in Calendar.",
            .spanish: "Una cuadrícula de 24 horas con tus ciudades: un corte vertical es el mismo instante en todas. Haz clic en una media hora y di qué planificar: el evento se crea en Calendario.",
            .russian: "Сетка суток по вашим городам: вертикальный срез — это один и тот же момент везде. Клик по получасу — скажите, что запланировать, и встреча появится в Календаре."
        ],
        "ob.tour.image.title": [
            .english: "Three edits for any image",
            .spanish: "Tres retoques para cualquier imagen",
            .russian: "Три операции с любой картинкой"
        ],
        "ob.tour.image.body": [
            .english: "Attach a picture and the actions bar appears: remove the background, upscale ×4, or brush over something to erase it.",
            .spanish: "Adjunta una imagen y aparecerá la barra de acciones: quitar el fondo, escalar ×4 o pintar sobre algo para borrarlo.",
            .russian: "Прикрепите изображение — появится панель действий: убрать фон, апскейл ×4 или закрасить лишнее, чтобы стереть."
        ],

        // Step rail labels
        "ob.step.chat": [.english: "Chat", .spanish: "Chat", .russian: "Чат"],
        "ob.step.shot": [.english: "Capture", .spanish: "Captura", .russian: "Скриншот"],
        "ob.step.dict": [.english: "Dictation", .spanish: "Dictado", .russian: "Диктовка"],
        "ob.step.world": [.english: "World time", .spanish: "Hora mundial", .russian: "Мировое время"],
        "ob.step.image": [.english: "Images", .spanish: "Imágenes", .russian: "Картинки"],
        "ob.replay": [.english: "Replay", .spanish: "Repetir", .russian: "Ещё раз"],

        // MARK: Onboarding scenes (mock UI inside the animations)
        "obs.mb.file": [.english: "File", .spanish: "Archivo", .russian: "Файл"],
        "obs.mb.edit": [.english: "Edit", .spanish: "Edición", .russian: "Правка"],
        "obs.mb.view": [.english: "View", .spanish: "Visualización", .russian: "Вид"],
        "obs.s1.app": [.english: "Mail", .spanish: "Correo", .russian: "Почта"],
        "obs.s1.winTitle": [.english: "Mail — Inbox", .spanish: "Correo — Entrada", .russian: "Почта — Входящие"],
        "obs.s1.q": [
            .english: "What's the weather in Barcelona today?",
            .spanish: "¿Qué tiempo hace hoy en Barcelona?",
            .russian: "Какая погода сегодня в Барселоне?"
        ],
        "obs.s1.searching": [.english: "Searching the web…", .spanish: "Buscando en la web…", .russian: "Ищу в интернете…"],
        "obs.s1.a1": [
            .english: "Right now 26 °C, clear, wind 12 km/h.",
            .spanish: "Ahora 26 °C, despejado, viento 12 km/h.",
            .russian: "Сейчас +26 °C, ясно, ветер 12 км/ч."
        ],
        "obs.s1.a2": [
            .english: "By evening 21 °C, no rain expected.",
            .spanish: "Por la tarde 21 °C, sin lluvia.",
            .russian: "К вечеру +21 °C, дождя не будет."
        ],
        "obs.s1.ph": [.english: "Ask anything…", .spanish: "Pregunta lo que sea…", .russian: "Спросите что угодно…"],

        "obs.s2.winTitle": [.english: "Q3-report.numbers", .spanish: "Informe-Q3.numbers", .russian: "Q3-отчёт.numbers"],
        "obs.s2.h.channel": [.english: "Channel", .spanish: "Canal", .russian: "Канал"],
        "obs.s2.r1": [.english: "Direct sales", .spanish: "Ventas directas", .russian: "Прямые продажи"],
        "obs.s2.r2": [.english: "Partners", .spanish: "Socios", .russian: "Партнёры"],
        "obs.s2.r3": [.english: "Subscriptions", .spanish: "Suscripciones", .russian: "Подписки"],
        "obs.s2.total": [.english: "Total", .spanish: "Total", .russian: "Итого"],
        "obs.s2.recognizing": [.english: "Recognizing the table…", .spanish: "Reconociendo la tabla…", .russian: "Распознаю таблицу…"],
        "obs.s2.q": [.english: "Calculate the growth vs Q2", .spanish: "Calcula el crecimiento frente al Q2", .russian: "Посчитай прирост к Q2"],
        "obs.s2.a": [
            .english: "Total 12.4M — 18 % above Q2.",
            .spanish: "Total 12,4 M: un 18 % más que el Q2.",
            .russian: "Итого 12,4 млн — на 18 % больше Q2."
        ],

        "obs.s3.inserted": [
            .english: "typed at the cursor — the other app never noticed",
            .spanish: "escrito donde estaba el cursor: la otra app no notó nada",
            .russian: "вставлено на месте курсора — приложение ничего не заметило"
        ],
        "obs.s3.saying": [.english: "you say:", .spanish: "dices:", .russian: "вы говорите:"],

        "obs.s4.c1": [.english: "Moscow", .spanish: "Moscú", .russian: "Москва"],
        "obs.s4.c1c": [.english: "Russia", .spanish: "Rusia", .russian: "Россия"],
        "obs.s4.c2": [.english: "London", .spanish: "Londres", .russian: "Лондон"],
        "obs.s4.c2c": [.english: "United Kingdom", .spanish: "Reino Unido", .russian: "Великобритания"],
        "obs.s4.c3": [.english: "New York", .spanish: "Nueva York", .russian: "Нью-Йорк"],
        "obs.s4.c3c": [.english: "United States", .spanish: "EE. UU.", .russian: "США"],
        "obs.s4.c4": [.english: "Tokyo", .spanish: "Tokio", .russian: "Токио"],
        "obs.s4.c4c": [.english: "Japan", .spanish: "Japón", .russian: "Япония"],
        "obs.s4.date": [.english: "Thu, Jul 23", .spanish: "jue, 23 jul", .russian: "Чт, 23 июля"],
        "obs.s4.chipThu": [.english: "THU", .spanish: "JUE", .russian: "ЧТ"],
        "obs.s4.chipFri": [.english: "FRI", .spanish: "VIE", .russian: "ПТ"],
        "obs.s4.chipMon": [.english: "JUL", .spanish: "JUL", .russian: "ИЮЛЬ"],
        "obs.s4.stripSel": [.english: "Jul 23", .spanish: "23 jul", .russian: "23 июля"],
        "obs.s4.meeting": [.english: "New event · 15:30", .spanish: "Nuevo evento · 15:30", .russian: "Новая встреча · 15:30"],
        "obs.s4.meetingTitle": [
            .english: "Sync with London and Tokyo",
            .spanish: "Reunión con Londres y Tokio",
            .russian: "Созвон с Лондоном и Токио"
        ],
        "obs.s4.create": [.english: "Create", .spanish: "Crear", .russian: "Создать"],

        "obs.s5.r1": [
            .english: "Background removed — PNG with transparency",
            .spanish: "Fondo eliminado: PNG con transparencia",
            .russian: "Фон удалён — PNG с прозрачностью"
        ],
        "obs.s5.r2": [
            .english: "Upscaled ×4 — 2048 × 1536",
            .spanish: "Escalado ×4: 2048 × 1536",
            .russian: "Увеличено ×4 — 2048 × 1536"
        ],
        "obs.s5.r3": [
            .english: "Object removed — the gap filled in",
            .spanish: "Objeto eliminado — hueco rellenado",
            .russian: "Объект удалён — фон восстановлен"
        ],
        "obs.s5.note": [
            .english: "Every result comes back into the chat as a ready file — save it or keep editing.",
            .spanish: "Cada resultado vuelve al chat como un archivo listo: guárdalo o sigue editando.",
            .russian: "Каждый результат возвращается в чат готовым файлом — сохраните или продолжайте править."
        ],
        "obs.s5.ph": [
            .english: "Or just ask about the picture…",
            .spanish: "O pregunta por la imagen…",
            .russian: "Или просто спросите про картинку…"
        ],

        "panel.extractText": [.english: "Extract Text", .spanish: "Extraer texto", .russian: "Извлечь текст"],
        "panel.extracting": [.english: "Extracting…", .spanish: "Extrayendo…", .russian: "Извлечение…"],
        "panel.noProviderKey": [.english: "No API key for the active provider. Open the status bar icon → Settings… to add your API key and load the model list.", .spanish: "No hay clave API para el proveedor activo. Abre el icono de la barra de estado → Ajustes… para añadir tu clave y cargar los modelos.", .russian: "Нет ключа API для активного провайдера. Откройте иконку в статус-баре → Настройки…, добавьте ключ и загрузите список моделей."],
        "panel.noModelSelected": [.english: "No model selected for the active provider. Open Settings… and press “Load Models”.", .spanish: "No hay modelo seleccionado. Abre Ajustes… y pulsa “Cargar modelos”.", .russian: "Не выбрана модель. Откройте Настройки… и нажмите «Загрузить модели»."],
        "panel.needTranscription": [.english: "Voice messages need a transcription provider. Open Settings… and add a Mistral (Voxtral) or OpenAI key.", .spanish: "Los mensajes de voz necesitan un proveedor de transcripción. Abre Ajustes… y añade una clave de Mistral (Voxtral) u OpenAI.", .russian: "Для голосовых нужен провайдер распознавания. Откройте Настройки… и добавьте ключ Mistral (Voxtral) или OpenAI."],
    ]
}
