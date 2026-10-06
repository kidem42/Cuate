package com.aispotlight.android.hermes

/**
 * The wire text of a consented continuation turn and its recognition.
 *
 * The desktop asks the agent to continue after background results arrive
 * by sending a user turn. Sent as plain localized prose it came back
 * through the shared session as a message the USER typed (2026-10-03). It
 * now travels in a tagged frame with an English instruction, and the chat
 * renders the row as a compact "continued" marker. Rows sent by older
 * desktop builds are recognized by their exact localized text.
 *
 * Display only: the row stays a user row for sync and turn recovery.
 * Pure Kotlin. Twin: `HermesContinuationFrame` on the desktop — both are
 * checked against `shared/fixtures/service-notices.json`.
 */
object HermesContinuationFrame {
    const val OPEN = "<cuate-continuation>"
    const val CLOSE = "</cuate-continuation>"

    val WIRE: String = OPEN + "\n" +
        "Continue the original task using the background results already received " +
        "in this session and prepare the answer. Do not repeat completed work.\n" +
        CLOSE

    /** The unframed prompt older desktop builds sent (en/es/ru). */
    val LEGACY_PROMPTS: Set<String> = setOf(
        "Continue the original task using the background results already received in this session and prepare the answer. Do not repeat completed work.",
        "Continúa la tarea original con los resultados en segundo plano ya recibidos en esta sesión y prepara la respuesta. No repitas el trabajo completado.",
        "Продолжи исходную задачу с учётом фоновых результатов, уже полученных в этой сессии, и подготовь ответ. Не повторяй завершённую работу.",
    )

    fun isContinuation(text: String): Boolean {
        val trimmed = text.trim()
        return trimmed.startsWith(OPEN) || trimmed in LEGACY_PROMPTS
    }
}
