import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Keeps a Bluetooth headset's hands-free (HFP/SCO) link up for the whole
/// capture session, independently of the capture unit, and reports when
/// the link is REALLY up (the mic is heard).
///
/// Why this exists (field log 2026-09-04, Sony WH-1000XM5 as the default
/// input AND output): the capture then ran on `AVAudioEngine`, whose I/O
/// unit binds to an automatic aggregate of the default input and the
/// default output — even for an input-only graph, and regardless of
/// `kAudioOutputUnitProperty_CurrentDevice`. Starting input flips the
/// headset from A2DP to HFP; the aggregate's OUTPUT half changes format
/// (48 kHz stereo → 16 kHz mono), the aggregate reconfigures, the engine
/// stops itself, and the moment it stops the system drops the SCO link and
/// restores A2DP. Every restart then re-triggers the same flip: a
/// self-sustained loop with a ~1 s period, visible as `capture.engine.died`
/// storms on nearly every cold start.
///
/// A plain HAL output unit bound to the headset's INPUT device alone is
/// immune to that: its device is 16 kHz mono before and after the profile
/// switch. `MicCapture` now captures on exactly such a unit (since the
/// 2026-09-07 rewrite), and this hold still runs ahead of it: starting the
/// hold first raises the SCO link before the capture unit binds, so the
/// unit is born on a settled link, and the link stays up across the
/// restarts a capture death still needs.
///
/// Readiness: the output device's nominal rate flips the moment the link is
/// REQUESTED, ~0.9 s before the voice channel actually connects (bluetoothd:
/// "Sco route reason … AudioIO" → "voice audio connected"); a capture unit
/// started in between still dies once. The only honest signal is audio:
/// the unit renders its input buffers and flags `linkHeard` on the first
/// non-zero sample — the BT HAL delivers exact zeros (or nothing) until the
/// link is up. Owned and driven by `MicCapture` on its control queue; the
/// render callback runs on the HAL IO thread and touches only the lock and
/// buffers allocated for the unit's lifetime.
nonisolated final class BluetoothInputHold {
    private var unit: AudioUnit?
    /// The device the hold currently runs on (nil when stopped).
    private(set) var deviceID: AudioDeviceID?
    private let heard = OSAllocatedUnfairLock(initialState: false)
    private static let maxFrames = 8192
    private var samples: UnsafeMutablePointer<Float>?
    private var bufferList: UnsafeMutableAudioBufferListPointer?

    /// True once the mic delivered a non-zero sample since `start`.
    var linkHeard: Bool { heard.withLock { $0 } }

    /// Starts IO on `target`. Returns false (holding nothing) when the unit
    /// could not be created or started — the caller then proceeds exactly
    /// as it did before the hold existed.
    @discardableResult
    func start(deviceID target: AudioDeviceID) -> Bool {
        if deviceID == target, unit != nil { return true }
        stop()
        heard.withLock { $0 = false }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            Diagnostics.log("dictation", "capture.hold.error no HAL output component")
            return false
        }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let created = instance else {
            Diagnostics.log("dictation", "capture.hold.error instance")
            return false
        }

        func step(_ name: String, _ status: OSStatus) -> Bool {
            if status == noErr { return true }
            Diagnostics.log("dictation", "capture.hold.error \(name) status=\(status)")
            return false
        }
        func discard() {
            unit = nil
            AudioUnitUninitialize(created)
            AudioComponentInstanceDispose(created)
            releaseBuffers()
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var device = target
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        // Order matters (TN2091): enable/disable IO first, then bind the
        // device, then formats and the input callback, then initialize
        // and start.
        guard step("enableInput", AudioUnitSetProperty(
                  created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, flagSize)),
              step("disableOutput", AudioUnitSetProperty(
                  created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, flagSize)),
              step("device", AudioUnitSetProperty(
                  created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                  UInt32(MemoryLayout<AudioDeviceID>.size))) else {
            discard()
            return false
        }

        // Client format on the input element's output side: float mono at
        // the device's own rate (AUHAL does not resample).
        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard step("deviceFormat", AudioUnitGetProperty(
                  created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &formatSize)) else {
            discard()
            return false
        }
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        let allocated = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(mNumberChannels: 1,
                              mDataByteSize: UInt32(Self.maxFrames * MemoryLayout<Float>.size),
                              mData: UnsafeMutableRawPointer(allocated))
        samples = allocated
        bufferList = list
        var callback = AURenderCallbackStruct(
            inputProc: Self.inputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        // Published before start so the very first callbacks can render.
        unit = created
        guard step("clientFormat", AudioUnitSetProperty(
                  created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, formatSize)),
              step("callback", AudioUnitSetProperty(
                  created, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                  UInt32(MemoryLayout<AURenderCallbackStruct>.size))),
              step("initialize", AudioUnitInitialize(created)),
              step("start", AudioOutputUnitStart(created)) else {
            discard()
            return false
        }
        deviceID = target
        return true
    }

    /// Releases the link (the headset returns to A2DP once no client is left).
    func stop() {
        deviceID = nil
        heard.withLock { $0 = false }
        guard let unit else { return }
        // Stop is synchronous with the IO cycle: no callback runs after it.
        AudioOutputUnitStop(unit)
        self.unit = nil
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        releaseBuffers()
    }

    private func releaseBuffers() {
        if let bufferList {
            free(bufferList.unsafeMutablePointer)
            self.bufferList = nil
        }
        samples?.deallocate()
        samples = nil
    }

    // MARK: HAL IO thread

    private static let inputProc: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
        Unmanaged<BluetoothInputHold>.fromOpaque(refCon).takeUnretainedValue()
            .render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
    }

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timestamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32) -> OSStatus {
        // Once heard there is nothing more to learn — the unit merely holds
        // the link, the unrendered input just falls off the ring buffer.
        if heard.withLock({ $0 }) { return noErr }
        guard let unit, let samples, let bufferList,
              frames > 0, frames <= UInt32(Self.maxFrames) else { return noErr }
        bufferList[0].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        guard AudioUnitRender(unit, flags, timestamp, bus, frames, bufferList.unsafeMutablePointer) == noErr else {
            return noErr
        }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frames))
        if peak > 0 { heard.withLock { $0 = true } }
        return noErr
    }
}
