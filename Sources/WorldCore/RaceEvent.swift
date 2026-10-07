import Foundation

/// Race lifecycle independent of rendering/network decisions. Lap validation is
/// supplied by RaceProgress, so wrong-way crossings and shortcuts cannot score.
public struct RaceEvent: Sendable {
  public enum Phase: Sendable, Equatable { case countdown, racing, finished, cancelled }
  public let circuitID:UInt64
  public let entrants:[UInt64]
  public let player:UInt64
  public let lapCount:Int = 3
  public private(set) var phase:Phase = .countdown
  public private(set) var countdown:Float = 3
  public private(set) var elapsed:Float = 0
  public private(set) var finishOrder:[UInt64] = []
  public private(set) var finishTimes:[UInt64:Float] = [:]
  public private(set) var completed:[UInt64:Int] = [:]
  public init(circuitID:UInt64,player:UInt64,opponents:[UInt64]) {
    self.circuitID=circuitID;self.player=player
    var seen:Set<UInt64>=[player]
    entrants=[player]+opponents.filter {seen.insert($0).inserted}
  }
  public mutating func advance(seconds:Float) {
    guard seconds.isFinite,seconds>0 else {return}
    let dt=min(0.1,seconds)
    if phase == .countdown {countdown=max(0,countdown-dt);if countdown<0.0001 {phase = .racing;countdown=0}}
    else if phase == .racing {elapsed += dt}
  }
  public func canDrive(_ id:UInt64) -> Bool {
    !entrants.contains(id) || phase != .countdown
  }
  public mutating func record(_ id:UInt64,laps:Int) {
    guard phase == .racing,entrants.contains(id) else {return}
    completed[id]=min(lapCount,max(completed[id] ?? 0,laps))
    if laps>=lapCount && !finishOrder.contains(id) {finishOrder.append(id);finishTimes[id]=elapsed}
    if finishOrder.count == entrants.count {phase = .finished}
  }
  public mutating func cancel() {phase = .cancelled}
  public var label:String {
    if phase == .countdown {return "STARTING IN \(max(1,Int(ceil(countdown)))) · 3 laps"}
    if let place=finishOrder.firstIndex(of:player) {return "FINISHED · Place \(place+1) / \(entrants.count) · \(String(format:"%.1fs",finishTimes[player] ?? elapsed))"}
    if phase == .cancelled {return "Race cancelled"}
    return "Lap \(min(lapCount,(completed[player] ?? 0)+1)) / \(lapCount) · \(String(format:"%.1fs",elapsed))"
  }
}
