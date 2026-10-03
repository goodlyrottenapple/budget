import Foundation
import Testing
import ImageIO
@testable import BudgetCore

private let logoPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9WQAAAAASUVORK5CYII=")!
private let firstLogo = URL(string: "https://img.logo.dev/first.example?token=public")!
private let secondLogo = URL(string: "https://img.logo.dev/second.example?token=public")!

@Test func customIconsRejectInvalidAndOversizedData() {
    #expect(throws: (any Error).self) { try MerchantIconImage.prepare(Data("not an image".utf8)) }
    #expect(throws: (any Error).self) { try MerchantIconImage.prepare(Data(count: MerchantIconImage.maximumInputSize + 1)) }
}

@Test func customIconsAreDownsampledAndCanBeDecodedOffline() throws {
    let context = try #require(CGContext(data: nil, width: 1600, height: 800, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
    let image = try #require(context.makeImage())
    let sourceData = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(sourceData, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let icon = try MerchantIconImage.prepare(sourceData as Data)
    let source = try #require(CGImageSourceCreateWithData(icon as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 512)
    #expect(decoded.height == 256)
    #expect(icon.count < 1_024 * 1_024)
}

private func temporaryLogoDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("logo-test-\(UUID())", isDirectory: true)
}

@Test func logosSurviveRelaunchWithoutNetwork() async throws {
    let directory = temporaryLogoDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let online = RetailerLogoCache(directory: directory) { _ in logoPNG }
    try await online.retain([firstLogo], revision: 1)
    #expect(try await online.data(for: firstLogo) == logoPNG)

    let offline = RetailerLogoCache(directory: directory) { _ in throw URLError(.notConnectedToInternet) }
    try await offline.retain([firstLogo], revision: 1)
    #expect(try await offline.data(for: firstLogo) == logoPNG)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(files.count == 1)
    #expect(!files[0].contains("token"))
}

@Test func cleanupKeepsUsedLogosAndRemovesLastUnusedReference() async throws {
    let directory = temporaryLogoDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = RetailerLogoCache(directory: directory) { _ in logoPNG }
    try await cache.retain([firstLogo, secondLogo], revision: 1)
    _ = try await cache.data(for: firstLogo)
    _ = try await cache.data(for: secondLogo)
    try await cache.retain([firstLogo], revision: 3)
    // A delayed older snapshot must not restore removed references.
    try await cache.retain([secondLogo], revision: 2)
    let offline = RetailerLogoCache(directory: directory) { _ in throw URLError(.notConnectedToInternet) }
    #expect(try await offline.data(for: firstLogo) == logoPNG)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    try await cache.retain([], revision: 4)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test func searchPreviewsAreNotPersistedUntilSelected() async throws {
    let directory = temporaryLogoDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = RetailerLogoCache(directory: directory) { _ in logoPNG }
    try await cache.retain([], revision: 1)
    #expect(try await cache.data(for: firstLogo) == logoPNG)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    try await cache.retain([firstLogo], revision: 2)
    _ = try await cache.data(for: firstLogo)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
}

@Test func invalidResponsesAreNotCachedAndCanBeRetried() async throws {
    let directory = temporaryLogoDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let response = LogoResponse()
    let cache = RetailerLogoCache(directory: directory) { _ in await response.data() }
    try await cache.retain([firstLogo], revision: 1)
    await #expect(throws: URLError.self) { try await cache.data(for: firstLogo) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    await response.useValidImage()
    #expect(try await cache.data(for: firstLogo) == logoPNG)
    // A damaged file is replaced on the next online load.
    let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    try Data("broken".utf8).write(to: file)
    #expect(try await cache.data(for: firstLogo) == logoPNG)
    #expect(try Data(contentsOf: file) == logoPNG)
}

private actor LogoResponse {
    private var valid = false
    func useValidImage() { valid = true }
    func data() -> Data { valid ? logoPNG : Data("error response".utf8) }
}

@Test func finishingDownloadDoesNotResurrectUnusedLogo() async throws {
    let directory = temporaryLogoDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = LogoDownloadGate()
    let cache = RetailerLogoCache(directory: directory) { _ in await gate.download() }
    try await cache.retain([firstLogo], revision: 1)
    let download = Task { try await cache.data(for: firstLogo) }
    await gate.waitUntilStarted()
    try await cache.retain([], revision: 2)
    await gate.finish()
    #expect(try await download.value == logoPNG)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

private actor LogoDownloadGate {
    private var downloadContinuation: CheckedContinuation<Data, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    func download() async -> Data {
        await withCheckedContinuation { continuation in
            downloadContinuation = continuation
            startContinuation?.resume()
            startContinuation = nil
        }
    }
    func waitUntilStarted() async {
        if downloadContinuation != nil { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
    func finish() { downloadContinuation?.resume(returning: logoPNG); downloadContinuation = nil }
}
