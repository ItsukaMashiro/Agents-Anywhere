import Foundation
import Darwin

// LAN diagnostics logging (v1). Every declaration here is explicitly nonisolated:
// the target compiles with SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor and nothing in
// this module may pin work to the main actor. Disk writes are raw-fd appends;
// uploads, heartbeat and the stall watchdog live on dedicated queues.
// Privacy: paths only (never queries/tokens), never message content.

private let kAADiagURLKey = "AA_LAN_LOG_URL"
private let kAADiagDefaultURL = "http://10.0.0.241:8099/njlog?name=AgentsAnywhereDiagnostics"
private let kAADiagSentOffsetKey = "AADiag.sentOffset"
private let kAADiagMaxFileBytes = 6 * 1024 * 1024
private let kAADiagMaxPostBytes = 8 * 1024 * 1024
private let kAADiagLineCapBytes = 1500
private let kAADiagCrashPayloadBytes = 4096

// Shared state: nonisolated(unsafe); synchronized by aaDiagLock where noted.
// Signal-handler state is pre-built at start so the handler performs no allocation,
// no DNS, and no Objective-C runtime work.

nonisolated(unsafe) private var aaDiagLock = NSLock()
nonisolated(unsafe) private var aaDiagStarted = false
nonisolated(unsafe) private var aaDiagFD: Int32 = -1            // active.ndjson append fd (guarded)
nonisolated(unsafe) private var aaDiagFilePath = ""
nonisolated(unsafe) private var aaDiagDirPath = ""
nonisolated(unsafe) private var aaDiagLaunch = "-"
nonisolated(unsafe) private var aaDiagStageValue = "boot"
nonisolated(unsafe) private var aaDiagLinesSinceUpload = 0
nonisolated(unsafe) private var aaDiagSentOffset = 0
nonisolated(unsafe) private var aaDiagUploadQueue: DispatchQueue?
nonisolated(unsafe) private var aaDiagTimer: DispatchSourceTimer?
nonisolated(unsafe) private var aaDiagNetFailures: [String: Int] = [:]
nonisolated(unsafe) private var aaDiagLaunchBytes: [UInt8] = Array("-".utf8)
nonisolated(unsafe) private var aaDiagStageBytes: [UInt8] = Array("boot".utf8)
nonisolated(unsafe) private var aaDiagHeadBytes: [UInt8] = []   // pre-formatted crash HTTP POST head
nonisolated(unsafe) private var aaDiagHeadLen = 0
nonisolated(unsafe) private var aaDiagCrashIP: UInt32 = 0       // network byte order; 0 = skip socket attempt
nonisolated(unsafe) private var aaDiagCrashPort: UInt16 = 0     // network byte order
nonisolated(unsafe) private var aaDiagScratch: UnsafeMutablePointer<UInt8>?
nonisolated(unsafe) private var aaDiagFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
nonisolated(unsafe) private var aaDiagObjcCrashDone = false

nonisolated enum AADiag {
    /// Idempotent; call once from App init. Brings up disk spool, upload queue,
    /// heartbeat, stall watchdog and crash handlers on background queues.
    static func start() {
        aaDiagLock.lock()
        if aaDiagStarted {
            aaDiagLock.unlock()
            return
        }
        aaDiagStarted = true
        aaDiagUploadQueue = DispatchQueue(label: "aa.diag.uploader", qos: .utility)
        let queue = aaDiagUploadQueue
        aaDiagLock.unlock()
        queue?.async { aaDiagBootstrap() }
    }

    static func event(_ kind: String, _ fields: [String: Any] = [:]) {
        aaDiagWriteRecord(kind: kind, fields: fields, capBytes: kAADiagLineCapBytes)
    }

    /// Records the "current phase" atomically; attached to every subsequent line.
    static func stage(_ s: String) {
        aaDiagLock.lock()
        aaDiagStageValue = s
        var bytes = Array(s.utf8.prefix(64))
        if bytes.isEmpty { bytes = [0x2D] }
        aaDiagStageBytes = bytes
        aaDiagLock.unlock()
    }

    static func metric(_ name: String, ms: Double, bytes: Int = -1, _ extra: [String: Any] = [:]) {
        var fields = extra
        fields["ms"] = ms
        if bytes >= 0 { fields["bytes"] = bytes }
        aaDiagWriteRecord(kind: name, fields: fields, capBytes: kAADiagLineCapBytes)
    }

    /// Nudges the spooler now (scenePhase → background).
    static func flush() {
        aaDiagScheduleUpload()
    }

    /// Heartbeat tick on the upload queue: beat line + spool.
    static func heartbeatTick() {
        event("beat", ["kb": aaDiagFootprintKB()])
        aaDiagSpoolOnce()
    }
}

nonisolated func aaDiagMs(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

// MARK: - Line writer

nonisolated private func aaDiagNowMs() -> Double {
    Date().timeIntervalSince1970 * 1000
}

nonisolated private func aaDiagWriteRecord(kind: String, fields: [String: Any], capBytes: Int) {
    aaDiagLock.lock()
    let fd = aaDiagFD
    let launch = aaDiagLaunch
    let stageNow = aaDiagStageValue
    aaDiagLock.unlock()
    guard fd >= 0 else { return }
    let t = Int(aaDiagNowMs())
    var payload: [String: Any] = ["t": t, "launch": launch, "kind": kind, "stage": stageNow]
    for (key, value) in fields {
        if value is String || value is NSNumber { payload[key] = value }
    }
    guard JSONSerialization.isValidJSONObject(payload), var body = try? JSONSerialization.data(withJSONObject: payload) else { return }
    if body.count > capBytes {
        guard let minimal = try? JSONSerialization.data(withJSONObject: ["t": t, "launch": launch, "kind": kind, "trunc": true]) else { return }
        body = minimal
    }
    body.append(0x0A)
    aaDiagLock.lock()
    let liveFD = aaDiagFD
    if liveFD >= 0 {
        body.withUnsafeBytes { raw in _ = write(liveFD, raw.baseAddress, body.count) }
        aaDiagLinesSinceUpload += 1
    }
    let due = aaDiagLinesSinceUpload >= 25
    if due { aaDiagLinesSinceUpload = 0 }
    aaDiagLock.unlock()
    if due { aaDiagScheduleUpload() }
}

// MARK: - Bootstrap (runs once on the upload queue)

nonisolated private func aaDiagBootstrap() {
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
    let dir = support.appendingPathComponent("AADiagnostics", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("active.ndjson").path
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    let launch = String(format: "%08x", arc4random())
    var st = stat()
    fstat(fd, &st)
    let size = Int(st.st_size)
    var stored = UserDefaults.standard.integer(forKey: kAADiagSentOffsetKey)
    if stored < 0 || stored > size { stored = size }
    aaDiagLock.lock()
    aaDiagFD = fd
    aaDiagFilePath = path
    aaDiagDirPath = dir.path
    aaDiagLaunch = launch
    aaDiagLaunchBytes = Array(launch.utf8)
    aaDiagSentOffset = stored
    aaDiagLock.unlock()
    let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: kAADiagCrashPayloadBytes)
    for i in 0..<kAADiagCrashPayloadBytes { scratch[i] = 0x0A }
    aaDiagScratch = scratch
    aaDiagFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
    aaDiagPrepareCrashEndpoint()
    NSSetUncaughtExceptionHandler(aaDiagObjcUncaught)
    for sgn in [SIGABRT, SIGILL, SIGTRAP, SIGFPE, SIGBUS, SIGSEGV] {
        _ = signal(sgn, aaDiagSignalCatcher)
    }
    AADiag.event("launch", ["platform": "ios"])
    let queue = aaDiagUploadQueue
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 15, repeating: 30)
    timer.setEventHandler { AADiag.heartbeatTick() }
    timer.resume()
    aaDiagTimer = timer
    aaDiagStartWatchdog()
    // Spool pre-crash lines from the previous launch soon after boot.
    queue?.asyncAfter(deadline: .now() + 10) { aaDiagScheduleUpload() }
}

nonisolated private func aaDiagFootprintKB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1024) : -1
}

// MARK: - Upload spool (upload queue only; may block its own thread, never MainActor)

nonisolated private func aaDiagScheduleUpload() {
    aaDiagUploadQueue?.async { aaDiagSpoolOnce() }
}

nonisolated private func aaDiagUploadURL() -> URL? {
    if let raw = UserDefaults.standard.string(forKey: kAADiagURLKey), let url = URL(string: raw) { return url }
    if let plist = Bundle.main.object(forInfoDictionaryKey: kAADiagURLKey) as? String, let url = URL(string: plist) { return url }
    return URL(string: kAADiagDefaultURL)
}

nonisolated private func aaDiagSpoolOnce() {
    aaDiagLock.lock()
    let path = aaDiagFilePath
    let offset = aaDiagSentOffset
    let fd = aaDiagFD
    aaDiagLock.unlock()
    guard fd >= 0, !path.isEmpty else { return }
    let rfd = open(path, O_RDONLY)
    guard rfd >= 0 else { return }
    defer { close(rfd) }
    var st = stat()
    guard fstat(rfd, &st) == 0 else { return }
    let size = Int(st.st_size)
    guard size > offset else {
        aaDiagTryRotate(activeSize: size)
        return
    }
    let want = min(size - offset, kAADiagMaxPostBytes)
    var buffer = Data(count: want)
    let got = buffer.withUnsafeMutableBytes { raw in pread(rfd, raw.baseAddress, want, off_t(offset)) }
    guard got > 0 else { return }
    if got < want { buffer = buffer.prefix(got) }
    let code = aaDiagPostData(buffer)
    if code == 200 {
        aaDiagLock.lock()
        aaDiagSentOffset = offset + got
        let persist = aaDiagSentOffset
        aaDiagLock.unlock()
        UserDefaults.standard.set(persist, forKey: kAADiagSentOffsetKey)
        aaDiagTryRotate(activeSize: size)
    } else {
        aaDiagNoteNetFailure(class: code == -1 ? "url" : code == -2 ? "timeout" : "http\(code)")
    }
}

nonisolated private func aaDiagPostData(_ body: Data) -> Int {
    guard let url = aaDiagUploadURL() else { return -1 }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 8
    config.urlCache = nil
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var statusCode = -2
    let task = session.dataTask(with: request) { _, response, error in
        if error == nil, let http = response as? HTTPURLResponse { statusCode = http.statusCode }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + 6) == .timedOut {
        task.cancel()
        return -2
    }
    return statusCode
}

nonisolated private func aaDiagNoteNetFailure(class key: String) {
    aaDiagLock.lock()
    let count = (aaDiagNetFailures[key] ?? 0) + 1
    aaDiagNetFailures[key] = count
    let shouldLog = count <= 3 || count % 50 == 0
    aaDiagLock.unlock()
    if shouldLog {
        aaDiagWriteRecord(kind: "netup_fail", fields: ["class": key, "count": count], capBytes: 400)
    }
}

/// active.ndjson > 6MB and fully uploaded → rename to spill-<ts>.ndjson + reset (upload queue only).
nonisolated private func aaDiagTryRotate(activeSize: Int) {
    guard activeSize > kAADiagMaxFileBytes else { return }
    aaDiagLock.lock()
    guard aaDiagSentOffset >= activeSize, aaDiagFD >= 0 else {
        aaDiagLock.unlock()
        return
    }
    let old = aaDiagFilePath
    let stamp = Int(aaDiagNowMs() / 1000)
    let spill = (aaDiagDirPath as NSString).appendingPathComponent("spill-\(stamp).ndjson")
    close(aaDiagFD)
    let renamed = rename(old, spill) == 0
    let fd = open(old, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    aaDiagFD = fd
    var reset = false
    if fd >= 0 {
        aaDiagSentOffset = 0
        reset = renamed
    }
    aaDiagLock.unlock()
    if reset { UserDefaults.standard.set(0, forKey: kAADiagSentOffsetKey) }
}

// MARK: - Main-thread stall watchdog (dedicated thread)

nonisolated private func aaDiagStartWatchdog() {
    DispatchQueue(label: "aa.diag.watchdog", qos: .utility).async {
        Thread.sleep(forTimeInterval: 5) // launch grace: main queue is busy booting
        while !Task.isCancelled {
            let sem = DispatchSemaphore(value: 0)
            let t0 = ContinuousClock.now
            DispatchQueue.main.async { sem.signal() }
            let timedOut = sem.wait(timeout: .now() + 10) == .timedOut
            let ms = aaDiagMs(t0.duration(to: .now))
            if ms > 5000 || timedOut {
                aaDiagWriteRecord(kind: "stall_severe", fields: ["delay_ms": ms, "kb": aaDiagFootprintKB()], capBytes: 400)
            } else if ms > 1000 {
                aaDiagWriteRecord(kind: "stall", fields: ["delay_ms": ms, "kb": aaDiagFootprintKB()], capBytes: 400)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

// MARK: - Crash capture

/// Parses the endpoint once so the signal handler never allocates or resolves names.
nonisolated private func aaDiagPrepareCrashEndpoint() {
    guard let url = aaDiagUploadURL(), let host = url.host else { return }
    let port = url.port ?? (url.scheme == "https" ? 443 : 80)
    var ipAddr = in_addr(s_addr: 0)
    var resolved = false
    if inet_aton(host, &ipAddr) != 0 {
        resolved = true
    } else {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_addr: nil, ai_canonname: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &hints, &res) == 0, let r = res, let sa = r.pointee.ai_addr {
            ipAddr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            resolved = true
        }
        if let r = res { freeaddrinfo(r) }
    }
    // The last-gasp socket speaks plain HTTP; never attempt TLS from a signal handler.
    guard resolved, url.scheme != "https" else { return }
    var path = url.path.isEmpty ? "/" : url.path
    if let query = url.query { path += "?\(query)" }
    let hostHeader = url.port == nil ? host : "\(host):\(port)"
    let head = "POST \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nContent-Type: application/x-ndjson\r\nContent-Length: \(kAADiagCrashPayloadBytes)\r\nConnection: close\r\n\r\n"
    let bytes = Array(head.utf8)
    aaDiagHeadBytes = bytes
    aaDiagHeadLen = bytes.count
    aaDiagCrashIP = ipAddr.s_addr
    aaDiagCrashPort = in_port_t(port).bigEndian
}

// Async-signal-safe buffer writes: raw pointers only; arrays are read, never mutated.
nonisolated private func aaDiagPutStr(_ b: UnsafeMutablePointer<UInt8>, _ o: inout Int, _ s: StaticString) {
    s.withUTF8 { p, len in
        var i = 0
        while i < len { b[o + i] = p[i]; i += 1 }
        o += len
    }
}

nonisolated private func aaDiagPutInt(_ b: UnsafeMutablePointer<UInt8>, _ o: inout Int, _ value: UInt64) {
    var v = value
    if v == 0 { b[o] = 0x30; o += 1; return }
    var probe = v
    var digits = 0
    while probe > 0 { probe /= 10; digits += 1 }
    var shift = digits
    while shift > 0 {
        shift -= 1
        b[o + shift] = 0x30 + UInt8(v % 10)
        v /= 10
    }
    o += digits
}

nonisolated private func aaDiagPutBytes(_ b: UnsafeMutablePointer<UInt8>, _ o: inout Int, _ src: [UInt8], _ limit: Int) {
    var i = 0
    while i < src.count && i < limit && o + i < kAADiagCrashPayloadBytes - 1 {
        b[o + i] = src[i]
        i += 1
    }
    o += i
}

nonisolated private func aaDiagEmitCrash(_ sig: Int32) {
    guard let s = aaDiagScratch else { return }
    if aaDiagObjcCrashDone && sig == SIGABRT { return } // exception handler already recorded it
    var n = 0
    aaDiagPutStr(s, &n, "{\"t\":")
    aaDiagPutInt(s, &n, UInt64(bitPattern: Int64(time(nil))) * 1000)
    aaDiagPutStr(s, &n, ",\"launch\":\"")
    aaDiagPutBytes(s, &n, aaDiagLaunchBytes, 16)
    aaDiagPutStr(s, &n, "\",\"kind\":\"crash\",\"signal\":")
    aaDiagPutInt(s, &n, sig < 0 ? 0 : UInt64(sig))
    aaDiagPutStr(s, &n, ",\"stage\":\"")
    aaDiagPutBytes(s, &n, aaDiagStageBytes, 64)
    aaDiagPutStr(s, &n, "\"}\n")
    let fd = aaDiagFD
    if fd >= 0 {
        _ = write(fd, s, n)
        if let frames = aaDiagFrames {
            let count = backtrace(frames, 64)
            if count > 0 { backtrace_symbols_fd(frames, count, fd) }
        }
    }
    // Last-gasp LAN POST: fixed 4096-byte payload (crash line + '\n' padding).
    let ip = aaDiagCrashIP
    let headLen = aaDiagHeadLen
    guard ip != 0, headLen > 0 else { return }
    while n < kAADiagCrashPayloadBytes { s[n] = 0x0A; n += 1 }
    aaDiagCrashLastGasp()
}

nonisolated private func aaDiagCrashLastGasp() {
    guard let s = aaDiagScratch else { return }
    let sf = socket(AF_INET, SOCK_STREAM, 0)
    guard sf >= 0 else { return }
    _ = fcntl(sf, F_SETFL, O_NONBLOCK)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = aaDiagCrashPort
    addr.sin_addr = in_addr(s_addr: aaDiagCrashIP)
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sf, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var pfd = pollfd(fd: sf, events: Int16(POLLOUT), revents: 0)
    _ = poll(&pfd, 1, 300)
    let head = aaDiagHeadBytes
    var off = 0
    var attempts = 0
    let total = aaDiagHeadLen + kAADiagCrashPayloadBytes
    while off < total && attempts < 8 {
        let sent: Int
        if off < aaDiagHeadLen {
            sent = head.withUnsafeBytes { raw in send(sf, raw.baseAddress?.advanced(by: off), total - off, 0) }
        } else {
            sent = send(sf, s + (off - aaDiagHeadLen), total - off, 0)
        }
        if sent > 0 {
            off += sent
        } else {
            attempts += 1
            var wait = pollfd(fd: sf, events: Int16(POLLOUT), revents: 0)
            _ = poll(&wait, 1, 150)
        }
    }
    close(sf)
}

/// Top-level non-capturing function auto-converts to @convention(c); no state captured.
nonisolated private func aaDiagSignalCatcher(_ sig: Int32) {
    aaDiagEmitCrash(sig)
    _ = signal(sig, SIG_DFL)
    raise(sig)
}

nonisolated private func aaDiagObjcUncaught(_ exception: NSException) {
    aaDiagObjcCrashDone = true
    var stack = exception.callStackSymbols.joined(separator: "\n")
    if stack.utf8.count > 20_000 { stack = String(decoding: stack.utf8.prefix(20_000), as: UTF8.self) }
    var fields: [String: Any] = ["exception": "objc", "name": exception.name.rawValue, "stack": stack]
    if let reason = exception.reason { fields["reason"] = String(reason.prefix(1000)) }
    aaDiagWriteRecord(kind: "crash", fields: fields, capBytes: 24_000)
}
