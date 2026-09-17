# Hermes transcript presentation: desktop / web audit

Date: 2026-09-17. Source review of the current local Cuate and CuateWeb checkouts.
This is a presentation-path audit, not a complete repository or installed-server
audit. Both checkouts contain uncommitted work. Desktop HEAD: `9e7be63`;
CuateWeb HEAD: `9e83b1054`. At the time of this audit, deployed web version was `.5` and subsequent
tool-grouping changes were local only. This section records that historical
baseline, not the current release state. See the release notes for shipped fixes.
A source-level finding is not a passed browser test.

## Finding

Desktop treats the Hermes transcript as an event history from which it constructs
human-visible replies, step journals and service cards. The web adapter initially
mapped individual transcript records to individual chat messages. Correcting the
shape of one tool result fixes raw JSON and false cancellation, but cannot by
itself provide the desktop's transcript structure.

The missing work is a coherent presentation projection, shared by restored
history and live reconciliation. Keep Hermes history, native session IDs,
Gateway routes, model/context accounting and existing consent contracts intact.
Do not add a second history store or implement a new chat UI.

## Verified source comparison

Desktop paths below are relative to `Cuate/`. Web paths are relative to the
CuateWeb checkout.

| Area | Desktop source and actual behavior | Web source and gap |
|---|---|---|
| Visible rows | `Addons/HermesAddon/HermesMirrorSync.swift`, `contentRows`: only user/assistant content enters ordinary bubbles; empty shells and ordinary tool rows do not. Tool rows can yield extracted steer messages. | `packages/data-provider/src/hermes/sessionView.ts` maps rows directly, with tool-result joining added in .5. No general classification pass. |
| Reply grouping | `HermesMirrorSync.merge`: consecutive content-bearing assistant rows join with blank lines, retaining the head identity and combining their step summaries. | One message shell per assistant row. Local follow-up merges tool-only runs but does **not** yet reproduce the full reply/journal model. |
| Restored steps | `HermesMirrorSync.stepSummaries`: tool results accumulate until a content-bearing assistant row, then attach to that reply. `Views/MessageRow.swift` places the journal under the reply. | .5 uses stock tool parts, but separate assistant shells prevent stock grouping across rows. `ContentParts.tsx` / `utils/groupToolCalls.ts` group only parts within one message. |
| Compact journal | `AgentGateway/Core/AgentGatewayViews.swift`, `AgentStepJournalView`: initially closed `Steps · N`; second-level disclosure for each step. | Reuse `ToolCallGroup.tsx` and stock tool details. No new per-step message shells or desktop-style parallel chat view. Preserve user text between groups. |
| Step details | `HermesStepDetails.swift`: command arguments matched by call ID; transcript fetched lazily, 20-second session cache; output limited to 4,000 chars in this view; exact paths retained. | Results are already in fetched web history. Use stock lazy disclosure rendering, preserve downloadable/copyable raw details and exact IDs. Do not add redundant per-step requests. |
| Live execution | `AgentChatService.swift` / `AgentStepJournal.swift` accumulate live step updates separately from reply text. `HermesLiveTurn.swift` can reconstruct pending steps from calls/results in a transcript tail. `_thinking` is excluded from live tool steps. | `client/src/components/Hermes/engine.ts` tracks a single current `tool` string, clearing it on completion. No accumulated live step journal. History projection and transient `.live` message in `NativeChat.tsx` need coordinated stable identity/reconciliation. |
| Delegation notices | `HermesServiceNotice.swift` detects batch/single async delegation markers; `HermesServiceNoticeView.swift` renders an assistant-side collapsed card, task disclosures, success/error counts and duration. | `hermesServiceNotice` exists in `protocol.ts` for continuation detection but is not used by message projection. Notices therefore appear as user bubbles. |
| Process notices | Same native parser recognizes both `[Background process` and `[IMPORTANT: Background process`, exposes exit code and output in a service card. | Same presentation gap. Reuse stock background-result disclosure semantics with a native adapter. |
| Existing web service UI | Native service cards are a separate view from ordinary assistant prose. | `Content/Parts/wakeup.ts` and `Content/Wakeup.tsx` already implement stock service-result UI, but recognize LibreChat's own wakeup envelopes, not Hermes markers. Adapt the input contract; do not fabricate LibreChat durable child-thread IDs or enable irrelevant thread-navigation actions. |
| Context compression | `HermesCompaction.swift`: hides synthetic summary-only rows, both exact continuation sentinels and preserved-TODO injection; retains real user text after the summary end marker or before the merged-summary delimiter. | No compaction classifier in the current web projection. Hidden metadata and actual user content must be distinguished before grouping. |
| Formatting briefing | `HermesBriefing.swift` strips only a complete leading tagged frame; `HermesAgentSession.swift` sends the frame per session and marks acceptance. | `briefing.ts` and engine acceptance tracking implement the same presentation-marker approach. Retain cross-client detection; do not remove arbitrary tags inside normal text. |
| Mid-turn steer | `HermesSteer.swift`: `<cuate-addendum>` framing; extracts one or more `[OUT-OF-BAND USER MESSAGE ...]` blocks from tool results; unframes pending deliveries. `contentRows` restores them as real user messages. | `sendHermesSteer` uses native run/session routes; `hermesUnframe` handles pending text. No extraction of embedded steer messages in history projection and no equivalent framing in the reviewed send path. Must retain the web's explicit-steer rule: never silently turn a stale steer into a new ordinary send. |
| Background continuation | `HermesContinuation.swift`: consent applies to the exact unconsumed notice suffix, endpoint and session; no arbitrary expiry. Separate from tool approval. | Engine has delivery IDs, scoped state and continuation tests. Preserve raw rows for this logic when changing their display; hiding or reclassifying a notice must not grant consent or lose the pending delivery. |
| Attachments | `AgentAttachNote.swift` and `MessageRow`: host-file notes become attachment pills, not raw injected path paragraphs. | Sending builds native attachment notes in `NativeChat.prepareSubmission`. `hermesSplitAttachments` / `hermesMessagePaths` exist but are not wired into `sessionView`. Restored file presentation is incomplete. |
| File links | `HermesFileCourier.swift`, `AgentFileChips.swift` and native path helpers expose exact host paths, preview/cache/download and file chips. | `.4` added authorized native file loaders, Markdown/HTML/image previews and sandbox URL preservation. Relative path inference is intentionally absent. Restored attachment chips and broader file discovery need adaptation; do not copy native Finder actions into web. |
| Ordinary Markdown | `Views/MarkdownBlocksView.swift`: headings, nested lists, checklists, quotes, code, separators, tables and images. | Stock `markdownConfig.ts`: GFM plus highlighting, math/KaTeX and shared components. Use that pipeline; do not port a second Markdown parser. Test streamed and restored content. |
| Document fences | Native parser recognizes `html`, complete HTML in unlabelled fences, `markdown` **and `md`**, and Mermaid. Artifact cards distinguish incomplete streaming from terminated/truncated output. | Native web fence routing currently checks `html` and `markdown`; `md` and unlabelled complete-HTML behavior differ. Streaming/truncated-document parity needs explicit tests. |
| Tables / copying | Native table view plus `copyTableToPasteboard` / `clipboardHTML` support rendered tables and rich clipboard output. | Stock table rendering exists. Rich table copy/export equivalence has not been verified. Do not claim parity from a table screenshot alone. |
| Long code / logs | Native code view folds above 300 lines, handles terminal/diff/ANSI presentation and has explicit command execution affordances. | Stock `Messages/Content/CodeBlock.tsx` is used. Large-log, diff/ANSI and copy/save parity has not been established. Native command execution is a capability decision, not an automatic formatting port; native backend currently disables unrelated web code execution. |

## Desktop behavior that must not be copied blindly

- `AgentStepJournal.record` resolves live completion by the last running tool of
  the same name. Preserve exact call IDs wherever the wire supplies them; parallel
  same-name calls must not exchange outputs.
- `HermesMirrorSync.stepSummaries` labels tool results `completed` without deriving
  failure from their payload. Its pending list does not explicitly reset at user
  rows, whereas `HermesStepDetails` does. The web contract must define matching
  boundaries and preserve real errors instead of copying that discrepancy.
- `HermesServiceNotice.parseBatch` retains recognized metadata/tasks/error blocks
  but does not preserve all unknown lines. The web adaptation should keep a raw
  fallback available when parsing is incomplete; content must not disappear.
- Desktop local-cache containment healing is tied to its mirror persistence.
  Do not port that heuristic into the web projection as text-based deduplication:
  repeated legitimate messages must survive and no second mirror store is needed.

## Implementation contract for the next cohesive change

1. Classify native records before presentation: real user text, assistant prose,
   tool call/result, service delivery, compression metadata, attachment note,
   embedded steer. Retain original record IDs and raw content outside the view.
2. Build stable reply/activity units. Accumulate calls/results in one expandable
   activity block instead of separate message shells. Preserve prose order and
   visible final replies; do not hide commentary by labelling it as reasoning.
   A real user message, recovered steer or service delivery is an explicit boundary.
3. Reuse stock message/ToolCallGroup/Wakeup/file/Markdown components with typed
   native inputs. Do not synthesize another provider's thread/run identities.
4. Drive restored history and live updates through compatible identities. A poll,
   reconnect, final-result arrival or model text segment must not duplicate rows,
   reset expanded details or change the reader's scroll position.
5. Keep display normalization separate from continuation, approval, Stop, steer,
   context accounting and model selection. No automatic POST retry or new consent.
6. Finish fence/file/attachment differences through existing renderers and document
   capability limits explicitly. No server patch is required by the findings above.

## Required acceptance matrix

Use independently authored fixtures, not copied Hermes source files.

- Consecutive 1/2/50 tools: one compact activity block, stable identity as it grows;
  expand group, expand one result, copy details; no repeated Hermes headers.
- Parallel same-name calls, out-of-order/empty/error results, duplicate page rows,
  missing call/result in truncated history, cancellation while a tool is pending.
- Assistant commentary before/between tools and final prose; multiple user turns;
  images and file links between phases; identical legitimate messages stay distinct.
- Batch/single delegation and process reports, failures, unknown/malformed report
  bodies; raw fallback, correct side of chat, no execution of report instructions.
- Compression variants, summary glued to real user text, exact sentinels/TODO
  injection, literal quoted markers and incomplete briefing/addendum frames.
- Multiple embedded steers, accepted-but-undelivered steer, another client's steer;
  reconstruct user text exactly once without altering the current task automatically.
- Tail service notice retains independent continuation consent; tool approvals
  remain tied to request ID and known run. Normalized view does not hide controls.
- Markdown tables/lists/code/math, html/md/markdown/Mermaid fences, incomplete
  streams, preview/download/copy, real attachments and long logs.
- Stream, history refresh, reconnect, page reload and reopening the same session:
  same visible meaning and activity counts, no duplicated live tail, deliberate
  upward scrolling respected. Measure large-history cost without quadratic scans.

## Audit-time verification snapshot

`.5` is deployed with exact tool-result joining, but not cross-row grouping.
The local follow-up groups only consecutive tool-only rows; 20 projection/briefing
contracts and lint passed. It is **not** the complete adaptation described above
and should not be advertised as desktop parity. New service/compaction/steer
presentation changes have not been implemented during this audit.

No application build, browser launch, server change or deployment was performed
for this audit. Prior Lighthouse attempts were blocked by automatic approval
review; that is not evidence of a UI regression or a passed acceptance test.

## Web adaptation implemented after the audit

The `.6` web source now projects consecutive assistant records into one reply,
with ordered prose and a single collapsed stock ToolCallGroup below it. Real user
turns, recovered steers and service deliveries remain explicit boundaries. Exact
call IDs join results; missing results are labelled unknown instead of cancelled.
Display normalization filters compaction metadata, retains merged human text and
attachments, and restores complete embedded steer envelopes as user messages.
Batch, single-delegation and process reports use assistant-side stock Wakeup cards
with collapsed per-task details. Unrecognized report text remains available.
Consent continues to use raw history independently of this view projection.

The shared Markdown pipeline covers tables, lists, checkboxes, quotes, math,
code and Mermaid. Native `md` fences and unlabelled HTML documents reuse artifact
previews; the original unlabelled HTML classification is retained before syntax
highlighting guesses a language. Attachment notes reuse authenticated file links.
No Hermes patch or history migration is part of this presentation change.

Local coverage includes pure projection/briefing contracts, component/engine tests
and isolated browser cases with independently authored API responses: 20 tools in
one group, refresh/reload, preserved expansion, service-report task disclosure,
compaction filtering and recovered steer roles. These cases do not establish every
entry of the larger acceptance matrix above. In particular, real Gateway streams,
large real attachments, desktop-specific file actions and every long-log variant
require separate installed-system verification.

### Adaptation verification, 2026-09-17

Version `v0.8.8-rc4-cuate.6` passed 27 projection/briefing contracts, 127 focused
client/engine/component tests, TypeScript and changed-source lint. Three isolated
browser scenarios passed, including the Lighthouse budgets. The Docker image was
built on the deployment host and the running version and public HTTPS health were
verified after replacement. A read-only check through the installed Gateway
projected five existing histories without mutating their input: the two tool-heavy
samples went from 193/177 source records to 33/44 display rows, retaining 90/104
tool parts respectively. This is real-data projection evidence, not a claim that
the authenticated live browser's appearance or a fresh model run was verified.
A targeted second read-only sample covered four more existing histories and found
four service deliveries in a 490-record history. All four projected to the
assistant side; that history retained 219 tool parts in 165 display rows. Nine
real histories were checked in total. Live visual expansion remains a separate
manual acceptance check.
