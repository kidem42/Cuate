import Foundation

/// Self-contained localization for the Translator addon (pattern: `LFL`).
/// Honors the app's current language so the tab switches together with the
/// rest of Settings.
func TRL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = TranslatorStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum TranslatorStrings {
    static let table: [String: [AppLanguage: String]] = [
        "tr.tab": [.english: "Translator", .spanish: "Traductor", .russian: "Переводчик"],

        // General tab master switch + menu-bar item
        "tr.general.enable": [.english: "Translate selection (beta)", .spanish: "Traducir la selección (beta)", .russian: "Перевод выделенного (бета)"],
        "tr.general.enable.caption": [
            .english: "Select text in any app and press the hotkey: the translation opens in a bubble right next to the text and goes away on its own. Configure in the Translator tab.",
            .spanish: "Selecciona texto en cualquier app y pulsa el atajo: la traducción se abre en un bocadillo junto al texto y desaparece sola. Se configura en la pestaña Traductor.",
            .russian: "Выделите текст в любом приложении и нажмите горячую клавишу: перевод откроется в облачке рядом с текстом и сам исчезнет. Настраивается во вкладке «Переводчик»."
        ],
        "tr.menu.translate": [.english: "Translate Selection", .spanish: "Traducir la selección", .russian: "Перевести выделенное"],

        // Tab intro
        "tr.header": [.english: "Translate the selection", .spanish: "Traducir la selección", .russian: "Перевод выделенного"],
        "tr.footer": [
            .english: "Select text anywhere and press the hotkey. The translation opens in a bubble next to the text; the model detects the language itself. Copy it from the bubble, switch the language on the spot or continue in the chat. Esc or a click elsewhere closes the bubble; otherwise it goes away on its own. Needs the Accessibility permission to read the selection.",
            .spanish: "Selecciona texto en cualquier sitio y pulsa el atajo. La traducción se abre en un bocadillo junto al texto; el modelo detecta el idioma por sí mismo. Cópiala desde el bocadillo, cambia el idioma al momento o sigue en el chat. Esc o un clic fuera cierra el bocadillo; si no, desaparece solo. Necesita el permiso de Accesibilidad para leer la selección.",
            .russian: "Выделите текст где угодно и нажмите горячую клавишу. Перевод откроется в облачке рядом с текстом; язык текста модель определяет сама. Скопируйте его из облачка, смените язык на месте или продолжите в чате. Esc или клик в стороне закрывает облачко; иначе оно исчезнет само. Нужно разрешение «Универсальный доступ», чтобы прочитать выделение."
        ],

        // Hotkey
        "tr.hotkeys.header": [.english: "Hotkey", .spanish: "Atajo", .russian: "Горячая клавиша"],
        "tr.hotkey": [.english: "Translate the selection", .spanish: "Traducir la selección", .russian: "Перевести выделенное"],
        "tr.hotkeys.footer": [
            .english: "Click the shortcut, then press the new combination (must include ⌘, ⌃ or ⌥). Applies immediately, system-wide.",
            .spanish: "Haz clic en el atajo y pulsa la nueva combinación (debe incluir ⌘, ⌃ u ⌥). Se aplica al instante, en todo el sistema.",
            .russian: "Кликните по шорткату и нажмите новую комбинацию (обязательно с ⌘, ⌃ или ⌥). Применяется сразу и во всей системе."
        ],
        "tr.help.hotkey": [.english: "The system-wide shortcut that translates the current selection", .spanish: "El atajo global que traduce la selección actual", .russian: "Системный шорткат, переводящий текущее выделение"],

        // Languages
        "tr.lang.header": [.english: "Languages", .spanish: "Idiomas", .russian: "Языки"],
        "tr.lang.target": [.english: "Translate into", .spanish: "Traducir al", .russian: "Переводить на"],
        "tr.lang.fallback": [.english: "Text already in that language goes into", .spanish: "Si el texto ya está en ese idioma, al", .russian: "Если текст уже на нём, то на"],
        "tr.lang.caption": [
            .english: "The model detects the language of the text itself; the pair only says where to go.",
            .spanish: "El modelo detecta el idioma del texto por sí mismo; el par solo dice adónde ir.",
            .russian: "Язык текста модель определяет сама; пара языков лишь говорит, куда переводить."
        ],
        "tr.help.target": [.english: "The language every selection is translated into", .spanish: "El idioma al que se traduce cada selección", .russian: "Язык, на который переводится выделение"],
        "tr.help.fallback": [.english: "Used when the selected text is already in the target language", .spanish: "Se usa cuando el texto seleccionado ya está en el idioma de destino", .russian: "Используется, когда выделенный текст уже на целевом языке"],

        // Model
        "tr.model.header": [.english: "Model", .spanish: "Modelo", .russian: "Модель"],
        "tr.model.provider": [.english: "Provider", .spanish: "Proveedor", .russian: "Провайдер"],
        "tr.model.model": [.english: "Model", .spanish: "Modelo", .russian: "Модель"],
        "tr.model.same": [.english: "Same as dictation", .spanish: "Igual que el dictado", .russian: "Как у диктовки"],
        "tr.model.runs": [.english: "Translates with", .spanish: "Traduce con", .russian: "Переводит"],
        "tr.model.caption": [
            .english: "A small fast model is enough: the pass runs on every hotkey press. The dictation choice lives in Settings → Voice.",
            .spanish: "Basta con un modelo pequeño y rápido: la pasada se ejecuta con cada pulsación del atajo. La elección del dictado vive en Ajustes → Voz.",
            .russian: "Хватит маленькой быстрой модели: проход выполняется при каждом нажатии. Выбор диктовки живёт в Настройках → Голос."
        ],
        "tr.model.unavailable": [
            .english: "No provider can translate right now: add an API key in Settings → Keys or enable local models.",
            .spanish: "Ningún proveedor puede traducir ahora: añade una clave API en Ajustes → Claves o activa los modelos locales.",
            .russian: "Сейчас переводить некому: добавьте ключ API в Настройках → Ключи или включите локальные модели."
        ],
        "tr.help.provider": [.english: "Which provider translates; “Same as dictation” follows Settings → Voice", .spanish: "Qué proveedor traduce; «Igual que el dictado» sigue Ajustes → Voz", .russian: "Какой провайдер переводит; «Как у диктовки» следует за Настройками → Голос"],
        "tr.help.model": [.english: "The model of that provider used for translation", .spanish: "El modelo de ese proveedor que traduce", .russian: "Модель этого провайдера для перевода"],

        // Behavior
        "tr.behavior.header": [.english: "Behavior", .spanish: "Comportamiento", .russian: "Поведение"],
        "tr.linger": [.english: "Stays on screen", .spanish: "Permanece en pantalla", .russian: "Остаётся на экране"],
        "tr.linger.unit": [.english: "s", .spanish: "s", .russian: "с"],
        "tr.help.linger": [.english: "How long the bubble stays once the translation is complete; hovering it pauses the clock", .spanish: "Cuánto permanece el bocadillo una vez completa la traducción; al pasar el cursor el reloj se detiene", .russian: "Сколько облачко остаётся после завершения перевода; наведение курсора ставит часы на паузу"],
        "tr.behavior.caption": [.english: "Esc or a click anywhere else closes the bubble at once.", .spanish: "Esc o un clic en cualquier otro sitio cierra el bocadillo al instante.", .russian: "Esc или клик в любом другом месте закрывает облачко сразу."],

        // Accessibility
        "tr.access.warning": [
            .english: "The Accessibility permission is missing: the selection cannot be read.",
            .spanish: "Falta el permiso de Accesibilidad: no se puede leer la selección.",
            .russian: "Нет разрешения «Универсальный доступ»: выделение прочитать нельзя."
        ],
        "tr.access.open": [.english: "Open System Settings…", .spanish: "Abrir Ajustes del Sistema…", .russian: "Открыть Системные настройки…"],

        // Bubble
        "tr.bubble.nothing": [.english: "Select some text first.", .spanish: "Selecciona un texto primero.", .russian: "Сначала выделите текст."],
        "tr.bubble.noModel": [
            .english: "No model can translate: add an API key in Settings → Keys.",
            .spanish: "Ningún modelo puede traducir: añade una clave API en Ajustes → Claves.",
            .russian: "Переводить некому: добавьте ключ API в Настройках → Ключи."
        ],
        "tr.bubble.failed": [.english: "The translation failed.", .spanish: "La traducción falló.", .russian: "Перевод не удался."],
        "tr.bubble.copy": [.english: "Copy", .spanish: "Copiar", .russian: "Скопировать"],
        "tr.bubble.copied": [.english: "Copied", .spanish: "Copiado", .russian: "Скопировано"],
        "tr.bubble.chat": [.english: "Open in chat", .spanish: "Abrir en el chat", .russian: "Открыть в чате"],
        "tr.bubble.dismiss": [.english: "Dismiss", .spanish: "Cerrar", .russian: "Убрать"],
        "tr.help.copy": [.english: "Copy the translation", .spanish: "Copiar la traducción", .russian: "Скопировать перевод"],
        "tr.help.chat": [.english: "Send the original text to the chat", .spanish: "Enviar el texto original al chat", .russian: "Отправить исходный текст в чат"],
        "tr.help.language": [.english: "Switch the target language and translate again", .spanish: "Cambiar el idioma de destino y traducir de nuevo", .russian: "Сменить язык и перевести заново"],
        "tr.help.dismiss": [.english: "Close (Esc)", .spanish: "Cerrar (Esc)", .russian: "Закрыть (Esc)"],
    ]
}
