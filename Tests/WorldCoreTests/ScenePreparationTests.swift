import XCTest
@testable import WorldCore

@MainActor private final class PreparationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  var entered: Bool { continuation != nil }
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class ScenePreparationTests: XCTestCase {
  private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
  }

  func testStalledAudioAndPlanetsDoNotHoldTrackingOrFrameWork() async {
    let preparation = ScenePreparation(), audio = PreparationGate(), planets = PreparationGate()
    defer { preparation.cancel(); audio.release(); planets.release() }
    var trackingReady = false
    preparation.launch(.audio) { await audio.wait() }
    preparation.launch(.planets) { await planets.wait() }
    preparation.launch(.tracking) { trackingReady = true }
    let ready = await eventually { trackingReady && audio.entered && planets.entered }
    XCTAssertTrue(ready)
    XCTAssertEqual(Set(preparation.pending), [.audio, .planets])
    // A frame scheduled on the same executor must run while both framework
    // operations are suspended, without completing or canceling either job.
    let frame = Task { @MainActor in
      XCTAssertEqual(Set(preparation.pending), [.audio, .planets])
      return true
    }
    let delivered = await frame.value
    XCTAssertTrue(delivered)
  }

  func testExitAndReentryIgnoreLateFrameworkCompletions() async {
    let preparation = ScenePreparation(), old = PreparationGate(), current = PreparationGate()
    defer { preparation.cancel(); old.release(); current.release() }
    var oldReturned = false
    var completed: [ScenePreparation.Job] = []
    preparation.onEvent = { if case .finished(let job, _) = $0 { completed.append(job) } }
    preparation.launch(.planets) { await old.wait(); oldReturned = true }
    let entered = await eventually { old.entered }
    XCTAssertTrue(entered)
    preparation.cancel()
    XCTAssertTrue(preparation.pending.isEmpty)
    preparation.launch(.planets) { await current.wait() }
    let reentered = await eventually { current.entered }
    XCTAssertTrue(reentered)
    old.release()
    let returned = await eventually { oldReturned }
    XCTAssertTrue(returned)
    XCTAssertEqual(preparation.pending, [.planets])
    XCTAssertTrue(completed.isEmpty)
    current.release()
    let finished = await eventually { preparation.pending.isEmpty }
    XCTAssertTrue(finished)
    XCTAssertEqual(completed, [.planets])
  }

  func testOptionalFailureIsReportedWithoutPreventingOtherJobs() async {
    let preparation = ScenePreparation()
    var failures: [ScenePreparation.Job] = [], completed: [ScenePreparation.Job] = []
    preparation.onEvent = {
      switch $0 {
      case .failed(let job, _): failures.append(job)
      case .finished(let job, _): completed.append(job)
      case .started: break
      }
    }
    preparation.launch(.audio) { throw CocoaError(.fileReadCorruptFile) }
    preparation.launch(.tracking) {}
    preparation.launch(.planets) {}
    let finished = await eventually { preparation.pending.isEmpty }
    XCTAssertTrue(finished)
    XCTAssertEqual(failures, [.audio])
    XCTAssertEqual(Set(completed), [.tracking, .planets])
  }

  func testRepeatedStartDoesNotDuplicatePendingResources() async {
    let preparation = ScenePreparation(), gate = PreparationGate()
    defer { preparation.cancel(); gate.release() }
    var starts = 0
    for _ in 0..<20 { preparation.launch(.audio) { starts += 1; await gate.wait() } }
    let entered = await eventually { gate.entered }
    XCTAssertTrue(entered)
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(preparation.pending, [.audio])
  }

  func testLoaderCancellationClearsItsPendingState() async {
    let preparation = ScenePreparation()
    preparation.launch(.audio) { throw CancellationError() }
    let finished = await eventually { preparation.pending.isEmpty }
    XCTAssertTrue(finished)
  }

  func testSoundPlanKeepsAllRecordingsAndPreparesUsableTakesBeforeAlternates() {
    let effects = ["fox", "step_grass", "ocean", "jump", "car_engine", "wind"].flatMap { event in
      (1...3).map { SoundEffectAsset(event: event, file: "\(event)_\($0)", duration: 2,
        loop: ["ocean", "car_engine", "wind"].contains(event), gain: -6) }
    }
    let plan = SoundPreloadPlan.ordered(effects)
    XCTAssertEqual(plan.count, effects.count)
    XCTAssertEqual(Set(plan.map(\.file)), Set(effects.map(\.file)))
    XCTAssertEqual(plan.first?.event, "step_grass")
    XCTAssertEqual(Set(plan.prefix(6).map(\.event)).count, 6)
    XCTAssertTrue(plan.prefix(6).allSatisfy { $0.file.hasSuffix("_1") })
    XCTAssertGreaterThanOrEqual(SoundPreloadPlan.interval, .milliseconds(50))
  }
}
