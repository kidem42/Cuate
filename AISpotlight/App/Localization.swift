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

        // MARK: OpenRouter manual model entry
        "or.placeholder": [.english: "e.g. openai/gpt-4o", .spanish: "p. ej. openai/gpt-4o", .russian: "напр. openai/gpt-4o"],
        "or.browse": [.english: "Browse models on openrouter.ai ↗", .spanish: "Explorar modelos en openrouter.ai ↗", .russian: "Каталог моделей на openrouter.ai ↗"],
        "or.valid": [.english: "Model found in the OpenRouter catalog", .spanish: "Modelo encontrado en el catálogo de OpenRouter", .russian: "Модель найдена в каталоге OpenRouter"],
        "or.notFound": [.english: "Not in the OpenRouter catalog — double-check the slug", .spanish: "No está en el catálogo de OpenRouter — revisa el identificador", .russian: "Нет в каталоге OpenRouter — проверьте идентификатор"],
        "or.recent": [.english: "Recent models", .spanish: "Modelos recientes", .russian: "Недавние модели"],
        "or.clear": [.english: "Clear history", .spanish: "Borrar historial", .russian: "Очистить историю"],
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
        "web.allow": [.english: "Allow web search", .spanish: "Permitir búsqueda web", .russian: "Разрешить веб-поиск"],
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
        "ocr.footer": [.english: "Used by “Extract Text” on screenshots and as a fallback that lets non-vision chat models read images. Uses the Mistral key.", .spanish: "Se usa en “Extraer texto” de capturas y como respaldo para que modelos sin visión lean imágenes. Usa la clave de Mistral.", .russian: "Используется кнопкой «Извлечь текст» на скриншотах и как запасной путь, чтобы модели без зрения могли читать изображения. Использует ключ Mistral."],
        "dictation.header": [.english: "Dictation", .spanish: "Dictado", .russian: "Диктовка"],
        "dictation.enable": [.english: "System-wide dictation", .spanish: "Dictado en todo el sistema", .russian: "Диктовка во всей системе"],
        "dictation.cleanup": [.english: "Clean up fillers & punctuation", .spanish: "Limpiar muletillas y puntuación", .russian: "Убирать слова-паразиты и пунктуацию"],
        "dictation.chunked": [.english: "Insert by phrases (pause detection)", .spanish: "Insertar por frases (detección de pausas)", .russian: "Вставлять по фразам (детекция пауз)"],
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
        "panel.welcome": [.english: "Hi! I'm your AI assistant. How can I help you today?", .spanish: "¡Hola! Soy tu asistente de IA. ¿En qué puedo ayudarte hoy?", .russian: "Привет! Я ваш ИИ-ассистент. Чем могу помочь?"],
        "panel.thinking": [.english: "Thinking…", .spanish: "Pensando…", .russian: "Думаю…"],
        "panel.searching": [.english: "Searching", .spanish: "Buscando", .russian: "Поиск"],
        "panel.retry": [.english: "Retry last message", .spanish: "Reintentar último mensaje", .russian: "Повторить сообщение"],
        "panel.jumpLatest": [.english: "Jump to the latest message", .spanish: "Ir al mensaje más reciente", .russian: "К последнему сообщению"],
        "panel.recordingCancelled": [.english: "Recording cancelled.", .spanish: "Grabación cancelada.", .russian: "Запись отменена."],
        "recording.hint": [.english: "Space to send · ×2 to cancel", .spanish: "Espacio para enviar · ×2 para cancelar", .russian: "Пробел — отправить · ×2 — отмена"],
        "panel.recordLimitSent": [.english: "Recording reached the limit of %d minutes and was sent automatically.", .spanish: "La grabación alcanzó el límite de %d minutos y se envió automáticamente.", .russian: "Запись достигла лимита в %d минут и была отправлена автоматически."],
        "panel.recordLimitStopped": [.english: "Recording reached the limit of %d minutes and was stopped.", .spanish: "La grabación alcanzó el límite de %d minutos y se detuvo.", .russian: "Запись достигла лимита в %d минут и была остановлена."],
        "panel.recordStartFailed": [.english: "Failed to start recording. Please check microphone permissions in System Settings.", .spanish: "No se pudo iniciar la grabación. Revisa los permisos del micrófono en Ajustes del Sistema.", .russian: "Не удалось начать запись. Проверьте доступ к микрофону в Системных настройках."],
        "panel.noSpeech": [.english: "The recording contained no recognizable speech.", .spanish: "La grabación no contenía voz reconocible.", .russian: "В записи не распознано речи."],
        "panel.transcriptionFailed": [.english: "Transcription failed: %@", .spanish: "Falló la transcripción: %@", .russian: "Ошибка расшифровки: %@"],
        "panel.emptyReply": [.english: "(empty reply)", .spanish: "(respuesta vacía)", .russian: "(пустой ответ)"],
        "panel.ocrDone": [.english: "Extracted with OCR — structure preserved as Markdown, raw text copied to the clipboard.", .spanish: "Extraído con OCR — estructura conservada como Markdown, texto copiado al portapapeles.", .russian: "Распознано через OCR — структура сохранена в Markdown, текст скопирован в буфер обмена."],
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
        "copy.copied": [.english: "Copied", .spanish: "Copiado", .russian: "Скопировано"],
        "tooltip.tapToCopy": [.english: "Click to copy", .spanish: "Haz clic para copiar", .russian: "Клик — скопировать"],

        // MARK: Onboarding
        "ob.next": [.english: "Next", .spanish: "Siguiente", .russian: "Далее"],
        "ob.back": [.english: "Back", .spanish: "Atrás", .russian: "Назад"],
        "ob.done": [.english: "Get Started", .spanish: "Empezar", .russian: "Начать"],
        "ob.skip": [.english: "Skip", .spanish: "Omitir", .russian: "Пропустить"],
        "ob.showTour": [.english: "Show Welcome Tour", .spanish: "Mostrar el tour de bienvenida", .russian: "Показать обзор функций"],
        "ob.p1.title": [.english: "AI anywhere on your Mac", .spanish: "IA en cualquier lugar de tu Mac", .russian: "ИИ в любом месте вашего Mac"],
        "ob.p1.body": [.english: "AISpotlight lives in the menu bar and appears over any app with one hotkey, Spotlight-style. Ask anything, then press Esc or click away to dismiss.", .spanish: "AISpotlight vive en la barra de menús y aparece sobre cualquier app con un atajo, al estilo Spotlight. Pregunta lo que sea y haz clic fuera para cerrarlo.", .russian: "AISpotlight живёт в статус-баре и появляется поверх любого приложения по хоткею, как Spotlight. Спросите что угодно; клик мимо окна скрывает панель."],
        "ob.p2.title": [.english: "Bring your own keys", .spanish: "Usa tus propias claves", .russian: "Ваши собственные ключи"],
        "ob.p2.body": [.english: "Works with OpenAI, Claude, Gemini, Mistral and DeepSeek — add any API keys in Settings → API Keys, load the model list and pick a model. Keys are stored only in the macOS Keychain on this device.", .spanish: "Funciona con OpenAI, Claude, Gemini, Mistral y DeepSeek: añade tus claves en Ajustes → Claves API, carga la lista de modelos y elige uno. Las claves se guardan solo en el Llavero de macOS de este equipo.", .russian: "Работает с OpenAI, Claude, Gemini, Mistral и DeepSeek: добавьте ключи в Настройки → Ключи API, загрузите список моделей и выберите модель. Ключи хранятся только в Связке ключей macOS на этом устройстве."],
        "ob.p2.note": [.english: "For all features to work, add at least one chat key; a Mistral key additionally covers voice and OCR (voice also works with OpenAI or Deepgram).", .spanish: "Para que todo funcione, añade al menos una clave de chat; la de Mistral cubre además voz y OCR (la voz también funciona con OpenAI o Deepgram).", .russian: "Чтобы работали все функции, добавьте хотя бы один ключ для чата; ключ Mistral дополнительно покрывает голос и OCR (голос также работает с OpenAI или Deepgram)."],
        "ob.p3.title": [.english: "Screenshots & OCR", .spanish: "Capturas y OCR", .russian: "Скриншоты и OCR"],
        "ob.p3.body": [.english: "Capture the whole screen or a selected area straight into the chat — ask questions about what's on screen, or press “Extract Text” to turn any screenshot into structured Markdown.", .spanish: "Captura toda la pantalla o un área directamente al chat: pregunta sobre lo que ves o pulsa “Extraer texto” para convertir la captura en Markdown estructurado.", .russian: "Скриншот всего экрана или выделенной области попадает прямо в чат: задавайте вопросы о том, что на экране, или нажмите «Извлечь текст», чтобы получить структурированный Markdown."],
        "ob.p4.title": [.english: "Voice messages", .spanish: "Mensajes de voz", .russian: "Голосовые сообщения"],
        "ob.p4.body": [.english: "Record with the mic button — speech is transcribed and sent to the model. Pick the transcription provider in Settings → Voice: Mistral Voxtral, OpenAI or Deepgram. While recording: Space sends, double-Space or Esc cancels.", .spanish: "Graba con el botón del micrófono: la voz se transcribe y se envía al modelo. Elige el proveedor de transcripción en Ajustes → Voz: Mistral Voxtral, OpenAI o Deepgram. Durante la grabación: Espacio envía, doble Espacio o Esc cancela.", .russian: "Записывайте кнопкой микрофона: речь распознаётся и уходит модели. Провайдер распознавания выбирается в Настройки → Голос: Mistral Voxtral, OpenAI или Deepgram. Во время записи: Пробел — отправить, двойной Пробел или Esc — отмена."],
        "ob.p5.title": [.english: "Dictate into any app", .spanish: "Dicta en cualquier app", .russian: "Диктовка в любое приложение"],
        "ob.p5.body": [.english: "Press the dictation hotkey in any text field — a pill appears under the camera, and the recognized (or translated) text is typed phrase by phrase right where your cursor is, while you speak. In translate mode, click the language badge on the pill to switch the target language mid-dictation. Requires the Accessibility permission.", .spanish: "Pulsa el atajo de dictado en cualquier campo de texto: aparece una pastilla bajo la cámara y el texto reconocido (o traducido) se escribe frase a frase justo donde está el cursor, mientras hablas. En modo traducción, haz clic en la insignia del idioma de la pastilla para cambiar el idioma de destino sin dejar de dictar. Requiere el permiso de Accesibilidad.", .russian: "Нажмите хоткей диктовки в любом текстовом поле: под камерой появится пилюля, а распознанный (или переведённый) текст будет впечатываться фраза за фразой прямо туда, где курсор, — пока вы говорите. В режиме перевода кликните по бейджу языка на пилюле, чтобы сменить язык, не прерывая диктовку. Нужно разрешение «Универсальный доступ»."],
        // New pages use semantic keys (not positional ob.pN) so inserting
        // pages never renumbers existing strings.
        "ob.selection.title": [.english: "Select → summon → ask", .spanish: "Selecciona → invoca → pregunta", .russian: "Выделил → вызвал → спросил"],
        "ob.selection.body": [.english: "Select text in any app and press the panel hotkey — the selection lands in the input field as an editable quote, even in WhatsApp, Telegram or Slack. Add an instruction and hit Enter: with a translator preset that's instant translation of anything you select.", .spanish: "Selecciona texto en cualquier app y pulsa el atajo del panel: la selección aparece en el campo de entrada como una cita editable, incluso en WhatsApp, Telegram o Slack. Añade una instrucción y pulsa Enter: con un preajuste de traductor es traducción instantánea de cualquier selección.", .russian: "Выделите текст в любом приложении и нажмите хоткей панели — выделенное появится в поле ввода редактируемой цитатой, даже в WhatsApp, Telegram и Slack. Добавьте инструкцию и нажмите Enter: с пресетом-переводчиком это мгновенный перевод любого выделения."],
        "ob.layoutfix.title": [.english: "Keyboard layout fixer", .spanish: "Corrección de la distribución", .russian: "Исправление раскладки"],
        "ob.layoutfix.body": [.english: "Typed ghbdtn instead of привет? LayoutFix converts text typed in the wrong keyboard layout (EN/RU/ES) — automatically as you type, or by hotkey for the selection. Off by default: enable it in Settings → General.", .spanish: "¿Escribiste ghbdtn en vez de привет? LayoutFix convierte el texto escrito con la distribución equivocada (EN/RU/ES): automáticamente al escribir o con un atajo para la selección. Desactivado por defecto: actívalo en Ajustes → General.", .russian: "Набрали ghbdtn вместо привет? LayoutFix конвертирует текст, набранный не в той раскладке (EN/RU/ES): автоматически при наборе или по хоткею для выделенного. По умолчанию выключен — включите в Настройки → Общие."],
        "ob.layoutfix.flip": [.english: "Fix selection", .spanish: "Corregir selección", .russian: "Исправить выделение"],
        "ob.layoutfix.smart": [.english: "Smart fix (AI)", .spanish: "Corrección inteligente (IA)", .russian: "Умное исправление (ИИ)"],
        "ob.p6.title": [.english: "Web search & more", .spanish: "Búsqueda web y más", .russian: "Веб-поиск и другое"],
        "ob.p6.body": [.english: "Add a Brave key and models can search the web on their own and cite their sources. Switch providers and prompt presets right from the panel header, click monospace values, quotes and code blocks to copy them instantly, and retry any failed request with one click.", .spanish: "Añade una clave de Brave y los modelos buscan en la web por sí mismos y citan sus fuentes. Cambia de proveedor y de preajuste desde la cabecera del panel, haz clic en valores monoespaciados, citas y bloques de código para copiarlos al instante, y reintenta cualquier petición fallida con un clic.", .russian: "Добавьте ключ Brave — модели смогут сами искать в интернете и указывать источники. Провайдер и пресет промпта переключаются в шапке панели, клик по моноширинным значениям, цитатам и код-блокам мгновенно копирует их, а упавший запрос повторяется одной кнопкой."],
        "panel.extractText": [.english: "Extract Text", .spanish: "Extraer texto", .russian: "Извлечь текст"],
        "panel.extracting": [.english: "Extracting…", .spanish: "Extrayendo…", .russian: "Извлечение…"],
        "panel.noProviderKey": [.english: "No API key for the active provider. Open the status bar icon → Settings… to add your API key and load the model list.", .spanish: "No hay clave API para el proveedor activo. Abre el icono de la barra de estado → Ajustes… para añadir tu clave y cargar los modelos.", .russian: "Нет ключа API для активного провайдера. Откройте иконку в статус-баре → Настройки…, добавьте ключ и загрузите список моделей."],
        "panel.noModelSelected": [.english: "No model selected for the active provider. Open Settings… and press “Load Models”.", .spanish: "No hay modelo seleccionado. Abre Ajustes… y pulsa “Cargar modelos”.", .russian: "Не выбрана модель. Откройте Настройки… и нажмите «Загрузить модели»."],
        "panel.needTranscription": [.english: "Voice messages need a transcription provider. Open Settings… and add a Mistral (Voxtral) or OpenAI key.", .spanish: "Los mensajes de voz necesitan un proveedor de transcripción. Abre Ajustes… y añade una clave de Mistral (Voxtral) u OpenAI.", .russian: "Для голосовых нужен провайдер распознавания. Откройте Настройки… и добавьте ключ Mistral (Voxtral) или OpenAI."],
    ]
}
