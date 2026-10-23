import Foundation
import Vision
import CoreGraphics
import CoreText
import PDFKit
import CryptoKit
import DataDetection

struct Source: Codable {
    let id: String, url: URL, sha256: String
    let page: Int, width: Int, height: Int
}
struct ProofError: Error, CustomStringConvertible { let description: String }
func require(_ valid: Bool, _ message: String) throws {
    if !valid { throw ProofError(description: message) }
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func supportsLanguages(_ requested: [String], _ available: [String]) -> Bool {
    let canonical: (String) -> String = { Locale.canonicalLanguageIdentifier(from: $0) }
    return Set(requested.map(canonical)).isSubset(of: Set(available.map(canonical)))
}
func jsonData(_ value: [String: Any]) throws -> Data {
    let pretty = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    let lines = String(decoding: pretty, as: UTF8.self).components(separatedBy: "\n")
    let unindented = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    return Data(unindented.joined(separator: "\n").utf8)
}
func rectJSON(_ r: CGRect) -> [String: Double] {
    ["x0": Double(r.minX), "y0": Double(r.minY), "x1": Double(r.maxX), "y1": Double(r.maxY)]
}
func topLeft(_ r: CGRect, _ width: Int, _ height: Int) -> CGRect {
    CGRect(x: r.minX * CGFloat(width), y: (1-r.maxY) * CGFloat(height),
           width: r.width * CGFloat(width), height: r.height * CGFloat(height))
}
func quadJSON(_ box: VNRectangleObservation, _ width: Int, _ height: Int) -> [[String: Double]] {
    let points: [CGPoint] = [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft]
    return points.map { point -> [String: Double] in
        let x: Double = Double(point.x) * Double(width)
        let y: Double = (1.0 - Double(point.y)) * Double(height)
        return ["x": x, "y": y]
    }
}
func render(_ data: Data, pageNumber: Int, width: Int, height: Int) throws -> (CGImage, [String: Any]) {
    guard let provider = CGDataProvider(data: data as CFData),
          let document = CGPDFDocument(provider), let page = document.page(at: pageNumber),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ProofError(description: "Cannot open page or allocate bitmap") }
    let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
    let rotated = abs(Int(page.rotationAngle)) % 180 == 90
    let displayWidth = rotated ? box.height : box.width
    let displayHeight = rotated ? box.width : box.height
    try require(displayWidth > 0 && displayHeight > 0, "Invalid page dimensions")
    try require(abs(Double(width)/Double(height) - Double(displayWidth/displayHeight)) < 0.003, "Manifest/page aspect mismatch")
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
    context.clip(to: bounds)
    // Quartz's PDF fitting transform only reduces pages; map to a unit rect, then enlarge explicitly.
    let edge = CGFloat(max(width, height))
    let unitRect = CGRect(x: 0, y: 0, width: bounds.width/edge, height: bounds.height/edge)
    let pdfTransform = page.getDrawingTransform(.cropBox, rect: unitRect, rotate: 0, preserveAspectRatio: true)
    context.scaleBy(x: edge, y: edge)
    context.concatenate(pdfTransform)
    let drawingTransform = context.ctm
    context.drawPDFPage(page)
    guard let image = context.makeImage(), let bytes = context.data else { throw ProofError(description: "Cannot make rendered image") }
    return (image, ["width": width, "height": height, "rotation": page.rotationAngle,
                    "cropBox": rectJSON(box), "renderer": "Quartz; differs from Poppler",
                    "drawingTransform": ["a": Double(drawingTransform.a), "b": Double(drawingTransform.b),
                                         "c": Double(drawingTransform.c), "d": Double(drawingTransform.d),
                                         "tx": Double(drawingTransform.tx), "ty": Double(drawingTransform.ty)],
                    "pixelFormat": "RGBA8-premultiplied-last", "bytesPerRow": width*4,
                    "pixelSha256": hash(Data(bytes: bytes, count: width*height*4))])
}
func recognize(_ image: CGImage) throws -> ([String: Any], [[String: Any]]) {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    request.minimumTextHeight = 0
    // Uniform baseline: leave the SDK's language selection and correction settings untouched.
    let languages = request.recognitionLanguages
    let automaticLanguage = request.automaticallyDetectsLanguage
    let languageCorrection = request.usesLanguageCorrection
    let supported = try request.supportedRecognitionLanguages()
    try require(supportsLanguages(languages, supported), "Default language unavailable; no silent substitution. Defaults=\(languages); supported=\(supported); automatic=\(automaticLanguage); correction=\(languageCorrection)")
    let started = Date()
    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
    let regex = try NSRegularExpression(pattern: #"\S+"#)
    var lines: [[String: Any]] = []
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else {
            lines.append(["error": "Observation has no candidate"]); continue
        }
        let text = candidate.string
        var words: [[String: Any]] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { throw ProofError(description: "Invalid UTF16 range") }
            var word: [String: Any] = ["text": String(text[range]), "startUTF16": match.range.location,
                                      "lengthUTF16": match.range.length, "confidence": candidate.confidence,
                                      "confidenceScope": "line-top-candidate"]
            do {
                if let box = try candidate.boundingBox(for: range) {
                    word["bbox"] = rectJSON(topLeft(box.boundingBox, image.width, image.height))
                    word["normalizedBox"] = rectJSON(box.boundingBox)
                    word["quad"] = quadJSON(box, image.width, image.height)
                } else { word["geometryError"] = "No substring box" }
            } catch { word["geometryError"] = String(describing: error) }
            words.append(word)
        }
        lines.append(["text": text, "confidence": candidate.confidence,
                      "normalizedBox": rectJSON(observation.boundingBox),
                      "quad": quadJSON(observation, image.width, image.height),
                      "bbox": rectJSON(topLeft(observation.boundingBox, image.width, image.height)), "words": words])
    }
    return (["revision": request.revision, "recognitionLevel": "accurate", "automaticallyDetectsLanguage": automaticLanguage,
             "usesLanguageCorrection": languageCorrection, "minimumTextHeight": request.minimumTextHeight,
             "languagePolicy": "SDK defaults; captured before recognition",
             "languages": languages, "supportedLanguages": supported,
             "geometryPrecision": "vision-word-approximate", "confidenceScale": "native 0..1; uncalibrated",
             "recognitionMs": Date().timeIntervalSince(started) * 1000], lines)
}
func selfTest() throws {
    func checkedRender(_ data: Data, pageNumber: Int, width: Int, height: Int) throws -> (CGImage, [String: Any]) {
        let (image, info) = try render(data, pageNumber: pageNumber, width: width, height: height)
        guard let pixels = image.dataProvider?.data, let expected = info["pixelSha256"] as? String else {
            throw ProofError(description: "No synthetic pixels")
        }
        return (try rawImage(pixels as Data, width: width, height: height, stride: width * 4, expectedHash: expected), info)
    }
    try require(supportsLanguages(["en_US"], ["en-US"]), "Equivalent language identifiers rejected")
    try require(!supportsLanguages(["en_AU"], ["en-US"]) && !supportsLanguages(["de-DE"], ["en-US"]), "Unsupported language accepted")
    let sample = "  quoted \"value\" \n café  "
    let sampleData = try jsonData(["text": sample])
    let roundTrip = try JSONSerialization.jsonObject(with: sampleData) as? [String: String]
    try require(roundTrip?["text"] == sample, "JSON formatting changed recognized text")
    let output = NSMutableData()
    var media = CGRect(x: 0, y: 0, width: 600, height: 400)
    guard let consumer = CGDataConsumer(data: output as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &media, nil)
    else { throw ProofError(description: "Cannot create test PDF") }
    pdf.beginPDFPage(nil)
    pdf.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); pdf.fill(CGRect(x: 0, y: 360, width: 40, height: 40))
    pdf.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); pdf.fill(CGRect(x: 560, y: 0, width: 40, height: 40))
    for (text, point) in [("TOP USD 12.50", CGPoint(x: 60, y: 330)), ("BOTTOM USD 7.25", CGPoint(x: 260, y: 40))] {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 28, nil)])
        pdf.textPosition = point; CTLineDraw(CTLineCreateWithAttributedString(attributed), pdf)
    }
    pdf.endPDFPage(); pdf.closePDF()
    let original = output as Data
    let (enlarged, enlargedInfo) = try checkedRender(original, pageNumber: 1, width: 1200, height: 800)
    guard let enlargedBytes = enlarged.dataProvider?.data, let enlargedPointer = CFDataGetBytePtr(enlargedBytes)
    else { throw ProofError(description: "No enlarged pixels") }
    let corner = 40*enlarged.bytesPerRow + 40*4, opposite = 760*enlarged.bytesPerRow + 1160*4
    try require(enlargedPointer[corner] > 240 && enlargedPointer[corner+2] < 20 && enlargedPointer[opposite] < 20 && enlargedPointer[opposite+2] > 240,
                "PDF enlargement failed; transform=\(enlargedInfo["drawingTransform"]!)")
    let (image, _) = try checkedRender(original, pageNumber: 1, width: 600, height: 400)
    let (_, lines) = try recognize(image)
    for (value, isTop) in [("12.50", true), ("7.25", false)] {
        guard let line = lines.first(where: { ($0["text"] as? String)?.contains(value) == true }),
              let box = line["bbox"] as? [String: Double], let y0 = box["y0"], let y1 = box["y1"]
        else { throw ProofError(description: "Synthetic OCR failed for \(value)") }
        try require(((y0+y1)/2 < 200) == isTop, "Vertical origin is incorrect")
    }
    guard let rotatedPDF = PDFDocument(data: original), let page = rotatedPDF.page(at: 0) else { throw ProofError(description: "Cannot reopen test PDF") }
    page.rotation = 90
    guard let rotatedData = rotatedPDF.dataRepresentation() else { throw ProofError(description: "Cannot rotate test PDF") }
    let (rotated, _) = try checkedRender(rotatedData, pageNumber: 1, width: 400, height: 600)
    guard let bytes = rotated.dataProvider?.data, let pointer = CFDataGetBytePtr(bytes) else { throw ProofError(description: "No rotated pixels") }
    let red = 20*rotated.bytesPerRow + 380*4, blue = 580*rotated.bytesPerRow + 20*4
    try require(pointer[red] > 240 && pointer[red+2] < 20 && pointer[blue] < 20 && pointer[blue+2] > 240, "PDF rotation is incorrect")
}

func languageDefaults() -> [String: Any] {
    let request = VNRecognizeTextRequest()
    return ["languages": request.recognitionLanguages,
            "automaticallyDetectsLanguage": request.automaticallyDetectsLanguage,
            "usesLanguageCorrection": request.usesLanguageCorrection]
}

func rawImage(_ pixels: Data, width: Int, height: Int, stride: Int, expectedHash: String) throws -> CGImage {
    try require(width > 0 && height > 0 && width <= 2600 && height <= 2600 && stride == width * 4, "Invalid raw dimensions")
    try require(pixels.count == stride * height && hash(pixels) == expectedHash, "Raw input byte identity failed")
    guard let provider = CGDataProvider(data: pixels as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let roundTrip = image.dataProvider?.data else { throw ProofError(description: "Cannot reconstruct pixels") }
    try require(hash(roundTrip as Data) == expectedHash, "Reconstructed byte identity failed")
    return image
}

// Both platforms read these exact runner-generated bytes; UIKit never resizes a menu.
func recognizeInputs(_ directory: URL, defaults: [String: Any], platform: String) throws -> [String: Any] {
    let data = try Data(contentsOf: directory.appendingPathComponent("inputs.json"))
    let sources = try JSONDecoder().decode([Source].self, from: Data(contentsOf: directory.appendingPathComponent("sources.json")))
    guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pages = input["pages"] as? [[String: Any]], let runIdentity = input["runIdentity"] as? String else { throw ProofError(description: "Invalid inputs") }
    try require(runIdentity.range(of: #"^\d+-\d+$"#, options: .regularExpression) != nil, "Invalid run identity")
    try require(input["renderScale"] as? Int == 2 && input["colorSpace"] as? String == "DeviceRGB", "Unexpected pixel policy")
    try require(pages.count == 3 && sources.count == 3 && Set(pages.compactMap { $0["id"] as? String }).count == 3, "Expected three distinct inputs")
    var results: [[String: Any]] = []
    for page in pages {
        guard let id = page["id"] as? String, let source = sources.first(where: { $0.id == id }),
              let info = page["render"] as? [String: Any], let width = info["width"] as? Int,
              let height = info["height"] as? Int, let stride = info["bytesPerRow"] as? Int,
              let expected = info["pixelSha256"] as? String else { throw ProofError(description: "Incomplete input") }
        try require(id.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil, "Invalid input id")
        try require(page["url"] as? String == source.url.absoluteString && page["sourceSha256"] as? String == source.sha256 && page["page"] as? Int == source.page, "Source identity mismatch")
        try require(width > 0 && height > 0 && max(width, height) == 2600 && width == source.width * 2 && height == source.height * 2 && stride == width * 4, "Unexpected dimensions")
        try require(info["pixelFormat"] as? String == "RGBA8-premultiplied-last", "Unexpected pixel layout")
        let pixels = try Data(contentsOf: directory.appendingPathComponent(id + ".rgba"))
        let image = try rawImage(pixels, width: width, height: height, stride: stride, expectedHash: expected)
        let (config, lines) = try recognize(image)
        for key in ["languages", "automaticallyDetectsLanguage", "usesLanguageCorrection"] {
            try require(NSDictionary(dictionary: [key: config[key]!]).isEqual(to: [key: defaults[key]!]), "SDK defaults changed during run")
        }
        var result = page
        result["request"] = config; result["lines"] = lines
        result["inputBytesVerified"] = true
        results.append(result)
    }
    return ["complete": true, "scope": "Static identical-pixel comparison; no camera or physical-device result",
            "platform": platform, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? Bundle.main.object(forInfoDictionaryKey: "ProofSourceRevision") as? String ?? "local",
            "runIdentity": runIdentity, "inputManifestSha256": hash(data),
            "renderScale": 2, "colorSpace": "DeviceRGB", "defaultsCapturedBeforeInputRead": true,
            "sdkLanguageDefaults": defaults, "pages": results]
}

// Diagnostic only: scan unchanged recognized strings, without inventing currency/price context.
@available(macOS 26.0, iOS 26.0, *)
func semanticProbe(_ result: [String: Any]) async -> [String: Any] {
    let started = Date()
    let controls = ["Coffee GBP 2.00", "Coffee 2.00", "Coffee 2", "ADD EGG 2.00", "USD 12.50",
                    "Coffee 12.50", "SINCE 1914", "Quantity 2", "Weight 330 g", "Volume 330 ml",
                    "Calories 330", "Phone +65 6123 4567", "Open 09:00-17:00", "Tax 9%",
                    "Protein 12.50 g", "Coffee SGD 12.50", "Coffee USD 12O", "SINCE 191 A", "Serves 2", "Add 2 eggs"]
    var inputs: [(String, Int, String)] = controls.enumerated().map { ("synthetic-control", $0.offset, $0.element) }
    for page in result["pages"] as? [[String: Any]] ?? [] {
        for (index, line) in (page["lines"] as? [[String: Any]] ?? []).enumerated() {
            if let id = page["id"] as? String, let text = line["text"] as? String { inputs.append((id, index, text)) }
        }
    }
    var records: [[String: Any]] = []
    for (id, index, text) in inputs {
        var matches: [[String: Any]] = []
        for await match in text.dataDetectorMatches(.all) {
            var item: [String: Any] = [:]
            switch match.details {
            case .moneyAmount(let money):
                item = ["kind": "money", "amount": NSDecimalNumber(decimal: money.amount).stringValue, "currency": money.currency.identifier]
            case .measurement: item["kind"] = "measurement"
            case .calendarEvent: item["kind"] = "calendar"
            case .phoneNumber: item["kind"] = "phone"
            default: item["kind"] = "other"
            }
            if let range = match.range {
                let span = NSRange(range, in: text)
                item["text"] = String(text[range]); item["startUTF16"] = span.location; item["lengthUTF16"] = span.length
            }
            matches.append(item)
        }
        records.append(["id": id, "lineIndex": index, "text": text, "matches": matches])
    }
    return ["scope": "Mac string-only diagnostic, not price classification or iOS/phone semantics",
            "options": "SDK defaults; no document-language, region or currency hint supplied",
            "locale": Locale.current.identifier, "currencyWarning": "Detected currency may be a best guess; never substitutes for selected currency",
            "elapsedMs": Date().timeIntervalSince(started) * 1000, "records": records]
}

// Separate layout diagnostic. It never supplies price labels to the baseline parser.
func documentControl() throws -> (CGImage, [String: Any]) {
    let data = NSMutableData()
    var media = CGRect(x: 0, y: 0, width: 600, height: 400)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let pdf = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw ProofError(description: "Cannot create document control") }
    pdf.beginPDFPage(nil)
    pdf.setFillColor(CGColor(gray: 1, alpha: 1)); pdf.fill(media)
    pdf.setStrokeColor(CGColor(gray: 0, alpha: 1)); pdf.setLineWidth(1)
    for x in [30, 280, 420, 570] { pdf.move(to: CGPoint(x: x, y: 130)); pdf.addLine(to: CGPoint(x: x, y: 320)) }
    for y in [130, 190, 250, 320] { pdf.move(to: CGPoint(x: 30, y: y)); pdf.addLine(to: CGPoint(x: 570, y: y)) }
    pdf.strokePath()
    let labels: [(String, CGFloat, CGFloat)] = [
        ("TOP CONTROL GBP 12.50", 35, 355), ("Item", 45, 280), ("Price GBP", 290, 280), ("Weight g", 430, 280),
        ("Coffee", 45, 215), ("2.50", 295, 215), ("330", 435, 215),
        ("Tea", 45, 155), ("3.00", 295, 155), ("250", 435, 155), ("BOTTOM CONTROL SINCE 1914", 35, 35)]
    for (text, x, y) in labels {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil)])
        pdf.textPosition = CGPoint(x: x, y: y); CTLineDraw(CTLineCreateWithAttributedString(attributed), pdf)
    }
    pdf.endPDFPage(); pdf.closePDF()
    return try render(data as Data, pageNumber: 1, width: 1200, height: 800)
}

@available(macOS 26.0, iOS 26.0, *)
func documentRegion(_ region: NormalizedRegion, width: Int, height: Int) -> [String: Any] {
    let points = region.normalizedPoints
    var value: [String: Any] = ["normalizedPolygon": points.map { ["x": Double($0.x), "y": Double($0.y)] }]
    if let x0 = points.map({ Double($0.x) }).min(), let x1 = points.map({ Double($0.x) }).max(),
       let y0 = points.map({ Double($0.y) }).min(), let y1 = points.map({ Double($0.y) }).max() {
        let box = CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0)
        value["normalizedBox"] = rectJSON(box); value["bbox"] = rectJSON(topLeft(box, width, height))
    } else { value["geometryError"] = "Empty returned polygon" }
    return value
}

@available(macOS 26.0, iOS 26.0, *)
func documentRead(_ image: CGImage) async throws -> [String: Any] {
    let request = RecognizeDocumentsRequest()
    let options = request.textRecognitionOptions
    let config: [String: Any] = [
        "policy": "SDK defaults; getters captured before inference; no options assigned",
        "revision": String(describing: request.revision), "supportedRevisions": RecognizeDocumentsRequest.supportedRevisions.map { String(describing: $0) },
        "supportedLanguages": request.supportedRecognitionLanguages.map { $0.minimalIdentifier },
        "languages": options.recognitionLanguages.map { $0.minimalIdentifier }, "automaticallyDetectLanguage": options.automaticallyDetectLanguage,
        "useLanguageCorrection": options.useLanguageCorrection, "customWords": options.customWords,
        "maximumCandidateCount": options.maximumCandidateCount, "minimumTextHeightFraction": options.minimumTextHeightFraction,
        "compute": request.supportedComputeStageDevices.map { stage, devices in
            ["stage": String(describing: stage), "supported": devices.map { String(describing: $0) },
             "assigned": request.computeDevice(for: stage).map { String(describing: $0) } ?? "unassigned"] as [String: Any]
        }]
    let started = Date()
    let observations = try await request.perform(on: image, orientation: .up)
    let regex = try NSRegularExpression(pattern: #"\S+"#)
    func lineJSON(_ observation: RecognizedTextObservation, substrings: Bool) throws -> [String: Any] {
        let candidates = observation.topCandidates(options.maximumCandidateCount)
        var value = documentRegion(observation.boundingRegion, width: image.width, height: image.height)
        value["text"] = observation.transcript; value["observationConfidence"] = observation.confidence
        value["candidates"] = candidates.map { ["text": $0.string, "confidence": $0.confidence] }
        if substrings, let candidate = candidates.first {
            let text = candidate.string
            var words: [[String: Any]] = []
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { throw ProofError(description: "Document candidate UTF16 range invalid") }
                var word: [String: Any] = ["text": String(text[range]), "startUTF16": match.range.location, "lengthUTF16": match.range.length,
                                           "confidence": candidate.confidence, "confidenceScope": "line-top-candidate"]
                if let box = candidate.boundingBox(for: range) {
                    let normalized = box.boundingBox.cgRect
                    word["normalizedBox"] = rectJSON(normalized); word["bbox"] = rectJSON(topLeft(normalized, image.width, image.height))
                    word["normalizedQuad"] = [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft].map { ["x": Double($0.x), "y": Double($0.y)] }
                } else { word["geometryError"] = "No returned candidate substring box" }
                words.append(word)
            }
            value["words"] = words
        }
        return value
    }
    func entities(_ owner: DocumentObservation.Container.Text) -> [[String: Any]] {
        let transcript = owner.transcript
        let detected = owner.detectedData // Computed once per owner, never once per number.
        return detected.map { entity in
            var value = documentRegion(entity.boundingRegion, width: image.width, height: image.height)
            switch entity.match.details {
            case .moneyAmount(let money): value["kind"] = "money"; value["amount"] = NSDecimalNumber(decimal: money.amount).stringValue; value["currency"] = money.currency.identifier
            case .measurement: value["kind"] = "measurement"
            case .calendarEvent: value["kind"] = "calendar"
            case .phoneNumber: value["kind"] = "phone"
            default: value["kind"] = "other"
            }
            if let range = entity.match.range {
                let span = NSRange(range, in: transcript)
                value["text"] = String(transcript[range]); value["startUTF16"] = span.location; value["lengthUTF16"] = span.length
            }
            return value
        }
    }
    var documents: [[String: Any]] = []
    for observation in observations {
        let owner = observation.document.text
        var document = documentRegion(observation.document.boundingRegion, width: image.width, height: image.height)
        document["transcript"] = owner.transcript; document["observationConfidence"] = observation.confidence
        document["lines"] = try owner.lines.map { try lineJSON($0, substrings: true) }
        if let words = owner.words { document["nativeWords"] = try words.map { try lineJSON($0, substrings: false) } }
        else { document["nativeWords"] = NSNull() }
        document["entities"] = entities(owner)
        document["tables"] = observation.document.tables.map { table in
            var value = documentRegion(table.boundingRegion, width: image.width, height: image.height)
            value["rowCount"] = table.rows.count; value["columnCount"] = table.columns.count
            value["cells"] = table.rows.enumerated().flatMap { rowIndex, row in
                row.enumerated().map { occurrence, cell in
                    var record = documentRegion(cell.content.boundingRegion, width: image.width, height: image.height)
                    let text = cell.content.text
                    record["returnedRowIndex"] = rowIndex; record["returnedOccurrenceIndex"] = occurrence
                    record["rowSpan"] = [cell.rowRange.lowerBound, cell.rowRange.upperBound]
                    record["columnSpan"] = [cell.columnRange.lowerBound, cell.columnRange.upperBound]
                    record["transcript"] = text.transcript; record["entities"] = entities(text)
                    return record
                }
            }
            return value
        }
        documents.append(document)
    }
    return ["complete": true, "request": config, "recognitionAndSerializationMs": Date().timeIntervalSince(started)*1000, "documents": documents]
}

@available(macOS 26.0, iOS 26.0, *)
func documentProbe(_ directory: URL, platform: String) async throws -> [String: Any] {
    let bytes = try Data(contentsOf: directory.appendingPathComponent("inputs.json"))
    guard let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          let pages = input["pages"] as? [[String: Any]], let control = input["documentControl"] as? [String: Any] else { throw ProofError(description: "Missing document diagnostic inputs") }
    var results: [[String: Any]] = []
    for page in [["id": "synthetic-document-control", "render": control] as [String: Any]] + pages {
        guard let id = page["id"] as? String, let info = page["render"] as? [String: Any],
              let width = info["width"] as? Int, let height = info["height"] as? Int, let stride = info["bytesPerRow"] as? Int,
              let expected = info["pixelSha256"] as? String else { throw ProofError(description: "Invalid document input metadata") }
        var result: [String: Any] = ["id": id, "render": info]
        do {
            let pixels = try Data(contentsOf: directory.appendingPathComponent(id + ".rgba"))
            let image = try rawImage(pixels, width: width, height: height, stride: stride, expectedHash: expected)
            result["inputBytesVerified"] = true
            result["reading"] = try await documentRead(image)
        } catch { result["error"] = String(describing: error) }
        results.append(result)
    }
    return ["scope": "Separate default document-layout diagnostic; no price promotion, currency authority or phone claim",
            "inputManifestSha256": hash(bytes), "records": results, "platform": platform,
            "sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? Bundle.main.object(forInfoDictionaryKey: "ProofSourceRevision") as? String ?? "local",
            "runIdentity": input["runIdentity"] ?? "missing", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString]
}
