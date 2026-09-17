# Hermes action approvals

macOS and Android keep the native `/api/sessions/{id}/chat/stream` route.
Action approvals use Hermes' existing run control API; session history, model
locks, files, context usage and background continuation consent keep their
existing paths. No second queue, database or synchronization service is added.

## Wire contract

Read `GET /v1/runs/{run_id}` for a known, persisted run. `waiting_for_approval`
is busy, including after a disconnected stream or reopening the conversation.
Unknown/network state is not terminal. Stop remains available and waits for a
terminal status or a confirmed missing run.

The Cuate gateway patch v6 adds `cuate_approval_version: 1` and an `approvals`
array to that response. Each item has `request_id`, `run_id`, a redacted
`command`, and `choices: ["once", "deny"]`. The array is read directly from
Hermes' unresolved queue, so multiple requests, timeouts and decisions made by
another client are represented. Clients also accept the upstream singular
`approval` field when present; they never infer an ID from `id`/`approval_id`.

Answer exactly one item with `POST /v1/runs/{run_id}/approval`:

```json
{"request_id": "the-request-on-the-card", "choice": "once"}
```

Refusal uses `"choice": "deny"`. Cuate sends neither `all` nor `resolve_all`
and does not offer a session/permanent tool grant. A valid response echoes the
run, request and choice and reports `resolved: 1`. A stale request cannot select
the next request. The native bridge rejects bulk/missing-ID answers and answers
after Stop. Existing authentication/ownership checks still run.

Cards are scoped to endpoint, session, run and request. The saved run's endpoint
is recorded without rewriting the session/history. The client rechecks the
pending snapshot before POST, disables duplicate taps, and never retries a lost
decision automatically. An unconfirmed decision requires an explicit status
check before another human choice. macOS uses a one-shot body stream and refuses redirects or replacement streams.
Android run control preserves HTTP error codes and uses a one-shot POST body
with redirects and connection retries off.

## Native gateway bridge

The compatibility source is `scripts/hermes/native_approval_patch.py`.
`scripts/hermes/sync_approval_patch.py` generates the identical transform for
the macOS local patcher, remote command, embedded guide, Android asset and VPS
guide. `--check` detects drift. This extends the existing context/catalog/
detached-run installer; application versions are independent of patch v6.

The same generated transform checks the installed `_find_all_skills` signature.
For the recognized retained Gateway call, it removes `include_editorial=True`
only when the installed helper does not accept it. New signatures are preserved,
unknown call shapes are rejected before writes, and repeat application is a no-op.
This restores the shared `/v1/skills` catalog for macOS, Android and CuateWeb;
there is no separate web catalog or server-specific manual edit. Regression tests
live in `scripts/HermesSkillsCatalogContractTest.py` and run with the approval suite.

The bridge enrolls only native turns with an existing run ID. It registers the
Hermes notifier/context, forwards `approval.changed` through the existing native
SSE queue, and uses the existing status, approval and Stop endpoints. The clients
consume changes through their stream and existing recovery/polling paths.

Hermes revision `1ab32b212b` also classifies `api_server` as unattended in its
approval presence gate. The bridge enables human presence only for an API run
with its own live `cuate-native:` notifier, never cron or an unrelated API run.
It does not change `HERMES_SESSION_PLATFORM`, global approval settings, configured
allowlists, hard-deny rules, or the policy for background continuation. Context
and notifier cleanup happen on success and exceptions. Stop wakes waiters with
no permission decision; cleanup never grants an action.

The installer checks native invocation/event anchors, exact-request resolution,
queue snapshot/settle functions, context and redaction APIs. It refuses unknown
layouts and pre-existing upstream/foreign native bridges. The CuateWeb candidate
is not installed over or silently replaced. Backups and Python syntax validation
remain in the existing installer, before source files are changed. Do not force
a rejected layout; review that Hermes version first.

## Verification and deployment

`python3 scripts/test-hermes-approvals.py` runs standalone Swift/Kotlin contracts
and isolated Python bridge tests. No app target is built. Kotlin uses installed
or cached compiler/dependency jars and does not run Gradle or download packages.
Tests include exact allow/deny bodies, multiple/stale requests, connection loss,
reopening, unconfirmed decisions, Stop, timeout/exception cleanup, native presence
isolation, authentication and generated installer parity. Python exercises
queue/wait functions read in memory from an external Hermes `1ab32b212b` checkout;
no Hermes sources or license files are vendored in the test fixtures. Set
`CUATE_HERMES_TEST_SOURCE` to that checkout (default: `~/.hermes/hermes-agent`).
The loader requires it to be outside Cuate and verifies source SHA-256 hashes;
missing or changed sources fail the test with an explanation, without downloads
or changes to the checkout. Swift compiles the actual
control methods against a scripted HTTP boundary, and Kotlin compiles the actual
transport against an interceptor that never opens a socket.

The transform was also checked read-only against that local Hermes revision.
This is not evidence of the version or behavior installed on a VPS. Application
builds, installed UI acceptance and live gateway acceptance are separate checks.
Before deployment, verify the serving source revision, inspect the proposed diff,
and use the existing Cuate patch command only if compatible. After a separately
authorized restart, test a harmless synthetic approval in a new session, its
refusal, reconnection and Stop. Do not alter an existing session or `state.db`.
