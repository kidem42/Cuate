import Foundation

/// Self-contained localization for the AgentGateway core (pattern:
/// `CalendarLocalization.CAL`). Follows the app's current language, adds
/// nothing to the global `L()` table. Addon-specific strings (Hermes) live
/// in the addon's own table; this one holds what the shared UI components
/// and diagnostics need.
func AGL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = AgentGatewayStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum AgentGatewayStrings {
    static let table: [String: [AppLanguage: String]] = [

        // MARK: Gateway probe diagnostics (§7 table)
        "agent.probe.ok": [
            .english: "Connected.",
            .spanish: "Conectado.",
            .russian: "Подключено."
        ],
        "agent.probe.unreachable": [
            .english: "The server is not responding — check the address, and the VPN/tunnel if the gateway is remote.",
            .spanish: "El servidor no responde — revisa la dirección, y la VPN o el túnel si el gateway es remoto.",
            .russian: "Сервер не отвечает — проверьте адрес, а для удалённого гейтвея — VPN или туннель."
        ],
        "agent.probe.endpointDisabled": [
            .english: "The API endpoint is disabled on the gateway — enable it in the agent's config (Hermes: API_SERVER_ENABLED=true) and restart the gateway.",
            .spanish: "El endpoint de la API está desactivado en el gateway — actívalo en la configuración del agente (Hermes: API_SERVER_ENABLED=true) y reinicia el gateway.",
            .russian: "API-эндпоинт выключен на гейтвее — включите его в конфиге агента (Hermes: API_SERVER_ENABLED=true) и перезапустите гейтвей."
        ],
        "agent.probe.unauthorized": [
            .english: "The gateway rejected the token — check the API key.",
            .spanish: "El gateway rechazó el token — revisa la clave API.",
            .russian: "Гейтвей отклонил токен — проверьте API-ключ."
        ],
        "agent.probe.tls": [
            .english: "TLS handshake failed — the server certificate did not match.",
            .spanish: "Falló el handshake TLS — el certificado del servidor no coincide.",
            .russian: "Ошибка TLS — сертификат сервера не прошёл проверку."
        ],
        "agent.probe.noAgents": [
            .english: "Connected, but no agents or profiles are configured on the gateway.",
            .spanish: "Conectado, pero no hay agentes ni perfiles configurados en el gateway.",
            .russian: "Подключено, но на гейтвее не настроено ни одного агента или профиля."
        ],
        "agent.probe.failed": [
            .english: "Connection check failed: %@",
            .spanish: "La comprobación de conexión falló: %@",
            .russian: "Проверка соединения не прошла: %@"
        ],

        // MARK: Role chip / connection dot
        "agent.chip.connected": [
            .english: "Agent connected",
            .spanish: "Agente conectado",
            .russian: "Агент подключён"
        ],
        "agent.chip.disconnected": [
            .english: "Agent unreachable — tap for diagnostics",
            .spanish: "Agente inaccesible — toca para diagnóstico",
            .russian: "Агент недоступен — нажмите для диагностики"
        ],

        // MARK: Approval card
        "agent.approval.title": [
            .english: "The agent asks permission to run:",
            .spanish: "El agente pide permiso para ejecutar:",
            .russian: "Агент просит разрешение выполнить:"
        ],
        "agent.approval.allow": [
            .english: "Allow",
            .spanish: "Permitir",
            .russian: "Разрешить"
        ],
        "agent.approval.always": [
            .english: "Always allow",
            .spanish: "Permitir siempre",
            .russian: "Разрешать всегда"
        ],
        "agent.approval.deny": [
            .english: "Deny",
            .spanish: "Denegar",
            .russian: "Отклонить"
        ],
        "agent.approval.resolvedElsewhere": [
            .english: "Resolved from another client.",
            .spanish: "Resuelto desde otro cliente.",
            .russian: "Решено из другого клиента."
        ],

        // MARK: Step journal
        "agent.steps.title": [
            .english: "Steps",
            .spanish: "Pasos",
            .russian: "Шаги"
        ],
        "agent.steps.running": [
            .english: "running",
            .spanish: "en curso",
            .russian: "выполняется"
        ],
        "agent.steps.completed": [
            .english: "done",
            .spanish: "hecho",
            .russian: "готово"
        ],
        "agent.steps.failed": [
            .english: "failed",
            .spanish: "falló",
            .russian: "ошибка"
        ],

        // MARK: Code blocks / terminal output (§7.2–7.3)
        "agent.code.showAll": [
            .english: "Show all %d lines",
            .spanish: "Mostrar las %d líneas",
            .russian: "Показать все %d строк"
        ],
        "agent.code.saveLog": [
            .english: "Save the full output to a file",
            .spanish: "Guardar toda la salida en un archivo",
            .russian: "Сохранить весь вывод в файл"
        ],
        "agent.code.runAtAgent": [
            .english: "Run at the agent (%@)",
            .spanish: "Ejecutar en el agente (%@)",
            .russian: "Выполнить у агента (%@)"
        ],
        "agent.code.remotePrompt": [
            .english: "Run this command in your terminal and show the output:\n```sh\n%@\n```",
            .spanish: "Ejecuta este comando en tu terminal y muestra la salida:\n```sh\n%@\n```",
            .russian: "Выполни эту команду в своём терминале и покажи вывод:\n```sh\n%@\n```"
        ],
        "agent.files.title": [
            .english: "Chat files",
            .spanish: "Archivos del chat",
            .russian: "Файлы чата"
        ],
        "agent.files.fromUser": [
            .english: "Shared by you",
            .spanish: "Compartidos por ti",
            .russian: "Отправленные вами"
        ],
        "agent.files.empty": [
            .english: "The agent has not shared any files in this chat yet.",
            .spanish: "El agente aún no ha compartido archivos en este chat.",
            .russian: "Агент пока не отдавал файлов в этой беседе."
        ],
        "agent.files.open": [
            .english: "Open",
            .spanish: "Abrir",
            .russian: "Открыть"
        ],
        "agent.file.reveal": [
            .english: "Reveal in Finder: %@",
            .spanish: "Mostrar en Finder: %@",
            .russian: "Показать в Finder: %@"
        ],
        "agent.file.remote": [
            .english: "The file lives on the agent's host — click to copy the path: %@",
            .spanish: "El archivo está en el host del agente — clic para copiar la ruta: %@",
            .russian: "Файл на машине агента — клик копирует путь: %@"
        ],
        "agent.file.fetch": [
            .english: "Download from the agent's machine to ~/Downloads: %@",
            .spanish: "Descargar de la máquina del agente a ~/Downloads: %@",
            .russian: "Скачать с машины агента в ~/Downloads: %@"
        ],
        "agent.file.fetchFailed": [
            .english: "Download failed — the path was copied instead",
            .spanish: "No se pudo descargar — se copió la ruta",
            .russian: "Скачать не удалось — путь скопирован в буфер"
        ],
        "agent.image.failed": [
            .english: "Image from the agent could not be loaded",
            .spanish: "No se pudo cargar la imagen del agente",
            .russian: "Картинку от агента загрузить не удалось"
        ],

        // MARK: Notifications (§7.1)
        "agent.notif.reply": [
            .english: "Reply",
            .spanish: "Responder",
            .russian: "Ответить"
        ],
        "agent.notif.turnDone": [
            .english: "The agent finished the task.",
            .spanish: "El agente terminó la tarea.",
            .russian: "Агент завершил задачу."
        ],
        "agent.notif.approvalTitle": [
            .english: "%@ asks permission",
            .spanish: "%@ pide permiso",
            .russian: "%@ просит разрешение"
        ],
        "agent.notif.approvalHidden": [
            .english: "The agent asks permission to run a command.",
            .spanish: "El agente pide permiso para ejecutar un comando.",
            .russian: "Агент просит разрешение выполнить команду."
        ],

        // MARK: Chat-side status
        "agent.status.tool": [
            .english: "Agent: %@",
            .spanish: "Agente: %@",
            .russian: "Агент: %@"
        ],
        "agent.status.thinking": [
            .english: "Agent is working…",
            .spanish: "El agente está trabajando…",
            .russian: "Агент работает…"
        ],
        "agent.attach.fileNote.header": [
            .english: "Attached file (read it from your host):",
            .spanish: "Archivo adjunto (léelo desde tu host):",
            .russian: "Приложен файл (прочитай его со своей машины):"
        ],
        "agent.attach.filesNote.header": [
            .english: "Attached files (read them from your host):",
            .spanish: "Archivos adjuntos (léelos desde tu host):",
            .russian: "Приложены файлы (прочитай их со своей машины):"
        ],
        // MARK: Pinned messages (Telegram-style, agent chats)
        "agent.pin.pin": [
            .english: "Pin message",
            .spanish: "Fijar mensaje",
            .russian: "Закрепить сообщение"
        ],
        "agent.pin.unpin": [
            .english: "Unpin message",
            .spanish: "Soltar mensaje",
            .russian: "Открепить сообщение"
        ],
        "agent.pin.title": [
            .english: "Pinned message",
            .spanish: "Mensaje fijado",
            .russian: "Закреплённое сообщение"
        ],
        "agent.pin.barHelp": [
            .english: "Click to jump between pinned messages",
            .spanish: "Clic para saltar entre mensajes fijados",
            .russian: "Клик — переход по закреплённым сообщениям по кругу"
        ],
        "agent.stop": [
            .english: "Stop the agent (the run is cancelled on the gateway too)",
            .spanish: "Detener el agente (la ejecución se cancela también en el gateway)",
            .russian: "Остановить агента (ран отменяется и на гейтвее)"
        ],
        "agent.stopped": [
            .english: "Stopped.",
            .spanish: "Detenido.",
            .russian: "Остановлено."
        ],
        "agent.offline.older": [
            .english: "Older messages are stored on the agent, which is unreachable right now.",
            .spanish: "Los mensajes anteriores están en el agente, que ahora mismo está inaccesible.",
            .russian: "Более старые сообщения хранятся у агента, сейчас он недоступен."
        ]
    ]
}
