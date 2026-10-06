package com.aispotlight.android.hermes

/**
 * Gateway service notifications (delegation results, process reports).
 *
 * The gateway injects background-event reports into the conversation as
 * `role == "user"` rows (LLM APIs only have user/assistant): async-delegation
 * completions and background-process notifications from hermes-agent
 * `tools/process_registry_notifications.py`, and since 0.21.5 the gateway's
 * consolidated batches (`gateway/run_notifications.py`). Mirrored verbatim
 * they rendered as messages the USER supposedly sent — a wall of
 * `[ASYNC DELEGATION BATCH COMPLETE …]` in the outgoing bubble (2026-10-03).
 * They are the AGENT's side of the story, so the mirror imports them
 * assistant-side and the chat shows a collapsed service card: one summary
 * line closed, the full report on demand. The card never eats content —
 * whatever does not parse into structure stays in [body].
 *
 * Detection is by stable content markers; the gateway's metadata never
 * crosses the wire. Pure Kotlin. Twin: `HermesServiceNotice` on the desktop
 * (`Addons/HermesAddon/HermesServiceNotice.swift`) — both are checked
 * against `shared/fixtures/service-notices.json`.
 */
data class HermesServiceNotice(
    val kind: Kind,
    /** Header lines shown when the card expands (Dispatched/Role/Status…). */
    val metaLines: List<String>,
    val tasks: List<TaskItem>,
    /** Free-form remainder; null when everything parsed into tasks. */
    val body: String?,
    val okCount: Int,
    val failCount: Int,
    /** Compact duration for the collapsed line ("2m07s"). */
    val durationText: String?,
    /** Process reports: "exit 0"-style capsule for the collapsed line. */
    val exitText: String?,
) {
    enum class Kind { DELEGATION, PROCESS }

    /** One subagent's (or one process's) slice of a report. */
    data class TaskItem(
        val id: Int,
        val ok: Boolean,
        /** "1/3" — position label; empty for a single result. */
        val label: String,
        val goal: String,
        /** Raw stats tail: "status=completed, api_calls=10, 94.23s". */
        val stats: String?,
        val body: String,
    )

    companion object {
        private const val DELEGATION_MARKER = "[ASYNC DELEGATION "
        private const val BATCH_MARKER = "[ASYNC DELEGATION BATCH COMPLETE"
        private const val SINGLE_MARKER = "[ASYNC DELEGATION COMPLETE"
        private const val TASK_FAILED_MARKER = "[ASYNC DELEGATION TASK FAILED"
        private val PROCESS_MARKERS = listOf("[IMPORTANT: Background process", "[Background process")
        private val META_PREFIXES = listOf(
            "Dispatched:", "Original goal:", "Context you provided:", "Toolsets:", "Role:", "Status:",
        )

        /** `[IMPORTANT: N background subagent delegations|processes completed…]`. */
        private fun consolidatedKind(head: String): Kind? {
            val prefix = "[IMPORTANT: "
            if (!head.startsWith(prefix)) return null
            val rest = head.substring(prefix.length)
            val digits = rest.takeWhile { it.isDigit() }
            if (digits.isEmpty()) return null
            val tail = rest.substring(digits.length)
            return when {
                tail.startsWith(" background subagent delegations completed") -> Kind.DELEGATION
                tail.startsWith(" background processes completed") -> Kind.PROCESS
                else -> null
            }
        }

        /** Whether a transcript row's content is a gateway service notification. */
        fun isNotice(text: String): Boolean {
            val head = text.trimStart()
            return head.startsWith(DELEGATION_MARKER) ||
                PROCESS_MARKERS.any { head.startsWith(it) } ||
                consolidatedKind(head) != null
        }

        fun parse(text: String): HermesServiceNotice? {
            val trimmed = text.trimStart()
            consolidatedKind(trimmed)?.let { return parseConsolidated(trimmed, it) }
            if (trimmed.startsWith(DELEGATION_MARKER)) return parseDelegation(trimmed)
            if (PROCESS_MARKERS.any { trimmed.startsWith(it) }) return parseProcess(trimmed)
            return null
        }

        private fun parseDelegation(text: String): HermesServiceNotice = when {
            text.startsWith(BATCH_MARKER) -> parseBatch(text)
            text.startsWith(TASK_FAILED_MARKER) -> parseTaskFailed(text)
            text.startsWith(SINGLE_MARKER) -> parseSingle(text)
            else -> {
                // A delegation report this build does not know: whole text, no tally.
                val body = text.lines().drop(1).joinToString("\n").trim()
                HermesServiceNotice(Kind.DELEGATION, emptyList(), emptyList(), body.ifEmpty { text },
                    0, 0, null, null)
            }
        }

        private fun parseConsolidated(text: String, kind: Kind): HermesServiceNotice {
            val starts = if (kind == Kind.DELEGATION) listOf(DELEGATION_MARKER) else PROCESS_MARKERS
            val blocks = mutableListOf<MutableList<String>>()
            for (line in text.lines().drop(1)) {
                if (starts.any { line.startsWith(it) }) blocks.add(mutableListOf(line))
                else blocks.lastOrNull()?.add(line)
            }
            val tasks = mutableListOf<TaskItem>()
            val bodies = mutableListOf<String>()
            var ok = 0
            var failed = 0
            for (block in blocks) {
                val report = block.joinToString("\n").trim()
                val notice = if (kind == Kind.DELEGATION) parseDelegation(report) else parseProcess(report)
                ok += notice.okCount
                failed += notice.failCount
                if (kind == Kind.PROCESS) {
                    tasks.add(TaskItem(tasks.size, notice.failCount == 0, "",
                        notice.metaLines.firstOrNull() ?: "", notice.exitText, notice.body ?: ""))
                    continue
                }
                for (task in notice.tasks) tasks.add(task.copy(id = tasks.size))
                notice.body?.takeIf { it.isNotEmpty() }?.let { bodies.add(it) }
            }
            return HermesServiceNotice(kind, emptyList(), tasks,
                bodies.takeIf { it.isNotEmpty() }?.joinToString("\n\n"), ok, failed, null, null)
        }

        private fun parseBatch(text: String): HermesServiceNotice {
            // Task headers: `--- ✓ TASK 1/3: goal  (status=…) ---`; ⚠ marks a
            // task cut off at max_iterations — its work may be incomplete.
            fun taskHeader(line: String): Pair<Boolean, String>? = when {
                line.startsWith("--- ✓ TASK ") -> true to line.removePrefix("--- ✓ TASK ")
                line.startsWith("--- ✗ TASK ") -> false to line.removePrefix("--- ✗ TASK ")
                line.startsWith("--- ⚠ TASK ") -> false to line.removePrefix("--- ⚠ TASK ")
                else -> null
            }
            val metaLines = mutableListOf<String>()
            val tasks = mutableListOf<TaskItem>()
            val errorBody = mutableListOf<String>()
            var inError = false
            var current: TaskItem? = null
            val currentBody = mutableListOf<String>()
            fun flush() {
                current?.let { tasks.add(it.copy(body = currentBody.joinToString("\n").trim())) }
                current = null
                currentBody.clear()
            }
            for (line in text.lines().drop(1)) {
                val header = taskHeader(line)
                if (header != null) {
                    flush()
                    inError = false
                    var rest = header.second
                    if (rest.endsWith("---")) rest = rest.dropLast(3).trim()
                    var label = ""
                    var goal = rest
                    val colon = rest.indexOf(": ")
                    if (colon >= 0) {
                        label = rest.substring(0, colon)
                        goal = rest.substring(colon + 2)
                    }
                    var stats: String? = null
                    val open = goal.lastIndexOf("(status=")
                    if (open >= 0) {
                        stats = goal.substring(open).trim().removePrefix("(").removeSuffix(")")
                        goal = goal.substring(0, open).trim()
                    }
                    current = TaskItem(tasks.size, header.first, label, goal, stats, "")
                    continue
                }
                if (current != null) {
                    currentBody.add(line)
                    continue
                }
                if (line == "--- ERROR ---") { inError = true; continue }
                if (inError) { errorBody.add(line); continue }
                if (META_PREFIXES.any { line.startsWith(it) }) metaLines.add(line)
            }
            flush()
            val error = errorBody.joinToString("\n").trim()
            return HermesServiceNotice(Kind.DELEGATION, metaLines, tasks, error.ifEmpty { null },
                tasks.count { it.ok }, tasks.count { !it.ok }, duration(metaLines), null)
        }

        private fun parseSingle(text: String): HermesServiceNotice {
            val metaLines = mutableListOf<String>()
            val resultBody = mutableListOf<String>()
            var inResult = false
            var goal = ""
            var ok = true
            for (line in text.lines().drop(1)) {
                if (inResult) { resultBody.add(line); continue }
                if (line == "--- RESULT ---") { inResult = true; continue }
                if (META_PREFIXES.any { line.startsWith(it) }) {
                    metaLines.add(line)
                    if (line.startsWith("Original goal:")) goal = line.removePrefix("Original goal:").trim()
                    if (line.startsWith("Status:")) {
                        val status = line.lowercase()
                        ok = "completed" in status || "success" in status
                    }
                }
            }
            val body = resultBody.joinToString("\n").trim()
            val empty = goal.isEmpty() && body.isEmpty()
            return HermesServiceNotice(Kind.DELEGATION, metaLines,
                if (empty) emptyList() else listOf(TaskItem(0, ok, "", goal, null, body)),
                if (empty) body else null,
                if (ok) 1 else 0, if (ok) 0 else 1, duration(metaLines), null)
        }

        /** `[ASYNC DELEGATION TASK FAILED — deleg_…, task 2/3]` + `Task:`/`Status:`/`Error:`. */
        private fun parseTaskFailed(text: String): HermesServiceNotice {
            val lines = text.lines()
            val title = lines.firstOrNull().orEmpty()
            val at = title.lastIndexOf(", task ")
            val label = if (at >= 0) title.substring(at + ", task ".length).trim(']', ' ') else ""
            var goal = ""
            val metaLines = mutableListOf<String>()
            val body = mutableListOf<String>()
            for (line in lines.drop(2)) {
                when {
                    line.startsWith("Task:") -> goal = line.removePrefix("Task:").trim()
                    line.startsWith("Status:") -> metaLines.add(line)
                    else -> body.add(line)
                }
            }
            val task = TaskItem(0, false, label, goal, metaLines.firstOrNull(), body.joinToString("\n").trim())
            return HermesServiceNotice(Kind.DELEGATION, metaLines, listOf(task), null, 0, 1,
                duration(metaLines), null)
        }

        private fun parseProcess(text: String): HermesServiceNotice {
            // Strip the outer [IMPORTANT: … ] / [ … ] envelope (tolerate a
            // missing close bracket — truncation upstream).
            var content = text.removePrefix("[").removePrefix("IMPORTANT:").trim()
            content = content.removeSuffix("]")
            val lines = content.lines()
            val headline = lines.firstOrNull().orEmpty()
            val body = lines.drop(1).joinToString("\n").trim()
            var exitText: String? = null
            val at = headline.indexOf("exit code ")
            if (at >= 0) {
                val code = headline.substring(at + "exit code ".length).takeWhile { it == '-' || it.isDigit() }
                if (code.isNotEmpty()) exitText = "exit $code"
            }
            val failed = (exitText != null && exitText != "exit 0") ||
                "failed to start" in headline || "terminated" in headline
            return HermesServiceNotice(Kind.PROCESS, listOf(headline), emptyList(), body.ifEmpty { null },
                if (failed) 0 else 1, if (failed) 1 else 0, null, exitText)
        }

        /** "Total duration: 127.26s" / "Duration: 94.23s" → "2m07s". */
        private fun duration(lines: List<String>): String? {
            for (line in lines) {
                val at = line.indexOf("uration: ")
                if (at < 0) continue
                val number = line.substring(at + "uration: ".length).takeWhile { it.isDigit() || it == '.' }
                val seconds = number.toDoubleOrNull() ?: continue
                if (seconds <= 0) continue
                // Half up, like Swift's rounded() on the desktop (round() is half-even).
                val total = kotlin.math.floor(seconds + 0.5).toInt()
                return if (total < 60) "${total}s"
                else String.format(java.util.Locale.ROOT, "%dm%02ds", total / 60, total % 60)
            }
            return null
        }
    }
}
