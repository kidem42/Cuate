import Foundation

/// Self-contained localization for the LayoutFix addon.
///
/// Deliberately kept separate from the app's global `L()` table so every string
/// the addon needs lives inside the addon folder. It still honors the app's
/// current language (`Localization.currentLanguage`), so the tab switches
/// languages together with the rest of Settings.
func LFL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = LayoutFixStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum LayoutFixStrings {
    static let table: [String: [AppLanguage: String]] = [
        "lf.tab": [.english: "Layout", .spanish: "Teclado", .russian: "Раскладка"],

        // General tab master switch + menu-bar items
        "lf.general.enable": [.english: "AutoSwitcher (beta)", .spanish: "AutoSwitcher (beta)", .russian: "Автосвитчер (бета)"],
        "lf.general.enable.caption": [.english: "Fixes text typed in the wrong keyboard layout (ghbdtn → привет) in any app: automatically as you type, or by hotkey. Configure in the Layout tab.", .spanish: "Corrige el texto escrito con la distribución de teclado equivocada (ghbdtn → привет) en cualquier app: automáticamente al escribir o con un atajo. Se configura en la pestaña Layout.", .russian: "Исправляет текст, набранный не в той раскладке (ghbdtn → привет), в любом приложении: автоматически при наборе или по хоткею. Настраивается во вкладке «Раскладка»."],
        "lf.menu.title": [.english: "Layout Switcher", .spanish: "Cambiador de distribución", .russian: "Переключатель раскладки"],
        "lf.menu.auto": [.english: "Auto-fix layout while typing", .spanish: "Autocorregir distribución al escribir", .russian: "Автоисправление раскладки при наборе"],
        "lf.menu.openSettings": [.english: "Layout Switcher Settings…", .spanish: "Ajustes del cambiador…", .russian: "Настройки переключателя…"],

        "lf.header": [.english: "Fix Keyboard Layout", .spanish: "Corregir la distribución", .russian: "Исправление раскладки"],
        "lf.enable": [.english: "Enable layout fixing", .spanish: "Activar corrección de distribución", .russian: "Включить исправление раскладки"],
        "lf.footer": [
            .english: "Select text typed in the wrong layout (or leave nothing selected to grab the last word) and press the hotkey — “ghbdtn” becomes “привет”. Works in any app. Requires the Accessibility permission.",
            .spanish: "Selecciona el texto escrito en la distribución equivocada (o no selecciones nada para tomar la última palabra) y pulsa el atajo: “ghbdtn” se convierte en “привет”. Funciona en cualquier app. Requiere permiso de Accesibilidad.",
            .russian: "Выделите текст, набранный не в той раскладке (или ничего не выделяйте — возьмётся последнее слово), и нажмите горячую клавишу — «ghbdtn» превратится в «привет». Работает в любом приложении. Нужно разрешение «Универсальный доступ»."
        ],

        "lf.hotkeys.header": [.english: "Hotkeys", .spanish: "Atajos", .russian: "Горячие клавиши"],
        "lf.hotkey.flip": [.english: "Fix selection", .spanish: "Corregir selección", .russian: "Исправить выделение"],
        "lf.hotkey.smart": [.english: "Smart fix (AI)", .spanish: "Corrección inteligente (IA)", .russian: "Умное исправление (ИИ)"],
        "lf.hotkeys.footer": [
            .english: "Click a shortcut, then press the new combination (must include ⌘, ⌃ or ⌥). Applies immediately, system-wide.",
            .spanish: "Haz clic en un atajo y pulsa la nueva combinación (debe incluir ⌘, ⌃ u ⌥). Se aplica al instante, en todo el sistema.",
            .russian: "Кликните по шорткату и нажмите новую комбинацию (обязательно с ⌘, ⌃ или ⌥). Применяется сразу и во всей системе."
        ],

        "lf.options.header": [.english: "Options", .spanish: "Opciones", .russian: "Параметры"],
        "lf.autoWord": [.english: "Grab the last word when nothing is selected", .spanish: "Tomar la última palabra si no hay selección", .russian: "Брать последнее слово, если ничего не выделено"],
        "lf.autoWord.footer": [
            .english: "With nothing selected, the word right before the cursor is selected and converted automatically.",
            .spanish: "Sin selección, la palabra justo antes del cursor se selecciona y convierte automáticamente.",
            .russian: "Если ничего не выделено, слово перед курсором выделяется и конвертируется автоматически."
        ],

        "lf.smart.header": [.english: "Smart Fix (AI)", .spanish: "Corrección inteligente (IA)", .russian: "Умное исправление (ИИ)"],
        "lf.smart.enable": [.english: "Enable AI smart fix", .spanish: "Activar corrección con IA", .russian: "Включить умное исправление ИИ"],
        "lf.smart.footer": [
            .english: "The smart-fix hotkey sends the text to a fast model that fixes layout AND typos in context — better than the table for tricky cases. Falls back to the offline flip if no API key is set. Uses your Mistral key, or the active chat provider.",
            .spanish: "El atajo de corrección inteligente envía el texto a un modelo rápido que corrige la distribución Y las erratas en contexto — mejor que la tabla en casos difíciles. Si no hay clave API, recurre a la conversión offline. Usa tu clave de Mistral o el proveedor de chat activo.",
            .russian: "Хоткей умного исправления отправляет текст быстрой модели, которая чинит и раскладку, И опечатки по контексту — точнее таблицы в сложных случаях. Без ключа API откатывается к офлайн-конвертации. Использует ключ Mistral или активного чат-провайдера."
        ],

        "lf.auto.early": [
            .english: "Switch mid-word (don't wait for the word to end)",
            .spanish: "Cambiar a mitad de palabra",
            .russian: "Переключать не дожидаясь конца слова"
        ],
        "lf.auto.capitalize": [
            .english: "Capitalize the first letter after “. ”",
            .spanish: "Mayúscula inicial tras “. ”",
            .russian: "Заглавная буква после точки с пробелом"
        ],
        "lf.auto.undoHint": [
            .english: "Switched by mistake? Press Backspace right after — the correction is reverted.",
            .spanish: "¿Cambio equivocado? Pulsa Retroceso justo después — la corrección se revierte.",
            .russian: "Ошиблось? Нажми Backspace сразу после — исправление откатится."
        ],
        "lf.exceptions.count": [.english: "Learned exceptions", .spanish: "Excepciones aprendidas", .russian: "Запомненные исключения"],
        "lf.exceptions.clear": [.english: "Clear", .spanish: "Borrar", .russian: "Очистить"],

        "lf.monitor.active": [.english: "Monitoring active", .spanish: "Monitoreo activo", .russian: "Монитор активен"],
        "lf.monitor.inactive": [.english: "Not active — grant Accessibility permission", .spanish: "Inactivo — concede permiso de Accesibilidad", .russian: "Не активен — выдайте доступ «Универсальный доступ»"],
        "lf.debug.toggle": [.english: "Diagnostic logging (to a log file)", .spanish: "Registro de diagnóstico (archivo)", .russian: "Диагностический лог (в файл)"],
        "lf.debug.footer": [
            .english: "Logs each finished word and the decision to ~/Library/Logs/Cuate-LayoutFix.log. Turn on to diagnose, off for daily use.",
            .spanish: "Registra cada palabra y la decisión en ~/Library/Logs/Cuate-LayoutFix.log. Actívalo para diagnosticar.",
            .russian: "Пишет каждое слово и решение в ~/Library/Logs/Cuate-LayoutFix.log. Включай для диагностики."
        ],

        "lf.preview.header": [.english: "Try It", .spanish: "Pruébalo", .russian: "Попробовать"],
        "lf.preview.placeholder": [.english: "Type or paste text to flip…", .spanish: "Escribe o pega texto para convertir…", .russian: "Введите или вставьте текст для конвертации…"],
        "lf.preview.result": [.english: "Result", .spanish: "Resultado", .russian: "Результат"],

        "lf.auto.header": [.english: "Automatic Mode", .spanish: "Modo automático", .russian: "Автоматический режим"],
        "lf.auto.enable": [.english: "Fix layout automatically as I type", .spanish: "Corregir la distribución automáticamente al escribir", .russian: "Исправлять раскладку автоматически при наборе"],
        "lf.auto.switchLayout": [.english: "Also switch the system layout", .spanish: "Cambiar también la distribución del sistema", .russian: "Также переключать системную раскладку"],
        "lf.auto.footer": [
            .english: "Deterministic, no AI: letter-trigram probabilities and word frequencies (RU/EN/ES) decide which layout you meant, with the macOS dictionary as a supporting signal. Handles names, word forms and even typos. Works on space, on Enter (chats), and mid-word.",
            .spanish: "Determinista, sin IA: probabilidades de trigramas y frecuencias de palabras (RU/EN/ES) deciden qué distribución querías, con el diccionario de macOS como señal de apoyo. Maneja nombres, formas y hasta erratas. Actúa con espacio, con Enter (chats) y a mitad de palabra.",
            .russian: "Детерминированно, без ИИ: вероятности буквенных триграмм и частоты слов (RU/EN/ES) решают, какую раскладку ты имел в виду; словарь macOS — вспомогательный сигнал. Понимает имена, словоформы и даже опечатки. Срабатывает на пробел, на Enter (чаты) и посреди слова."
        ],
        "lf.auto.privacy": [
            .english: "Runs entirely on this Mac. Keystrokes are analyzed locally to detect wrong-layout words and never leave your device or get stored.",
            .spanish: "Se ejecuta por completo en este Mac. Las pulsaciones se analizan localmente para detectar palabras en la distribución equivocada; nunca salen del dispositivo ni se guardan.",
            .russian: "Работает полностью на этом Mac. Нажатия анализируются локально для поиска слов не в той раскладке — они не покидают устройство и не сохраняются."
        ],

        "lf.access.warning": [
            .english: "Accessibility permission is required to read the selection and paste the fix.",
            .spanish: "Se requiere permiso de Accesibilidad para leer la selección y pegar la corrección.",
            .russian: "Для чтения выделения и вставки исправления нужно разрешение «Универсальный доступ»."
        ],
        "lf.access.open": [.english: "Open Accessibility Settings", .spanish: "Abrir ajustes de Accesibilidad", .russian: "Открыть настройки доступа"]
    ]
}
