// Contract test for the Hermes gateway patch (HermesGatewayPatch.swift): the
// three anchored edits to gateway/platforms/api_server.py must be recognized,
// applied once, left alone afterwards and refused on a foreign layout —
// against the source layouts of Hermes 0.20.x–0.21.0 (one usage entry per
// line, the disconnect call closing on its own line) and 0.21.1 (packed
// usage dict, hugged bracket). Compiled standalone by scripts/test-attach-note.sh.
//
// With file paths as arguments it patches those real api_server.py files in
// memory instead, prints the counts and writes <path>.swift-patched next to
// each — for diffing against the Python paste-block's output.
import Foundation



typealias P = HermesGatewayPatch

@main
struct HermesGatewayPatchContractTest {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ what: String) {
            print((condition ? "  ok   " : "  FAIL ") + what)
            if !condition { failures += 1 }
        }

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 4, arguments[0] == "--catalog" {
            do {
                let inventory = try String(contentsOfFile: arguments[1], encoding: .utf8)
                let models = try String(contentsOfFile: arguments[2], encoding: .utf8)
                let pricing = try String(contentsOfFile: arguments[3], encoding: .utf8)
                let result = P.repairCatalog(inventory: inventory, models: models, pricing: pricing) ?? inventory
                try result.write(toFile: arguments[1] + ".swift-patched", atomically: true, encoding: .utf8)
            } catch {
                print("catalog fixture failed: \(error)")
                exit(1)
            }
            return
        }
        if !arguments.isEmpty {
            for path in arguments {
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    check(false, "unreadable: \(path)")
                    continue
                }
                let state = P.state(of: src)
                guard let outcome = P.apply(to: src) else {
                    check(state == .patched, "\(path): nothing to apply, state \(state)")
                    continue
                }
                print("  \(path): state \(state) -> context \(outcome.contextSites) upgraded \(outcome.upgradedSites) window \(outcome.windowSites) detached \(outcome.detachedSites)")
                check(P.state(of: outcome.source) == .patched, "\(path): patched afterwards")
                check(P.apply(to: outcome.source) == nil, "\(path): idempotent")
                try? outcome.source.write(toFile: path + ".swift-patched", atomically: true, encoding: .utf8)
            }
            exit(failures == 0 ? 0 : 1)
        }

        // MARK: - Hermes up to 0.21.0: one entry per line, two usage dicts (0.20.x)

        let legacy = """
                            result = agent.run_conversation(user_message=user_message)
                            usage = {
                                "input_tokens": getattr(agent, "session_prompt_tokens", 0) or 0,
                                "output_tokens": getattr(agent, "session_completion_tokens", 0) or 0,
                                "total_tokens": getattr(agent, "session_total_tokens", 0) or 0,
                            }
                                u = {
                                    "input_tokens": getattr(agent, "session_prompt_tokens", 0) or 0,
                                    "output_tokens": getattr(agent, "session_completion_tokens", 0) or 0,
                                    "total_tokens": getattr(agent, "session_total_tokens", 0) or 0,
                                }
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError):
                    await self._drain_session_stream_task_on_disconnect(
                        run_id, task, interrupt_message="SSE client disconnected", shield_wait=False
                    )
                    logger.info("Session SSE client disconnected; interrupted live run %s", run_id)
                except asyncio.CancelledError:
                    await self._drain_session_stream_task_on_disconnect(
                        run_id, task, interrupt_message="SSE task cancelled", shield_wait=True
                    )
                    logger.info("Session SSE task cancelled; drained live run %s", run_id)
                    raise

        """

        let legacyExpected = """
                            result = agent.run_conversation(user_message=user_message)
                            usage = {
                                "input_tokens": getattr(agent, "session_prompt_tokens", 0) or 0,
                                "output_tokens": getattr(agent, "session_completion_tokens", 0) or 0,
                                "total_tokens": getattr(agent, "session_total_tokens", 0) or 0,
                                \(P.fillLine)
                                \(P.windowLine)
                            }
                                u = {
                                    "input_tokens": getattr(agent, "session_prompt_tokens", 0) or 0,
                                    "output_tokens": getattr(agent, "session_completion_tokens", 0) or 0,
                                    "total_tokens": getattr(agent, "session_total_tokens", 0) or 0,
                                    \(P.fillLine)
                                    \(P.windowLine)
                                }
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError):
                    logger.info("Session SSE client disconnected; run %s continues detached", run_id)
                except asyncio.CancelledError:
                    await self._drain_session_stream_task_on_disconnect(
                        run_id, task, interrupt_message="SSE task cancelled", shield_wait=True
                    )
                    logger.info("Session SSE task cancelled; drained live run %s", run_id)
                    raise

        """

        print("legacy layout (Hermes <= 0.21.0)")
        check(P.state(of: legacy) == .patchable, "stock is patchable")
        if let outcome = P.apply(to: legacy) {
            check(outcome.contextSites == 2 && outcome.upgradedSites == 0, "context fill lands at both usage dicts")
            check(outcome.windowSites == 2, "context window rides on both fill lines")
            check(outcome.detachedSites == 1, "disconnect block replaced")
            check(outcome.source == legacyExpected, "output is exactly the expected file")
            check(P.state(of: outcome.source) == .patched, "patched afterwards")
            check(P.apply(to: outcome.source) == nil, "idempotent")
        } else {
            check(false, "apply returned nothing")
        }

        // A gateway carrying the older one-line patch (v3 fill, no window, stock
        // disconnect): the fill upgrades in place, the rest lands as usual.
        let legacyV3 = legacy
            .replacingOccurrences(of: "\(P.totalTokensEntry),\n                    }",
                                  with: "\(P.totalTokensEntry),\n                        \(P.fillLineV3)\n                    }")
            .replacingOccurrences(of: "\(P.totalTokensEntry),\n                        }",
                                  with: "\(P.totalTokensEntry),\n                            \(P.fillLineV3)\n                        }")
        print("legacy layout carrying the v3 fill line")
        check(legacyV3 != legacy, "fixture carries the v3 line")
        check(P.state(of: legacyV3) == .patchable, "v3 is patchable (upgrade)")
        if let outcome = P.apply(to: legacyV3) {
            check(outcome.upgradedSites == 2 && outcome.contextSites == 0, "both v3 lines upgraded, none inserted")
            check(outcome.windowSites == 2 && outcome.detachedSites == 1, "window and detached edits still land")
            check(outcome.source == legacyExpected, "same output as a stock file")
        } else {
            check(false, "apply returned nothing")
        }

        // MARK: - Hermes 0.21.1: packed usage dict, hugged bracket

        let packed = """
                usage = {"input_tokens": getattr(agent, "session_prompt_tokens", 0) or 0,
                         "output_tokens": getattr(agent, "session_completion_tokens", 0) or 0,
                         "total_tokens": getattr(agent, "session_total_tokens", 0) or 0}
                # Effective session id lets callers track compression-triggered rotations.
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError):
                    await self._drain_session_stream_task_on_disconnect(
                        run_id, task, interrupt_message="SSE client disconnected", shield_wait=False)
                    logger.info("Session SSE client disconnected; interrupted live run %s", run_id)
                except asyncio.CancelledError:
                    await self._drain_session_stream_task_on_disconnect(
                        run_id, task, interrupt_message="SSE task cancelled", shield_wait=True)
                    logger.info("Session SSE task cancelled; drained live run %s", run_id)
                    raise

        """

        let packedExpected = """
                usage = {"input_tokens": getattr(agent, "session_prompt_tokens", 0) or 0,
                         "output_tokens": getattr(agent, "session_completion_tokens", 0) or 0,
                         "total_tokens": getattr(agent, "session_total_tokens", 0) or 0,
                         \(P.fillLine)
                         \(P.windowLine)
                         }
                # Effective session id lets callers track compression-triggered rotations.
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError):
                    logger.info("Session SSE client disconnected; run %s continues detached", run_id)
                except asyncio.CancelledError:
                    await self._drain_session_stream_task_on_disconnect(
                        run_id, task, interrupt_message="SSE task cancelled", shield_wait=True)
                    logger.info("Session SSE task cancelled; drained live run %s", run_id)
                    raise

        """

        print("packed layout (Hermes 0.21.1)")
        check(P.state(of: packed) == .patchable, "stock is patchable")
        if let outcome = P.apply(to: packed) {
            check(outcome.contextSites == 1 && outcome.upgradedSites == 0, "context fill lands once")
            check(outcome.windowSites == 1, "context window rides on the fill line")
            check(outcome.detachedSites == 1, "hugged disconnect block replaced")
            check(outcome.source == packedExpected, "output is exactly the expected file")
            check(P.state(of: outcome.source) == .patched, "patched afterwards")
            check(P.apply(to: outcome.source) == nil, "idempotent")
        } else {
            check(false, "apply returned nothing")
        }

        // MARK: - Nothing to offer

        print("foreign and native layouts")
        let foreign = "        usage = self._usage(agent)\n        except OSError:\n            pass\n"
        check(P.state(of: foreign) == .unavailable, "unknown layout is unavailable")
        check(P.apply(to: foreign) == nil, "unknown layout is left untouched")

        let native = packed.replacingOccurrences(
            of: "\(P.totalTokensEntry)}",
            with: "\(P.totalTokensEntry),\n                 \"context_tokens\": agent.context_fill}")
        check(P.state(of: native) == .patchable, "a native fill with the stock disconnect block still offers the detached edit")
        if let outcome = P.apply(to: native) {
            check(outcome.contextSites == 0 && outcome.windowSites == 0, "a native fill takes neither our fill nor the window")
            check(outcome.detachedSites == 1, "the detached edit alone lands")
            check(P.state(of: outcome.source) == .patched, "native fill + detached reads as patched")
        } else {
            check(false, "apply returned nothing")
        }

        print(failures == 0 ? "gateway patch: all green" : "gateway patch: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
