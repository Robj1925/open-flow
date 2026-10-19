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
//   openflow-cli speak <text> [--out f.wav] [--play]   synthesize with Kokoro
//   openflow-cli live <audio> [preset-id]   replay a file as a live recording, print partials
//   openflow-cli live-stream <audio> [320|640|1120]   same, through the Parakeet Unified streaming preview

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
    try await audio.startAndWait()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    let capture = await audio.stopAndWait()
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

/// Writes mono Float32 PCM as a 16-bit WAV.
func writeWAV(_ clip: SpeechClip, to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: clip.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)) else {
        throw NSError(domain: "cli", code: 5)
    }
    buffer.frameLength = AVAudioFrameCount(clip.samples.count)
    clip.samples.withUnsafeBufferPointer { source in
        buffer.floatChannelData![0].update(from: source.baseAddress!, count: clip.samples.count)
    }
    try file.write(from: buffer)
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
    let presetID = arguments.dropFirst(2).first ?? ModelCatalog.parakeetV3.id
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
    let presetArg = arguments.dropFirst(2).first ?? ModelCatalog.parakeetV3.id
    let capture = try loadAudioFile(path)
    print(String(format: "Loaded %.1fs of audio (peak RMS %.4f)", capture.duration, capture.peakRMS))
    let presets: [ModelPreset]
    if presetArg == "both" {
        presets = [ModelCatalog.parakeetV3, ModelCatalog.whisperLargeTurbo]
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
    let parakeet = ModelCatalog.parakeetV3
    let whisper = ModelCatalog.whisperLargeTurbo
    let parakeetEngine = try await prepare(parakeet)
    let whisperEngine = try await prepare(whisper)
    let capture = try await record(seconds: seconds)
    await transcribe(capture, with: parakeetEngine, preset: parakeet)
    await transcribe(capture, with: whisperEngine, preset: whisper)

case "live":
    guard let path = arguments.dropFirst().first else {
        print("Usage: openflow-cli live <audio-file> [preset-id]")
        exit(1)
    }
    let presetID = arguments.dropFirst(2).first ?? ModelCatalog.parakeetV3.id
    guard let preset = ModelCatalog.preset(id: presetID) else {
        print("Unknown preset \(presetID). Run `openflow-cli models`.")
        exit(1)
    }
    let capture = try loadAudioFile(path)
    print(String(format: "Loaded %.1fs of audio; replaying it in real time with live partials", capture.duration))
    let engine = try await prepare(preset)

    // Reveal the file at the wall-clock rate a microphone would.
    let startedAt = Date()
    let rate = AudioCaptureEngine.targetSampleRate
    let live = await LiveTranscriber()
    var passes = 0
    var lastPartial = ""
    await MainActor.run {
        var raw = ""
        var shownRaw = ""
        live.onPass = { raw = $0 }
        live.onUpdate = { transcript in
            passes += 1
            let elapsed = Date().timeIntervalSince(startedAt)
            lastPartial = transcript.text
            if raw != shownRaw {
                shownRaw = raw
                print("           raw: \(raw)")
            }
            // "|" separates the stable prefix from the tail still being decided.
            let committed = transcript.committed.suffix(12).joined(separator: " ")
            let prefix = transcript.committed.count > 12 ? "… " : ""
            print(String(format: "  +%5.2fs  pass %2d  [%d stable] %@%@ | %@", elapsed, passes, transcript.committed.count, prefix, committed, transcript.tentative.joined(separator: " ")))
        }
        live.start(hints: TranscriptionHints(language: "en"), engine: { engine }, samples: {
            let elapsed = Date().timeIntervalSince(startedAt)
            let available = min(capture.samples.count, Int(elapsed * rate))
            return Array(capture.samples.prefix(available))
        })
    }
    try await Task.sleep(nanoseconds: UInt64((capture.duration + 1.0) * 1_000_000_000))
    await MainActor.run { live.stop() }
    let final = try await engine.transcribe(capture.samples, hints: TranscriptionHints(language: "en"))
    print("Passes: \(passes)")
    print("Final:  \(final.text)")
    print("Word timings on final: \(final.words?.count ?? 0)")
    print(lastPartial == final.text ? "✅ last partial matches the final transcript" : "ℹ️ last partial differs from final (expected when audio ended mid-pass)")

case "live-stream":
    // Replays a file in real time through the streaming preview engine and
    // prints each increment as it is emitted, then compares with the batch model.
    guard let path = arguments.dropFirst().first else {
        print("Usage: openflow-cli live-stream <audio> [320|640|1120]")
        exit(1)
    }
    let tierRaw = arguments.dropFirst(2).first ?? "320"
    guard let tier = StreamingPreviewEngine.Tier(rawValue: tierRaw) else {
        print("Unknown tier \(tierRaw); use 320, 640 or 1120.")
        exit(1)
    }
    let capture = try loadAudioFile(path)
    print(String(format: "Loaded %.1fs of audio; streaming it in real time (Parakeet Unified, %@ms tier)", capture.duration, tier.rawValue))
    let streaming = StreamingPreviewEngine(tier: tier)
    if !StreamingPreviewEngine.isDownloaded(tier) {
        print("⬇️  Downloading Parakeet Unified \(tier.rawValue) ms (\(StreamingPreviewEngine.approxSize)) — one time only…")
    }
    var lastShownStream = -1
    let streamLoadStart = Date()
    try await streaming.prepare { fraction in
        let percent = Int(fraction * 100)
        if percent / 10 != lastShownStream / 10 {
            lastShownStream = percent
            print("   … \(percent)%")
        }
    }
    print(String(format: "✅ Streaming model ready in %.1fs", Date().timeIntervalSince(streamLoadStart)))

    let startedAt = Date()
    let rate = AudioCaptureEngine.targetSampleRate
    let live = await LiveTranscriber()
    var lastText = ""
    await MainActor.run {
        live.onPass = { text in
            let elapsed = Date().timeIntervalSince(startedAt)
            let added = text.hasPrefix(lastText) ? String(text.dropFirst(lastText.count)) : "⟲ " + text
            lastText = text
            print(String(format: "  +%5.2fs  %@", elapsed, added.trimmingCharacters(in: .whitespaces)))
        }
        live.startStreaming(engine: streaming, samples: {
            let elapsed = Date().timeIntervalSince(startedAt)
            let available = min(capture.samples.count, Int(elapsed * rate))
            return Array(capture.samples.prefix(available))
        })
    }
    try await Task.sleep(nanoseconds: UInt64((capture.duration + 1.0) * 1_000_000_000))
    await MainActor.run { live.stop() }
    let streamed = try await streaming.finish()
    print("Streamed: \(streamed)")
    let batch = try await prepare(ModelCatalog.parakeetV3)
    let reference = try await batch.transcribe(capture.samples, hints: TranscriptionHints(language: "en"))
    print("TDT v3:   \(reference.text)")
    try await Task.sleep(nanoseconds: 300_000_000)
    if let log = try? String(contentsOf: TimingLog.url, encoding: .utf8),
       let summary = log.split(separator: "\n").last(where: { $0.contains("stream summary") }) {
        print(summary)
    }

case "speak":
    var words = Array(arguments.dropFirst())
    var outputPath: String?
    var play = false
    if let flag = words.firstIndex(of: "--out"), flag + 1 < words.count {
        outputPath = words[flag + 1]
        words.removeSubrange(flag...(flag + 1))
    }
    if let flag = words.firstIndex(of: "--play") {
        play = true
        words.remove(at: flag)
    }

    let text = words.joined(separator: " ")
    guard !text.isEmpty else {
        print("Usage: openflow-cli speak <text> [--out file.wav] [--play]")
        exit(1)
    }

    let chunks = TextChunker.chunks(text)
    print("Chunks: \(chunks.count)")
    for (index, chunk) in chunks.enumerated() {
        print("  [\(index + 1)] \(chunk)")
    }

    let synthesizer = KokoroSpeechSynthesizer()
    if !KokoroSpeechSynthesizer.isDownloaded {
        print("⬇️  Downloading \(synthesizer.displayName) (\(KokoroSpeechSynthesizer.approxSize)) — one time only…")
    }
    let loadStart = Date()
    try await synthesizer.prepare()
    print(String(format: "✅ %@ ready in %.1fs", synthesizer.displayName, Date().timeIntervalSince(loadStart)))

    let player = AudioPlaybackEngine()
    var allSamples: [Float] = []
    var sampleRate = 24_000.0
    var totalSynth: TimeInterval = 0
    var firstAudioAt: TimeInterval?
    let runStart = Date()
    for (index, chunk) in chunks.enumerated() {
        let started = Date()
        let clip = try await synthesizer.synthesize(chunk, speed: 1.0)
        let elapsed = Date().timeIntervalSince(started)
        totalSynth += elapsed
        if firstAudioAt == nil { firstAudioAt = Date().timeIntervalSince(runStart) }
        sampleRate = clip.sampleRate
        allSamples.append(contentsOf: clip.samples)
        print(String(format: "  chunk %d: %.0f ms synth → %.2fs audio (%.1f× realtime)",
                     index + 1, elapsed * 1000, clip.duration, clip.duration / max(elapsed, 0.001)))
        if play { try await player.enqueue(clip) }
    }
    let total = SpeechClip(samples: allSamples, sampleRate: sampleRate)
    print(String(format: "Time to first audio: %.0f ms", (firstAudioAt ?? 0) * 1000))
    print(String(format: "Total: %.2fs synth → %.2fs audio (%.1f× realtime)",
                 totalSynth, total.duration, total.duration / max(totalSynth, 0.001)))
    if let outputPath {
        let url = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: url)
        try writeWAV(total, to: url)
        print("Wrote \(url.path)")
    }
    if play {
        await player.waitUntilDrained()
        print("Playback finished")
    }

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
      openflow-cli speak <text> [--out f.wav] [--play]
                                              read text aloud with the Kokoro voice
      openflow-cli live <audio> [preset-id]   replay a file as a live recording and print partials
    """)
}
