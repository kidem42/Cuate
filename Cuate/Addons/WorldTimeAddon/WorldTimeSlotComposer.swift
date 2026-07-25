import SwiftUI
import AVFoundation

/// The slot composer: opens right where the user clicked a half-hour slot.
/// The microphone is live immediately ("say what to plan"), with a toggle to
/// type instead; the description goes through `WorldTimeSlotService`'s quiet
/// mini-call and the confirmation shows in place. No chat history involved.
struct WorldTimeSlotComposer: View {
    let slot: Date
    let rowZoneID: String
    let homeZoneID: String
    var onClose: () -> Void

    @ObservedObject private var settings = WorldTimeSettings.shared
    @StateObject private var recorder = AudioRecorder()

    private enum Phase: Equatable {
        case input
        case transcribing
        case creating(String)
        case done(String)
        case failed(String)
    }
    @State private var phase: Phase = .input
    @State private var voiceMode = true
    @State private var text = ""
    @State private var pulse = false
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pinHeader
            Divider()
            content
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            voiceMode = settings.slotVoiceInput
            if voiceMode {
                Task { @MainActor in
                    if await recorder.startRecording() {
                        pulse = true
                    } else {
                        switchToText() // no mic permission → type instead
                    }
                }
            } else {
                textFocused = true
            }
        }
        .onDisappear { recorder.cancelRecording() }
    }

    // MARK: - Pin header (the slot, pinned like an attachment)

    private var pinHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(slotLine(zoneID: homeZoneID))
                    .font(.system(size: 12, weight: .semibold))
                if rowZoneID != homeZoneID {
                    Text("\(slotTime(zoneID: rowZoneID)) · \(WorldTimeCatalog.city(for: rowZoneID).name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .input:
            if voiceMode { voiceInput } else { textInput }
        case .transcribing:
            statusLine(icon: nil, text: WTL("wt.slot.transcribing"))
        case .creating(let status):
            statusLine(icon: nil, text: status)
        case .done(let message):
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(WTL("wt.slot.retryText")) {
                    switchToText()
                    phase = .input
                }
                .font(.caption)
            }
        }
    }

    private func statusLine(icon: String?, text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Voice input

    private var voiceInput: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .scaleEffect(pulse ? 1.25 : 0.95)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                Image(systemName: "mic.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
            }
            Text(WTL("wt.slot.speak"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                switchToText()
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(.borderless)
            .help(WTL("wt.slot.typeInstead"))
            Button {
                finishVoice()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help(WTL("wt.slot.doneSpeaking"))
        }
    }

    private func finishVoice() {
        recorder.stopRecording()
        phase = .transcribing
        Task { @MainActor in
            // Give AVAudioRecorder a beat to finalize the file.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let url = recorder.recordingURL else {
                phase = .failed(WTL("wt.slot.err.noAudio"))
                return
            }
            do {
                let transcript = try await TranscriptionService.transcribe(audioURL: url)
                recorder.deleteRecording() // one-shot: nothing references it
                text = transcript
                guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
                    phase = .failed(WTL("wt.slot.err.noAudio"))
                    return
                }
                await send(transcript)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Text input

    private var textInput: some View {
        HStack(spacing: 8) {
            // The way back to voice — switching to text must not be a trap.
            Button {
                switchToVoice()
            } label: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(WTL("wt.slot.speakInstead"))
            TextField(WTL("wt.slot.placeholder"), text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .onSubmit { submitText() }
            Button {
                submitText()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.borderless)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submitText() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in await send(trimmed) }
    }

    private func switchToText() {
        recorder.cancelRecording()
        voiceMode = false
        settings.slotVoiceInput = false // remember the preference
        textFocused = true
    }

    private func switchToVoice() {
        voiceMode = true
        settings.slotVoiceInput = true
        Task { @MainActor in
            if await recorder.startRecording() {
                pulse = true
            } else {
                switchToText() // mic unavailable → back to typing
            }
        }
    }

    // MARK: - Direct creation (no LLM — the slot is the time, the words are
    // the title; EventKit and the account's own sync do the rest)

    @MainActor
    private func send(_ description: String) async {
        phase = .creating(WTL("wt.slot.creating"))
        do {
            let confirmation = try WorldTimeSlotService.create(
                title: description,
                slot: slot,
                homeZoneID: homeZoneID
            )
            phase = .done(confirmation)
            // Linger long enough to read the confirmation, then close.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onClose()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Formatting

    private func slotLine(zoneID: String) -> String {
        guard let zone = TimeZone(identifier: zoneID) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.currentLanguage.rawValue)
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(settings.uses24Hour ? "EEEdMMM HHmm" : "EEEdMMM hmm a")
        return formatter.string(from: slot)
    }

    private func slotTime(zoneID: String) -> String {
        guard let zone = TimeZone(identifier: zoneID) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.currentLanguage.rawValue)
        formatter.timeZone = zone
        formatter.dateFormat = settings.uses24Hour ? "H:mm" : "h:mm a"
        return formatter.string(from: slot)
    }
}
