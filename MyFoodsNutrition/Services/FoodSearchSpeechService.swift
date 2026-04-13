import AVFoundation
import Foundation
import Speech

/// Apple on-device/server speech recognition first; on low confidence or failure, sends recorded audio to Whisper (same flow as `personal_assistant_app` `TranscriptionService`).
@MainActor
final class FoodSearchSpeechService: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribingRemote
    }

    /// Matches `TranscriptionService.confidenceThreshold` in personal_assistant_app.
    private static let confidenceThreshold: Float = 0.5

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastErrorMessage: String?

    private let whisperClient = WhisperTranscriptionClient()

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var wavAccumulator: WavAccumulator?
    private var tapInstalled = false
    private var selectedLocale: Locale = .current

    private var onPartial: ((String) -> Void)?
    private var onFinished: ((Result<String, Error>) -> Void)?
    private var didEmitFinished = false

    /// Stops recognition without delivering a result (user cancelled).
    func cancelSession() {
        onPartial = nil
        onFinished = nil
        didEmitFinished = false
        tearDownFullSession()
        phase = .idle
    }

    /// - Parameters:
    ///   - onPartial: Streaming text from Apple STT.
    ///   - onFinished: Final text to place in the search field, or error.
    func startListening(
        onPartial: @escaping (String) -> Void,
        onFinished: @escaping (Result<String, Error>) -> Void
    ) {
        didEmitFinished = false
        lastErrorMessage = nil
        self.onPartial = onPartial
        self.onFinished = onFinished

        Task {
            await self.beginSession()
        }
    }

    private func beginSession() async {
        let speechAuth: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechAuth == .authorized else {
            finish(.failure(SpeechServiceError.speechPermissionDenied))
            return
        }

        let session = AVAudioSession.sharedInstance()
        let micGranted: Bool = await withCheckedContinuation { cont in
            switch session.recordPermission {
            case .granted:
                cont.resume(returning: true)
            case .denied:
                cont.resume(returning: false)
            case .undetermined:
                session.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            @unknown default:
                cont.resume(returning: false)
            }
        }
        guard micGranted else {
            finish(.failure(SpeechServiceError.microphonePermissionDenied))
            return
        }

        selectedLocale = preferredSpeechLocale()

        guard let recognizer = SFSpeechRecognizer(locale: selectedLocale), recognizer.isAvailable else {
            finish(.failure(SpeechServiceError.recognizerUnavailable))
            return
        }

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                finish(.failure(SpeechServiceError.internalState))
                return
            }
            recognitionRequest.shouldReportPartialResults = true
            if #available(iOS 13, *) {
                recognitionRequest.requiresOnDeviceRecognition = false
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            wavAccumulator = WavAccumulator(sampleRate: format.sampleRate, channelCount: format.channelCount)

            recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    self.handleRecognitionResult(result: result, error: error)
                }
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                self?.wavAccumulator?.append(buffer)
            }
            tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()
            didEmitFinished = false
            phase = .listening
        } catch {
            tearDownFullSession()
            finish(.failure(error))
        }
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if didEmitFinished { return }
        if onFinished == nil { return }

        if let error {
            phase = .transcribingRemote
            stopRecordingCaptureOnly()
            Task {
                await self.runWhisperUpload(appleFallbackText: nil, underlying: error)
            }
            return
        }

        guard let result else { return }

        let transcription = result.bestTranscription.formattedString
        let isFinal = result.isFinal
        let confidence = averageSegmentConfidence(result.bestTranscription)

        if !transcription.isEmpty {
            onPartial?(transcription)
        }

        if isFinal {
            let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                phase = .transcribingRemote
                stopRecordingCaptureOnly()
                Task {
                    await self.runWhisperUpload(appleFallbackText: nil, underlying: SpeechServiceError.emptyAppleTranscript)
                }
                return
            }

            if shouldUseWhisperFallback(confidence: confidence) {
                phase = .transcribingRemote
                onPartial?(trimmed)
                stopRecordingCaptureOnly()
                Task {
                    await self.runWhisperUpload(appleFallbackText: trimmed, underlying: nil)
                }
            } else {
                tearDownFullSession()
                finish(.success(trimmed))
            }
        }
    }

    private func shouldUseWhisperFallback(confidence: Float) -> Bool {
        confidence < Self.confidenceThreshold
    }

    private func averageSegmentConfidence(_ transcription: SFTranscription) -> Float {
        let segments = transcription.segments
        guard !segments.isEmpty else { return 0 }
        let sum = segments.reduce(0 as Float) { $0 + $1.confidence }
        return sum / Float(segments.count)
    }

    private func runWhisperUpload(appleFallbackText: String?, underlying: Error?) async {
        defer {
            tearDownFullSession()
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("food_search_voice_\(UUID().uuidString).wav")

        do {
            try wavAccumulator?.finalizeWriting(to: wavURL)
            wavAccumulator = nil

            let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if size < 512 {
                if let t = appleFallbackText, !t.isEmpty {
                    finish(.success(t))
                    return
                }
                finish(.failure(underlying ?? SpeechServiceError.emptyAppleTranscript))
                return
            }

            let whisperResult = try await whisperClient.transcribeAudioFile(at: wavURL, autoDetectLanguage: true)
            try? FileManager.default.removeItem(at: wavURL)
            finish(.success(whisperResult.text))
        } catch {
            if let t = appleFallbackText, !t.isEmpty {
                finish(.success(t))
            } else {
                finish(.failure(error))
            }
        }
    }

    /// Stops mic tap and engine; keeps `wavAccumulator` for Whisper upload.
    private func stopRecordingCaptureOnly() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func tearDownFullSession() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        wavAccumulator = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finish(_ result: Result<String, Error>) {
        guard !didEmitFinished else { return }
        didEmitFinished = true
        phase = .idle
        let callback = onFinished
        onPartial = nil
        onFinished = nil

        if case let .failure(err) = result {
            lastErrorMessage = err.localizedDescription
        }

        callback?(result)
    }

    private func preferredSpeechLocale() -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        let id = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        if id.hasSuffix("_IL") {
            if let he = supported.first(where: { $0.identifier.hasPrefix("he") }) {
                return he
            }
        }
        if supported.contains(where: { $0.identifier == Locale.current.identifier }) {
            return Locale.current
        }
        if let en = supported.first(where: { $0.identifier.hasPrefix("en") }) {
            return en
        }
        return Locale.current
    }
}

enum SpeechServiceError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case internalState
    case emptyAppleTranscript

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "אין הרשאה לזיהוי דיבור. אפשר להפעיל בהגדרות > פרטיות > זיהוי דיבור."
        case .microphonePermissionDenied:
            return "אין הרשאה למיקרופון. אפשר להפעיל בהגדרות > MyFoodsNutrition."
        case .recognizerUnavailable:
            return "זיהוי דיבור לא זמין בשפה זו במכשיר."
        case .internalState:
            return "שגיאה פנימית בהפעלת ההקלטה."
        case .emptyAppleTranscript:
            return "לא זוהה דיבור. נסה שוב."
        }
    }
}

// MARK: - WAV capture (for Whisper upload)

private final class WavAccumulator {
    private let sampleRate: Double
    private let channelCount: AVAudioChannelCount
    private var monoInt16: [Int16] = []

    init(sampleRate: Double, channelCount: AVAudioChannelCount) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let ch = Int(buffer.format.channelCount)
        guard ch >= 1, frames > 0 else { return }

        monoInt16.reserveCapacity(monoInt16.count + frames)
        for i in 0 ..< frames {
            var sum: Float = 0
            for c in 0 ..< ch {
                sum += src[c][i]
            }
            let m = sum / Float(ch)
            let clamped = max(-1, min(1, m))
            monoInt16.append(Int16(clamped * Float(Int16.max)))
        }
    }

    func finalizeWriting(to url: URL) throws {
        try WavFileWriter.writePCM16Mono(samples: monoInt16, sampleRate: sampleRate, to: url)
    }
}

private enum WavFileWriter {
    static func writePCM16Mono(samples: [Int16], sampleRate: Double, to url: URL) throws {
        let dataSize = samples.count * MemoryLayout<Int16>.size
        let headerSize = 44
        var data = Data(capacity: headerSize + dataSize)

        let sampleRateUInt = UInt32(sampleRate)
        let byteRate = UInt32(sampleRate) * 1 * 2
        let blockAlign: UInt16 = 1 * 2

        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(headerSize + dataSize - 8).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(sampleRateUInt.littleEndianData)
        data.append(byteRate.littleEndianData)
        data.append(blockAlign.littleEndianData)
        data.append(UInt16(16).littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(dataSize).littleEndianData)

        samples.withUnsafeBytes { raw in
            data.append(contentsOf: raw)
        }

        try data.write(to: url)
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
