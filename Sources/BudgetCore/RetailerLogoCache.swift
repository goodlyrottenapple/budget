import Foundation
import CryptoKit
import ImageIO

/// Downsample user-selected images before persisting them with a merchant override.
public enum MerchantIconImage {
    public static let maximumInputSize = 20 * 1_024 * 1_024

    public static func prepare(_ data: Data) throws -> Data {
        guard data.count <= maximumInputSize else { throw CSVError.invalid("Choose an image smaller than 20 MB.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else {
            throw CSVError.invalid("This image could not be opened. Choose a PNG, JPEG or HEIC image.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw CSVError.invalid("This image could not be saved. Choose another image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CSVError.invalid("This image could not be saved. Choose another image.")
        }
        return output as Data
    }
}

/// Durable artwork for saved transactions. Search previews can share downloads,
/// but only URLs retained by the persisted transaction snapshot are saved to disk.
public actor RetailerLogoCache {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    private let directory: URL
    private let fetch: Fetch
    private var retained: Set<URL> = []
    private var revision = -1
    private var inFlight: [URL: Task<Data, Error>] = [:]

    public init(directory: URL, fetch: @escaping Fetch = { try await RetailerLogoCache.download($0) }) {
        self.directory = directory
        self.fetch = fetch
    }

    /// Revisions prevent an older scheduled snapshot from undoing newer cleanup.
    public func retain(_ urls: Set<URL>, revision: Int) throws {
        guard revision > self.revision else { return }
        self.revision = revision
        retained = urls
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filenames = Set(urls.map { fileURL(for: $0).lastPathComponent })
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if !filenames.contains(file.lastPathComponent) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    public func data(for url: URL) async throws -> Data {
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file), Self.isImage(data) { return data }
        if let task = inFlight[url] { return try await task.value }
        let fetch = self.fetch
        let task = Task {
            let data = try await fetch(url)
            guard Self.isImage(data) else { throw URLError(.cannotDecodeContentData) }
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let data = try await task.value
        // Recheck after download: a transaction may have been deleted or changed.
        if retained.contains(url) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        return data
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".image")
    }

    private static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 5 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }

    public static func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "img.logo.dev" else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
