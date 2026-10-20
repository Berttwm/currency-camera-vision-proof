import Foundation
import Vision
import CoreGraphics
import CoreText
import PDFKit
import CryptoKit

struct Source: Codable {
    let id: String, url: URL, sha256: String
    let page: Int, width: Int, height: Int
}
struct ProofError: Error, CustomStringConvertible { let description: String }
func require(_ valid: Bool, _ message: String) throws {
    if !valid { throw ProofError(description: message) }
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
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
    try require(Set(languages).isSubset(of: Set(supported)), "Default language unavailable; no silent substitution. Defaults=\(languages); supported=\(supported); automatic=\(automaticLanguage); correction=\(languageCorrection)")
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
    let (enlarged, enlargedInfo) = try render(original, pageNumber: 1, width: 1200, height: 800)
    guard let enlargedBytes = enlarged.dataProvider?.data, let enlargedPointer = CFDataGetBytePtr(enlargedBytes)
    else { throw ProofError(description: "No enlarged pixels") }
    let corner = 40*enlarged.bytesPerRow + 40*4, opposite = 760*enlarged.bytesPerRow + 1160*4
    try require(enlargedPointer[corner] > 240 && enlargedPointer[corner+2] < 20 && enlargedPointer[opposite] < 20 && enlargedPointer[opposite+2] > 240,
                "PDF enlargement failed; transform=\(enlargedInfo["drawingTransform"]!)")
    let (image, _) = try render(original, pageNumber: 1, width: 600, height: 400)
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
    let (rotated, _) = try render(rotatedData, pageNumber: 1, width: 400, height: 600)
    guard let bytes = rotated.dataProvider?.data, let pointer = CFDataGetBytePtr(bytes) else { throw ProofError(description: "No rotated pixels") }
    let red = 20*rotated.bytesPerRow + 380*4, blue = 580*rotated.bytesPerRow + 20*4
    try require(pointer[red] > 240 && pointer[red+2] < 20 && pointer[blue] < 20 && pointer[blue+2] > 240, "PDF rotation is incorrect")
}
if CommandLine.arguments.dropFirst().first == "--self-test" {
    try selfTest(); print("Synthetic PDF orientation, rotated page and OCR coordinate checks passed")
} else {
    try require(CommandLine.arguments.count == 2, "Pass sources.json or --self-test")
    let sources = try JSONDecoder().decode([Source].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    try require(sources.count == 3 && Set(sources.map(\.id)).count == 3, "Expected three distinct frozen sources")
    let defaultRequest = VNRecognizeTextRequest()
    let sdkLanguageDefaults: [String: Any] = ["languages": defaultRequest.recognitionLanguages,
                                            "automaticallyDetectsLanguage": defaultRequest.automaticallyDetectsLanguage,
                                            "usesLanguageCorrection": defaultRequest.usesLanguageCorrection]
    var results: [[String: Any]] = []
    for source in sources {
        try require(source.url.scheme == "https" && source.page > 0 && max(source.width, source.height) == 1300 && min(source.width, source.height) > 0, "Invalid source manifest")
        var request = URLRequest(url: source.url); request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: request)
        try require((response as? HTTPURLResponse)?.statusCode == 200 && data.count < 25_000_000, "Public PDF fetch failed")
        try require(hash(data) == source.sha256, "Public PDF changed; frozen hash mismatch for \(source.id)")
        let (image, rendered) = try render(data, pageNumber: source.page, width: source.width, height: source.height)
        let (config, lines) = try recognize(image)
        results.append(["id": source.id, "url": source.url.absoluteString, "sourceSha256": hash(data),
                        "page": source.page, "render": rendered, "request": config, "lines": lines])
    }
    let result: [String: Any] = ["scope": "macOS static public-PDF OCR only; not an iPhone/camera performance result",
                               "sdkLanguageDefaults": sdkLanguageDefaults, "defaultsCapturedBeforePdfDownload": true,
                               "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                               "sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "local", "pages": results]
    let bytes = try jsonData(result)
    try require(bytes.count < 2_000_000, "JSON exceeds log cap")
    FileHandle.standardOutput.write(bytes)
}
