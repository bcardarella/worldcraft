import Foundation

/// City ballparks share one plan for voxel collision, full-detail terrain and
/// distant meshes. Coordinates are measured from home plate: u toward first,
/// v toward third. Both clubhouses sit under their respective grandstands.
public struct BaseballStadium: Sendable {
  public let field: SportsGround
  public static let wingLength = 190
  public static let outerRadius = 76
  public static let lockerFloor = -11
  public static let roof = 21

  public struct Row: Sendable {
    public let distance, height: Int
  }
  public static let rows: [Row] = (0..<14).map {
    .init(distance: $0 < 8 ? 22+$0*3 : 52+($0-8)*3, height:$0+1)
  }
  static let aisles = [16,64,112,160]
  static func isAisle(_ along: Float) -> Bool {
    aisles.contains { abs(along-Float($0)) < 3 }
  }
  public func point(along: Float, depth: Float, y: Float, thirdBase: Bool = false) -> SIMD3<Float> {
    let u = thirdBase ? -depth : along, v = thirdBase ? along : -depth
    return [field.homePlate.x+u,y,field.homePlate.y-v]
  }
  public func column(x: Int, z: Int) -> Column {
    .init(u:x-Int(field.homePlate.x.rounded(.down)),
      v:Int(field.homePlate.y.rounded(.down))-z)
  }

  /// Cached by the terrain worker, including the expensive curved-corner
  /// distance. No entities, physics bodies or per-frame stadium work.
  public struct Column: Sendable {
    let u, v: Int
    let along, depth: Int
    let thirdBase: Bool
    let distance: Int
    let deck: Int?
    let aisle: Bool
    let room, tunnel, dugout, fieldSteps: Bool
    public var minimumY: Int { room || tunnel || dugout || fieldSteps ? -12 : -4 }

    init(u: Int, v: Int) {
      self.u=u; self.v=v
      thirdBase = u < 0 && v >= 0
      along = thirdBase ? v:u
      depth = thirdBase ? -u:-v
      if u < 0 && v < 0 {
        distance = Int(sqrt(Float(u*u+v*v)))
        aisle = abs(u-v) < 4
      } else {
        distance = depth
        aisle = BaseballStadium.isAisle(Float(along))
      }
      if max(u,v) <= BaseballStadium.wingLength, distance >= 22, distance < 76 {
        deck = distance < 46 ? (distance-22)/3+1 : distance < 52 ? 8 : min(14,(distance-52)/3+9)
      } else { deck = nil }
      room = (28...84).contains(along) && (38...65).contains(depth)
      tunnel = (47...54).contains(along) && (21...38).contains(depth)
      dugout = (20...77).contains(along) && (8...20).contains(depth)
      fieldSteps = ((24...27).contains(along) || (68...71).contains(along)) && (5...7).contains(depth)
    }

    public func block(y: Int) -> Block? {
      guard y >= minimumY else { return nil }
      // Team stair landings, rooms and furniture replace rock with explicit
      // air. In particular, a basement must never inherit the pad's solid fill.
      if room && y <= -4 {
        if y == -12 { return .limestone }
        if y == -4 { return .stone }
        // Use the existing bounded local-light pool for usable underground
        // rooms, with the fixture safely above standing head height.
        if y == -5 && (along == 40 || along == 60 || along == 76) && (depth == 44 || depth == 58) { return .lantern }
        if depth == 38 && (48...53).contains(along) && y <= -6 { return .air }
        if along == 28 || along == 84 || depth == 38 || depth == 65 { return .brick }
        // Recessed wooden locker bays around three walls, with a broad central
        // route and benches. The mesh adds handles, dividers and open shelves.
        if (depth == 63 && along % 3 != 0) || ((along == 30 || along == 82) && depth % 3 != 0) {
          if (-11 ... -7).contains(y) { return .wood }
        }
        if y == -11 && (depth == 47 || depth == 57) && (35...77).contains(along)
          && !(46...55).contains(along) { return .wood }
        return .air
      }
      if tunnel {
        let stair = (24...31).contains(depth)
        let base = depth < 24 ? -4 : depth <= 31 ? -4-(depth-24) : -12
        let ceiling = base+7
        if y <= ceiling {
          // Recess fixtures into the side wall, outside the swept headroom of
          // someone descending from the preceding, higher stair tread.
          if y == ceiling-2 && along == 47 && [22,28,35].contains(depth) { return .lantern }
          if y < base || y == ceiling || along == 47 || along == 54 { return .stone }
          if y == base { return stair ? (thirdBase ? .stoneStairsEast:.stoneStairsNorth) : .stone }
          return .air
        }
      }
      if fieldSteps {
        let base = -(depth-4)
        if y < base { return .stone }
        if y == base { return thirdBase ? .stoneStairsEast:.stoneStairsNorth }
        return .air
      }
      if dugout && y <= 3 {
        if y <= -4 { return .stone }
        if y == 3 { return .basalt }
        let entry = (24...27).contains(along) || (68...71).contains(along)
        let clubhouseDoor = (48...53).contains(along) && y <= 1
        if along == 20 || along == 77 || (depth == 20 && !clubhouseDoor) { return .brick }
        if depth == 8 && y < 1 && !entry { return .basalt }
        if depth == 17 && y == -3 && !(46...55).contains(along) { return .wood }
        if depth == 19 && y == 2 && (along == 32 || along == 64) { return .lantern }
        return .air
      }
      if let deck {
        if y == -1 { return .limestone }
        guard y >= 0 else { return nil }
        // Outer facade and covered upper rows. Tall arches open at street
        // level; all railings, roofs and terraces have real block collision.
        if distance == 75 && y < 22 {
          if along >= 0 && (158...163).contains(along) && y < 6 { return .air }
          if along >= 0 && (4...11).contains(along % 16) && (8...11).contains(y) { return .glass }
          return y >= 20 ? .basalt:.brick
        }
        if distance >= 52 && y == BaseballStadium.roof { return .basalt }
        if y == deck-1 {
          if aisle && (distance < 46 || (52..<70).contains(distance)) && (distance < 46 ? distance-22:distance-52)%3 == 0 {
            return thirdBase || (u < 0 && v < 0 && abs(u)>abs(v)) ? .stoneStairsWest:.stoneStairsSouth
          }
          return .limestone
        }
        if distance == 73 && along >= 0 && along % 16 == 8 && y < 21 { return .stone }
        if distance == 74 && along >= 0 && along % 32 == 8 && y == 19 { return .lamp }
        return .air
      }
      return nil
    }
  }
}
