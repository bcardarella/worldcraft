import Foundation

public struct TerrainPublicationFeederMetrics: Sendable, Encodable {
  public let independent: Bool
  public let eventRefills, frameRefills, admitted, stale, rejected: Int
  public let operationTime, readyToAdmission: DurationTiming.Snapshot
}

/// Joins CPU preparation to the bounded native queue without awaiting a scene
/// callback. Only one task consumes a one-element notification stream. Events
/// carry no geometry; the exchange and native queue remain the sole owners.
@MainActor public final class TerrainPublicationFeeder<Value> {
  private let exchange: TerrainStreamingExchange
  private let queue: TerrainPublicationQueue<Value>
  private let independent: Bool, reuseMeshes: Bool
  private let permits: @MainActor () -> Bool
  private let current: @MainActor (TerrainWorkID) -> Bool
  private let retry: @MainActor (TerrainWorkID) -> Void
  private let resumeWorkers: @Sendable () -> Void
  private let notification: AsyncStream<Void>.Continuation
  private var consumer: Task<Void, Never>?
  private var eventRefills = 0, frameRefills = 0, admitted = 0, stale = 0, rejected = 0
  private var operationTime = DurationTiming(), readyToAdmission = DurationTiming()

  public init(exchange: TerrainStreamingExchange, queue: TerrainPublicationQueue<Value>,
    independent: Bool = true, reuseMeshes: Bool = true,
    permits: @escaping @MainActor () -> Bool,
    current: @escaping @MainActor (TerrainWorkID) -> Bool,
    retry: @escaping @MainActor (TerrainWorkID) -> Void,
    resumeWorkers: @escaping @Sendable () -> Void) {
    self.exchange = exchange; self.queue = queue; self.independent = independent
    self.reuseMeshes = reuseMeshes; self.permits = permits; self.current = current
    self.retry = retry; self.resumeWorkers = resumeWorkers
    let (stream, notification) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.notification = notification
    if independent {
      // Install before starting the consumer; registration also signals work
      // that completed before this feeder existed. Both callbacks are O(1).
      exchange.setReadyNotification { notification.yield(()) }
      queue.onCapacityAvailable = { notification.yield(()) }
      consumer = Task(priority: .utility) { @MainActor [weak self] in
        for await _ in stream {
          guard !Task.isCancelled, let self else { break }
          self.refill(event: true)
        }
      }
    }
  }
  deinit { consumer?.cancel(); notification.finish() }

  /// Native resource retirement calls this when it releases backpressure.
  /// Coalescing prevents a burst of completions from queuing one Task per tile.
  public func wake() { if independent { notification.yield(()) } }

  /// Frame calls remain useful after adoption and supply the comparison mode.
  public func refill() { refill(event: false) }
  private func refill(event: Bool) {
    let began = ProcessInfo.processInfo.systemUptime
    if event { eventRefills += 1 } else { frameRefills += 1 }
    var consumed = false
    defer {
      operationTime.record(seconds: ProcessInfo.processInfo.systemUptime-began)
      if consumed { resumeWorkers() }
    }
    while queue.hasCapacity && permits() {
      guard let input = exchange.takeReady(maximumPublicationBytes: queue.availableBytes,
        reuseMeshes: reuseMeshes) else { break }
      consumed = true
      guard current(input.id) else { stale += 1; continue }
      guard queue.admit(input, bytes: input.publicationByteCount(reuseMeshes: reuseMeshes)) else {
        rejected += 1; retry(input.id); break
      }
      admitted += 1
      readyToAdmission.record(seconds: max(0,ProcessInfo.processInfo.systemUptime-input.readyAt))
    }
  }
  public var metrics: TerrainPublicationFeederMetrics {
    .init(independent: independent, eventRefills: eventRefills, frameRefills: frameRefills,
      admitted: admitted, stale: stale, rejected: rejected,
      operationTime: operationTime.snapshot, readyToAdmission: readyToAdmission.snapshot)
  }
}
