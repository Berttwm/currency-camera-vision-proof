import UIKit
import VisionKit
import Vision
import AVFoundation

@MainActor final class ScannerController: UIViewController, DataScannerViewControllerDelegate {
    private var scanner: DataScannerViewController?
    private var items: [RecognizedItem] = []
    private var reader: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var timer: Timer?
    private var record: ProofRecord?
    private var started: TimeInterval = 0
    private var epoch = 0
    private var mode = "currency"
    private var photoIndex = 0
    private var nextPhoto: TimeInterval = 6
    private var running = false
    private var starting = false
    private var generation = 0
    private var savedPhotos = ["currency": 0, "allText": 0]
    private let message = UILabel()
    private let action = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        message.text = "Live currency reader test\nRuns two camera modes for 80 seconds. No conversions or uploads."
        action.setTitle("Start test", for: .normal)
        action.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.running { self.stop(complete: false, reason: "Stopped by user") }
            else { Task { await self.start() } }
        }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [message, action])
        stack.axis = .vertical; stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        stack.backgroundColor = .secondarySystemBackground
        stack.layer.cornerRadius = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if ProcessInfo.processInfo.environment["CAMERA_GUARD_ONLY"] == "1" { guardProbe() }
    }

    private func metadata() -> [String: Any] {
        ["sourceRevision": Bundle.main.object(forInfoDictionaryKey: "ProofSourceRevision") as? String ?? "local",
         "runIdentity": Bundle.main.object(forInfoDictionaryKey: "ProofRunIdentity") as? String ?? "local",
         "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
         "isSupported": DataScannerViewController.isSupported, "isAvailable": DataScannerViewController.isAvailable,
         "quality": "accurate", "languages": [String](), "multipleItems": true, "highFrameRateTracking": true,
         "samplingSeconds": 0.5, "phaseSeconds": 40, "scope": "Currency filter versus all text; no price/conversion acceptance"]
    }

    private func guardProbe() {
        action.isEnabled = false
        do {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("guard-result.json")
            try JSONSerialization.data(withJSONObject: metadata(), options: [.sortedKeys]).write(to: file, options: .withoutOverwriting)
            action.isEnabled = false
            message.text = "Availability check saved. No camera or recognition test was run."
        } catch { message.text = "Availability check failed: \(error)" }
    }

    private func start() async {
        guard !running, !starting else { return }
        starting = true; generation += 1
        let attempt = generation
        action.isEnabled = false
        guard DataScannerViewController.isSupported else {
            message.text = "This device cannot run Apple's live reader. No camera test was run."
            starting = false; action.isEnabled = true; return
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard generation == attempt, starting else { return }
        guard allowed, view.window?.windowScene?.activationState == .foregroundActive,
              DataScannerViewController.isAvailable else {
            message.text = "Camera access is unavailable. Allow camera access in Settings before starting."
            starting = false; action.isEnabled = true; return
        }
        do {
            let parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            record = try ProofRecord(parent: parent, metadata: metadata())
            running = true; starting = false; mode = "currency"; photoIndex = 0
            savedPhotos = ["currency": 0, "allText": 0]; nextPhoto = 6; epoch = 0
            started = ProcessInfo.processInfo.systemUptime
            try beginScanner(currency: true)
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            action.setTitle("Stop and keep results", for: .normal)
            action.isEnabled = true
        } catch { stop(complete: false, reason: "Start failed: \(error)") }
    }

    private func beginScanner(currency: Bool) throws {
        reader?.cancel(); scanner?.stopScanning()
        scanner?.willMove(toParent: nil); scanner?.view.removeFromSuperview(); scanner?.removeFromParent()
        items = []; epoch += 1
        let mine = epoch
        let types: Set<DataScannerViewController.RecognizedDataType> = [
            .text(languages: [], textContentType: currency ? .currency : nil)]
        let next = DataScannerViewController(recognizedDataTypes: types, qualityLevel: .accurate,
            recognizesMultipleItems: true, isHighFrameRateTrackingEnabled: true, isPinchToZoomEnabled: false,
            isGuidanceEnabled: true, isHighlightingEnabled: true)
        next.delegate = self
        addChild(next); next.view.frame = view.bounds; next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(next.view, at: 0); next.didMove(toParent: self); scanner = next
        // Each scanner owns one stream consumer. A mode change creates a fresh scanner.
        reader = Task { [weak self, weak next] in
            guard let next else { return }
            for await found in next.recognizedItems {
                guard !Task.isCancelled, let self, self.running, self.epoch == mine else { return }
                self.items = found
            }
            if !Task.isCancelled, let self, self.running, self.epoch == mine {
                self.stop(complete: false, reason: "Native item stream ended before the test finished")
            }
        }
        try next.startScanning()
        guard running, scanner === next, let record else { throw RecordError.closed }
        try record.append(["type": "phase", "mode": mode, "epoch": epoch, "elapsed": elapsed()])
    }

    private func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }
    private func point(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }
    private func rect(_ r: CGRect) -> [String: Double] {
        ["x": Double(r.origin.x), "y": Double(r.origin.y), "width": Double(r.width), "height": Double(r.height)]
    }
    private func rows(detailed: Bool) -> [[String: Any]] {
        items.compactMap { item in
            guard case .text(let text) = item else { return nil }
            let b = text.bounds
            var row: [String: Any] = ["id": text.id.uuidString, "transcript": text.transcript,
                "viewQuad": [point(b.topLeft), point(b.topRight), point(b.bottomRight), point(b.bottomLeft)]]
            let candidates = text.observation.topCandidates(3)
            row["candidates"] = candidates.map { ["text": $0.string, "confidence": Double($0.confidence)] }
            if detailed {
                row["observationConfidence"] = Double(text.observation.confidence)
                row["observationBox"] = rect(text.observation.boundingBox)
                if let first = candidates.first {
                    let s = first.string
                    let regex = try! NSRegularExpression(pattern: #"\S+"#)
                    row["words"] = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { match -> [String: Any] in
                        let range = Range(match.range, in: s)!
                        var word: [String: Any] = ["text": String(s[range]), "startUTF16": match.range.location,
                            "lengthUTF16": match.range.length, "confidence": Double(first.confidence), "scope": "observation-first-candidate"]
                        do {
                            if let box = try first.boundingBox(for: range) {
                                word["normalizedBox"] = rect(box.boundingBox)
                                word["normalizedQuad"] = [point(box.topLeft), point(box.topRight), point(box.bottomRight), point(box.bottomLeft)]
                            } else { word["geometryError"] = "No returned substring box" }
                        } catch { word["geometryError"] = String(describing: error) }
                        return word
                    }
                }
            }
            return row
        }
    }

    private func tick() {
        guard running else { return }
        let seconds = elapsed()
        guard DataScannerViewController.isAvailable else {
            stop(complete: false, reason: "Native camera became unavailable"); return
        }
        if seconds >= 80 {
            stop(complete: savedPhotos["currency"] == 4 && savedPhotos["allText"] == 4 && epoch == 2 && photoTask == nil,
                 reason: "Timed capture ended; accuracy has not been scored"); return
        }
        do {
            if seconds >= 40, mode == "currency" {
                guard photoTask == nil, savedPhotos["currency"] == 4 else {
                    stop(complete: false, reason: "Currency phase did not save all four photos before its boundary"); return
                }
                mode = "allText"; try beginScanner(currency: false)
            }
            try record?.append(["type": "snapshot", "mode": mode, "epoch": epoch, "elapsed": seconds,
                "at": Date().timeIntervalSince1970, "viewBounds": rect(scanner?.view.bounds ?? .zero), "items": rows(detailed: false)])
            message.text = "\(mode == "currency" ? "Currency filter" : "All text") · \(Int(80 - seconds)) seconds left\n\(items.count) matches. Images and text stay on this iPhone."
            if seconds >= nextPhoto, photoTask == nil {
                guard seconds < nextPhoto + 3 else {
                    stop(complete: false, reason: "Missed a scheduled photo window"); return
                }
                let scheduled = nextPhoto; nextPhoto += 10; capture(scheduledAt: scheduled)
            }
        } catch { stop(complete: false, reason: "Recording failed: \(error)") }
    }

    private func capture(scheduledAt: Double) {
        guard let scanner, let record else { return }
        let beforeAt = Date().timeIntervalSince1970
        let before = rows(detailed: true), captureEpoch = epoch, captureMode = mode, index = photoIndex
        photoIndex += 1
        let captureGeneration = generation
        let viewBounds = rect(scanner.view.bounds)
        photoTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == captureGeneration { self.photoTask = nil } }
            do {
                guard !Task.isCancelled, self.running, self.generation == captureGeneration,
                      self.epoch == captureEpoch, self.record === record else { return }
                let beganElapsed = self.elapsed(), begin = Date().timeIntervalSince1970
                guard beganElapsed >= scheduledAt, beganElapsed < scheduledAt + 3 else { throw RecordError.missedWindow }
                let image = try await scanner.capturePhoto()
                guard !Task.isCancelled, self.running, self.generation == captureGeneration,
                      self.epoch == captureEpoch, self.record === record else { return }
                guard let data = image.jpegData(compressionQuality: 0.95) else { throw RecordError.encoding }
                var photo = try record.photo(data, index: index)
                photo.merge(["type": "photo", "mode": captureMode, "epoch": captureEpoch, "beganAt": begin,
                    "finishedAt": Date().timeIntervalSince1970, "scheduledElapsed": scheduledAt, "beganElapsed": beganElapsed,
                    "finishedElapsed": self.elapsed(), "viewBounds": viewBounds,
                    "imageOrientation": image.imageOrientation.rawValue,
                    "pixelWidth": image.cgImage?.width ?? 0, "pixelHeight": image.cgImage?.height ?? 0,
                    "imageSize": [Double(image.size.width), Double(image.size.height)], "scale": Double(image.scale),
                    "beforeItems": before, "beforeItemsAt": beforeAt, "afterEpoch": self.epoch,
                    "afterItems": self.epoch == captureEpoch ? self.rows(detailed: true) : [],
                    "alignment": "Photo output and item observations are not guaranteed frame-synchronized or identically cropped"], uniquingKeysWith: { _, new in new })
                try record.append(photo)
                self.savedPhotos[captureMode, default: 0] += 1
            } catch {
                guard self.running, self.generation == captureGeneration, self.record === record else { return }
                try? record.append(["type": "photoError", "mode": captureMode, "epoch": captureEpoch, "index": index,
                                    "error": String(describing: error)])
                self.stop(complete: false, reason: "Photo evidence failed: \(error)")
            }
        }
    }

    func stop(complete: Bool, reason: String) {
        guard running || starting || record != nil else { return }
        let finished = complete && photoTask == nil && savedPhotos["currency"] == 4 && savedPhotos["allText"] == 4 && epoch == 2
        generation += 1; running = false; starting = false
        timer?.invalidate(); timer = nil; reader?.cancel(); reader = nil
        photoTask?.cancel(); photoTask = nil
        scanner?.stopScanning()
        scanner?.willMove(toParent: nil); scanner?.view.removeFromSuperview(); scanner?.removeFromParent(); scanner = nil
        items = []
        do {
            try record?.finish(complete: finished, reason: reason)
            message.text = record == nil ? reason : "\(finished ? "Capture saved" : "Partial test kept") on this iPhone.\n\(reason)"
        } catch { message.text = "Partial files kept; final save failed: \(error)" }
        record = nil
        action.setTitle("Start another test", for: .normal); action.isEnabled = true
    }

    func interrupted(background: Bool) {
        // The owner permission prompt can make the scene inactive before a run starts.
        if running || (background && starting) { stop(complete: false, reason: "App left the foreground") }
    }

    func dataScanner(_ dataScanner: DataScannerViewController,
                     becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        guard scanner === dataScanner else { return }
        stop(complete: false, reason: "Native camera interrupted: \(error)")
    }
}
