import Foundation

public struct TerrainDiskCacheMetrics: Sendable, Encodable {
  public var entries = 0, bytes = 0, limitBytes = 0, limitEntries = 0
  public var compressedWrites = 0, rawWriteBytes = 0, storedWriteBytes = 0
  public var compressionEnabled = false
  public var minimumSurfacePreparationMilliseconds: Double = 0
  public var inexpensiveSurfaceWritesSkipped = 0
  public var hits = 0, misses = 0, writes = 0, evictions = 0, invalid = 0, failures = 0
  public var oversized = 0, droppedWrites = 0, coalescedWrites = 0
  public var queuedWrites = 0, queuedBytes = 0
  public var mainThreadViolations = 0
  public var startupMilliseconds: Double = 0
  public var readCPU = DurationTiming().snapshot
  public var readQueueWait = DurationTiming().snapshot
  public var writeCPU = DurationTiming().snapshot
  public var archiveEncodingCPU = DurationTiming().snapshot
  public var fileWriteCPU = DurationTiming().snapshot
  public var writebackLatency = DurationTiming().snapshot
}

/// Optional, disposable derived data. Reads/index ownership and writeback use
/// separate utility executors: an archive being compressed or written cannot
/// hold up an existing cached tile. Publication never awaits optional writeback.
/// An unavailable cache simply falls back to generation.
actor TerrainDiskCache {
  static let shared: TerrainDiskCache = {
    // Diagnostic switch changes storage/admission policy only. It preserves
    // the same geometry, quota, actor isolation and current bookkeeping fixes.
    let legacy = ProcessInfo.processInfo.arguments.contains("--legacy-terrain-cache")
    return TerrainDiskCache(root: FileManager.default.urls(for: .cachesDirectory,
      in: .userDomainMask).first?.appendingPathComponent("Worldcraft/Terrain-v1", isDirectory: true),
      limitEntries: legacy ? 512 : 8_192, compressionEnabled: !legacy,
      minimumSurfacePreparationSeconds: legacy ? 0 : 0.001)
  }()
  private let executor = TerrainIOExecutor(label: "com.worldcraft.terrain-cache-read")
  nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
  private nonisolated let mailbox: TerrainDiskWriteQueue
  private let writer: TerrainArchiveWriter
  private let root: URL?
  private let limitBytes: Int, limitEntries: Int
  private let compressionEnabled: Bool
  private nonisolated let minimumSurfacePreparationSeconds: Double
  private struct Entry { let bytes: Int; var access: Double }
  private var entries: [String: Entry] = [:]
  private var recency = TerrainCacheRecency<String>()
  private var ordered = false
  private var started = false, available = false
  private var metrics = TerrainDiskCacheMetrics()
  private var readTiming = DurationTiming(), writeTiming = DurationTiming()
  private var readWaitTiming = DurationTiming(), encodingTiming = DurationTiming()
  private var fileWriteTiming = DurationTiming(), writebackTiming = DurationTiming()

  init(root: URL?, limitBytes: Int = 256 * 1_024 * 1_024, limitEntries: Int = 512,
    writeLimitBytes: Int = 32 * 1_024 * 1_024, writeLimitEntries: Int = 4, compressionEnabled: Bool = false,
    minimumSurfacePreparationSeconds: Double = 0, writer: TerrainArchiveWriter = .init()) {
    precondition(limitBytes > 0 && limitEntries > 0 && minimumSurfacePreparationSeconds >= 0
      && minimumSurfacePreparationSeconds.isFinite)
    self.root = root; self.limitBytes = limitBytes; self.limitEntries = limitEntries
    self.compressionEnabled = compressionEnabled
    self.writer = writer
    self.minimumSurfacePreparationSeconds = minimumSurfacePreparationSeconds
    mailbox = .init(limitBytes: writeLimitBytes, limitEntries: writeLimitEntries)
    metrics.limitBytes = limitBytes; metrics.limitEntries = limitEntries
    metrics.compressionEnabled = compressionEnabled
    metrics.minimumSurfacePreparationMilliseconds = minimumSurfacePreparationSeconds * 1_000
  }
  nonisolated var snapshot: TerrainDiskCacheMetrics { mailbox.snapshot }

  nonisolated func enqueue(_ payload: PreparedTerrainTile, key: TerrainPayloadKey) {
    // Simple surface proxies can cost less to regenerate than read + validate,
    // and admitting them displaces expensive voxel work. Keep complex surfaces
    // eligible using the actual generation/packing cost, excluding cache waits.
    let surfaceSeconds = (payload.stages["surface"] ?? 0) + (payload.stages["packing"] ?? 0)
      + (payload.stages["wind_partition"] ?? 0)
    guard payload.tile.fullDetail || surfaceSeconds >= minimumSurfacePreparationSeconds else {
      mailbox.skipInexpensiveSurface(); return
    }
    if mailbox.offer(payload, key: key) { Task { await drainOne() } }
  }

  nonisolated func value(for key: TerrainPayloadKey, id: TerrainWorkID) async -> PreparedTerrainTile? {
    guard !Task.isCancelled else { return nil }
    let name = TerrainPayloadCodec.filename(key)
    // Cold/moving terrain usually has no file. Consult the immutable filename
    // inventory without joining the I/O queue behind unrelated writes.
    if mailbox.definitelyAbsent(name) { return nil }
    return await load(key: key, id: id, name: name, requestedAt: ProcessInfo.processInfo.systemUptime)
  }
  private func load(key: TerrainPayloadKey, id: TerrainWorkID, name: String,
    requestedAt: TimeInterval) -> PreparedTerrainTile? {
    recordExecutorThread()
    readWaitTiming.record(seconds: ProcessInfo.processInfo.systemUptime - requestedAt)
    guard !Task.isCancelled else { return nil }
    start()
    let began = ProcessInfo.processInfo.systemUptime
    defer {
      readTiming.record(seconds: ProcessInfo.processInfo.systemUptime - began)
      publishMetrics()
    }
    guard available, let root, entries[name] != nil else { metrics.misses += 1; return nil }
    let url = root.appendingPathComponent(name)
    do {
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      // A changed/partial/oversized file cannot allocate beyond the entry cap.
      let data = try file.read(upToCount: TerrainPayloadCodec.maximumBytes + 1) ?? Data()
      guard !Task.isCancelled else { return nil }
      guard let archive = TerrainArchiveCompression.decode(data),
        let value = TerrainPayloadCodec.decode(archive, key: key, id: id) else {
        metrics.invalid += 1; metrics.misses += 1; remove(name); return nil
      }
      let previous = entries[name]?.access ?? 0, now = Date.timeIntervalSinceReferenceDate
      entries[name]?.access = now
      recency.touch(name)
      // Persist approximate LRU without a metadata write for every hit.
      if now - previous > 60 { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
      metrics.hits += 1
      return value
    } catch {
      metrics.failures += 1; metrics.misses += 1; remove(name); return nil
    }
  }

  private func drainOne() async {
    guard let item = mailbox.take() else { return }
    recordExecutorThread()
    start()
    let began = ProcessInfo.processInfo.systemUptime
    var suspendedSeconds = 0.0, workerSeconds = 0.0
    defer {
      let now = ProcessInfo.processInfo.systemUptime
      // These are elapsed operation durations, as with readCPU. Exclude actor
      // queue/suspension time from writeCPU; expose total enqueue-to-finish too.
      writeTiming.record(seconds: max(0, now - began - suspendedSeconds) + workerSeconds)
      writebackTiming.record(seconds: now - item.enqueuedAt)
      mailbox.finish(item)
      publishMetrics()
      Task { await drainOne() }
    }
    guard available, let root else { return }
    let name = TerrainPayloadCodec.filename(item.key)
    // Duplicate content already on disk needs no re-encoding or rewrite.
    guard entries[name] == nil else { return }
    let encodeBegan = ProcessInfo.processInfo.systemUptime
    let encoded = await writer.encode(item.payload, key: item.key, compressed: compressionEnabled)
    suspendedSeconds += ProcessInfo.processInfo.systemUptime - encodeBegan
    workerSeconds += encoded.seconds
    encodingTiming.record(seconds: encoded.seconds)
    if encoded.onMainThread { metrics.mainThreadViolations += 1 }
    guard let data = encoded.data else { metrics.oversized += 1; return }
    guard data.count <= limitBytes else { metrics.oversized += 1; return }
    // Reads can invalidate the cache while encoding is suspended. Re-check its
    // state before reserving disk capacity. The active item stays charged to the
    // bounded mailbox throughout both awaits; there is only one writer in flight.
    guard available, evict(addingBytes: data.count, addingEntries: 1), available else { return }
    let writeBegan = ProcessInfo.processInfo.systemUptime
    let stored = await writer.store(data, at: root.appendingPathComponent(name))
    suspendedSeconds += ProcessInfo.processInfo.systemUptime - writeBegan
    workerSeconds += stored.seconds
    fileWriteTiming.record(seconds: stored.seconds)
    if stored.onMainThread { metrics.mainThreadViolations += 1 }
    guard stored.succeeded else { metrics.failures += 1; return }
    // Only publish complete atomic writes. During this await reads may remove
    // or touch entries, but cannot add any, so the reserved quota still holds.
    entries[name] = .init(bytes: data.count, access: Date.timeIntervalSinceReferenceDate)
    recency.touch(name); mailbox.insertName(name)
    metrics.bytes += data.count; metrics.writes += 1
    metrics.rawWriteBytes += encoded.rawBytes; metrics.storedWriteBytes += data.count
    if data.count < encoded.rawBytes { metrics.compressedWrites += 1 }
  }

  private func start() {
    guard !started else { return }
    let began = ProcessInfo.processInfo.systemUptime
    defer {
      metrics.startupMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1_000
      // Establish the inventory once. Later membership changes are incremental.
      publishMetrics(names: Set(entries.keys))
    }
    started = true
    guard let root else { return }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
      // Enumerate once on the I/O executor. Only our digest-named files are owned
      // by this cache; unrelated files and subdirectories are never removed.
      guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
        options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
      for case let file as URL in files {
        guard Self.owns(file.lastPathComponent) else { continue }
        let info = try file.resourceValues(forKeys: Set(keys))
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize else { continue }
        entries[file.lastPathComponent] = .init(bytes: size,
          access: info.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
        metrics.bytes += size
        // Keep index memory bounded even if a previous interrupted build left
        // too many files. Both the entry limit and byte quota apply at startup.
        guard evict(addingBytes: 0, addingEntries: 0) else { throw CocoaError(.fileWriteUnknown) }
      }
      // File modification times retain approximate access order across restarts.
      // Startup eviction above remains bounded even for an oversized old folder;
      // steady-state eviction uses the constant-time linked order below.
      for name in entries.keys.sorted(by: {
        let a = entries[$0]!.access, b = entries[$1]!.access
        return a == b ? $0 < $1 : a < b
      }) { recency.touch(name) }
      ordered = true
      available = true
    } catch { metrics.failures += 1 }
  }
  private static func owns(_ name: String) -> Bool {
    guard name.hasSuffix(".wcterrain"), name.count == 74 else { return false }
    return name.prefix(64).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }
  private func remove(_ name: String) {
    guard let root, let entry = entries[name] else { return }
    do {
      try FileManager.default.removeItem(at: root.appendingPathComponent(name))
      entries[name] = nil; metrics.bytes -= entry.bytes
      recency.remove(name); mailbox.removeName(name)
    } catch {
      // A missing file is already evicted. Other failures disable writes rather
      // than pretending the disk quota has been reclaimed.
      if (error as NSError).code == NSFileNoSuchFileError {
        entries[name] = nil; metrics.bytes -= entry.bytes
        recency.remove(name); mailbox.removeName(name)
      } else { metrics.failures += 1; available = false }
    }
  }
  private func evict(addingBytes: Int, addingEntries: Int) -> Bool {
    while metrics.bytes + addingBytes > limitBytes || entries.count + addingEntries > limitEntries {
      let oldest = ordered ? recency.oldest : entries.min(by: { $0.value.access < $1.value.access })?.key
      guard let name = oldest else { return false }
      let before = entries.count
      remove(name)
      guard entries.count < before else { return false }
      metrics.evictions += 1
    }
    return true
  }
  private func publishMetrics(names: Set<String>? = nil) {
    metrics.entries = entries.count; metrics.readCPU = readTiming.snapshot; metrics.writeCPU = writeTiming.snapshot
    metrics.readQueueWait = readWaitTiming.snapshot; metrics.archiveEncodingCPU = encodingTiming.snapshot
    metrics.fileWriteCPU = fileWriteTiming.snapshot; metrics.writebackLatency = writebackTiming.snapshot
    mailbox.publish(metrics, names: names)
  }
  private func recordExecutorThread() {
    if Thread.isMainThread { metrics.mainThreadViolations += 1 }
  }
}

/// Counts both pending and currently encoding payloads, so serialization cannot
/// hide retained memory outside the queue's limits. One wakeup services a burst.
final class TerrainDiskWriteQueue: @unchecked Sendable {
  struct Item: Sendable {
    let payload: PreparedTerrainTile
    let key: TerrainPayloadKey
    let bytes: Int
    let enqueuedAt: TimeInterval
  }
  private let lock = NSLock()
  private let limitBytes: Int, limitEntries: Int
  private var pending: [Item] = [], keys: Set<TerrainPayloadKey> = []
  private var bytes = 0, active = false, scheduled = false
  private var dropped = 0, coalesced = 0
  private var metrics = TerrainDiskCacheMetrics()
  private var names: Set<String>?
  private var fastMisses = 0
  private var skippedSurfaces = 0
  init(limitBytes: Int, limitEntries: Int) {
    precondition(limitBytes > 0 && limitEntries > 0)
    self.limitBytes = limitBytes; self.limitEntries = limitEntries
  }
  func offer(_ payload: PreparedTerrainTile, key: TerrainPayloadKey) -> Bool {
    lock.withLock {
      if keys.contains(key) { coalesced += 1; return false }
      let cost = payload.byteCount + key.byteCount
      guard cost < TerrainPayloadCodec.maximumBytes, cost <= limitBytes - bytes,
        keys.count < limitEntries else { dropped += 1; return false }
      pending.append(.init(payload: payload, key: key, bytes: cost, enqueuedAt: ProcessInfo.processInfo.systemUptime))
      keys.insert(key); bytes += cost
      guard !scheduled else { return false }
      scheduled = true; return true
    }
  }
  func take() -> Item? {
    lock.withLock {
      guard !active else { return nil }
      guard !pending.isEmpty else { scheduled = false; return nil }
      active = true; return pending.removeFirst()
    }
  }
  func finish(_ item: Item) { lock.withLock { active = false; keys.remove(item.key); bytes -= item.bytes } }
  func definitelyAbsent(_ name: String) -> Bool {
    lock.withLock {
      guard let names, !names.contains(name) else { return false }
      fastMisses += 1; return true
    }
  }
  func publish(_ value: TerrainDiskCacheMetrics, names: Set<String>?) {
    lock.withLock {
      metrics = value
      // A read/metrics-only publication must not allocate or reset the filename
      // inventory. Only actual membership changes replace it.
      if let names { self.names = names }
    }
  }
  func insertName(_ name: String) { lock.withLock { _ = names?.insert(name) } }
  func removeName(_ name: String) { lock.withLock { _ = names?.remove(name) } }
  func skipInexpensiveSurface() { lock.withLock { skippedSurfaces += 1 } }
  var snapshot: TerrainDiskCacheMetrics {
    lock.withLock {
      var value = metrics
      value.queuedWrites = keys.count; value.queuedBytes = bytes
      value.droppedWrites = dropped; value.coalescedWrites = coalesced
      value.misses += fastMisses
      value.inexpensiveSurfaceWritesSkipped = skippedSurfaces
      return value
    }
  }
}

/// A single writeback worker, deliberately independent of the read/index actor.
/// Injectable archive and file operations permit deterministic stalled-I/O tests
/// without introducing timers or test branches into the live scheduling path.
actor TerrainArchiveWriter {
  struct Encoded: Sendable {
    let data: Data?
    let rawBytes: Int
    let seconds: TimeInterval
    let onMainThread: Bool
  }
  struct Stored: Sendable {
    let succeeded: Bool
    let seconds: TimeInterval
    let onMainThread: Bool
  }
  private let executor = TerrainIOExecutor(label: "com.worldcraft.terrain-cache-write")
  nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
  private let encodeArchive: @Sendable (PreparedTerrainTile, TerrainPayloadKey) -> Data?
  private let writeFile: @Sendable (Data, URL) throws -> Void

  init(encode: @escaping @Sendable (PreparedTerrainTile, TerrainPayloadKey) -> Data? = {
    TerrainPayloadCodec.encode($0, key: $1)
  }, write: @escaping @Sendable (Data, URL) throws -> Void = {
    try $0.write(to: $1, options: .atomic)
  }) {
    encodeArchive = encode; writeFile = write
  }

  func encode(_ payload: PreparedTerrainTile, key: TerrainPayloadKey, compressed: Bool) -> Encoded {
    let began = ProcessInfo.processInfo.systemUptime
    let archive = encodeArchive(payload, key)
    let data = archive.map { compressed ? TerrainArchiveCompression.encode($0) : $0 }
    return .init(data: data, rawBytes: archive?.count ?? 0,
      seconds: ProcessInfo.processInfo.systemUptime - began, onMainThread: Thread.isMainThread)
  }

  func store(_ data: Data, at url: URL) -> Stored {
    let began = ProcessInfo.processInfo.systemUptime
    let succeeded: Bool
    do { try writeFile(data, url); succeeded = true }
    catch { succeeded = false }
    return .init(succeeded: succeeded, seconds: ProcessInfo.processInfo.systemUptime - began,
      onMainThread: Thread.isMainThread)
  }
}

private final class TerrainIOExecutor: SerialExecutor {
  private let queue: DispatchQueue
  init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }
  func enqueue(_ job: consuming ExecutorJob) {
    let work = UnownedJob(job)
    queue.async { work.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
}
