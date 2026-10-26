import Foundation
import UIKit

/// Process-wide decoded-image cache for chat attachments.
///
/// Before the fix every appearance of an attachment cell ran `UIImage(data:)` on the main
/// actor, and the session-scoped byte store (ChatAttachmentStore, LRU-trimmed under memory
/// pressure) forced full scroll round-trips to re-decode. This cache is keyed by
/// `V2AttachmentContent.cacheKey`, outlives a single session store, and decodes off the
/// main actor: a re-visited cell after a trim only re-fetches bytes (deduplicated by
/// `V2AttachmentDownloads`) and never pays decode twice.
nonisolated final class V2AttachmentImageCache: @unchecked Sendable {
    static let shared = V2AttachmentImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 512
        return cache
    }()
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {}

    /// Already-decoded image when cached. Cheap and synchronous — safe from view bodies.
    func cached(key: String) -> UIImage? { cache.object(forKey: NSString(string: key)) }

    /// Remembers an image decoded elsewhere (e.g. the synchronous local-bytes fast path) so
    /// later visits skip decoding entirely.
    func store(_ image: UIImage, key: String) { cache.setObject(image, forKey: NSString(string: key)) }

    /// Decodes bytes off the main actor exactly once per key. Concurrent requests for the
    /// same key share one decode task, so a scroll burst on the same attachment never
    /// spawns N identical decodes. Only `String`/`Data` cross the task boundary — the
    /// target's MainActor default isolation makes `V2AttachmentContent` (and `UIImage`)
    /// non-Sendable, so byte fetching stays on the caller side (deduplicated separately by
    /// `V2AttachmentDownloads`). A failed decode is not cached, so the retry button
    /// refetches. A joined caller being cancelled does not cancel the shared task: the
    /// work still serves the remaining callers and is bounded by one image's decode. Only
    /// the task's creator clears the registry slot, so a fresh pipeline can only start
    /// after the previous one finished.
    func decoded(key: String, data: Data) async -> UIImage? {
        if let hit = cached(key: key) { return hit }
        lock.lock()
        if let task = inflight[key] {
            lock.unlock()
            return await task.value
        }
        let task = Task(priority: .utility) { () -> UIImage? in
            guard !Task.isCancelled, let image = UIImage(data: data) else { return nil }
            self.cache.setObject(image, forKey: NSString(string: key))
            return image
        }
        inflight[key] = task
        lock.unlock()
        let result = await task.value
        lock.lock()
        inflight[key] = nil
        lock.unlock()
        return result
    }
}
