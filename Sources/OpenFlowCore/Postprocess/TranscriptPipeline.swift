import Foundation

/// Context handed to every post-processing stage.
public struct DictationContext: Sendable {
    public var audioDuration: TimeInterval
    public var peakRMS: Float
    public var engineID: String
    public var noSpeechProb: Float?
    public var avgLogprob: Float?

    public init(audioDuration: TimeInterval, peakRMS: Float, engineID: String,
                noSpeechProb: Float? = nil, avgLogprob: Float? = nil) {
        self.audioDuration = audioDuration
        self.peakRMS = peakRMS
        self.engineID = engineID
        self.noSpeechProb = noSpeechProb
        self.avgLogprob = avgLogprob
    }
}

/// One transformation applied to a transcript. Returning "" drops the result.
public protocol TranscriptStage: Sendable {
    func process(_ text: String, context: DictationContext) async -> String
}

/// Ordered post-processing chain. v1 runs HallucinationFilter → DictionaryReplacer;
/// the v2 LLM cleanup stage slots in here without touching anything else.
public struct TranscriptPipeline: Sendable {
    private let stages: [any TranscriptStage]

    public init(stages: [any TranscriptStage]) {
        self.stages = stages
    }

    public func run(_ text: String, context: DictationContext) async -> String {
        var current = text
        for stage in stages {
            if current.isEmpty { return "" }
            current = await stage.process(current, context: context)
        }
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
