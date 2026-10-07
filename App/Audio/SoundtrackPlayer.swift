import AVFAudio
import Foundation
import WorldCore

/// Two compressed streams and a 20 Hz mixer on an actor. Asset opening,
/// preparation and music timing never run in the RealityKit frame callback.
actor SoundtrackPlayer {
  private var session = UUID()
  private var library: [WorldCore.MusicTrack] = []
  private var director = MusicDirector(seed: 0)
  private var current: AVAudioPlayer?
  private var incoming: AVAudioPlayer?
  private var currentTrack: WorldCore.MusicTrack?
  private var incomingTrack: WorldCore.MusicTrack?
  private var timer: Task<Void, Never>?
  private var volume: Float = 0.45
  private var duck: Float = 1
  private var targetDuck: Float = 1
  private var paused = false
  private var clock = 0.0
  private var trackStarted = 0.0
  private var fadeStarted: Double?
  private var lastTick = ProcessInfo.processInfo.systemUptime
  private var moodChanged = false
  private var lastLoadAttempt = -Double.infinity
  private let fadeDuration = 7.0

  func start(session: UUID, library: [WorldCore.MusicTrack], seed: UInt64, volume: Float) {
    guard !Task.isCancelled else { return }
    guard timer == nil || self.session != session else { return }
    stopPlayers()
    self.session = session
    self.library = library
    director = MusicDirector(seed: seed)
    self.volume = volume
    clock = 0
    trackStarted = 0
    moodChanged = false
    paused = false
    lastLoadAttempt = -.infinity
    lastTick = ProcessInfo.processInfo.systemUptime
    loadIncoming()
    if let incoming {
      current = incoming
      currentTrack = incomingTrack
      self.incoming = nil
      incomingTrack = nil
      current?.volume = 0
      current?.play()
      fadeStarted = clock
    }
    timer = Task(priority: .utility) { [weak self] in
      while !Task.isCancelled {
        guard let self, await self.step(session: session) else { return }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
    }
  }
  func update(mood: MusicMood, volume: Float, ducked: Bool) {
    self.volume = min(1, max(0, volume))
    targetDuck = ducked ? 0.48 : 1
    if director.observe(mood, at: clock) { moodChanged = true }
  }
  func setPaused(_ value: Bool) {
    guard paused != value else { return }
    paused = value
    if value {
      current?.pause()
      incoming?.pause()
    } else {
      lastTick = ProcessInfo.processInfo.systemUptime
      current?.play()
      if fadeStarted != nil { incoming?.play() }
    }
  }
  func stop(session: UUID) {
    guard session == self.session else { return }
    stopPlayers()
  }
  private func stopPlayers() {
    timer?.cancel()
    timer = nil
    current?.stop()
    incoming?.stop()
    current = nil
    incoming = nil
    currentTrack = nil
    incomingTrack = nil
    fadeStarted = nil
  }
  private func loadIncoming() {
    lastLoadAttempt = clock
    // A missing or corrupt file falls through to another track, with retries
    // bounded to three opens. The currently playing loop remains uninterrupted.
    for _ in 0..<3 {
      guard let track = director.next(in: library),
        let url = Bundle.main.url(forResource: track.file, withExtension: nil)
      else { continue }
      do {
        let player = try AVAudioPlayer(contentsOf: url)
        player.numberOfLoops = -1
        player.volume = 0
        guard player.prepareToPlay() else { continue }
        incoming = player
        incomingTrack = track
        return
      } catch {
        print("WORLDCRAFT_AUDIO unavailable music=\(track.id)")
      }
    }
  }
  private func step(session: UUID) -> Bool {
    guard session == self.session else { return false }
    let now = ProcessInfo.processInfo.systemUptime
    let dt = max(0, now - lastTick)
    lastTick = now
    guard !paused else { return true }
    clock += dt
    duck += (targetDuck - duck) * Float(min(1, dt * (targetDuck < duck ? 5 : 0.7)))
    let gain = volume * duck
    if current == nil {
      if incoming == nil && clock - lastLoadAttempt > 3 { loadIncoming() }
      if let incoming {
        current = incoming
        currentTrack = incomingTrack
        self.incoming = nil
        incomingTrack = nil
        current?.play()
        trackStarted = clock
        fadeStarted = clock
      }
    }
    if let started = fadeStarted {
      let progress = (clock - started) / fadeDuration
      let mix = MusicDirector.crossfade(progress)
      if incoming != nil {
        setVolume(current, to: gain * mix.outgoing)
        setVolume(incoming, to: gain * mix.incoming)
      } else {
        setVolume(current, to: gain * mix.incoming)
      }
      if progress >= 1 {
        if let incoming {
          current?.stop()
          current = incoming
          currentTrack = incomingTrack
          self.incoming = nil
          incomingTrack = nil
          trackStarted = started
        }
        fadeStarted = nil
      }
      return true
    }
    setVolume(current, to: gain)
    let length = current?.duration ?? currentTrack?.duration ?? 80
    let elapsed = clock - trackStarted
    let nextSoon = elapsed >= length - fadeDuration - 5 || (moodChanged && elapsed >= 32)
    if nextSoon && incoming == nil && clock - lastLoadAttempt > 3 { loadIncoming() }
    if incoming != nil && (elapsed >= length - fadeDuration || (moodChanged && elapsed >= 36)) {
      fadeStarted = clock
      moodChanged = false
      incoming?.play()
    }
    return true
  }

  private func setVolume(_ player: AVAudioPlayer?, to volume: Float) {
    guard let player, abs(player.volume-volume) >= 0.001 || (volume == 0 && player.volume != 0) else { return }
    player.volume = volume
  }
}
