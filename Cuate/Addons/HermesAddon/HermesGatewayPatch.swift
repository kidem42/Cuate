import Foundation

/// The Hermes gateway patch as a pure text transform over
/// `gateway/platforms/api_server.py` — the three anchored edits the VPS
/// paste-block makes, kept free of AppKit so `scripts/test-attach-note.sh`
/// compiles it standalone against the source layouts of every Hermes
/// release it must recognize. Locating the file, the backup, the
/// `ast.parse` gate and the restart live in `HermesLocalGateway`.
///
/// 1. `usage.context_tokens` — the real context fill. Hermes reports
///    run-CUMULATIVE token sums in `run.completed.usage`, useless as a
///    gauge (a 26-step turn "fills" the window severalfold; seen live:
///    2188K against a 1050K window). The true fill is what Hermes' own
///    /context shows: preferably the usage anchor (`agent._usage_anchor`,
///    the last response's exact provider-reported prompt+completion), with
///    `agent.context_compressor.last_prompt_tokens` as the fallback on
///    installs that predate the anchor. An older v3 fill line (fallback
///    only) upgrades in place; a Hermes shipping the field natively is
///    left alone.
/// 2. `usage.context_window` — the window the agent ACTUALLY operates with
///    (OAuth caps included), so both gauge numbers come from one frame. It
///    rides on the fill line, which also upgrades a gateway carrying only
///    the older one-line patch.
/// 3. Detached session runs — stock Hermes INTERRUPTS the live run when the
///    session SSE client disconnects (a backgrounded phone, a network
///    flap), stamping "Operation interrupted" into the transcript. Patched,
///    the run finishes on its own and clients recover the reply from the
///    transcript; `POST /v1/runs/{id}/stop` is then the only early end
///    (`HermesAddon.requestStop` sends it on Stop and on every abandoned
///    turn).
///
/// Layouts, anchored by code rather than line numbers: up to Hermes 0.21.0
/// the usage dict holds one entry per line with a trailing comma and the
/// disconnect call closes on its own line; 0.21.1 packs `"total_tokens"`
/// together with the closing brace and hugs the call's bracket. The
/// `/v1/runs` usage dict moved out to `api_server_runs.py` in 0.21.0 and is
/// not patched — the clients launch turns through the session stream.
/// `hermes update` overwrites the file; the state is re-checked whenever
/// the settings pane looks and the offer simply reappears. Mirrors the
/// paste-block in `HermesSettingsView`, `docs/hermes-vps-setup.md` and the
/// Android asset `hermes_gateway_patch.sh` — keep them in sync.
/// `repairCatalog` separately repairs a retained old inventory's price import
/// when the installed Hermes has moved that helper to models_pricing.
enum HermesGatewayPatch {

    /// A locally retained pre-0.21.1 inventory can import the price formatter
    /// from its old module after Hermes moves it. Repair only the observed
    /// import shapes, and only when the destination defines the function and
    /// the old module no longer does. Stock old/new installs are unchanged.
    static func repairCatalog(inventory: String, models: String, pricing: String) -> String? {
        let definition = #"(?m)^def _format_price_per_mtok\("#
        guard pricing.range(of: definition, options: .regularExpression) != nil,
              models.range(of: definition, options: .regularExpression) == nil else { return nil }
        var repaired = inventory.replacingOccurrences(
            of: #"(?m)^([ \t]*)from hermes_cli\.models import \(\n[ \t]*_format_price_per_mtok,\n"#,
            with: "$1from hermes_cli.models_pricing import _format_price_per_mtok\n$1from hermes_cli.models import (\n",
            options: .regularExpression)
        repaired = repaired.replacingOccurrences(
            of: #"(?m)^([ \t]*)from hermes_cli\.models import _format_price_per_mtok$"#,
            with: "$1from hermes_cli.models_pricing import _format_price_per_mtok",
            options: .regularExpression)
        return repaired == inventory ? nil : repaired
    }

    /// The `total_tokens` entry of the usage dict — the context anchor,
    /// followed by `,` (one entry per line) or `}` (packed dict).
    static let totalTokensEntry =
        "\"total_tokens\": getattr(agent, \"session_total_tokens\", 0) or 0"
    static let fillLine =
        "\"context_tokens\": (lambda _a, _c: max(0, int(_a[\"prompt_tokens\"]) + int(_a.get(\"completion_tokens\") or 0)) if isinstance(_a, dict) and _a.get(\"prompt_tokens\") else max(0, getattr(_c, \"last_prompt_tokens\", 0) or 0))(getattr(agent, \"_usage_anchor\", None), getattr(agent, \"context_compressor\", None)),"
    /// The pre-anchor (v3) fill line — recognized so it upgrades in place;
    /// the window line inserted after it stays put through the swap.
    static let fillLineV3 =
        "\"context_tokens\": max(0, getattr(getattr(agent, \"context_compressor\", None), \"last_prompt_tokens\", 0) or 0),"
    static let windowLine =
        "\"context_window\": max(0, getattr(getattr(agent, \"context_compressor\", None), \"context_length\", 0) or 0),"

    /// Only ever exists in a patched file — doubles as the idempotence check.
    static let detachedMarker = "continues detached"
    private static let detachedCall = [
        "            await self._drain_session_stream_task_on_disconnect(",
        "                run_id, task, interrupt_message=\"SSE client disconnected\", shield_wait=False",
    ].joined(separator: "\n")
    private static let detachedLog =
        "            logger.info(\"Session SSE client disconnected; interrupted live run %s\", run_id)"
    /// The stock disconnect handler in both layouts, replaced wholesale by a
    /// log line: the call closing on its own line (up to 0.21.0), then the
    /// hugged bracket (0.21.1).
    static let detachedOldBlocks = [
        detachedCall + "\n            )\n" + detachedLog,
        detachedCall + ")\n" + detachedLog,
    ]
    static let detachedNewBlock =
        "            logger.info(\"Session SSE client disconnected; run %s continues detached\", run_id)"

    enum State: Equatable {
        case patched
        case patchable
        /// A layout none of the anchors match — nothing can be offered.
        case unavailable
    }

    /// The patched source with a count per edit (sites touched).
    struct Outcome: Equatable {
        var source: String
        var contextSites = 0
        var upgradedSites = 0
        var windowSites = 0
        var detachedSites = 0
    }

    /// Any edit still applicable → offer the patch. A gateway too old or
    /// too new to carry a given anchor simply doesn't get that edit; "ours
    /// is in place" reads as patched, a fully foreign layout as unavailable.
    static func state(of src: String) -> State {
        let contextDone = src.contains("\"context_tokens\"")
        if src.contains(fillLineV3) { return .patchable }
        if !contextDone, hasContextAnchor(src) { return .patchable }
        // The window rides on OUR fill line — a native field can't take it.
        if !src.contains("\"context_window\""), src.contains(fillLine) { return .patchable }
        if !src.contains(detachedMarker), detachedOldBlocks.contains(where: { src.contains($0) }) {
            return .patchable
        }
        return contextDone ? .patched : .unavailable
    }

    /// Applies every edit that still applies; nil when nothing changed
    /// (already patched, or no anchor matched — `state(of:)` tells which).
    static func apply(to src: String) -> Outcome? {
        var outcome = Outcome(source: src)
        var work = src
        // v3 → v4 upgrade: swap the fill line's content in place — the
        // window line, inserted after it, stays put.
        while let range = work.range(of: fillLineV3) {
            work.replaceSubrange(range, with: fillLine)
            outcome.upgradedSites += 1
        }
        if !work.contains("\"context_tokens\"") {
            var lines: [String] = []
            for line in work.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                if trimmed == totalTokensEntry + "," {
                    lines.append(line)
                    lines.append(indent + fillLine)
                    outcome.contextSites += 1
                } else if trimmed == totalTokensEntry + "}" {
                    // Packed dict: reopen it so the fill line stands alone.
                    lines.append(indent + totalTokensEntry + ",")
                    lines.append(indent + fillLine)
                    lines.append(indent + "}")
                    outcome.contextSites += 1
                } else {
                    lines.append(line)
                }
            }
            if outcome.contextSites > 0 { work = lines.joined(separator: "\n") }
        }
        // context_window rides on the context_tokens line — this same pass
        // upgrades a gateway that carried only the older one-line patch.
        if work.contains("\"context_tokens\""), !work.contains("\"context_window\"") {
            var lines: [String] = []
            for line in work.components(separatedBy: "\n") {
                lines.append(line)
                if line.trimmingCharacters(in: .whitespaces) == fillLine {
                    lines.append(String(line.prefix { $0 == " " || $0 == "\t" }) + windowLine)
                    outcome.windowSites += 1
                }
            }
            if outcome.windowSites > 0 { work = lines.joined(separator: "\n") }
        }
        // Detached runs: replace the disconnect-interrupt block wholesale.
        if !work.contains(detachedMarker),
           let old = detachedOldBlocks.first(where: { work.contains($0) }) {
            work = work.replacingOccurrences(of: old, with: detachedNewBlock)
            outcome.detachedSites = 1
        }
        guard work != src else { return nil }
        outcome.source = work
        return outcome
    }

    private static func hasContextAnchor(_ src: String) -> Bool {
        src.components(separatedBy: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == totalTokensEntry + "," || trimmed == totalTokensEntry + "}"
        }
    }
}
