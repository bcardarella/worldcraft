import Foundation

public enum SettlementLotUse: String, CaseIterable, Sendable {
  case home, grocery, bakery, cafe, books, hardware, office, school, park, apartments, hotel, hospital, library, theatre, market, workshop, warehouse, fireStation, observatory
  public var shop: Bool { [.grocery, .bakery, .cafe, .books, .hardware, .market, .workshop].contains(self) }
  public var sign: String {
    switch self {
    case .grocery: "FOOD"
    case .bakery: "BREAD"
    case .cafe: "CAFE"
    case .books: "BOOKS"
    case .hardware: "TOOLS"
    case .office: "OFFICE"
    case .school: "SCHOOL"
    case .apartments: "HOMES"
    case .hotel: "HOTEL"
    case .hospital: "CLINIC"
    case .library: "LIBRARY"
    case .theatre: "THEATRE"
    case .market: "MARKET"
    case .workshop: "WORKSHOP"
    case .warehouse: "DEPOT"
    case .fireStation: "FIRE"
    case .observatory: "STARS"
    default: ""
    }
  }
  public var accent: Block {
    switch self {
    case .grocery: .leaves
    case .bakery: .sand
    case .cafe: .brick
    case .books: .coral
    case .hardware: .stone
    case .school: .sand
    default: .limestone
    }
  }
  /// Small solid voxel lettering survives atlas changes and has no text entities.
  private static let glyphs: [Character: [String]] = [
    "M": ["101","111","111","101","101"], "N": ["101","111","111","111","101"],
    "P": ["110","101","110","100","100"], "W": ["101","101","111","111","101"],
    "Y": ["101","101","010","010","010"], "U": ["101","101","101","101","111"],
    "A": ["010", "101", "111", "101", "101"], "B": ["110", "101", "110", "101", "110"],
    "C": ["011", "100", "100", "100", "011"], "D": ["110", "101", "101", "101", "110"],
    "E": ["111", "100", "110", "100", "111"], "F": ["111", "100", "110", "100", "100"],
    "H": ["101", "101", "111", "101", "101"], "I": ["111", "010", "010", "010", "111"],
    "K": ["101", "101", "110", "101", "101"], "L": ["100", "100", "100", "100", "111"],
    "O": ["111", "101", "101", "101", "111"], "R": ["110", "101", "110", "101", "101"],
    "S": ["011", "100", "010", "001", "110"], "T": ["111", "010", "010", "010", "010"],
  ]
  public func letter(at x: Int, y: Int) -> Bool {
    guard x >= 0, y >= 0, y < 5 else { return false }
    let text = Array(sign)
    let column = x % 4
    guard x / 4 < text.count, column < 3, let rows = Self.glyphs[text[x / 4]] else { return false }
    return Array(rows[4 - y])[column] == "1"
  }
}

public struct SportsGround: Sendable {
  public enum Kind: Sendable { case soccer, baseball }
  public let kind: Kind
  public let x0, x1, z0, z1: Int
  public let hasStadium: Bool
  public init(kind: Kind, x0: Int, x1: Int, z0: Int, z1: Int, hasStadium: Bool = false) {
    self.kind = kind; self.x0 = x0; self.x1 = x1; self.z0 = z0; self.z1 = z1
    self.hasStadium = hasStadium && kind == .baseball
  }
  public var stadium: BaseballStadium? { hasStadium ? .init(field:self) : nil }
  public var center: SIMD2<Float> { [Float(x0+x1+1)/2, Float(z0+z1+1)/2] }
  public var senior: Bool { x1-x0 >= 180 }
  /// Metres converted to the half-metre world grid. Town pitches use the
  /// national 90 x 45 m minimum; cities have a 105 x 68 m pitch (IFAB Law 1).
  public var pitchHalfSize: SIMD2<Float> {
    [min(Float(x1-x0-24)/2, WorldScale.blocks(senior ? 34 : 22.5)),
     min(Float(z1-z0-28)/2, WorldScale.blocks(senior ? 52.5 : 45))]
  }
  /// The diamond faces diagonally into the parcel, leaving foul territory
  /// behind both baselines. Towns use a Little League 60 ft diamond / 200 ft
  /// outfield; cities use a 90 ft diamond with deeper centre field.
  public var homePlate: SIMD2<Float> {
    let inset = hasStadium ? 80 : 18
    return [Float(x0+inset)+0.5, Float(z1-inset)+0.5]
  }
  public var basePath: Float { WorldScale.blocks((senior ? 90 : 60) * 0.3048) }
  public var pitchingDistance: Float { WorldScale.blocks((senior ? 60.5 : 46) * 0.3048) }
  public var foulDistance: Float { WorldScale.blocks((senior ? 325 : 200) * 0.3048) }
  public func outfieldRadius(u: Float, v: Float) -> Float {
    let r2 = max(0.001, u*u+v*v)
    let centre = 2*u*v/r2
    return foulDistance + (senior ? WorldScale.blocks(75*0.3048)*centre*centre : 0)
  }
  public func contains(x: Int, z: Int) -> Bool { x >= x0 && x <= x1 && z >= z0 && z <= z1 }
  public func overlaps(x: Int, z: Int, width: Int) -> Bool {
    x0 < x+width && x1 >= x && z0 < z+width && z1 >= z
  }
  public func surface(x: Float, z: Float) -> Block {
    if kind == .soccer { return .grass }
    let u = x-homePlate.x, v = homePlate.y-z
    let radius = (u*u+v*v).squareRoot()
    let fence = outfieldRadius(u:u,v:v)
    // A real warning track, a dirt infield arc, base paths, home-plate cutout
    // and mound; the centre of the diamond remains grass.
    if u >= 0 && v >= 0 && abs(radius-fence+3) < 3 { return .dirt }
    let mound = pitchingDistance / Float(2).squareRoot()
    let infieldRadius = ((u-mound)*(u-mound)+(v-mound)*(v-mound)).squareRoot()
    let b = basePath
    let paths = (u >= -2 && u <= b+2 && (abs(v) < 2 || abs(v-b) < 2))
      || (v >= -2 && v <= b+2 && (abs(u) < 2 || abs(u-b) < 2))
    let arc = u >= -2 && v >= -2 && infieldRadius > b*0.75 && infieldRadius < b*0.98
    if paths || arc || radius < 6.1 || infieldRadius < 5.49 { return .dirt }
    // Dugout aprons stay clear and visibly distinct from the maintained turf.
    if (u >= 12 && u <= b+12 && v >= -13 && v <= -6)
      || (v >= 12 && v <= b+12 && u >= -13 && u <= -6) { return .sand }
    return .grass
  }
  public func block(x: Int, y: Int, z: Int) -> Block {
    if let block = stadium?.column(x:x,z:z).block(y:y) { return block }
    return surfaceBlock(x:x,y:y,z:z)
  }
  /// Shared fallback for cached stadium columns during chunk generation.
  func surfaceBlock(x: Int, y: Int, z: Int) -> Block {
    if y == -1 { return surface(x: Float(x)+0.5, z: Float(z)+0.5) }
    guard y >= 0 && y < 19 else { return .air }
    let dx = Float(x)+0.5-center.x, dz = Float(z)+0.5-center.y
    if kind == .soccer {
      let pitch = pitchHalfSize
      // Three stepped bleacher rows with a central access aisle, beyond the
      // touchline runoff. Markings and thin goal frames are static mesh detail.
      let row = Int(abs(dx)-pitch.x-7)
      if (0..<6).contains(row), abs(dz) > 3, abs(dz) < 34,
        abs(dx) >= pitch.x+7, y == row/2 { return .wood }
    } else {
      let u = Float(x)+0.5-homePlate.x, v = homePlate.y-Float(z)-0.5
      let distance = (u*u+v*v).squareRoot()
      // Low outfield wall, foul-side dugouts with open field-facing fronts.
      if u >= 0 && v >= 0 && abs(distance-outfieldRadius(u:u,v:v)) < 0.6 && y < 4 { return .basalt }
      for (along, across) in [(u,v), (v,u)] where !hasStadium {
        if along >= 12 && along <= basePath+12 {
          if across == -12 && y < 4 { return .brick }
          if across == -10 && y == 0 { return .wood }
        }
        // Seating beyond the dugouts, separated from the playing surface.
        if along > basePath+15 && along < basePath+39 && across <= -6 && across >= -13,
          y == Int(-across-6)/2 { return .wood }
      }
    }
    // Floodlight masts are outside all playing/runoff areas. They use the
    // existing bounded local-light system, never a light entity per bulb.
    if (x == x0+3 || x == x1-3) && (z == z0+3 || z == z1-3) {
      return y == 18 ? .lantern : .stone
    }
    return .air
  }
}

extension Settlement {
  public func lotUse(x: Int, z: Int, terrain: TerrainGenerator) -> SettlementLotUse {
    if habitat == .aquatic {return .home}
    if kind == .village {
      if x == -1 && z == 0 {return .market}
      if x == 0 && z == -1 {return .workshop}
      return .home
    }
    if x == 0 && z == 0 { return .park }
    if x == -1 && z == -1 { return .school }
    let h = terrain.hash(x + self.x, z + self.z, salt: id)
    if h % 11 == 0 { return .park }
    let district = max(abs(x * 2 + 1), abs(z * 2 + 1))
    let central = district <= (kind == .city ? 5 : 3)
    if x == -2 && z == -2 {return .hospital}
    if x == 1 && z == -1 {return .library}
    if x == 2 && z == -2 {return .fireStation}
    if central && h % 3 != 0 {return [.office,.hotel,.apartments,.theatre,.observatory][Int((h>>20)%5)]}
    if h%9 == 1 {return .warehouse}
    if h % 4 == 0 || (abs(x) <= 1 && h % 2 == 0) {
      return [.grocery, .bakery, .cafe, .books, .hardware, .market, .workshop][Int((h >> 12) % 7)]
    }
    return .home
  }
  public var sportsGrounds: [SportsGround] {
    guard habitat == .surface, kind != .village else { return [] }
    return [sportsGround(kind: .soccer), sportsGround(kind: .baseball)]
  }
  private func sportsGround(kind sport: SportsGround.Kind) -> SportsGround {
    let border = streetHalfWidth + sidewalkWidth + 2
    let hi = kind == .city ? 5 : 4
    if sport == .soccer {
      let lo = kind == .city ? 2 : 1
      let startZ = kind == .city ? 1 : -1
      return .init(kind: sport, x0: x-hi*spacing+border, x1: x-lo*spacing-border,
        z0: z+startZ*spacing+border, z1: z+hi*spacing-border)
    }
    let lo = kind == .city ? 1 : 0
    let baseballHi = kind == .city ? 6 : hi
    return .init(kind: sport, x0: x+lo*spacing+border, x1: x+baseballHi*spacing-border,
      z0: z+lo*spacing+border, z1: z+baseballHi*spacing-border, hasStadium: kind == .city)
  }
  public func sportsGround(atX px: Int, z pz: Int) -> SportsGround? {
    guard habitat == .surface, kind != .village else { return nil }
    let field = sportsGround(kind: px < x ? .soccer : .baseball)
    return field.contains(x:px,z:pz) ? field : nil
  }
}
