# Documents in chat

**Version:** Cuate 5.0 (macOS) · Android 3.0

A user attaches up to three documents to a message in an ordinary chat, asks
questions, compares them, and never learns where the bytes went. One rule:
a document lives exactly as long as its attachment lives in the chat (the
15-day media window, `Config.mediaRetentionDays`) and dies with it.

Cost shape: the model reads a document in full only on the turn it was
attached. Every later turn carries no file; the model gets a `read_document`
tool and opens the document itself, only when the question needs it, and only
the part it asks for. Re-attaching from the chat-files popover (the folder
icon in the header) starts a fresh attach turn.

## 1. File types and limits

| Check | Rule | Where |
|---|---|---|
| Types | pdf, docx, doc, pptx, xlsx, xls, txt, md/markdown, csv, json, rtf (`DocumentPreflight.mimeByExtension`) | picker allowlist + drop |
| Documents per message | 3 | `DocumentPreflight.maxDocumentsPerMessage` |
| Attachments per message (images + documents) | 5 | `ChatWindow.maxPendingAttachments` |
| Single file / all documents in one message | 50 MB each (the OpenAI request limit, enforced for every provider) | `DocumentPreflight` |
| Empty file, password-protected PDF | refused | `DocumentPreflight.check`, `PDFDocument.isLocked` |
| Large PDF | ≥ 100 pages → the chip warns about token cost, sending is allowed | `DocumentPreflight.largePDFPages` |

The pre-flight runs at pick/drop time, before any upload or extraction; a
refusal posts a system line in the chat. The PDF page count is read by
PDFKit at attach time and stored on the attachment.

Locally readable (the text path): pdf, docx, doc, rtf, txt, md, csv, json.
Spreadsheets and slide decks reach a model only where the provider reads
them natively (OpenAI); elsewhere they are announced as "not readable by this
provider".

## 2. Data model

`ChatAttachment` / `SDAttachment` (optional columns, lightweight migration):
`remoteFileID`, `remoteProvider`, `remoteExpiresAt` (the provider-side copy),
`pageCount`, `contentHash` (hex SHA-256 of the bytes, for duplicate
detection). `ocrText` doubles as the cached local extraction (with
`[Page N]` markers for PDFs). `isDocument` derives from the MIME type;
`hasLiveRemoteFile` means uploaded and not past the server expiry.

`ChatStore.liveDocuments`: the conversation's documents whose local file
still exists, newest first, one per file name — the source of the tool
inventory. `ChatStore.documentDuplicate(hash:)` finds the same bytes among the
loaded user messages. Both walk the loaded window only.

`LLMMessage.documents: [LLMDocument]` (filename, MIME, remote id) is
populated for the attach turn on OpenAI only; text fallbacks are folded into
the message text before the provider sees them.

## 3. Attach turn

`ChatService.uploadPendingDocuments` runs inside the reply stream so its
status lines ("Uploading name.pdf…") reach the thinking pill:

- **OpenAI:** each document of the last user message without a live remote
  copy is uploaded once through `OpenAIFilesService` (`POST /v1/files`,
  `purpose=user_data`, `expires_after` anchored on creation = the retention
  window; an API that rejects the expiry gets the upload again without it).
  The id and expiry are persisted on the attachment. The Responses request
  carries `{"type":"input_file","file_id":…,"filename":…}` parts BEFORE the
  text part. An upload failure degrades that document to the text path with a
  system note; the turn always goes out.
- **Every other provider** (Anthropic, Gemini, the chat/completions family,
  Ollama): the locally extracted text rides inline as
  `[Document: name.pdf, 12 pages]` + text, capped at 60,000 characters per
  document and 150,000 per message (`DocumentPreflight.inlineTextCharacterCap*`),
  the truncation stated and pointing at the tool.
- A provider that rejects a file reference (a 400 or a streamed error whose
  message names a file) gets ONE retry of the same turn with the documents as
  text.

Older messages carry a one-line placeholder instead of the file:
`[Attached document: name.pdf, 12 pages — open it with read_document when needed]`
(or "re-attach it to discuss its content" for tool-less models).

## 4. Local extraction (`DocumentTextService`)

Everything runs on the Mac; no cloud OCR for documents, by decision (a user
with only a DeepSeek key must get documents with nothing but that key):

- PDF: per-page `PDFPage.string` joined with `[Page N]` markers; a page
  without a text layer is rendered (~150 dpi, longest side ≤ 2,000 px) and
  recognized with `AppleOCRService` (Vision, on-device), languages = the UI
  language then English. Off the main actor.
- DOCX / DOC / RTF: `NSAttributedString` document readers (main thread).
- TXT / MD / CSV / JSON: UTF-8, then UTF-16, then Latin-1.
- XLSX / PPTX: not extracted locally.

Extraction is lazy: the first attach turn on a non-native provider or the
first `read_document` call computes it once and persists it on the
attachment (the twin of the image OCR cache).

## 5. The `read_document` tool (`DocumentToolService`)

Registered only when `liveDocuments` is non-empty and the model can call
tools (the same gate as web, calendar and Plaud; never in agent chats). The
description carries the inventory (name, pages, size, attach date).

Parameters: `name` (required; case-insensitive, exact → prefix → substring),
`pages` ("3-5" or "7", PDFs; en/em dashes and spaces tolerated, clamped to
the document), `query` (paragraphs containing the text, with page numbers,
first 20 hits). Precedence: pages, then query, then the whole text. Results
are capped at 30,000 characters with `[Truncated — request a page range or a
query]`. Unknown name → the inventory; no readable text → says so; a type not
readable locally → asks for a re-attach where the provider reads it natively.
Not added to `toolDigest`. Status line "Reading name.pdf…".

Prompt hint (with the tool): open a document only when the question needs its
content; prefer a range or a query; ask for a re-attach when charts or images
are needed.

## 6. UI

- Picker (`presentAttachOpenPanel`) offers the document types in ordinary
  chats; drop and pick route through `attachDocumentFile`. Agent chats keep
  taking any file as a path.
- Pending card: `DocumentChipView` (icon by extension, name, pages · size,
  the large-PDF warning); thumbnails for mixed batches; the count line reads
  "N of 5 attachments" once a document is staged.
- Transcript: the same chip in the bubble; click opens the file.
- Chat-files popover (`LocalChatFilesView`, the folder icon in the header):
  document rows show "12 pages · 21 KB · 15 d" (server expiry when the copy
  has one, else the local retention from the attach date) instead of the
  MIME type, and carry a third glyph, a paperclip, next to open/reveal.
  A click stages a fresh row that copies the local file and reuses the
  remote id and cached text, so nothing uploads or extracts twice, and closes
  the popover. (A separate "in memory" row above the composer was tried and
  removed on 2026-09-04: the popover already lists everything the chat holds.)
- Duplicates: attaching a byte-identical file under any name within the same
  conversation and retention window (`contentHash`, computed at attach time)
  inherits the twin's remote id, expiry, page count and cached text —
  logged as `dedup <new> = <twin> …`. Byte-identical only; one conversation
  only (provider-side ids are deleted per conversation).
- Provider capabilities (`ProviderCapabilityHints`): hovering a provider's
  name in Settings → API keys shows what it takes — documents (native on
  OpenAI, extracted text elsewhere), images, tools — and the chat provider
  picker shows the documents line under itself.
- Strings: `panel.doc*`, `panel.attachCountMixed`, `panel.uploadingDoc`,
  `panel.readingDoc`, `panel.docSentAsText`, `panel.memoryDocDays`,
  `chatfiles.attachAgain`, `cap.documents.*`, `cap.images.*`, `cap.tools.*`
  (en/es/ru).

## 7. Lifecycle and deletion

Remote deletion is best-effort and never blocks the UI; the server expiry set
at upload is the backstop.

| Trigger | Where | Action |
|---|---|---|
| New chat | `ChatStore.clearMessages` (loaded rows) + `ChatPersistence.deleteAllMediaFiles` (rows below the window) | delete every provider-side copy of the conversation |
| Preset conversation deleted | `ChatPersistence.deleteConversation` | same |
| 15-day prune | `applyStoreRetention` (every conversation, at launch) | enqueue the delete (the server copy expires the same day; 404 tolerated) |
| Message removed | `ChatStore.removeMessage` → `releaseRemoteFiles` | delete unless another row still references the id (a chip re-attach shares it) |

`RemoteFileJanitor`: a persisted queue (UserDefaults, capped at 200 entries)
of (provider, file id), drained at launch and after each enqueue; an entry
leaves on 2xx or 404, stays on network errors, is dropped on other 4xx.

## 8. Providers

| Provider | Attach turn | Later turns |
|---|---|---|
| OpenAI | native `input_file` (text + page images for vision models) | `read_document` |
| DeepSeek | inline extracted text; thinking mode requires the assistant's `reasoning_content` to be echoed back inside a tool loop, which `OpenAICompatibleProvider` now does (DeepSeek only) | `read_document` |
| OpenRouter | a PDF (≤ 20 MB) rides base64 as a `file` part; the `file-parser` plugin runs the `native` engine on models whose catalog lists "file" input (page images, like the direct providers), else the free `cloudflare-ai` text extraction — never the paid OCR OpenRouter would pick on its own. Word/text files as local text. Every turn that involves a document is sent with `provider.data_collection = "deny"` (only providers that don't collect data; the served provider is logged as `served by …`). | `read_document` |
| Anthropic, Gemini, Mistral, Kimi, Ollama | inline extracted text | `read_document` where the model can call tools |
| Agent roles (Hermes) | untouched: files travel as paths | the agent's own tools |

Native document blocks for Anthropic and Gemini, local extraction for xlsx
and pptx, and cloud OCR for documents are not implemented.

OpenRouter and privacy: OpenRouter's public endpoint listing carries no data
policy per provider, so the app does not try to display one; the request-level
`data_collection: "deny"` is the enforced guarantee for document turns, and
the account-level "allow routing to providers that may train on your data"
setting still governs plain chat. Models whose catalog lists file input get a
"Documents" chip in Settings → OpenRouter.

## 9. Costs and diagnostics

Spend accounting is unchanged: document tokens arrive inside the turn's
usage and are priced like any input (cached reads in the cache columns);
uploads are free and get no ledger record.

`Diagnostics` category `files`: `upload id= bytes= pages= expires=`,
`upload failed`, `extract <name> chars=`, `attach turn provider= native=
inline= inlineChars=`, `attach turn rejected … retrying with local text`,
`tool.read_document name= pages= query=`, `janitor enqueue`, `delete id=
status=`, `retention sweep`.

## 10. Tests

`scripts/DocumentContractTest.swift` compiles `DocumentPreflight` and
`DocumentTextQuery` standalone (run by `scripts/test-attach-note.sh`):
the allowlist, size and count rules, empty and encrypted files, page-marker
round trips, page-range parsing and clamping, search hits with page numbers,
rendering and the cap.

## 11. Known limitations

- The tool inventory, the chat-files popover and duplicate detection see
  only the loaded window of the conversation (§2), so a document older than
  the window is invisible to them while its placeholder still names the tool.
- Scanned PDFs are recognized page by page without a page cap or
  cancellation; a long scan keeps the attach turn in "Reading…" for a while.
- A continuation round (`<continue/>`) is a new request whose last user turn
  is the hidden "Continue.", so the document rides as a placeholder from the
  second round of the same reply.
- `.doc`, `.rtf` and `.xls` are accepted by the pre-flight but were not
  verified against OpenAI's native reader; a rejection takes the text retry.

## 12. Android

The same design, ported to `android/` on 2026-09-04 for the same two providers
(OpenAI native, DeepSeek as text; every other provider gets the text path):

- Extraction (`chat/DocumentTextService.kt`): the PDF text layer through
  PdfBox-Android (`com.tom-roush:pdfbox-android`, Apache 2.0, initialized in
  `App.onCreate`), Word 2007+ from the docx zip's `word/document.xml`, plain
  text as is. No OCR on the phone (ML Kit has no Cyrillic): a scanned page
  yields nothing, and the tool says so. Legacy `.doc`, `.rtf`, spreadsheets and
  slide decks reach a model only where OpenAI reads them natively.
- Pre-flight, dedup, the `read_document` tool, the attach-turn regimes, the
  inline budgets, the OpenAI upload with expiry and the deletion queue are
  straight ports (`core/DocumentPreflight.kt`, `core/DocumentTextQuery.kt`,
  `chat/DocumentToolService.kt`, `providers/OpenAIFilesService.kt`,
  `chat/RemoteFileJanitor.kt`); the DeepSeek `reasoning_content` round-trip
  lives in `OpenAICompatibleProvider.kt`.
- Storage: Room schema version 5 (`AttachmentEntity.pageCount`,
  `contentHash`, `remoteFileId`, `remoteProvider`, `remoteExpiresAt`,
  migration 4→5). Retention stays the Android rule: files older than 15 days
  are deleted at launch by modification time (`App.sweepExpiredMedia`); the
  rows survive without payload, and the provider-side copy expires on the
  same clock. Deleting or clearing a conversation releases its remote ids
  through the janitor.
- UI: documents come through the existing attach sheet ("File"); the pending
  and transcript pills show pages and size; the chat menu of an ordinary chat
  gets "Documents of this chat" — a dialog with pages, size, days left and an
  "attach again" glyph. Settings show the documents line under the provider
  picker and in each key row's description.
- Tests: `DocumentContractTest.kt` (JUnit) mirrors the Swift contract test.
