import Foundation

/// CPU simulation has its own executor queue. It cannot accidentally inherit
/// MainActor from a RealityKit frame callback or monopolize a terrain worker.
/// A queue is an execution context, not a promise of a fixed OS thread.
@globalActor public actor SimulationActor {
  public static let shared = SimulationActor()
  private let executor = SimulationExecutor()
  public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
}

private final class SimulationExecutor: SerialExecutor {
  private let queue = DispatchQueue(label: "com.worldcraft.simulation", qos: .utility)
  func enqueue(_ job: consuming ExecutorJob) {
    let work = UnownedJob(job)
    queue.async { work.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
}
