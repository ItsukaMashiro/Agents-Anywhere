import Foundation

nonisolated struct V2SessionCachePolicy {
    var maximumSessions = 8
    var maximumTimelineItems = 1000
    var catalogLifetime: TimeInterval = 30
}

/// One repository per authenticated server/account. Views observe values and invoke
/// operations; this layer owns request coalescing, bounded caches and live recovery.
@MainActor
final class V2SessionRepository {
    let scope: V2ClientScope
    private let detail: V2SessionDetailService
    private let interactions: V2RuntimeInteractionService
    private let localStore: V2LocalStore?
    private var persistenceTask: Task<Void, Never>?
    private let policy: V2SessionCachePolicy
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var entries: [V2SessionID: Entry] = [:]
    private var accessCounter = 0
    private var suspended = false
    private(set) var network = V2NetworkStatus()

    init(
        scope: V2ClientScope,
        detail: V2SessionDetailService,
        interactions: V2RuntimeInteractionService,
        policy: V2SessionCachePolicy = V2SessionCachePolicy(),
        localStore: V2LocalStore? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.scope = scope
        self.detail = detail
        self.interactions = interactions
        self.policy = policy
        self.localStore = localStore
        self.now = now
        self.sleep = sleep
    }

    var cachedSessionIDs: Set<V2SessionID> { Set(entries.keys) }

    func session(id: V2SessionID) -> V2SessionModel {
        let entry = entry(for: id)
        evict(protecting: entry)
        return entry.model
    }

    func cached(sessionId: V2SessionID) -> V2SessionData? {
        guard let entry = entries[sessionId] else { return nil }
        touch(entry)
        return entry.projection?.data
    }

    /// Returns cached durable content immediately. Observe to keep live facts fresh.
    func load(sessionId: V2SessionID) async throws -> V2SessionData {
        let entry = entry(for: sessionId)
        await restoreCachedSession(id: sessionId)
        try requireCurrent(entry)
        if let data = entry.projection?.data { return data }
        try requireNetwork()
        return try await hydrate(entry)
    }

    /// A page visit starts with the latest 100 records, including cached visits.
    /// Explicit history loads may then accumulate additional 100-record pages.
    func open(sessionId: V2SessionID) async throws -> V2SessionData {
        let entry = entry(for: sessionId)
        _ = try await load(sessionId: sessionId)
        try Task.checkCancellation()
        try requireCurrent(entry)
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        // Trim before a possible latest-page request so an offline fallback
        // also stays bounded and cannot remount the entire cached history.
        // Serialize behind any in-flight fold: the trim must not be clobbered by a swap-back.
        await drainFolds(entry)
        if entry.projection?.limitToLatest(100) == true { emit(entry) }
        if entry.projection?.data.hasNewerItems == true {
            return try await loadLatest(sessionId: sessionId, limit: 100)
        }
        return entry.projection!.data
    }

    func stageCreation(_ submission: NewSessionSubmission) {
        let entry = entry(for: submission.session.id)
        entry.projection = V2SessionProjection.placeholder(submission.session, maximumItems: policy.maximumTimelineItems)
        entry.model.stage(submission.pending)
        emit(entry)
    }

    func bindCreation(_ submission: NewSessionSubmission, response: V2SessionCreateResponse) {
        let entry = entry(for: response.session.id)
        if entry.projection == nil {
            entry.projection = V2SessionProjection.placeholder(response.session, maximumItems: policy.maximumTimelineItems)
            entry.needsSnapshot = true
        }
        for (attachment, uploaded) in zip(submission.pending.attachments, response.attachments ?? []) {
            submission.pending.bindUpload(uploaded.reference(sessionID: response.session.id), localID: attachment.id)
        }
        submission.pending.update(.accepted)
        entry.model.stage(submission.pending)
        emit(entry)
        remove(sessionIds: [submission.session.id])
    }

    func restoreCachedSession(id: String) async {
        guard let localStore else { return }
        let entry = entry(for: id)
        guard entry.projection == nil, !entry.hasReadLocal else { return }
        if entry.localReadTask == nil {
            entry.localReadTask = Task { await localStore.restoreSession(id) }
        }
        let saved = await entry.localReadTask?.value
        guard isCurrent(entry), entry.projection == nil, !entry.hasReadLocal else { return }
        entry.hasReadLocal = true; entry.localReadTask = nil
        guard let saved, saved.archive.session.id == id else { return }
        // Building the projection sorts the cached page; keep it off the main actor.
        // No fold can compete here: the projection is still nil and the socket loop
        // only receives after load() returns.
        let maximumItems = policy.maximumTimelineItems
        let built = await Task.detached(priority: .userInitiated) {
            saved.archive.projection(items: saved.items, maximumItems: maximumItems)
        }.value
        // The detached build introduced a suspension: if a server hydrate completed in the
        // meantime its (newer) snapshot wins, exactly as it would have when the synchronous
        // cached assignment ran before hydrate in the old ordering.
        guard isCurrent(entry), entry.projection == nil else { return }
        entry.foldGeneration += 1
        entry.projection = built
        entry.model.restoreLocal(saved.archive)
        emit(entry, persist: false)
    }

    /// Writes only sessions whose durable state changed since their last save.
    /// Passing a session ID flushes just that session, e.g. before a send.
    func flushCache(sessionID: V2SessionID? = nil) async {
        if sessionID == nil { persistenceTask?.cancel(); persistenceTask = nil }
        guard let localStore else { return }
        let dirty = entries.values.filter { $0.isDirty && (sessionID == nil || $0.id == sessionID) }
            .sorted { $0.lastAccess < $1.lastAccess }
        for entry in dirty {
            guard let projection = entry.projection else { continue }
            entry.isDirty = false
            await localStore.saveSession(V2SessionArchive(data: projection.data, model: entry.model))
        }
    }

    /// Streaming emits several times per second; a 2.5 s window coalesces them
    /// into one archive write per session instead of one per batch.
    private func schedulePersistence() {
        guard localStore != nil, persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
            await self?.flushCache()
        }
    }

    /// Multiple observers share one socket; removing the last observer closes it.
    func observe(sessionId: V2SessionID) -> AsyncStream<V2SessionObservation> {
        let entry = entry(for: sessionId)
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            entry.observers[observerID] = continuation
            continuation.yield(observation(entry))
            continuation.onTermination = { [weak self, weak entry] _ in
                Task { @MainActor [weak self, weak entry] in
                    guard let self, let entry else { return }
                    entry.observers.removeValue(forKey: observerID)
                    if entry.observers.isEmpty {
                        self.stop(entry)
                        self.evict()
                    }
                }
            }
            start(entry)
        }
    }

    /// Explicit refresh replaces the aggregate and then re-establishes live recovery.
    func refresh(sessionId: V2SessionID) async throws -> V2SessionData {
        try requireNetwork()
        let entry = entry(for: sessionId)
        stop(entry)
        entry.loadTask?.cancel()
        entry.loadTask = nil
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        defer { if isCurrent(entry) { start(entry) } }
        return try await hydrate(entry)
    }

    func loadOlder(sessionId: V2SessionID, limit: Int = 100) async throws -> V2SessionData {
        try requireNetwork()
        _ = try await load(sessionId: sessionId)
        let entry = entry(for: sessionId)
        if let task = entry.historyTask { return try await task.value }
        guard let data = entry.projection?.data,
              data.hasOlderItems, let before = data.items.first?.orderSeq else {
            return entry.projection!.data
        }
        let version = entry.readVersion
        let task = Task { [self] in
            defer { if entry.readVersion == version { entry.historyTask = nil } }
            let page = try await detail.loadOlderItems(sessionId: sessionId, beforeOrderSeq: before, limit: limit)
            try requireCurrent(entry, version: version)
            // History merge re-sorts the whole window — run it off the main actor,
            // serialized with live folds through the fold slot.
            try await offMainFold(entry) { projection in
                var projection = projection
                projection.applyHistory(page)
                return projection
            }
            try requireCurrent(entry, version: version)
            emit(entry)
            return entry.projection!.data
        }
        entry.historyTask = task
        return try await task.value
    }

    func loadLatest(sessionId: V2SessionID, limit: Int = 100) async throws -> V2SessionData {
        try requireNetwork()
        _ = try await load(sessionId: sessionId)
        let entry = entry(for: sessionId)
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        let version = entry.readVersion
        let page = try await detail.latestItems(sessionId: sessionId, limit: limit)
        try requireCurrent(entry, version: version)
        // Same full-window re-sort as loadOlder — off the main actor, via the fold slot.
        try await offMainFold(entry) { projection in
            var projection = projection
            projection.applyLatest(page)
            return projection
        }
        try requireCurrent(entry, version: version)
        emit(entry)
        return entry.projection!.data
    }

    func catalogs(sessionId: V2SessionID, force: Bool = false, capabilities: V2RuntimeCapabilitySnapshot? = nil) async throws -> V2SessionCatalogs {
        let entry = entry(for: sessionId)
        let scopes = capabilities.map { value in Set(["model", "permission"].filter { value.allows("catalog.\($0)") }) }
        if entry.catalogScopes != scopes {
            invalidateCatalogs(entry)
            entry.catalogScopes = scopes
        }
        if !force, let cached = entry.catalogs, let readAt = entry.catalogReadAt,
           now().timeIntervalSince(readAt) < policy.catalogLifetime { return cached }
        try requireNetwork()
        if let task = entry.catalogTask { return try await task.value }
        let version = entry.catalogVersion
        let task = Task { [self] in
            defer {
                if entry.catalogVersion == version { entry.catalogTask = nil }
                evict()
            }
            let catalogs = try await detail.catalogs(sessionId: sessionId, scopes: scopes)
            try requireCurrent(entry)
            guard version == entry.catalogVersion else { throw CacheError.invalidated }
            entry.catalogs = catalogs
            entry.catalogReadAt = now()
            evict()
            return catalogs
        }
        entry.catalogTask = task
        return try await task.value
    }

    /// The command catalog is read once per live connection; it is dropped with
    /// the option catalogs when the connection stops or selections change.
    func commands(sessionId: V2SessionID, force: Bool = false) async throws -> [V2RuntimeCommand] {
        let entry = entry(for: sessionId)
        if !force, let cached = entry.commands { return cached }
        try requireNetwork()
        let version = entry.catalogVersion
        let commands = try await interactions.commands(sessionId: sessionId)
        try requireCurrent(entry)
        guard version == entry.catalogVersion else { throw CacheError.invalidated }
        entry.commands = commands
        return commands
    }

    func executeCommand(sessionId: V2SessionID, request: RuntimeCommandRequest) async throws -> V2RuntimeCommandExecuteResponse {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let response = try await interactions.executeCommand(sessionId: sessionId, command: request.command, arguments: request.args, raw: request.raw)
        try requireCurrent(entry)
        if let session = response.session {
            // Serialize behind any in-flight fold so its swap-back cannot clobber this meta.
            await drainFolds(entry)
            entry.projection?.applyMeta(session)
            emit(entry)
        }
        return response
    }

    func draftDidChange(sessionID: V2SessionID) {
        entries[sessionID]?.isDirty = true
        schedulePersistence()
    }

    func localWorkDidChange(sessionID: V2SessionID) {
        if let entry = entries[sessionID] { emit(entry) }
    }

    func send(sessionId: V2SessionID, content: String, attachmentIDs: [V2AttachmentID] = [], clientMessageID: String) async throws -> V2RuntimeActionResponse {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let response = try await detail.sendMessage(sessionId: sessionId, content: content, attachmentIds: attachmentIDs, clientMessageId: clientMessageID)
        try requireCurrent(entry)
        // Timeline echoes reconcile by clientMessageId; sending never refetches the snapshot.
        return response
    }

    func steer(sessionId: V2SessionID, content: String, attachmentIDs: [V2AttachmentID] = [], clientMessageID: String) async throws -> V2RuntimeActionResponse {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let response = try await detail.steer(sessionId: sessionId, content: content, attachmentIds: attachmentIDs, clientMessageId: clientMessageID)
        try requireCurrent(entry)
        return response
    }

    func interrupt(sessionId: V2SessionID) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        _ = try await detail.interrupt(sessionId: sessionId)
        try requireCurrent(entry)
    }

    func setTakeover(sessionId: V2SessionID, enabled: Bool) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let session = try await detail.setTakeover(sessionId: sessionId, enabled: enabled)
        try requireCurrent(entry)
        await drainFolds(entry)
        entry.projection?.applyMeta(session)
        entry.projection?.markStale()
        emit(entry)
        // Takeover was confirmed by the write response. A failed following read
        // must not invite a duplicate toggle or claim the write was rejected.
        do { try await reconcile(entry) }
        catch { if isCurrent(entry) { entry.error = V2ClientFailure(error); emit(entry) } }
    }

    func setSelection(sessionId: V2SessionID, scope: V2RuntimeSelectionScope, selectionId: V2SelectionID?) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        let state = try await detail.updateSelection(sessionId: sessionId, scope: scope, selectionId: selectionId)
        try requireCurrent(entry)
        await drainFolds(entry)
        if let state { entry.projection?.applyState(state) }
        invalidateCatalogs(entry)
        emit(entry)
    }

    func respond(sessionId: V2SessionID, noticeId: V2NoticeID, actionId: String, input: JSONValue? = nil) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        _ = try await interactions.respond(sessionId: sessionId, noticeId: noticeId, actionId: actionId, input: input)
        try requireCurrent(entry)
        // Response acceptance is not notice resolution; wait for authoritative live facts.
        await drainFolds(entry)
        entry.projection?.markStale()
        emit(entry)
        do { try await reconcile(entry) }
        catch {
            // The action already succeeded. A failed read must not turn an
            // accepted approval into a retryable write failure in the UI.
            if isCurrent(entry) { entry.error = V2ClientFailure(error); emit(entry) }
        }
    }

    func sync(sessionId: V2SessionID) async throws {
        try requireNetwork()
        let entry = entry(for: sessionId)
        _ = try await detail.sync(sessionId: sessionId)
        try requireCurrent(entry)
        try await reconcile(entry)
    }

    func applyMetadata(_ sessions: [V2SessionMeta]) {
        for session in sessions {
            guard let entry = entries[session.id] else { continue }
            let previous = entry.projection?.data.session
            // Dashboard pushes repeat every session on each tick; unchanged
            // metadata must not re-project and re-persist every open session.
            let changed = entry.projection?.applyMeta(session) ?? false
            let invalidates = session.connectorStatus != .online || previous?.effectiveRuntimeId != session.effectiveRuntimeId
            if invalidates { invalidateCatalogs(entry) }
            if changed || invalidates { emit(entry) }
            if session.connectorStatus == .online,
               previous?.connectorStatus != .online || previous?.effectiveRuntimeId != session.effectiveRuntimeId {
                // A dashboard projection can arrive before the session socket frame.
                // Restart observed sessions so their runtime facts match the new binding.
                stop(entry)
                start(entry)
            }
        }
    }

    func suspend() {
        suspended = true
        for entry in entries.values { stop(entry); emit(entry, persist: false) }
    }

    func resume() {
        suspended = false
        for entry in entries.values { start(entry) }
    }

    func updateConnectivity(_ status: V2NetworkStatus) {
        let wasOffline = network.availability == .offline
        network = status
        for entry in entries.values {
            if status.availability == .offline {
                stop(entry)
                entry.readVersion += 1
                entry.loadTask?.cancel()
                entry.loadTask = nil
                entry.historyTask?.cancel()
                entry.historyTask = nil
                entry.connection = .offline
            } else if wasOffline {
                start(entry)
            }
            emit(entry, persist: false)
        }
    }

    private func requireNetwork() throws {
        if network.availability == .offline {
            throw V2ClientFailure(kind: .offline, message: String(localized: "You are offline. Cached content is still available."))
        }
    }

    func remove(sessionIds: [V2SessionID]) {
        for id in sessionIds {
            if let localStore { Task { await localStore.removeSession(id) } }
            guard let entry = entries.removeValue(forKey: id) else { continue }
            dispose(entry)
        }
    }

    /// Cancellation plus identity checks prevent late responses from repopulating a signed-out cache.
    func reset() {
        persistenceTask?.cancel(); persistenceTask = nil
        let old = Array(entries.values)
        entries.removeAll()
        for entry in old { dispose(entry) }
    }

    private func hydrate(_ entry: Entry) async throws -> V2SessionData {
        if let task = entry.loadTask { return try await task.value }
        entry.readVersion += 1
        entry.historyTask?.cancel()
        entry.historyTask = nil
        let version = entry.readVersion
        let task = Task { [self] in
            defer {
                if entry.readVersion == version { entry.loadTask = nil }
                evict()
            }
            let snapshot = try await detail.load(sessionId: entry.id)
            try requireCurrent(entry, version: version)
            guard snapshot.session.id == entry.id else { throw CacheError.invalidated }
            // Building the initial window sorts the snapshot page: build it off the main
            // actor and serialize behind any in-flight fold so no swap-back can clobber
            // the fresh snapshot. The socket loop blocks on loadTask, so no new event
            // queues between the drain and the assignment.
            await drainFolds(entry)
            let maximumItems = policy.maximumTimelineItems
            let built = await Task.detached(priority: .userInitiated) {
                V2SessionProjection(snapshot: snapshot, maximumItems: maximumItems)
            }.value
            // Advance the generation so any off-main mutation that captured the previous
            // projection (a history page started before this snapshot arrived) discards
            // its swap-back instead of overwriting the fresh snapshot.
            entry.foldGeneration += 1
            entry.projection = built
            invalidateCatalogs(entry)
            entry.error = nil
            emit(entry)
            evict()
            return entry.projection!.data
        }
        entry.loadTask = task
        return try await task.value
    }

    private func start(_ entry: Entry) {
        guard isCurrent(entry), !entry.model.isLocalCreation, !suspended, network.availability != .offline,
              !entry.observers.isEmpty, entry.connectionTask == nil else { return }
        let connectionID = UUID()
        entry.connectionID = connectionID
        entry.connectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if entry.connectionID == connectionID { entry.connectionTask = nil }
            }
            var attempt = 0
            var diagN = 0; var diagT = ContinuousClock.now
            while self.isCurrent(entry), entry.connectionID == connectionID, !Task.isCancelled {
                do {
                    entry.connection = attempt == 0 ? .connecting : .reconnecting
                    self.emit(entry, persist: false)
                    _ = try await self.load(sessionId: entry.id)
                    if entry.needsSnapshot {
                        _ = try await self.hydrate(entry)
                        entry.needsSnapshot = false
                    }
                    let events = try await self.detail.updates(sessionId: entry.id, clientId: "ios-session-\(connectionID)")
                    for try await event in events {
                        try self.requireCurrent(entry)
                        guard entry.connectionID == connectionID else { return }
                        if event.type == "session.subscribed" {
                            // The socket is registered before recovery, closing the snapshot/subscribe race.
                            try await self.reconcile(entry)
                            try self.requireCurrent(entry)
                            guard entry.connectionID == connectionID else { return }
                            entry.connection = .connected
                            attempt = 0
                            self.emit(entry, persist: false)
                        } else {
                            try await self.receive(event, entry: entry)
                        }
                        diagN += 1
                        if diagN >= 20 || aaDiagMs(diagT.duration(to: .now)) > 50 {
                            AADiag.event("ws_batch", ["n": diagN, "ms": aaDiagMs(diagT.duration(to: .now)), "items": entry.projection?.data.items.count ?? 0])
                            diagN = 0; diagT = .now
                        }
                    }
                    throw CacheError.connectionClosed
                } catch {
                    guard self.isCurrent(entry), entry.connectionID == connectionID, !Task.isCancelled else { return }
                    entry.projection?.markStale()
                    self.invalidateCatalogs(entry)
                    let failure = V2ClientFailure(error)
                    entry.error = failure
                    guard failure.permitsAutomaticReconnect else {
                        entry.connection = .failed(failure.message)
                        self.emit(entry, persist: false)
                        return
                    }
                    entry.connection = .reconnecting
                    self.emit(entry, persist: false)
                    attempt += 1
                    do { try await self.sleep(.seconds(min(1 << min(attempt - 1, 4), 15))) }
                    catch { return }
                }
            }
        }
    }

    private func receive(_ event: V2SessionEvent, entry: Entry) async throws {
        guard event.sessionId == entry.id else { return }
        if let pending = entry.loadTask { _ = try await pending.value }
        if let pending = entry.recoveryTask { try await pending.value }
        if event.type == "session.refetch_required" || event.sequence > effectiveSequence(entry) + 1 {
            try await reconcile(entry)
        }
        try requireCurrent(entry)
        let readTypes = ["runtime.state.updated", "runtime.capability.updated", "runtime.notice.snapshot", "runtime.notice.updated"]
        if readTypes.contains(event.type), event.receivedAt < entry.projectionBarrier { return }
        if event.type == "timeline.snapshot", event.sequence >= effectiveSequence(entry) {
            entry.readVersion += 1
            entry.historyTask?.cancel()
            entry.historyTask = nil
        }
        // Batch coalescing: applying a batch decodes every payload, merges it into the
        // timeline window and re-sorts it (measured 300–540 ms per ~103-item batch on the
        // main actor). The socket loop now only queues; scheduleFold(_:) folds consecutive
        // batches on a background task and the main actor swaps in only the final
        // projection once per fold. Catalog invalidation, online edges and the reconcile
        // they trigger are derived per-event inside the fold, exactly as they were here.
        entry.pendingEvents.append(event)
        scheduleFold(entry)
    }

    /// The cursor including every event this generation has handed to the fold machinery.
    /// While a fold is in flight `projection.sequence` trails it; comparing a live event
    /// against the trailed value would misread consecutive events as a gap and trigger a
    /// spurious recovery.
    private func effectiveSequence(_ entry: Entry) -> Int {
        max(entry.projection?.sequence ?? 0, entry.foldScheduledSeq ?? 0, entry.pendingEvents.last?.sequence ?? 0)
    }

    /// Queue coalescing for live batches — the session-socket sibling of the dashboard
    /// frame slot. One fold per session at a time: queued events are applied to a copy of
    /// the projection on a background task (payload decode, merge and full-window sort all
    /// leave the main actor); the main actor applies the minimal diff — swapping in the
    /// finished projection, applying derived catalog invalidation, and one coalesced emit.
    /// Events arriving while a fold runs wait in `pendingEvents` and ride the next fold,
    /// so a burst applies its terminal state, not every intermediate state.
    private func scheduleFold(_ entry: Entry) {
        guard entry.foldTask == nil, !entry.pendingEvents.isEmpty else { return }
        let connectionID = entry.connectionID
        entry.foldGeneration += 1
        let foldGeneration = entry.foldGeneration
        entry.foldTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if entry.foldGeneration == foldGeneration, entry.foldTask != nil { entry.foldTask = nil }
            }
            while !Task.isCancelled, !entry.pendingEvents.isEmpty,
                  self.isCurrent(entry), entry.connectionID == connectionID {
                let pending = entry.pendingEvents
                entry.pendingEvents.removeAll()
                let base = entry.projection
                let baseSeq = base?.sequence ?? 0
                // Events already covered by a snapshot-level replacement (for example a
                // hydrate that ran while this fold was scheduled) must not replay stale
                // payloads over it; `apply` guards the cursor per event too, dropping the
                // whole replay prefix here keeps the fold work minimal.
                let batch = pending.filter { $0.sequence > baseSeq }
                entry.foldScheduledSeq = pending.last?.sequence
                guard let snapshot = base else {
                    // A generation without a projection refetches through recover(after:).
                    self.abandonFoldQueue(entry)
                    return
                }
                guard !batch.isEmpty else { entry.foldScheduledSeq = nil; continue }
                do {
                    let outcome = try await Task.detached(priority: .userInitiated) {
                        var projection = snapshot
                        var invalidate = false
                        var reconcileNeeded = false
                        for event in batch {
                            let wasOnline = projection.data.session.connectorStatus == .online
                            let previousRuntime = projection.data.session.effectiveRuntimeId
                            try projection.apply(event)
                            if event.type == "runtime.catalog.updated" || projection.data.session.connectorStatus != .online {
                                invalidate = true
                            }
                            if projection.data.session.connectorStatus == .online,
                               !wasOnline || previousRuntime != projection.data.session.effectiveRuntimeId {
                                reconcileNeeded = true
                            }
                        }
                        return (projection: projection, invalidate: invalidate, reconcileNeeded: reconcileNeeded)
                    }.value
                    guard self.isCurrent(entry), entry.connectionID == connectionID,
                          entry.foldGeneration == foldGeneration, !Task.isCancelled else {
                        self.abandonFoldQueue(entry)
                        return
                    }
                    entry.foldScheduledSeq = nil
                    entry.projection = outcome.projection
                    if outcome.invalidate { self.invalidateCatalogs(entry) }
                    self.emitAfterBacklog(entry)
                    if outcome.reconcileNeeded {
                        // Recovery takes the fold slot for its own off-main apply; release it
                        // before awaiting so reconcile(_:) can drain it. The socket loop
                        // blocks on `recoveryTask`, so no event queues during recovery.
                        entry.foldTask = nil
                        do { try await self.reconcile(entry) }
                        catch { await self.failFoldGeneration(error, entry: entry, connectionID: connectionID); return }
                        if entry.foldTask == nil { self.scheduleFold(entry) }
                        return
                    }
                } catch {
                    await self.failFoldGeneration(error, entry: entry, connectionID: connectionID)
                    return
                }
            }
            entry.foldScheduledSeq = nil
        }
    }

    /// Replays the connection loop's failure handling for failures detected inside a fold
    /// (a malformed event, or the post-fold reconcile that the old inline path surfaced to
    /// that loop). The loop owns its attempt counter locally, so this path runs the loop's
    /// first-reconnect backoff once, tears down the stream generation — whose loop catch
    /// sees the cancellation and exits — and lets `start(_:)` open the next generation.
    /// The dropped queue belongs to the dead generation; it refetches through
    /// recover(after: cursor), so no event content is lost.
    private func failFoldGeneration(_ error: Error, entry: Entry, connectionID: UUID) async {
        abandonFoldQueue(entry)
        guard isCurrent(entry), entry.connectionID == connectionID, !Task.isCancelled else { return }
        entry.projection?.markStale()
        invalidateCatalogs(entry)
        let failure = V2ClientFailure(error)
        entry.error = failure
        entry.connectionTask?.cancel()
        guard failure.permitsAutomaticReconnect else {
            entry.connection = .failed(failure.message)
            emit(entry, persist: false)
            return
        }
        entry.connection = .reconnecting
        emit(entry, persist: false)
        do { try await sleep(.seconds(1)) }
        catch { return }
        guard isCurrent(entry), entry.connectionID == connectionID, !Task.isCancelled else { return }
        start(entry)
    }

    private func abandonFoldQueue(_ entry: Entry) {
        entry.pendingEvents.removeAll()
        entry.foldScheduledSeq = nil
    }

    /// Waits until the fold slot is free and every queued event has been applied. Every
    /// main-actor path that reads or mutates the projection outside the fold machinery
    /// suspends behind this first, so a swap-back never clobbers its result.
    private func drainFolds(_ entry: Entry) async {
        while let fold = entry.foldTask { await fold.value }
    }

    /// Runs one heavy projection mutation (history-page merge with full-window re-sort,
    /// or recovery-event apply) on a background task, serialized with live folds through
    /// the same fold slot: wait for in-flight folds, take the slot synchronously so no
    /// live event can start a competing fold in between, apply to a copy off the main
    /// actor, then swap the result back in only while the slot was never taken away —
    /// stop()/refresh() advance the generation, and their state wins over this swap.
    private func offMainFold(_ entry: Entry, _ work: @escaping @Sendable (V2SessionProjection) throws -> V2SessionProjection) async throws {
        await drainFolds(entry)
        guard let base = entry.projection else { return }
        entry.foldGeneration += 1
        let foldGeneration = entry.foldGeneration
        let detached = Task.detached(priority: .userInitiated) { try work(base) }
        // foldTask is Task<Void, Never>; drainFolds only needs a completion signal, so
        // the slot holds a waiter that mirrors the throwing work task. The work itself
        // is awaited through `detached` below and its error rethrown to the caller.
        let waiter = Task<Void, Never> { _ = try? await detached.value }
        entry.foldTask = waiter
        let result: V2SessionProjection
        do {
            result = try await detached.value
        } catch {
            if entry.foldGeneration == foldGeneration { entry.foldTask = nil }
            throw error
        }
        guard entry.foldGeneration == foldGeneration else { return }
        entry.projection = result
        if entry.foldGeneration == foldGeneration { entry.foldTask = nil }
        if entry.foldTask == nil, !entry.pendingEvents.isEmpty { scheduleFold(entry) }
    }

    private func reconcile(_ entry: Entry) async throws {
        if let task = entry.recoveryTask { return try await task.value }
        let version = entry.connectionID
        let task = Task { [self] in
            defer { if entry.connectionID == version { entry.recoveryTask = nil } }
            // Recovery reads the cursor from the projection: drain any in-flight fold
            // first so its swap-back cannot land under us. The socket loop blocks on
            // recoveryTask, so no new event queues while recovery runs.
            await drainFolds(entry)
            if entry.projection == nil { _ = try await hydrate(entry) }
            let cursor = entry.projection!.data.cursor
            let recovery = try await detail.recover(sessionId: entry.id, after: cursor)
            try requireCurrent(entry)
            guard entry.connectionID == version else { throw CacheError.invalidated }
            if recovery.snapshotRequired {
                _ = try await hydrate(entry)
            } else {
                let events = recovery.events.sorted { $0.sequence < $1.sequence }
                try await offMainFold(entry) { projection in
                    var projection = projection
                    for event in events { try projection.apply(event) }
                    return projection
                }
                entry.projection?.advanceCursor(recovery.nextCursor)
            }
            entry.projection?.markStale()
            invalidateCatalogs(entry)
            if entry.projection?.data.session.connectorStatus == .online {
                // Frames received before this read must not overwrite its newer live projection.
                let barrier = now()
                do {
                    let live = try await detail.liveState(sessionId: entry.id)
                    try requireCurrent(entry)
                    guard entry.connectionID == version else { throw CacheError.invalidated }
                    entry.projection?.applyLive(live)
                    entry.projectionBarrier = barrier
                    entry.error = nil
                } catch {
                    try requireCurrent(entry)
                    guard entry.connectionID == version else { throw CacheError.invalidated }
                    entry.error = V2ClientFailure(error)
                    throw error
                }
            }
            emit(entry)
        }
        entry.recoveryTask = task
        return try await task.value
    }

    private func entry(for id: V2SessionID) -> Entry {
        // A view may look up its stable model while a containing sidebar moves.
        // Re-projecting here walks every historical item and also registers all
        // of those observable values as dependencies of the caller's view body.
        if let entry = entries[id] { touch(entry); return entry }
        let entry = Entry(id: id, model: V2SessionModel(id: id, scope: scope, repository: self))
        entries[id] = entry
        touch(entry)
        if network.availability == .offline { entry.connection = .offline }
        entry.model.update(observation(entry), network: network)
        return entry
    }

    private func touch(_ entry: Entry) { accessCounter += 1; entry.lastAccess = accessCounter }
    private func isCurrent(_ entry: Entry) -> Bool { entries[entry.id] === entry }

    private func requireCurrent(_ entry: Entry, version: Int? = nil) throws {
        try Task.checkCancellation()
        guard isCurrent(entry), version == nil || version == entry.readVersion else { throw CacheError.invalidated }
    }

    private func observation(_ entry: Entry) -> V2SessionObservation {
        V2SessionObservation(sessionId: entry.id, data: entry.projection?.data, connection: entry.connection, error: entry.error)
    }

    /// Frames buffered during a reconnect or a long reconcile are delivered
    /// back-to-back without suspending. Publishing once the main queue turns
    /// again lets the whole backlog apply before the model and rows re-project,
    /// so catch-up cost is frames × log n instead of frames × n.
    private func emitAfterBacklog(_ entry: Entry) {
        guard !entry.emitScheduled else { return }
        entry.emitScheduled = true
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry else { return }
            entry.emitScheduled = false
            self.emit(entry)
        }
    }

    /// `persist` marks durable changes (timeline, metadata, cursor, local work).
    /// Connection and connectivity transitions republish without an archive write.
    private func emit(_ entry: Entry, persist: Bool = true) {
        guard isCurrent(entry) else { return }
        // Build the observation once: V2SessionData carries the whole timeline window,
        // and calling observation(entry) twice forced two full value copies per emit —
        // the measured copy hot spot while folds hammered this path.
        let snapshot = observation(entry)
        entry.model.update(snapshot, network: network)
        for observer in entry.observers.values { observer.yield(snapshot) }
        if persist, entry.projection != nil {
            entry.isDirty = true
            schedulePersistence()
        }
    }

    private func invalidateCatalogs(_ entry: Entry) {
        entry.catalogVersion += 1
        entry.catalogs = nil
        entry.catalogReadAt = nil
        entry.commands = nil
        entry.catalogTask?.cancel()
        entry.catalogTask = nil
    }

    private func stop(_ entry: Entry) {
        entry.connectionID = UUID()
        entry.connectionTask?.cancel()
        entry.connectionTask = nil
        // The queue belongs to the dead generation: its events refetch through
        // recover(after: cursor) on the next start, so dropping them loses no content.
        entry.foldGeneration += 1
        entry.foldTask?.cancel()
        entry.foldTask = nil
        entry.pendingEvents.removeAll()
        entry.foldScheduledSeq = nil
        entry.recoveryTask?.cancel()
        entry.recoveryTask = nil
        entry.connection = .inactive
        entry.projection?.markStale()
        invalidateCatalogs(entry)
        emit(entry, persist: false)
    }

    private func dispose(_ entry: Entry) {
        stop(entry)
        entry.loadTask?.cancel()
        entry.historyTask?.cancel()
        for observer in entry.observers.values { observer.finish() }
        entry.observers.removeAll()
        entry.model.invalidate()
    }

    private func evict(protecting protected: Entry? = nil) {
        let candidates = entries.values.filter {
            $0 !== protected && $0.observers.isEmpty && $0.loadTask == nil && $0.catalogTask == nil
                && $0.historyTask == nil && !$0.model.hasLocalWork
        }
            .sorted { $0.lastAccess < $1.lastAccess }
        for entry in candidates where entries.count > max(1, policy.maximumSessions) {
            entries.removeValue(forKey: entry.id)
            dispose(entry)
        }
    }
}

@MainActor
private final class Entry {
    let id: V2SessionID
    let model: V2SessionModel
    var needsSnapshot = false
    var hasReadLocal = false
    var isDirty = false
    var emitScheduled = false
    var localReadTask: Task<V2SessionRestore?, Never>?
    var projection: V2SessionProjection?
    /// Live events queued for the next background fold (not yet applied to the projection).
    var pendingEvents: [V2SessionEvent] = []
    /// The one running fold for this session, or nil. Doubles as the off-main history/
    /// recovery mutation slot — every main-actor path that mutates the projection outside
    /// the fold machinery drains behind it first.
    var foldTask: Task<Void, Never>?
    /// Highest sequence already handed to fold machinery (kept across folds for gap checks).
    var foldScheduledSeq: Int?
    /// Bumped whenever fold ownership changes hands (schedule / stop / off-main fold);
    /// an in-flight swap-back is discarded when the generation no longer matches.
    var foldGeneration = 0
    var connection = V2SessionConnectionState.inactive
    var error: V2ClientFailure?
    var lastAccess = 0
    var readVersion = 0
    var catalogVersion = 0
    var projectionBarrier = Date.distantPast
    var connectionID = UUID()
    var observers: [UUID: AsyncStream<V2SessionObservation>.Continuation] = [:]
    var loadTask: Task<V2SessionData, Error>?
    var historyTask: Task<V2SessionData, Error>?
    var catalogTask: Task<V2SessionCatalogs, Error>?
    var recoveryTask: Task<Void, Error>?
    var connectionTask: Task<Void, Never>?
    var catalogs: V2SessionCatalogs?
    var catalogScopes: Set<String>?
    var catalogReadAt: Date?
    var commands: [V2RuntimeCommand]?

    init(id: V2SessionID, model: V2SessionModel) { self.id = id; self.model = model }
}

private enum CacheError: LocalizedError {
    case invalidated
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidated: String(localized: "The session request no longer belongs to the active cache.")
        case .connectionClosed: String(localized: "The session connection closed.")
        }
    }
}
