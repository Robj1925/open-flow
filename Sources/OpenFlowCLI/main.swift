import AVFoundation
import Foundation
import OpenFlowCore

// openflow-cli — M1 transcription spike. Exercises capture, model download,
// and both engines head-to-head before any UI exists.
//
//   openflow-cli models                     list presets and download state
//   openflow-cli record [sec] [preset-id]   record then transcribe with one preset
//   openflow-cli compare [sec]              record once, run BOTH engines on it
//   openflow-cli file <audio> [preset-id]   transcribe an audio file (no mic needed)

func fmtBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func ensureMicAccess() async {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized { return }
    print("Requesting microphone access for this terminal…")
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    if !granted {
        print("❌ Microphone access denied. Grant it in System Settings → Privacy & Security → Microphone.")
        exit(1)
    }
}

func record(seconds: TimeInterval) async throws -> AudioCaptureEngine.Capture {
    let audio = AudioCaptureEngine()
    audio.prepare()
    audio.onFirstBuffer = { print("🎙  Mic is live — speak now (\(Int(seconds))s)…") }
    try audio.start()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    let capture = audio.stop()
    print(String(format: "Captured %.1fs of audio (peak RMS %.4f)", capture.duration, capture.peakRMS))
    return capture
}

func prepare(_ preset: ModelPreset) async throws -> TranscriptionEngine {
    let engine = ModelManager.shared.makeEngine(for: preset)
    let downloaded = ModelManager.shared.isDownloaded(preset)
    if !downloaded {
        print("⬇️  Downloading \(preset.displayName) (\(preset.approxSize)) — one time only…")
    }
    var lastShown = -1
    let loadStart = Date()
    try await engine.prepare { fraction in
        let percent = Int(fraction * 100)
        if percent / 10 != lastShown / 10 {
            lastShown = percent
            print("   … \(percent)%")
        }
    }
    print(String(format: "✅ %@ ready in %.1fs", preset.displayName, Date().timeIntervalSince(loadStart)))
    return engine
}

func transcribe(_ capture: AudioCaptureEngine.Capture, with engine: TranscriptionEngine, preset: ModelPreset) async {
    do {
        let result = try await engine.transcribe(capture.samples, hints: TranscriptionHints(language: "en"))
        let rtf = capture.duration / max(result.processingTime, 0.001)
        print("\n[\(preset.displayName)]")
        print(String(format: "  time: %.2fs  (%.1f× realtime)", result.processingTime, rtf))
        print("  text: \(result.text)")
    } catch {
        print("\n[\(preset.displayName)] ❌ \(error.localizedDescription)")
    }
}

/// Loads any audio file and resamples to 16 kHz mono Float32.
func loadAudioFile(_ path: String) throws -> AudioCaptureEngine.Capture {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCaptureEngine.targetSampleRate,
        channels: 1,
        interleaved: false
    )!
    guard let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
    ) else { throw NSError(domain: "cli", code: 1) }
    try file.read(into: inputBuffer)

    guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
        throw NSError(domain: "cli", code: 2)
    }
    let ratio = outputFormat.sampleRate / file.processingFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
        throw NSError(domain: "cli", code: 3)
    }
    var fed = false
    var conversionError: NSError?
    converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
        if fed {
            inputStatus.pointee = .endOfStream
            return nil
        }
        fed = true
        inputStatus.pointee = .haveData
        return inputBuffer
    }
    if let conversionError { throw conversionError }

    let frames = Int(outputBuffer.frameLength)
    guard let channel = outputBuffer.floatChannelData?[0] else { throw NSError(domain: "cli", code: 4) }
    let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
    var sumSquares: Float = 0
    var peak: Float = 0
    let window = 1024
    var index = 0
    while index < frames {
        let end = min(index + window, frames)
        sumSquares = 0
        for i in index..<end { sumSquares += samples[i] * samples[i] }
        peak = max(peak, (sumSquares / Float(end - index)).squareRoot())
        index = end
    }
    return AudioCaptureEngine.Capture(
        samples: samples,
        duration: Double(frames) / outputFormat.sampleRate,
        peakRMS: peak
    )
}

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "help"

switch command {
case "models":
    print("Available model presets:\n")
    for preset in ModelCatalog.all {
        let mark = ModelManager.shared.isDownloaded(preset) ? "✅" : "⬇️ "
        let size = ModelManager.shared.diskUsage(preset)
        let sizeNote = size > 0 ? " — \(fmtBytes(size)) on disk" : " — not downloaded (\(preset.approxSize))"
        print("  \(mark) \(preset.id): \(preset.displayName)\(sizeNote)")
        print("      \(preset.detail)")
    }

case "record":
    let seconds = TimeInterval(arguments.dropFirst().first ?? "8") ?? 8
    let presetID = arguments.dropFirst(2).first ?? ModelCatalog.parakeetV2.id
    guard let preset = ModelCatalog.preset(id: presetID) else {
        print("Unknown preset \(presetID). Run `openflow-cli models`.")
        exit(1)
    }
    await ensureMicAccess()
    let engine = try await prepare(preset)
    let capture = try await record(seconds: seconds)
    await transcribe(capture, with: engine, preset: preset)

case "file":
    guard let path = arguments.dropFirst().first else {
        print("Usage: openflow-cli file <audio-file> [preset-id|both]")
        exit(1)
    }
    let presetArg = arguments.dropFirst(2).first ?? ModelCatalog.parakeetV2.id
    let capture = try loadAudioFile(path)
    print(String(format: "Loaded %.1fs of audio (peak RMS %.4f)", capture.duration, capture.peakRMS))
    let presets: [ModelPreset]
    if presetArg == "both" {
        presets = [ModelCatalog.parakeetV2, ModelCatalog.whisperBaseEn]
    } else if let preset = ModelCatalog.preset(id: presetArg) {
        presets = [preset]
    } else {
        print("Unknown preset \(presetArg). Run `openflow-cli models`.")
        exit(1)
    }
    for preset in presets {
        let engine = try await prepare(preset)
        await transcribe(capture, with: engine, preset: preset)
        engine.unload()
    }

case "compare":
    let seconds = TimeInterval(arguments.dropFirst().first ?? "8") ?? 8
    await ensureMicAccess()
    let parakeet = ModelCatalog.parakeetV2
    let whisper = ModelCatalog.whisperLargeTurbo
    let parakeetEngine = try await prepare(parakeet)
    let whisperEngine = try await prepare(whisper)
    let capture = try await record(seconds: seconds)
    await transcribe(capture, with: parakeetEngine, preset: parakeet)
    await transcribe(capture, with: whisperEngine, preset: whisper)

case "clean":
    let text = arguments.dropFirst().joined(separator: " ")
    guard !text.isEmpty else {
        print("Usage: openflow-cli clean <raw transcript text>")
        exit(1)
    }
    let cleaner = AppleFoundationCleaner()
    print("Cleanup backend: \(cleaner.availability)")
    guard cleaner.isAvailable else {
        print("(Enable Apple Intelligence in System Settings to run cleanup.)")
        exit(0)
    }
    let started = Date()
    let cleaned = await cleaner.clean(text, vocabulary: nil)
    print(String(format: "time: %.2fs", Date().timeIntervalSince(started)))
    print("raw:     \(text)")
    print("cleaned: \(cleaned)")

default:
    print("""
    openflow-cli — OpenFlow transcription spike

      openflow-cli models                     list presets and download state
      openflow-cli record [sec] [preset-id]   record then transcribe (default: parakeet)
      openflow-cli compare [sec]              record once, transcribe with both engines
      openflow-cli file <audio> [preset|both] transcribe an audio file
      openflow-cli clean <text>               run the LLM cleanup pass on text
    """)
}
