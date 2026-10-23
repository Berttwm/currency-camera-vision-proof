import Foundation

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--documents" {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    if #available(macOS 26.0, *) {
        let result = try await documentProbe(directory, platform: "macOS")
        let bytes = try jsonData(result)
        try require(bytes.count < 16_000_000, "Decoded Mac document JSON exceeds16MB: \(bytes.count)")
        FileHandle.standardOutput.write(bytes)
    } else { throw ProofError(description: "Document probe requires macOS26") }
    exit(0)
}
try require(CommandLine.arguments.count == 2, "Pass a new output directory")
try selfTest()
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try require(!FileManager.default.fileExists(atPath: output.path), "Refuse to replace existing inputs")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sourcesData = try Data(contentsOf: URL(fileURLWithPath: "sources.json"))
let sources = try JSONDecoder().decode([Source].self, from: sourcesData)
try require(sources.count == 3 && Set(sources.map(\.id)).count == 3, "Expected three sources")
try sourcesData.write(to: output.appendingPathComponent("sources.json"), options: .atomic)
let defaults = languageDefaults()
var inputs: [[String: Any]] = []
for source in sources {
    try require(source.url.scheme == "https" && source.page == 1 && max(source.width, source.height) == 1300, "Invalid source")
    try require(source.id.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil, "Invalid source id")
    var request = URLRequest(url: source.url); request.timeoutInterval = 45
    let (data, response) = try await URLSession.shared.data(for: request)
    try require((response as? HTTPURLResponse)?.statusCode == 200 && data.count < 25_000_000, "Public PDF fetch failed")
    try require(hash(data) == source.sha256, "Public source changed")
    let (image, info) = try render(data, pageNumber: source.page, width: source.width * 2, height: source.height * 2)
    guard let pixels = image.dataProvider?.data else { throw ProofError(description: "No rendered pixels") }
    let rgba = pixels as Data
    try require(rgba.count == source.width * source.height * 16 && hash(rgba) == info["pixelSha256"] as? String, "Rendered byte identity failed")
    try rgba.write(to: output.appendingPathComponent(source.id + ".rgba"), options: .atomic)
    inputs.append(["id": source.id, "url": source.url.absoluteString, "sourceSha256": source.sha256,
                   "page": source.page, "render": info])
}
guard let run = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"], let attempt = ProcessInfo.processInfo.environment["GITHUB_RUN_ATTEMPT"] else {
    throw ProofError(description: "Missing workflow run identity")
}
let (controlImage, controlInfo) = try documentControl()
guard let controlPixels = controlImage.dataProvider?.data else { throw ProofError(description: "No document control pixels") }
try (controlPixels as Data).write(to: output.appendingPathComponent("synthetic-document-control.rgba"), options: .atomic)
try jsonData(["runIdentity": run + "-" + attempt, "renderScale": 2, "colorSpace": "DeviceRGB", "pages": inputs, "documentControl": controlInfo]).write(to: output.appendingPathComponent("inputs.json"), options: .atomic)
var result = try recognizeInputs(output, defaults: defaults, platform: "macOS")
if #available(macOS 26.0, *) {
    result["semanticProbe"] = await semanticProbe(result)
} else { throw ProofError(description: "String semantic probe requires macOS26") }
let bytes = try jsonData(result)
try require(bytes.count < 4_000_000, "Mac JSON exceeds log cap")
try bytes.write(to: output.appendingPathComponent("baseline-mac.json"), options: .atomic)
FileHandle.standardOutput.write(bytes)
