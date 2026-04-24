import AVFoundation
import Foundation
import Speech

/// Debug-only console lines (filter Xcode console: `SpeechSTT`).
private func debugSpeechSTT(_ message: String) {
    #if DEBUG
    print("[SpeechSTT] \(message)")
    #endif
}

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
    private static let minimumWhisperAudioSeconds: Double = 1.2

    /// Whisper API language code (ISO 639-1) when not auto-detecting.
    private static let whisperLanguageCode = "he"

    private static func normalizedSpeechTextForDisplay(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastErrorMessage: String?

    private let whisperClient = WhisperTranscriptionClient()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var wavAccumulator: WavAccumulator?
    private var tapInstalled = false
    private var selectedLocale: Locale = .current
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionSessionId = UUID()

    private var onPartial: ((String) -> Void)?
    /// Invoked for each completed phrase while the mic stays on (Apple `isFinal`, or Whisper result). Session ends only on `endSession`, permission failure, or `cancelSession`.
    private var onFinished: ((Result<String, Error>) -> Void)?
    private var rollingWhisperDebounceTask: Task<Void, Never>?
    private var rollingWhisperRequestSequence = 0
    private var rollingWhisperLastDeliveredSequence = 0

    /// Stops recognition without delivering a result (user cancelled).
    func cancelSession() {
        rollingWhisperDebounceTask?.cancel()
        rollingWhisperDebounceTask = nil
        rollingWhisperRequestSequence = 0
        rollingWhisperLastDeliveredSequence = 0
        onPartial = nil
        onFinished = nil
        tearDownFullSession()
        phase = .idle
    }

    /// After committing a food line (Enter / add) while the mic stays on: end the current recognition request and start a new one so the next partials don’t repeat the previous utterance.
    func resetStreamingRecognitionAfterCommittedLine() {
        guard phase == .listening, tapInstalled, let rec = speechRecognizer else { return }
        rollingWhisperDebounceTask?.cancel()
        rollingWhisperDebounceTask = nil
        rollingWhisperRequestSequence = 0
        rollingWhisperLastDeliveredSequence = 0

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 13, *) {
            req.requiresOnDeviceRecognition = false
        }
        recognitionRequest = req
        installRecognitionTask(recognizer: rec, request: req)

        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        wavAccumulator = WavAccumulator(sampleRate: format.sampleRate, channelCount: format.channelCount)
    }

    /// «נקה» / clear command: drop accumulated recognition + WAV; if Whisper is running, cancel the whole session.
    func resetBuffersForClearCommand() {
        switch phase {
        case .listening:
            resetStreamingRecognitionAfterCommittedLine()
        case .transcribingRemote:
            cancelSession()
        case .idle:
            break
        }
    }

    /// - Parameters:
    ///   - onPartial: Streaming text from Apple STT.
    ///   - onFinished: Called for **each** finalized utterance (phrase) while dictation stays active; not only once at the end.
    func startListening(
        onPartial: @escaping (String) -> Void,
        onFinished: @escaping (Result<String, Error>) -> Void
    ) {
        lastErrorMessage = nil
        self.onPartial = onPartial
        self.onFinished = onFinished

        Task {
            await self.beginSession()
        }
    }

    private func beginSession() async {
        guard onFinished != nil else {
            tearDownFullSession()
            return
        }

        let speechAuth: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechAuth == .authorized else {
            endSession(.failure(SpeechServiceError.speechPermissionDenied))
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
            endSession(.failure(SpeechServiceError.microphonePermissionDenied))
            return
        }

        selectedLocale = preferredSpeechLocale()

        guard let recognizer = SFSpeechRecognizer(locale: selectedLocale), recognizer.isAvailable else {
            endSession(.failure(SpeechServiceError.recognizerUnavailable))
            return
        }
        speechRecognizer = recognizer

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if #available(iOS 13, *) {
                req.requiresOnDeviceRecognition = false
            }
            recognitionRequest = req

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            wavAccumulator = WavAccumulator(sampleRate: format.sampleRate, channelCount: format.channelCount)

            installRecognitionTask(recognizer: recognizer, request: req)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                self?.wavAccumulator?.append(buffer)
            }
            tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()
            phase = .listening
            debugSpeechSTT("session started Apple SFSpeechRecognizer locale=\(selectedLocale.identifier)")
        } catch {
            tearDownFullSession()
            endSession(.failure(error))
        }
    }

    private func installRecognitionTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest) {
        let sessionId = UUID()
        recognitionSessionId = sessionId
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.recognitionSessionId == sessionId else { return }
                self.handleRecognitionResult(result: result, error: error)
            }
        }
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if onFinished == nil { return }
        if phase == .transcribingRemote { return }

        if let error {
            debugSpeechSTT("Apple STT error (Apple-only mode) error=\(String(describing: error)) localized=\(error.localizedDescription)")
            deliverUtterance(.failure(error))
            resetStreamingRecognitionAfterCommittedLine()
            return
        }

        guard let result else { return }

        let transcription = result.bestTranscription.formattedString
        let isFinal = result.isFinal
        let confidence = averageSegmentConfidence(result.bestTranscription)
        let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)

        if !isFinal, shouldUsePartialWhisperFallback(confidence: confidence, trimmed: trimmed, transcription: result.bestTranscription) {
            debugSpeechSTT("Apple STT partial low confidence (\(confidence) < \(Self.confidenceThreshold)) -> rolling Whisper path appleText=\(String(reflecting: trimmed))")
            onPartial?(Self.normalizedSpeechTextForDisplay(trimmed))
            scheduleRollingWhisperUpload(appleFallbackText: trimmed)
            return
        }

        if !transcription.isEmpty {
            if isFinal {
                debugSpeechSTT("Apple STT final transcript=\(String(reflecting: transcription)) avgSegmentConfidence=\(confidence)")
            } else {
                debugSpeechSTT("Apple STT partial transcript=\(String(reflecting: transcription)) avgSegmentConfidence=\(confidence)")
            }
            onPartial?(Self.normalizedSpeechTextForDisplay(transcription))
        }

        if isFinal {
            if trimmed.isEmpty {
                debugSpeechSTT("Apple STT final empty after trim (Apple-only mode); resetting recognition")
                resetStreamingRecognitionAfterCommittedLine()
                return
            }

            if shouldUseWhisperFallback(confidence: confidence) {
                debugSpeechSTT("Apple STT low confidence (\(confidence) < \(Self.confidenceThreshold)) but Apple-only mode keeps Apple text")
                deliverUtterance(.success(trimmed))
                resetStreamingRecognitionAfterCommittedLine()
            } else {
                debugSpeechSTT("result using Apple built-in only text=\(String(reflecting: trimmed)) avgSegmentConfidence=\(confidence)")
                deliverUtterance(.success(trimmed))
                resetStreamingRecognitionAfterCommittedLine()
            }
        }
    }

    private func deliverUtterance(_ result: Result<String, Error>) {
        let delivered: Result<String, Error>
        switch result {
        case let .success(s):
            let normalized = Self.normalizedSpeechTextForDisplay(s)
            if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            delivered = .success(normalized)
        case let .failure(e):
            delivered = .failure(e)
        }
        onFinished?(delivered)
    }

    private func scheduleRollingWhisperUpload(appleFallbackText: String?) {
        rollingWhisperDebounceTask?.cancel()
        rollingWhisperDebounceTask = nil
        rollingWhisperRequestSequence += 1
        let seq = rollingWhisperRequestSequence
        rollingWhisperDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self.runRollingWhisperUpload(sequence: seq, appleFallbackText: appleFallbackText)
        }
    }

    private func runRollingWhisperUpload(sequence: Int, appleFallbackText: String?) async {
        guard onFinished != nil, phase == .listening else { return }
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("food_search_voice_rolling_\(UUID().uuidString).wav")

        do {
            try wavAccumulator?.writeSnapshot(to: wavURL)
            let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            guard size >= 512 else { return }
            if let seconds = wavDurationSeconds(at: wavURL), seconds < Self.minimumWhisperAudioSeconds { return }

            debugSpeechSTT("Rolling Whisper POST seq=\(sequence) audio bytes=\(size)")
            let whisperResult = try await whisperClient.transcribeAudioFile(
                at: wavURL,
                autoDetectLanguage: false,
                language: Self.whisperLanguageCode
            )
            try? FileManager.default.removeItem(at: wavURL)

            if let lang = whisperResult.language?.lowercased(), !lang.hasPrefix("he") {
                debugSpeechSTT("Rolling Whisper non-Hebrew lang=\(lang); suppressing")
                return
            }
            if !shouldAcceptRollingResult(whisperText: whisperResult.text, appleFallbackText: appleFallbackText) {
                debugSpeechSTT("Rolling Whisper suppressed low-quality replacement text=\(String(reflecting: whisperResult.text)) fallback=\(String(reflecting: appleFallbackText ?? ""))")
                return
            }
            guard sequence >= rollingWhisperLastDeliveredSequence else { return }
            rollingWhisperLastDeliveredSequence = sequence
            deliverUtterance(.success(whisperResult.text))
        } catch {
            debugSpeechSTT("Rolling Whisper failed seq=\(sequence) error=\(error.localizedDescription); fallback=\(String(reflecting: appleFallbackText ?? ""))")
        }
    }

    private func shouldAcceptRollingResult(whisperText: String, appleFallbackText: String?) -> Bool {
        let candidate = whisperText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        guard let fallback = appleFallbackText?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty else { return true }

        // If Apple partial already contains Hebrew and Whisper regression is digit-only (e.g. "1130"),
        // keep the Apple partial shown in UI.
        if containsHebrew(fallback), isMostlyDigits(candidate), !containsHebrew(candidate) {
            return false
        }
        return true
    }

    private func containsHebrew(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
    }

    private func isMostlyDigits(_ s: String) -> Bool {
        let cleaned = s.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return false }
        let digitCount = cleaned.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return Double(digitCount) / Double(cleaned.count) >= 0.7
    }

    /// After Whisper (or any path that called `stopRecordingCaptureOnly` + `tearDownFullSession`), deliver text and start a new listening session if the user is still in voice mode.
    private func deliverUtteranceAndResumeAfterRemote(_ result: Result<String, Error>) {
        deliverUtterance(result)
        guard onFinished != nil else { return }
        Task { @MainActor in
            await self.beginSession()
        }
    }

    private func shouldUseWhisperFallback(confidence: Float) -> Bool {
        _ = confidence
        return false
    }

    /// Partials often report `avgSegmentConfidence == 0` until segments exist; avoid treating that alone as “low confidence” for 1–2 characters.
    private func shouldUsePartialWhisperFallback(confidence: Float, trimmed: String, transcription: SFTranscription) -> Bool {
        _ = confidence
        _ = trimmed
        _ = transcription
        return false
    }

    private func averageSegmentConfidence(_ transcription: SFTranscription) -> Float {
        let segments = transcription.segments
        guard !segments.isEmpty else { return 0 }
        let sum = segments.reduce(0 as Float) { $0 + $1.confidence }
        return sum / Float(segments.count)
    }

    private func runWhisperUpload(appleFallbackText: String?, underlying: Error?, reason: String) async -> Result<String, Error> {
        defer {
            tearDownFullSession()
        }

        debugSpeechSTT("Whisper path start reason=\(reason)")

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("food_search_voice_\(UUID().uuidString).wav")

        do {
            try wavAccumulator?.finalizeWriting(to: wavURL)
            wavAccumulator = nil

            let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if size < 512 {
                debugSpeechSTT("Whisper skipped WAV too small (\(size) bytes); using fallback appleText=\(String(reflecting: appleFallbackText ?? "")) underlying=\(String(describing: underlying))")
                if let t = appleFallbackText, !t.isEmpty {
                    return .success(t)
                }
                return .failure(underlying ?? SpeechServiceError.emptyAppleTranscript)
            }
            if let seconds = wavDurationSeconds(at: wavURL), seconds < Self.minimumWhisperAudioSeconds {
                debugSpeechSTT("Whisper skipped WAV too short (\(String(format: "%.2f", seconds))s < \(Self.minimumWhisperAudioSeconds)s)")
                return .success("")
            }

            debugSpeechSTT("Whisper POST audio bytes=\(size)")
            let whisperResult = try await whisperClient.transcribeAudioFile(
                at: wavURL,
                autoDetectLanguage: false,
                language: Self.whisperLanguageCode
            )
            try? FileManager.default.removeItem(at: wavURL)
            debugSpeechSTT("Whisper result text=\(String(reflecting: whisperResult.text))")
            if let lang = whisperResult.language?.lowercased(), !lang.hasPrefix("he") {
                debugSpeechSTT("Whisper result language is non-Hebrew (\(lang)); suppressing output")
                return .success("")
            }
            return .success(whisperResult.text)
        } catch {
            debugSpeechSTT("Whisper request failed error=\(String(describing: error)) localized=\(error.localizedDescription); fallback appleText=\(String(reflecting: appleFallbackText ?? ""))")
            if let t = appleFallbackText, !t.isEmpty {
                debugSpeechSTT("delivering Apple fallback text to caller")
                return .success(t)
            }
            return .failure(error)
        }
    }

    private func wavDurationSeconds(at url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url), data.count >= 44 else { return nil }

        // WAV header: byteRate at offset 28 (UInt32 LE), data size at offset 40 (UInt32 LE).
        let byteRate = data.withUnsafeBytes { raw -> UInt32 in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            let b0 = UInt32(base[28])
            let b1 = UInt32(base[29]) << 8
            let b2 = UInt32(base[30]) << 16
            let b3 = UInt32(base[31]) << 24
            return b0 | b1 | b2 | b3
        }
        let dataSize = data.withUnsafeBytes { raw -> UInt32 in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            let b0 = UInt32(base[40])
            let b1 = UInt32(base[41]) << 8
            let b2 = UInt32(base[42]) << 16
            let b3 = UInt32(base[43]) << 24
            return b0 | b1 | b2 | b3
        }
        guard byteRate > 0 else { return nil }
        return Double(dataSize) / Double(byteRate)
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
        speechRecognizer = nil
        recognitionSessionId = UUID()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Ends voice mode: stops the mic and clears callbacks (permission errors, unrecoverable start failure, or future explicit “stop” APIs).
    private func endSession(_ result: Result<String, Error>) {
        guard onFinished != nil else { return }
        phase = .idle
        let callback = onFinished
        onPartial = nil
        onFinished = nil
        tearDownFullSession()

        if case let .failure(err) = result {
            lastErrorMessage = err.localizedDescription
        }

        let delivered: Result<String, Error>
        switch result {
        case let .success(s):
            delivered = .success(Self.normalizedSpeechTextForDisplay(s))
        case let .failure(e):
            delivered = .failure(e)
        }
        callback?(delivered)
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

    func writeSnapshot(to url: URL) throws {
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
