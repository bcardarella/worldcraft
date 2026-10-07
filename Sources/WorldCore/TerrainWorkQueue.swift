/// Worker-owned selection index. Each service has both geometric-priority and
/// enqueue-time heaps so aging preserves the existing service policy without
/// rescanning every outstanding request after each completed tile.
struct TerrainWorkQueue {
  private struct Entry {
    let id: TerrainWorkID
    let priority: Int
    let enqueued: Double
    static func priorityBefore(_ a: Self, _ b: Self) -> Bool {
      a.priority == b.priority
        ? (a.id.tile.z,a.id.tile.x,a.id.tile.size) < (b.id.tile.z,b.id.tile.x,b.id.tile.size)
        : a.priority < b.priority
    }
    static func ageBefore(_ a: Self, _ b: Self) -> Bool {
      a.enqueued == b.enqueued ? priorityBefore(a,b) : a.enqueued < b.enqueued
    }
  }
  private struct Heap {
    var values: [Entry] = []
    var positions: [TerrainWorkID: Int] = [:]
    let byAge: Bool
    init(_ entries: [Entry], byAge: Bool) {
      self.byAge = byAge; values = entries
      positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id,$0.offset) })
      if values.count > 1 { for i in stride(from: values.count/2-1, through: 0, by: -1) { down(i) } }
    }
    var first: Entry? { values.first }
    func before(_ a: Entry, _ b: Entry) -> Bool {
      byAge ? Entry.ageBefore(a,b) : Entry.priorityBefore(a,b)
    }
    mutating func swap(_ a: Int, _ b: Int) {
      values.swapAt(a,b); positions[values[a].id] = a; positions[values[b].id] = b
    }
    mutating func up(_ start: Int) {
      var i = start
      while i > 0 {
        let parent = (i-1)/2
        guard before(values[i],values[parent]) else { break }
        swap(i,parent); i = parent
      }
    }
    mutating func down(_ start: Int) {
      var i = start
      while i*2+1 < values.count {
        var child = i*2+1
        if child+1 < values.count, before(values[child+1],values[child]) { child += 1 }
        guard before(values[child],values[i]) else { break }
        swap(i,child); i = child
      }
    }
    mutating func insert(_ entry: Entry) {
      remove(entry.id); positions[entry.id] = values.count; values.append(entry); up(values.count-1)
    }
    mutating func remove(_ id: TerrainWorkID) {
      guard let i = positions.removeValue(forKey: id) else { return }
      let last = values.removeLast()
      guard i < values.count else { return }
      values[i] = last; positions[last.id] = i
      if i > 0, before(last,values[(i-1)/2]) { up(i) } else { down(i) }
    }
  }
  private struct Service {
    var priority, age: Heap
    init(_ entries: [Entry]) { priority = .init(entries,byAge: false); age = .init(entries,byAge: true) }
    mutating func remove(_ id: TerrainWorkID) { priority.remove(id); age.remove(id) }
  }
  private var services: [TerrainWorkClass: Service] = [:]
  var count: Int { services.values.reduce(0) { $0+$1.priority.values.count } }
  init() {}
  init(_ requests: [TerrainPreparationRequest], enqueued: [TerrainWorkID: Double], now: Double) {
    var grouped: [TerrainWorkClass: [Entry]] = [:]
    for request in requests {
      grouped[request.service,default: []].append(.init(id: request.id,priority: request.priority,
        enqueued: enqueued[request.id] ?? now))
    }
    services = grouped.mapValues(Service.init)
  }
  mutating func insert(_ request: TerrainPreparationRequest, enqueued: Double) {
    let entry = Entry(id: request.id,priority: request.priority,enqueued: enqueued)
    if services[request.service] == nil { services[request.service] = .init([]) }
    services[request.service]?.priority.insert(entry); services[request.service]?.age.insert(entry)
  }
  mutating func next(turn: inout Int, now: Double, accepts: (TerrainWorkID) -> Bool) -> TerrainWorkID? {
    guard count > 0 else { return nil }
    for _ in TerrainServiceOrder.cycle.indices {
      let service = TerrainServiceOrder.cycle[turn % TerrainServiceOrder.cycle.count]
      turn = (turn+1) % TerrainServiceOrder.cycle.count
      // Discard obsolete heads without spending an extra service opportunity.
      // Synchronous exchange invalidation can arrive before the actor update.
      while let oldest = services[service]?.age.first {
        let choice = oldest.enqueued < now-2 ? oldest : services[service]!.priority.first!
        services[service]?.remove(choice.id)
        if accepts(choice.id) { return choice.id }
      }
    }
    return nil
  }
  func summary(now: Double) -> (counts: [String: Int], ages: [String: Double]) {
    var counts: [String: Int] = [:], ages: [String: Double] = [:]
    for (kind,service) in services where !service.priority.values.isEmpty {
      counts[kind.rawValue] = service.priority.values.count
      ages[kind.rawValue] = max(0,now-service.age.first!.enqueued)*1_000
    }
    return (counts,ages)
  }
}
