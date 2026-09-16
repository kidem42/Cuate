# Ollama voice recognition (macOS)

## Setup and behavior

Enable local models in General, connect Ollama in Local models, and install a
model with audio input and text output. In Voice, choose Ollama and a model from
the installed audio-model picker. Refresh retrieves current capabilities. Models
with unknown capabilities or Ollama cloud routing are excluded. The model may
load into memory on the first recognition request.

This selection serves both voice messages and system dictation. It produces
transcript text, which the existing chat/dictation pipeline consumes. It does not
enable arbitrary audio attachments, spoken model replies or real-time audio
conversation. Deepgram's live streaming remains a separate mode.

Audio goes to the configured Ollama endpoint, which may be another machine if
the user configured one. Ollama recognition never automatically switches to a
cloud transcription provider. The chat model, dictation cleanup and translation
have independent settings and can still use cloud providers for the text.

Existing provider selections remain unchanged. A first catalog refresh can choose
an initial local audio model but does not select Ollama as the voice provider.
A missing previously selected model stays missing until explicitly replaced.
Each recording/session captures its STT settings. Changing the endpoint or disabling
local models invalidates outstanding local results. Manual Retry starts a new
attempt with the settings currently selected by the user.

## Architecture and dependencies

| Concern | Owner and contract |
| --- | --- |
| Installed model metadata | `OllamaAdminService.show`, `AppSettings.ollamaCatalog`; all native capability strings retained, cloud routing decoded |
| Voice availability | `AppSettings.ollamaTranscriptionModels` and `transcriptionAvailable`; microphone UI shares the same decision |
| Settings | `STTProviderID`, existing `sttProvider`/`sttModels` persistence, `OllamaVoiceSettingsView`; no chat-model setting reused |
| Request selection | `TranscriptionService.Selection`; local path precedes cloud-key lookup and fallback |
| Audio conversion | `OllamaAudioReader`; AVAudioFile/AVAudioConverter, bounded buffers, PCM16 mono 16 kHz WAV, preserves source files |
| Long recordings | At most 30 seconds per request, quiet-point cuts, sequential text concatenation; no audio overlap or omission |
| Model request | `OllamaTranscriptionWire`; OpenAI-compatible audio content, explicit transcription instructions, no tools/history, independent 4096-token ceiling |
| Inference scheduling | `OllamaTranscriptionQueue`; one STT job at a time, cancellation propagated through an explicit detached worker |
| Dictation lifecycle | Existing capture, pause rotation, cleanup/insertion chain; captured provider and session-generation checks, tracked cancellable STT tasks |
| Chat/Hermes | Existing voice-send path receives text; conversation ownership and agent courier remain unchanged |
| Storage and spend | Original voice recordings retain the existing lifecycle; conversion writes no extra media; STT minutes recorded at zero cost |

The queue serializes recognition jobs, not independent chat or cleanup requests.
Using several local models can therefore still increase memory use or model-load
latency. Splitting continuous speech near the quietest available point preserves
samples, but recognition quality at a boundary still depends on the model.

## Capability badges

The console displays text generation, vision, tools, reasoning, audio input,
embeddings, infill and image generation when Ollama reports them. Unknown future
capabilities retain their reported names. Tooltips explain the feature and state
when Cuate does not use it. Ollama cloud models get a separate cloud badge;
missing metadata is shown as unknown, rather than as absence of capabilities.

## Source receipts

Protocol and format decisions were checked against official Ollama tag v0.34.0:

- [openai/openai.go](https://github.com/ollama/ollama/blob/v0.34.0/openai/openai.go):
  `FromChatRequest` accepts `input_audio`; `thinkFromReasoningEffort` maps `none`
  to false. `FromTranscriptionRequest` supplies the transcription-only contract.
- [integration/audio_test.go](https://github.com/ollama/ollama/blob/v0.34.0/integration/audio_test.go):
  actual audio chat/transcription request examples and WAV test media.
- [x/mlxrunner/model/audio/audio.go](https://github.com/ollama/ollama/blob/v0.34.0/x/mlxrunner/model/audio/audio.go):
  WAV-only container decoding, mono downmix and 600-second duration limit.
- [types/model/capability.go](https://github.com/ollama/ollama/blob/v0.34.0/types/model/capability.go):
  native capability names.
- [Apple TN3136](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions):
  sample-rate conversion requires the input-block converter API and explicit
  handling of converter output states.

## Verification

`scripts/OllamaAudioContractTest.swift` exercises real synthetic WAV/AAC conversion
at 8/16/44.1/48 kHz, mono/stereo input, multi-chunk sample preservation, empty/corrupt
input, request/response contracts and queue cancellation. AAC encoding requires
access to macOS system codecs. `scripts/OllamaTranscriptionIntegrationContractTest.py`
compiles the real service files with extracted provider declarations and mock
HTTP/key/settings/spend dependencies: routing checks, captured settings, local
failures without cloud fallback, endpoint changes and unchanged cloud dispatch.
Both are registered in the contract runner. They do not build or launch Cuate.

These contracts do not certify actual model recognition quality, cold-load latency,
live server compatibility, microphone capture, UI layout or end-to-end dictation.
Those require an authorized application build and human testing with the installed
Ollama model. Android does not yet include this local voice path.
