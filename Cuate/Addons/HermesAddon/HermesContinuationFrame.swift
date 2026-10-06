import Foundation

/// The wire text of a consented continuation turn and its recognition.
///
/// After background results arrive, Cuate asks the agent to continue by
/// sending a user turn. Sent as plain localized prose it came back through
/// the shared session as a message the USER typed — on every device, in the
/// sending device's language (Android 2026-10-03). The turn now travels in a
/// tagged frame: the instruction inside is English regardless of the UI
/// language (it talks to the agent, like the steer frame), and every client
/// renders the row as a compact "continued" marker instead of a bubble.
/// Rows sent by older builds are recognized by their exact localized text.
///
/// This is display only: a continuation row stays a user row for mirror
/// sync and is never a service notice (that would re-offer continuation).
/// Pure Foundation — checked against `shared/fixtures/service-notices.json`
/// with its Kotlin twin `HermesContinuationFrame` on Android.
nonisolated enum HermesContinuationFrame {
    static let open = "<cuate-continuation>"
    static let close = "</cuate-continuation>"

    static let wire = open + "\n"
        + "Continue the original task using the background results already received "
        + "in this session and prepare the answer. Do not repeat completed work.\n"
        + close

    /// The unframed prompt older builds sent (en/es/ru `hermes.continuation.prompt`).
    static let legacyPrompts: Set<String> = [
        "Continue the original task using the background results already received in this session and prepare the answer. Do not repeat completed work.",
        "Continúa la tarea original con los resultados en segundo plano ya recibidos en esta sesión y prepara la respuesta. No repitas el trabajo completado.",
        "Продолжи исходную задачу с учётом фоновых результатов, уже полученных в этой сессии, и подготовь ответ. Не повторяй завершённую работу.",
    ]

    static func isContinuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(open) || legacyPrompts.contains(trimmed)
    }
}
