import AVFoundation
import Foundation
import Speech

/// Records a visit with the phone's own recorder, so it keeps going with the
/// screen locked or another app open, then transcribes it on the phone.
///
/// The transcript is handed to the log page, where the Visit Scribe agent
/// drafts the visit note from it. Until the page confirms it has the
/// transcript, it is kept here, so nothing is lost if the page was closed
/// or the app was quit mid-way. The audio file is deleted once the page has it.
@MainActor
final class VisitRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var patientName = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var statusText: String?

    /// Sends an event to the log page.
    var send: (([String: Any]) -> Void)?

    private var recorder: AVAudioRecorder?
    private var vid = ""
    private var timer: Timer?
    private var transcribing = Set<String>()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    struct Item: Codable {
        var id: String
        var vid: String
        var name: String
        var seconds: Double
        var at: String
        var file: String
        var text: String?
        var failed: String?
    }
    private var items: [Item] = []
    private static let storeKey = "fvl.recordings"

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true      // patient audio stays on this phone
        var d = dir
        try? d.setResourceValues(values)
        return dir
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.interrupted(ended: raw == AVAudioSession.InterruptionType.ended.rawValue) }
        }
        // anything the app was quit in the middle of transcribing
        for item in items where item.text == nil && item.failed == nil {
            transcribe(item)
        }
    }

    // MARK: - Recording

    func start(vid: String, name: String) {
        if isRecording {
            send?(["type": "error", "vid": vid, "message": "Already recording \(patientName). Stop that one first."])
            return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            Task { @MainActor in
                if granted {
                    self.begin(vid: vid, name: name)
                } else {
                    self.send?(["type": "error", "vid": vid,
                                "message": "The microphone is off for Visit Log. Turn it on in Settings › Visit Log."])
                }
            }
        }
    }

    private func begin(vid: String, name: String) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let safe = vid.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "", options: .regularExpression)
            let url = Self.folder.appendingPathComponent("\(safe)-\(Int(Date().timeIntervalSince1970)).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else {
                send?(["type": "error", "vid": vid, "message": "The recorder wouldn't start. Try again."])
                return
            }
            recorder = r
            self.vid = vid
            patientName = name
            elapsed = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    self.elapsed = r.currentTime
                }
            }
            send?(["type": "started", "vid": vid, "seconds": 0])
        } catch {
            send?(["type": "error", "vid": vid, "message": "The recorder wouldn't start: \(error.localizedDescription)"])
        }
    }

    func stop() {
        guard let r = recorder else { return }
        let seconds = r.currentTime
        let file = r.url.lastPathComponent
        r.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let item = Item(id: UUID().uuidString, vid: vid, name: patientName, seconds: seconds,
                        at: ISO8601DateFormatter().string(from: Date()), file: file)
        items.append(item)
        save()
        send?(["type": "stopped", "vid": vid, "seconds": seconds])
        transcribe(item)
    }

    /// A phone call or Siri pauses the recording; pick it back up afterwards.
    private func interrupted(ended: Bool) {
        guard isRecording, let r = recorder else { return }
        if ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            r.record()
        }
    }

    /// Tells a page that just loaded whether a recording is running.
    func status() {
        if isRecording {
            send?(["type": "started", "vid": vid, "seconds": recorder?.currentTime ?? 0])
        }
    }

    // MARK: - Transcripts

    /// Hands the page every transcript it hasn't confirmed yet, and retries
    /// any that failed.
    func deliverPending() {
        for item in items {
            if let text = item.text {
                send?(["type": "transcript", "id": item.id, "vid": item.vid, "name": item.name,
                       "text": text, "seconds": item.seconds, "at": item.at])
            } else if !transcribing.contains(item.id) {
                var retry = item
                retry.failed = nil
                update(retry)
                transcribe(retry)
            }
        }
    }

    func acknowledge(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(item.file))
        items.removeAll { $0.id == id }
        save()
    }

    private func transcribe(_ item: Item) {
        guard !transcribing.contains(item.id) else { return }
        transcribing.insert(item.id)
        statusText = "Transcribing \(item.name)…"
        SFSpeechRecognizer.requestAuthorization { auth in
            Task { @MainActor in
                guard auth == .authorized else {
                    self.finish(item, text: nil,
                                error: "Speech recognition is off for Visit Log. Turn it on in Settings › Visit Log.")
                    return
                }
                do {
                    let text = try await self.transcribeFile(Self.folder.appendingPathComponent(item.file))
                    self.finish(item, text: text, error: nil)
                } catch {
                    self.finish(item, text: nil, error: "Couldn't transcribe the recording: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finish(_ item: Item, text: String?, error: String?) {
        transcribing.remove(item.id)
        if transcribing.isEmpty { statusText = nil }
        var done = item
        done.text = text
        done.failed = error
        update(done)
        if let text {
            send?(["type": "transcript", "id": item.id, "vid": item.vid, "name": item.name,
                   "text": text, "seconds": item.seconds, "at": item.at])
        } else {
            send?(["type": "error", "vid": item.vid,
                   "message": (error ?? "Transcription failed") + " The recording is kept on the phone and will be tried again."])
        }
    }

    /// Speech recognition takes about a minute of audio at a time, so a long
    /// visit is cut into pieces, each transcribed in turn, then joined.
    private func transcribeFile(_ url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return "" }
        let step = 50.0
        var parts: [String] = []
        var start = 0.0
        while start < duration {
            let length = min(step, duration - start)
            let piece = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw NSError(domain: "VisitRecorder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "couldn't read the audio"])
            }
            export.outputURL = piece
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           duration: CMTime(seconds: length, preferredTimescale: 600))
            await export.export()
            defer { try? FileManager.default.removeItem(at: piece) }
            guard export.status == .completed else {
                throw export.error ?? NSError(domain: "VisitRecorder", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: "couldn't cut the audio"])
            }
            let text = try await recognize(piece)
            if !text.isEmpty { parts.append(text) }
            start += step
        }
        return parts.joined(separator: " ")
    }

    private func recognize(_ url: URL) async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "VisitRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "speech recognition isn't available right now"])
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        // keep patient audio on the phone when the phone can do it itself
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if resumed { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    let code = (error as NSError).code
                    // 1110 / 203: nothing said in this stretch, which is fine
                    if code == 1110 || code == 203 {
                        continuation.resume(returning: "")
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Storage

    private func update(_ item: Item) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
