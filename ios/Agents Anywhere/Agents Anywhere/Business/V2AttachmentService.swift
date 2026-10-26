import Foundation

/// In-flight deduplication for attachment downloads. Keyed by session+file: concurrent
/// callers (thumbnail retry racing a full-image open, or a scroll burst re-appearing cells)
/// share one fetch. A cancelling caller does not cancel the shared task — the bytes still
/// serve the remaining callers, mirroring the old behavior where server-side work kept
/// running after a per-caller task was cancelled. Only the task's creator clears the slot,
/// so a fresh download can only start after the previous one finished, and errors are
/// delivered to every joined caller exactly like independent fetches would.
nonisolated final class V2AttachmentDownloads: @unchecked Sendable {
    static let shared = V2AttachmentDownloads()

    private let lock = NSLock()
    private var inflight: [String: Task<Data, Error>] = [:]

    private init() {}

    func data(key: String, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        lock.lock()
        if let task = inflight[key] {
            lock.unlock()
            return try await task.value
        }
        let task = Task(priority: .userInitiated) { try await load() }
        inflight[key] = task
        lock.unlock()
        do {
            let data = try await task.value
            lock.lock(); inflight[key] = nil; lock.unlock()
            return data
        } catch {
            lock.lock(); inflight[key] = nil; lock.unlock()
            throw error
        }
    }
}

struct V2AttachmentService {
    let attachmentAPI: any V2AttachmentAPIProtocol

    /// Uploads user-selected bytes to the server's session-scoped attachment store.
    func upload(
        sessionId: V2SessionID,
        attachments: [V2LocalAttachment]
    ) async throws -> [V2AttachmentReference] {
        if attachments.isEmpty { throw V2BusinessError.emptyAttachmentSelection }
        if attachments.count > 5 {
            throw V2BusinessError.tooManyAttachments(maximum: 5)
        }
        let files = try attachments.map { attachment in
            if attachment.data.isEmpty {
                throw V2BusinessError.emptyAttachment(name: attachment.name)
            }
            if attachment.data.count > 25 * 1024 * 1024 { throw V2BusinessError.attachmentTooLarge(name: attachment.name) }
            return HTTPUploadFile(
                fieldName: "files",
                fileName: attachment.name,
                mediaType: attachment.mediaType,
                data: attachment.data
            )
        }
        return try await attachmentAPI.upload(sessionId: sessionId, files: files).attachments
    }

    func download(sessionId: V2SessionID, fileId: V2AttachmentID) async throws -> Data {
        let diagT = ContinuousClock.now
        // The fetch + Base64 decode run on a background task: the raw response body can be
        // megabytes and decoding it on the main actor was part of the measured stall. The
        // per-session+file download is deduplicated in flight across concurrent callers.
        // The "attach" metric stays per-caller: joined waiters each record their own wait
        // time, so on-device numbers remain comparable.
        let data = try await V2AttachmentDownloads.shared.data(key: "\(sessionId)|\(fileId)") { [attachmentAPI] in
            let response = try await attachmentAPI.download(sessionId: sessionId, fileId: fileId)
            guard let data = Data(base64Encoded: response.contentBase64) else {
                throw HTTPError.decoding(message: String(localized: "The attachment content is not valid Base64 data."))
            }
            return data
        }
        AADiag.event("attach", ["bytes": data.count, "ms": aaDiagMs(diagT.duration(to: .now))])
        return data
    }
}
