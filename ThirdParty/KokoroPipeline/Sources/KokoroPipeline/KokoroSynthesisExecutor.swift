import CoreML
import Foundation

/// Supplies Core ML models to the shared synthesis executor.
///
/// The runtime pipeline uses already-loaded model dictionaries. The benchmark
/// uses a lazy cache that can evict bucket models before loading a new bucket.
public protocol KokoroModelProvider {
    func durationModelChoices() -> [DurationModelChoice]
    func availableBucketSeconds() -> [Int]
    func durationModel(choice: DurationModelChoice) throws -> MLModel
    func f0ntrainModel(tFrames: Int) throws -> MLModel
    func decoderPreModel(bucketSec: Int) throws -> MLModel
    func generatorModel(bucketSec: Int) throws -> MLModel
    func prepareForBucket(bucketSec: Int, tFrames: Int) throws
    func reusableFloatArray(name: String, shape: [Int]) throws -> MLMultiArray?
}

public extension KokoroModelProvider {
    func prepareForBucket(bucketSec: Int, tFrames: Int) throws {}
    func reusableFloatArray(name: String, shape: [Int]) throws -> MLMultiArray? { nil }
}

/// Pre-tokenized synthesis request for the shared Swift/Core ML pipeline.
public struct KokoroSynthesisRequest {
    public let inputIds: [Int32]
    public let attentionMask: [Int32]
    public let refS: [Float]
    public let speed: Float
    public let seed: UInt64
    public let warmModelsBeforeTiming: Bool
    public let bucketDurationOverrideSeconds: Double?

    public init(
        inputIds: [Int32],
        attentionMask: [Int32],
        refS: [Float],
        speed: Float = 1.0,
        seed: UInt64 = 42,
        warmModelsBeforeTiming: Bool = false,
        bucketDurationOverrideSeconds: Double? = nil
    ) {
        self.inputIds = inputIds
        self.attentionMask = attentionMask
        self.refS = refS
        self.speed = speed
        self.seed = seed
        self.warmModelsBeforeTiming = warmModelsBeforeTiming
        self.bucketDurationOverrideSeconds = bucketDurationOverrideSeconds
    }
}

private struct DurationInputBundle {
    let provider: MLDictionaryFeatureProvider
    let idsArray: MLMultiArray
    let maskArray: MLMultiArray?
    let refSArray: MLMultiArray
    let speedArray: MLMultiArray
}

private struct DurationProbe {
    let bucketSec: Int
    let tFrames: Int
    let fullF0Len: Int
}

private struct TimedHarBuildResult {
    let harFlat: [Float]
    let harFrames: Int
    let harDebug: HarDebugComponents?
    let startedAt: CFAbsoluteTime
    let endedAt: CFAbsoluteTime

    var elapsed: Double {
        endedAt - startedAt
    }
}

private final class TimedHarBuildResultBox {
    var result: TimedHarBuildResult?
}

/// Run the Core ML Kokoro pipeline once.
///
/// This is the single orchestration path shared by `KokoroPipeline.synthesize`
/// and the `kokoro-bench` executable. Benchmark-only behavior is injected via
/// `KokoroModelProvider.prepareForBucket(...)`, `warmModelsBeforeTiming`, and
/// the optional tensor dump writer.
public func executeKokoroSynthesis(
    request: KokoroSynthesisRequest,
    modelProvider: KokoroModelProvider,
    linearWeights: [Float],
    linearBias: Float,
    tensorDump: inout TensorDumpWriter?
) throws -> SynthesisResult {
    let durationChoices = modelProvider.durationModelChoices()
    let durationChoice = try KokoroPipeline.selectDurationChoice(
        durationChoices,
        actualTokens: requestedTokenCount(
            inputIds: request.inputIds,
            attentionMask: request.attentionMask
        )
    )
    let durationInput = try buildDurationInput(
        inputIds: request.inputIds,
        attentionMask: request.attentionMask,
        refS: request.refS,
        speed: request.speed,
        choice: durationChoice
    )
    let durationModel = try modelProvider.durationModel(choice: durationChoice)

    try writeDurationInputs(durationInput, tensorDump: &tensorDump)

    if request.warmModelsBeforeTiming {
        let probe = try probeDurationAndBucket(
            input: durationInput,
            durationModel: durationModel,
            modelProvider: modelProvider,
            validTokenLimit: validTokenCount(
                predDurTokenCount: durationChoice.tokenLength,
                attentionMask: request.attentionMask
            ),
            bucketDurationOverrideSeconds: request.bucketDurationOverrideSeconds
        )
        try warmModels(
            probe: probe,
            durationModel: durationModel,
            durationInput: durationInput.provider,
            modelProvider: modelProvider
        )
    }

    var timings = StageTimings()

    // Stage 1: Duration Core ML.
    let t0 = CFAbsoluteTimeGetCurrent()
    let durOutput = try durationModel.prediction(from: durationInput.provider)
    let t1 = CFAbsoluteTimeGetCurrent()
    timings.durationCoreML = t1 - t0

    let predDurArray = durOutput.featureValue(for: "pred_dur")!.multiArrayValue!
    let dArray = durOutput.featureValue(for: "d")!.multiArrayValue!
    let tEnArray = durOutput.featureValue(for: "t_en")!.multiArrayValue!
    let tokenCount = predDurArray.shape.last!.intValue
    let validTokens = validTokenCount(
        predDurTokenCount: tokenCount,
        attentionMask: request.attentionMask
    )
    let predDur = try readDurationFrames(from: predDurArray, validCount: validTokens)
    let frames = predDur.reduce(0, +)
    let totalSeconds = Double(frames * 2) / PipelineConstants.f0FrameRate
    let bucketSelectionSeconds = request.bucketDurationOverrideSeconds ?? totalSeconds

    try writeDurationOutputs(
        predDurArray: predDurArray,
        predDur: predDur,
        dArray: dArray,
        tEnArray: tEnArray,
        tensorDump: &tensorDump
    )

    // Stage 2: alignment metadata. Tensor dumps keep the old sparse matrix as
    // debug data; the hot path expands token vectors directly in Stage 3.
    let t2 = CFAbsoluteTimeGetCurrent()
    let alignment: [Float]? = tensorDump == nil
        ? nil
        : buildAlignmentMatrix(predDur: predDur, traceLength: tokenCount, frameCount: frames)
    let t3 = CFAbsoluteTimeGetCurrent()
    timings.alignment = t3 - t2

    if let alignment {
        try tensorDump?.writeFloatArray(
            name: "alignment",
            values: alignment,
            shape: [1, tokenCount, frames]
        )
    }

    // Stage 3: direct token-vector expansion.
    let t4 = CFAbsoluteTimeGetCurrent()
    let en = try alignTokenMajorToFrames(
        source: dArray,
        predDur: predDur,
        channels: PipelineConstants.hiddenDim,
        frameCount: frames
    )
    let asr = try alignChannelMajorToFrames(
        source: tEnArray,
        predDur: predDur,
        channels: PipelineConstants.textEncoderDim,
        frameCount: frames
    )
    let t5 = CFAbsoluteTimeGetCurrent()
    timings.matrixOps = t5 - t4

    try tensorDump?.writeMLMultiArray(name: "en", array: en)
    try tensorDump?.writeMLMultiArray(name: "asr", array: asr)

    // Stage 4: F0Ntrain Core ML.
    let t6 = CFAbsoluteTimeGetCurrent()
    guard let bucketSec = selectBucket(
        totalSeconds: bucketSelectionSeconds,
        availableBuckets: modelProvider.availableBucketSeconds()
    ) else {
        throw PipelineError.noBucketAvailable
    }
    guard let tFrames = PipelineConstants.tFramesForBucket[bucketSec] else {
        throw PipelineError.modelNotLoaded("f0ntrain bucket \(bucketSec)")
    }
    try modelProvider.prepareForBucket(bucketSec: bucketSec, tFrames: tFrames)
    let f0nModel = try modelProvider.f0ntrainModel(tFrames: tFrames)
    let enPadded = try zeroPad3D(
        source: en,
        channels: PipelineConstants.hiddenDim,
        targetTime: tFrames
    )
    let sArray = try makeZeroArray2D(dim: PipelineConstants.styleDim)
    let sPtr = sArray.dataPointer.assumingMemoryBound(to: Float.self)
    for i in 0..<PipelineConstants.styleDim {
        sPtr[i] = request.refS[PipelineConstants.baselineDim + i]
    }

    try tensorDump?.writeMLMultiArray(name: "en_padded", array: enPadded)
    try tensorDump?.writeMLMultiArray(name: "s", array: sArray)

    let f0nInput = try MLDictionaryFeatureProvider(dictionary: [
        "en": MLFeatureValue(multiArray: enPadded),
        "s": MLFeatureValue(multiArray: sArray),
    ])
    let f0nOutput = try f0nModel.prediction(from: f0nInput)
    let f0PredArray = f0nOutput.featureValue(for: "F0_pred")!.multiArrayValue!
    let nPredArray = f0nOutput.featureValue(for: "N_pred")!.multiArrayValue!
    let t7 = CFAbsoluteTimeGetCurrent()
    timings.f0ntrainCoreML = t7 - t6

    let f0Curve = floatValues(from: f0PredArray)
    let nCurve = floatValues(from: nPredArray)

    try tensorDump?.writeFloatArray(name: "f0", values: f0Curve, shape: [1, f0Curve.count])
    try tensorDump?.writeFloatArray(name: "n", values: nCurve, shape: [1, nCurve.count])

    // Stage 5: pad to bucket geometry.
    let t8 = CFAbsoluteTimeGetCurrent()
    let bucketSamples = bucketSec * PipelineConstants.sampleRate
    let fullF0Len = Int(round(Double(bucketSamples) / Double(HarmonicConstants.upsampleScale)))
    let f0Padded = zeroPad1D(source: f0Curve, targetLength: fullF0Len)
    let nPadded = zeroPad1D(source: nCurve, targetLength: fullF0Len)
    let frameCount = decoderPreFrameCount(fullF0Len: fullF0Len)
    let asrPadded = try zeroPad3D(
        source: asr,
        channels: PipelineConstants.textEncoderDim,
        targetTime: frameCount
    )
    let t9 = CFAbsoluteTimeGetCurrent()
    timings.padding = t9 - t8

    try tensorDump?.writeFloatArray(name: "f0_padded", values: f0Padded, shape: [1, fullF0Len])
    try tensorDump?.writeFloatArray(name: "n_padded", values: nPadded, shape: [1, fullF0Len])
    try tensorDump?.writeMLMultiArray(name: "asr_padded", array: asrPadded)

    let overlapDecoderPreAndHnsf =
        ProcessInfo.processInfo.environment["KOKORO_DISABLE_DECODER_HNSF_OVERLAP"] != "1"
    let captureHarDebug = tensorDump != nil
    let hnsfGroup = overlapDecoderPreAndHnsf ? DispatchGroup() : nil
    let hnsfBox = TimedHarBuildResultBox()
    if let hnsfGroup {
        hnsfGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            hnsfBox.result = buildTimedHar(
                f0Padded: f0Padded,
                linearWeights: linearWeights,
                linearBias: linearBias,
                seed: request.seed,
                captureDebug: captureHarDebug
            )
            hnsfGroup.leave()
        }
    }

    // Stage 6: DecoderPre Core ML. When enabled, Stage 7 starts above because
    // HnSF depends only on padded F0 and can overlap this Core ML prediction.
    let t10 = CFAbsoluteTimeGetCurrent()
    let decPreModel = try modelProvider.decoderPreModel(bucketSec: bucketSec)
    let f0Array3D = try makeZeroArray3D(modelProvider: modelProvider, name: "decoder_pre.f0", channels: 1, time: fullF0Len)
    copyInto(array: f0Array3D, from: f0Padded)
    let nArray3D = try makeZeroArray3D(modelProvider: modelProvider, name: "decoder_pre.n_input", channels: 1, time: fullF0Len)
    copyInto(array: nArray3D, from: nPadded)
    let decRefS = try makeZeroArray2D(modelProvider: modelProvider, name: "decoder_pre.ref_s", dim: PipelineConstants.voiceEmbeddingDim)
    copyInto(array: decRefS, from: request.refS)

    let decPreInput = try MLDictionaryFeatureProvider(dictionary: [
        "asr": MLFeatureValue(multiArray: asrPadded),
        "f0": MLFeatureValue(multiArray: f0Array3D),
        "n_input": MLFeatureValue(multiArray: nArray3D),
        "ref_s": MLFeatureValue(multiArray: decRefS),
    ])
    let decPreOutput = try decPreModel.prediction(from: decPreInput)
    let xPre = decPreOutput.featureValue(for: "x_pre")!.multiArrayValue!
    let t11 = CFAbsoluteTimeGetCurrent()
    timings.decoderPre = t11 - t10

    try tensorDump?.writeMLMultiArray(name: "x_pre", array: xPre)

    // Stage 7: hn-nsf Swift DSP, overlapped with DecoderPre when possible.
    let harBuild: TimedHarBuildResult
    if let hnsfGroup {
        hnsfGroup.wait()
        harBuild = hnsfBox.result!
    } else {
        harBuild = buildTimedHar(
            f0Padded: f0Padded,
            linearWeights: linearWeights,
            linearBias: linearBias,
            seed: request.seed,
            captureDebug: captureHarDebug
        )
    }
    let harFlat = harBuild.harFlat
    let harFrames = harBuild.harFrames
    let harDebug = harBuild.harDebug
    timings.hnsfSwift = harBuild.elapsed
    timings.decoderPreHnsfOverlap = hnsfGroup == nil
        ? 0
        : overlapSeconds(
            firstStart: t10,
            firstEnd: t11,
            secondStart: harBuild.startedAt,
            secondEnd: harBuild.endedAt
        )

    if let harDebug {
        try tensorDump?.writeFloatArray(
            name: "har_source",
            values: harDebug.harSource,
            shape: [1, harDebug.harSource.count]
        )
        try tensorDump?.writeFloatArray(
            name: "har_magnitude",
            values: harDebug.magnitude,
            shape: [1, 11, harDebug.nFrames]
        )
        try tensorDump?.writeFloatArray(
            name: "har_phase",
            values: harDebug.phase,
            shape: [1, 11, harDebug.nFrames]
        )
    }
    try tensorDump?.writeFloatArray(name: "har", values: harFlat, shape: [1, 22, harFrames])

    // Stage 8: GeneratorFromHar Core ML.
    let t14 = CFAbsoluteTimeGetCurrent()
    let genModel = try modelProvider.generatorModel(bucketSec: bucketSec)
    let genRefS = try makeZeroArray2D(modelProvider: modelProvider, name: "generator.ref_s", dim: PipelineConstants.voiceEmbeddingDim)
    copyInto(array: genRefS, from: request.refS)

    let genShapes = inputShapes(from: genModel)
    let xPreExpectedTime = genShapes["x_pre"]?.last ?? xPre.shape.last!.intValue
    let harExpectedTime = genShapes["har"]?.last ?? harFrames
    let xPrePadded = try zeroPad3D(
        modelProvider: modelProvider,
        name: "generator.x_pre",
        source: xPre,
        channels: xPre.shape[1].intValue,
        targetTime: xPreExpectedTime
    )
    let harPadded = try zeroPad3D(
        modelProvider: modelProvider,
        name: "generator.har",
        sourceValues: harFlat,
        channels: HarmonicConstants.harChannels,
        sourceTime: harFrames,
        targetTime: harExpectedTime
    )

    try tensorDump?.writeMLMultiArray(name: "x_pre_padded", array: xPrePadded)
    try tensorDump?.writeMLMultiArray(name: "har_padded", array: harPadded)

    let genInput = try MLDictionaryFeatureProvider(dictionary: [
        "x_pre": MLFeatureValue(multiArray: xPrePadded),
        "ref_s": MLFeatureValue(multiArray: genRefS),
        "har": MLFeatureValue(multiArray: harPadded),
    ])
    let genOutput = try genModel.prediction(from: genInput)
    let t15 = CFAbsoluteTimeGetCurrent()
    timings.generatorCoreML = t15 - t14

    // Stage 9: trim waveform.
    let t16 = CFAbsoluteTimeGetCurrent()
    let waveformKey = genOutput.featureNames.contains("waveform") ? "waveform" : genOutput.featureNames.first!
    let waveformArray = genOutput.featureValue(for: waveformKey)!.multiArrayValue!
    let originalF0Len = frames * 2
    let targetLen = Int(
        round(Double(originalF0Len) / PipelineConstants.f0FrameRate * Double(PipelineConstants.sampleRate))
    )
    let trimLen = min(waveformArray.count, targetLen)
    let rawAudio = floatValues(from: waveformArray, limit: trimLen)
    let expectedAudioSamples = predDur.reduce(0, +) * PipelineConstants.samplesPerDurationFrame
    #if DEBUG
    if trimLen < expectedAudioSamples {
        assertionFailure(
            "Trimmed waveform (\(trimLen) samples) is shorter than pred_dur span " +
            "(\(expectedAudioSamples) samples); punctuation suppression may be partial"
        )
    }
    #endif
    let audio = suppressPunctuationTokenAudio(
        rawAudio,
        inputIds: Array(request.inputIds.prefix(predDur.count)),
        predDur: predDur
    )
    let t17 = CFAbsoluteTimeGetCurrent()
    timings.trim = t17 - t16

    if tensorDump != nil {
        let waveformValues = floatValues(from: waveformArray)
        try tensorDump?.writeFloatArray(
            name: "waveform_full",
            values: waveformValues,
            shape: waveformArray.shape.map { $0.intValue }
        )
        try tensorDump?.writeFloatArray(name: "waveform_raw_trimmed", values: rawAudio, shape: [trimLen])
        try tensorDump?.writeFloatArray(name: "waveform", values: audio, shape: [trimLen])
    }

    return SynthesisResult(
        audio: audio,
        timings: timings,
        bucketSeconds: bucketSec,
        audioDurationSeconds: Double(originalF0Len) / PipelineConstants.f0FrameRate,
        wallTimeSeconds: t17 - t0,
        predictedDurationFrames: frames,
        predictedDurationTokens: predDur.count,
        durationModelCacheKey: durationChoice.cacheKey,
        durationModelAllowsPadding: durationChoice.allowsPadding,
        durationTokenLength: durationChoice.tokenLength,
        tFrames: tFrames,
        fullF0Length: fullF0Len,
        decoderFrameCount: frameCount,
        xPreExpectedTime: xPreExpectedTime,
        harExpectedTime: harExpectedTime,
        trimSampleCount: trimLen,
        tokenDurationFrames: predDur
    )
}

private func requestedTokenCount(inputIds: [Int32], attentionMask: [Int32]) -> Int {
    let maskedTokenCount = attentionMask.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
    return maskedTokenCount > 0 ? maskedTokenCount : inputIds.count
}

private func validTokenCount(predDurTokenCount: Int, attentionMask: [Int32]) -> Int {
    min(predDurTokenCount, attentionMask.reduce(0) { $0 + ($1 == 0 ? 0 : 1) })
}

private func buildDurationInput(
    inputIds: [Int32],
    attentionMask: [Int32],
    refS: [Float],
    speed: Float,
    choice: DurationModelChoice
) throws -> DurationInputBundle {
    let tokenLength = choice.tokenLength
    let idsArray = try MLMultiArray(shape: [1, NSNumber(value: tokenLength)], dataType: .int32)
    let maskArray = choice.requiresAttentionMask
        ? try MLMultiArray(shape: [1, NSNumber(value: tokenLength)], dataType: .int32)
        : nil
    let refSArray = try makeZeroArray2D(dim: PipelineConstants.voiceEmbeddingDim)
    let speedArray = try MLMultiArray(shape: [1], dataType: .float32)

    let idsPtr = idsArray.dataPointer.assumingMemoryBound(to: Int32.self)
    let refSPtr = refSArray.dataPointer.assumingMemoryBound(to: Float.self)
    for i in 0..<min(inputIds.count, tokenLength) {
        idsPtr[i] = inputIds[i]
    }
    if let maskArray {
        let maskPtr = maskArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<min(attentionMask.count, tokenLength) {
            maskPtr[i] = attentionMask[i]
        }
    }
    for i in 0..<min(refS.count, PipelineConstants.voiceEmbeddingDim) {
        refSPtr[i] = refS[i]
    }
    speedArray[0] = NSNumber(value: speed)

    var features: [String: MLFeatureValue] = [
        "input_ids": MLFeatureValue(multiArray: idsArray),
        "ref_s": MLFeatureValue(multiArray: refSArray),
        "speed": MLFeatureValue(multiArray: speedArray),
    ]
    if let maskArray {
        features["attention_mask"] = MLFeatureValue(multiArray: maskArray)
    }

    return DurationInputBundle(
        provider: try MLDictionaryFeatureProvider(dictionary: features),
        idsArray: idsArray,
        maskArray: maskArray,
        refSArray: refSArray,
        speedArray: speedArray
    )
}

private func writeDurationInputs(
    _ input: DurationInputBundle,
    tensorDump: inout TensorDumpWriter?
) throws {
    try tensorDump?.writeMLMultiArray(name: "tokens", array: input.idsArray)
    if let maskArray = input.maskArray {
        try tensorDump?.writeMLMultiArray(name: "attention_mask", array: maskArray)
    }
    try tensorDump?.writeMLMultiArray(name: "ref_s", array: input.refSArray)
    try tensorDump?.writeMLMultiArray(name: "speed", array: input.speedArray)
}

private func writeDurationOutputs(
    predDurArray: MLMultiArray,
    predDur: [Int],
    dArray: MLMultiArray,
    tEnArray: MLMultiArray,
    tensorDump: inout TensorDumpWriter?
) throws {
    try tensorDump?.writeMLMultiArray(name: "pred_dur", array: predDurArray)
    try tensorDump?.writeInt32Array(
        name: "pred_dur_valid",
        values: predDur.map { Int32($0) },
        shape: [1, predDur.count]
    )
    try tensorDump?.writeMLMultiArray(name: "duration_d", array: dArray)
    try tensorDump?.writeMLMultiArray(name: "duration_t_en", array: tEnArray)
}

private func probeDurationAndBucket(
    input: DurationInputBundle,
    durationModel: MLModel,
    modelProvider: KokoroModelProvider,
    validTokenLimit: Int,
    bucketDurationOverrideSeconds: Double?
) throws -> DurationProbe {
    let output = try durationModel.prediction(from: input.provider)
    let predDurArray = output.featureValue(for: "pred_dur")!.multiArrayValue!
    let predDur = try readDurationFrames(from: predDurArray, validCount: validTokenLimit)
    let totalFrames = predDur.reduce(0, +)
    let totalSeconds = Double(totalFrames * 2) / PipelineConstants.f0FrameRate
    guard let bucketSec = selectBucket(
        totalSeconds: bucketDurationOverrideSeconds ?? totalSeconds,
        availableBuckets: modelProvider.availableBucketSeconds()
    ) else {
        throw PipelineError.noBucketAvailable
    }
    guard let tFrames = PipelineConstants.tFramesForBucket[bucketSec] else {
        throw PipelineError.modelNotLoaded("f0ntrain bucket \(bucketSec)")
    }
    try modelProvider.prepareForBucket(bucketSec: bucketSec, tFrames: tFrames)
    let bucketSamples = bucketSec * PipelineConstants.sampleRate
    let fullF0Len = Int(round(Double(bucketSamples) / Double(HarmonicConstants.upsampleScale)))
    return DurationProbe(
        bucketSec: bucketSec,
        tFrames: tFrames,
        fullF0Len: fullF0Len
    )
}

private func warmModels(
    probe: DurationProbe,
    durationModel: MLModel,
    durationInput: MLDictionaryFeatureProvider,
    modelProvider: KokoroModelProvider
) throws {
    _ = try durationModel.prediction(from: durationInput)

    let f0nModel = try modelProvider.f0ntrainModel(tFrames: probe.tFrames)
    let warmEnArr = try makeZeroArray3D(
        channels: PipelineConstants.hiddenDim,
        time: probe.tFrames
    )
    let warmSArr = try makeZeroArray2D(dim: PipelineConstants.styleDim)
    let warmF0nIn = try MLDictionaryFeatureProvider(dictionary: [
        "en": MLFeatureValue(multiArray: warmEnArr),
        "s": MLFeatureValue(multiArray: warmSArr),
    ])
    _ = try f0nModel.prediction(from: warmF0nIn)

    let decPreModel = try modelProvider.decoderPreModel(bucketSec: probe.bucketSec)
    let warmFrameCount = decoderPreFrameCount(fullF0Len: probe.fullF0Len)
    let warmAsr = try makeZeroArray3D(
        channels: PipelineConstants.textEncoderDim,
        time: warmFrameCount
    )
    let warmF0 = try makeZeroArray3D(channels: 1, time: probe.fullF0Len)
    let warmN = try makeZeroArray3D(channels: 1, time: probe.fullF0Len)
    let warmRefS = try makeZeroArray2D(dim: PipelineConstants.voiceEmbeddingDim)
    let warmDecIn = try MLDictionaryFeatureProvider(dictionary: [
        "asr": MLFeatureValue(multiArray: warmAsr),
        "f0": MLFeatureValue(multiArray: warmF0),
        "n_input": MLFeatureValue(multiArray: warmN),
        "ref_s": MLFeatureValue(multiArray: warmRefS),
    ])
    _ = try decPreModel.prediction(from: warmDecIn)

    let genModel = try modelProvider.generatorModel(bucketSec: probe.bucketSec)
    let genShapes = inputShapes(from: genModel)
    var warmGenInputs: [String: MLFeatureValue] = [:]
    for (name, shape) in genShapes {
        if shape.count == 3 {
            warmGenInputs[name] = MLFeatureValue(
                multiArray: try makeZeroArray3D(channels: shape[1], time: shape[2])
            )
        } else if shape.count == 2 {
            warmGenInputs[name] = MLFeatureValue(
                multiArray: try makeZeroArray2D(dim: shape[1])
            )
        }
    }
    _ = try genModel.prediction(from: try MLDictionaryFeatureProvider(dictionary: warmGenInputs))
}

private func decoderPreFrameCount(fullF0Len: Int) -> Int {
    (fullF0Len - 1) / 2 + 1
}

private func makeZeroArray3D(
    modelProvider: KokoroModelProvider,
    name: String,
    channels: Int,
    time: Int
) throws -> MLMultiArray {
    if let array = try modelProvider.reusableFloatArray(name: name, shape: [1, channels, time]) {
        zero(array)
        return array
    }
    return try makeZeroArray3D(channels: channels, time: time)
}

private func makeZeroArray2D(
    modelProvider: KokoroModelProvider,
    name: String,
    dim: Int
) throws -> MLMultiArray {
    if let array = try modelProvider.reusableFloatArray(name: name, shape: [1, dim]) {
        zero(array)
        return array
    }
    return try makeZeroArray2D(dim: dim)
}

private func zero(_ array: MLMultiArray) {
    let byteCount: Int
    switch array.dataType {
    case .float32:
        byteCount = array.count * MemoryLayout<Float>.size
    case .float16:
        byteCount = array.count * MemoryLayout<Float16>.size
    case .double:
        byteCount = array.count * MemoryLayout<Double>.size
    case .int32:
        byteCount = array.count * MemoryLayout<Int32>.size
    case .int8:
        byteCount = array.count * MemoryLayout<Int8>.size
    @unknown default:
        for i in 0..<array.count {
            array[localMultiIndex(offset: i, shape: array.shape.map { $0.intValue })] = 0
        }
        return
    }
    memset(array.dataPointer, 0, byteCount)
}

private func localMultiIndex(offset: Int, shape: [Int]) -> [NSNumber] {
    guard !shape.isEmpty else { return [] }
    var remainder = offset
    var result = [Int](repeating: 0, count: shape.count)
    for dimIndex in stride(from: shape.count - 1, through: 0, by: -1) {
        let dim = max(1, shape[dimIndex])
        result[dimIndex] = remainder % dim
        remainder /= dim
    }
    return result.map { NSNumber(value: $0) }
}

private func zeroPad3D(
    modelProvider: KokoroModelProvider,
    name: String,
    source: MLMultiArray,
    channels: Int,
    targetTime: Int
) throws -> MLMultiArray {
    if let array = try modelProvider.reusableFloatArray(name: name, shape: [1, channels, targetTime]) {
        zero(array)
        let sourceShape = source.shape.map { $0.intValue }
        let sourceTime = sourceShape.count >= 3 ? sourceShape[2] : targetTime
        let copyTime = min(sourceTime, targetTime)
        let dstPtr = array.dataPointer.assumingMemoryBound(to: Float.self)
        let srcStrides = source.strides.map { $0.intValue }
        if source.dataType == .float32,
           srcStrides.count >= 3,
           srcStrides[2] == 1,
           srcStrides[1] == sourceTime {
            let srcPtr = source.dataPointer.assumingMemoryBound(to: Float.self)
            for c in 0..<channels {
                memcpy(
                    dstPtr + c * targetTime,
                    srcPtr + c * sourceTime,
                    copyTime * MemoryLayout<Float>.size
                )
            }
        } else {
            for c in 0..<channels {
                for t in 0..<copyTime {
                    dstPtr[c * targetTime + t] = source[[0, c, t] as [NSNumber]].floatValue
                }
            }
        }
        return array
    }
    return try zeroPad3D(source: source, channels: channels, targetTime: targetTime)
}

private func zeroPad3D(
    modelProvider: KokoroModelProvider,
    name: String,
    sourceValues: [Float],
    channels: Int,
    sourceTime: Int,
    targetTime: Int
) throws -> MLMultiArray {
    if let array = try modelProvider.reusableFloatArray(name: name, shape: [1, channels, targetTime]) {
        zero(array)
        let copyTime = max(0, min(sourceTime, targetTime))
        if copyTime > 0 {
            let dstPtr = array.dataPointer.assumingMemoryBound(to: Float.self)
            sourceValues.withUnsafeBufferPointer { srcBuf in
                guard let srcBase = srcBuf.baseAddress else { return }
                for c in 0..<channels {
                    memcpy(
                        dstPtr + c * targetTime,
                        srcBase + c * sourceTime,
                        copyTime * MemoryLayout<Float>.size
                    )
                }
            }
        }
        return array
    }
    return try zeroPad3D(
        sourceValues: sourceValues,
        channels: channels,
        sourceTime: sourceTime,
        targetTime: targetTime
    )
}

private func buildTimedHar(
    f0Padded: [Float],
    linearWeights: [Float],
    linearBias: Float,
    seed: UInt64,
    captureDebug: Bool
) -> TimedHarBuildResult {
    let startedAt = CFAbsoluteTimeGetCurrent()
    let harFlat: [Float]
    let harFrames: Int
    let harDebug: HarDebugComponents?

    if captureDebug {
        let components = buildHarComponents(
            f0Padded: f0Padded,
            linearWeights: linearWeights,
            linearBias: linearBias,
            seed: seed
        )
        harFlat = components.har
        harFrames = components.nFrames
        harDebug = components
    } else {
        let built = buildHar(
            f0Padded: f0Padded,
            linearWeights: linearWeights,
            linearBias: linearBias,
            seed: seed
        )
        harFlat = built.har
        harFrames = built.nFrames
        harDebug = nil
    }

    return TimedHarBuildResult(
        harFlat: harFlat,
        harFrames: harFrames,
        harDebug: harDebug,
        startedAt: startedAt,
        endedAt: CFAbsoluteTimeGetCurrent()
    )
}

private func overlapSeconds(
    firstStart: CFAbsoluteTime,
    firstEnd: CFAbsoluteTime,
    secondStart: CFAbsoluteTime,
    secondEnd: CFAbsoluteTime
) -> Double {
    max(0, min(firstEnd, secondEnd) - max(firstStart, secondStart))
}
