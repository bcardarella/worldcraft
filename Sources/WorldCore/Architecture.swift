public enum ArchitectureStyle: String, CaseIterable, Sendable {
  case timber, alpine, adobe, garden, townhouse, modern, artDeco, forge, citadel, reef, shell, furnace, sunSpire, caldera, arcade, warehouse, civic
}

public struct BuildingDescriptor: Sendable {
  public let style: ArchitectureStyle
  public let height: Int
  public let minimum: Int
  public let maximum: Int
  public let wall: Block
  public let frame: Block
  public let roof: Block
  public let roofRise: Int
  public let hash: UInt64
  public var use: SettlementLotUse = .home
  public var storey: Int { style == .modern || style == .artDeco ? 9 : 8 }
  public func roofHeight(inset: Int) -> Int { min(roofRise, inset * (style == .alpine ? 2 : 1)) }

  public var aquatic: Bool { style == .reef || style == .shell }
  public var solar: Bool { [.forge,.citadel,.furnace,.sunSpire,.caldera].contains(style) }
  public func block(x: Int, y: Int, z: Int) -> Block {
    guard (minimum...maximum).contains(x), (minimum...maximum).contains(z), y >= 0 else { return .air }
    let edge = x == minimum || x == maximum || z == minimum || z == maximum
    let corner = (x == minimum || x == maximum) && (z == minimum || z == maximum)
    let ridge = min(x - minimum, maximum - x)
    if aquatic {
      let middle = (minimum + maximum) / 2
      let inset = min(x - minimum, maximum - x, z - minimum, maximum - z)
      // Stepped shell dome, with a water-filled central oculus for vertical travel.
      if y >= height {
        if abs(x - middle) <= 1 && abs(z - middle) <= 1 { return .air }
        return y == height + min(3, inset) ? roof : .air
      }
      if y == 0 { return .limestone }
      if edge {
        if z == minimum && abs(x - middle) <= 1 && y <= 5 { return .air }
        if corner { return frame }
        if (2...5).contains(y) { return .glass }
        return wall
      }
      if x == minimum + 1 && z == maximum - 1 && y == 2 { return .lantern }
      if x == maximum - 1 && z >= maximum - 2 && y == 1 { return .coral }
      return .air
    }
    if solar && y>=height {
      let inset=min(x-minimum,maximum-x,z-minimum,maximum-z)
      let m=(minimum+maximum)/2
      if y==height {return .basalt}
      if style == .sunSpire {
        let rise=y-height
        guard rise<=7 else {return .air}
        if abs(x-m)+abs(z-m)<=max(0,7-rise) {return rise==7 ? .lamp:.basalt}
        return .air
      }
      if style == .caldera {
        let distance=max(abs(x-m),abs(z-m)),r=max(2,(maximum-minimum)/2-2)
        if y<height+5 && distance==r-(y-height)/2 {return .basalt}
        if y==height+1 && distance<r-1 {return .lamp}
        return .air
      }
      if style == .furnace && inset>=2 && inset<=4 && y<height+7 {return y==height+6 ? .brick:.basalt}
      if style == .citadel && inset==0 && y<=height+3 && (x+z)%4<2 {return .brick}
      if style == .forge && (x==minimum+2 || x==maximum-2) && z==maximum-2 && y<height+6 {return y==height+5 ? .lamp:.basalt}
      return .air
    }
    if y >= height {
      if roofRise > 0 {
        let rise = roofHeight(inset: ridge)
        if y <= height + rise && y >= height + rise - (style == .alpine ? 1 : 0) { return roof }
        // Gable ends, with a small attic window.
        if (z == minimum || z == maximum) && y < height + rise {
          return x == (minimum + maximum) / 2 && y == height + 1 ? .glass : wall
        }
      } else {
        if y == height { return roof }
        if y == height + 1 && edge { return frame }
        if style == .artDeco && y < height + 5 && (minimum + 2...maximum - 2).contains(x)
          && (minimum + 2...maximum - 2).contains(z) { return y == height + 4 ? .lamp : frame }
      }
      return .air
    }
    let middle = (minimum + maximum) / 2
    if y == 0 { return solar ? .basalt : .wood }
    if let circulation = circulationBlock(x:x,y:y,z:z) { return circulation }
    if y % storey == 0 { return solar ? .basalt : .wood }
    if edge {
      if z == minimum && (x == middle || x == middle + 1) && y <= 4 { return .air }
      if z == minimum && !use.sign.isEmpty && (6...10).contains(y) {
        let textX = x-(middle-use.sign.count*2)
        return use.letter(at:textX,y:y-6) ? .lamp : (solar ? .brick:use.accent)
      }
      if solar {
        // Ribbed obsidian shells, narrow molten vents and stone arch lintels.
        if corner || (x+z)%5==0 {return .basalt}
        if (2...4).contains(y%storey) && (x+z)%5==2 {return .lamp}
        return y%storey==6 ? .brick:.basalt
      }
      if style == .arcade && y<5 && z==minimum && x%5 != 0 {return .air}
      if style == .warehouse && z==minimum && abs(x-middle)<4 && y<6 {return .air}
      if corner || (style == .timber && y % storey == 6) { return frame }
      if (2...5).contains(y % storey) {
        if style == .modern || ((x + z) % 3 != 0) { return .glass }
      }
      if style == .artDeco && (x + z) % 3 == 0 { return frame }
      return wall
    }
    if use.shop {
      if y == 1 && z == minimum+4 && x < middle-1 { return solar ? .brick:use.accent }
      if (1...4).contains(y) && (x == minimum+2 || x == maximum-2) && z > minimum+4 {
        return solar ? .basalt : y%2 == 0 ? use.accent : .wood
      }
    }
    if use == .school && y <= 2 && x%5 <= 1 && z%5 <= 1 && z > minimum+4 { return solar ? .basalt:.wood }
    if [.office,.hospital,.library,.workshop].contains(use) && y%storey == 1 && x%6 <= 2 && z%6 <= 1 { return solar ? .basalt:.wood }
    if use == .library && (x == minimum+2 || x == maximum-2) && z>minimum+4 && (1...5).contains(y%storey) {return y%2==0 ? (solar ? .basalt:.wood):.brick}
    if use == .theatre && y==1 && z>minimum+5 && z%3==0 && x%4 != 0 {return solar ? .brick:.wood}
    if use == .hospital && y%storey==1 && x%6<2 && z%6<3 {return .limestone}
    if use == .warehouse && y<4 && x%8<3 && z%8<3 {return solar ? .basalt:.wood}
    // Compact usable interiors: table, counter, bed and warm lamps.
    if y == 1 && z == maximum - 1 && x <= minimum + 3 { return solar ? .brick : .wood }
    if y == 2 && z == maximum - 1 && x == minimum + 1 { return .lantern }
    if (1...2).contains(y) && x == maximum - 1 && z >= maximum - 3 {
      return y == 2 ? .limestone : (solar ? .basalt : .wood)
    }
    if y == 1 && x == minimum + 1 && z == minimum + 2 { return solar ? .basalt : .wood }
    return .air
  }
}

extension Settlement {
  public func building(lotX: Int, lotZ: Int, terrain: TerrainGenerator) -> BuildingDescriptor? {
    if sportsGround(atX:x+lotX*spacing+spacing/2,z:z+lotZ*spacing+spacing/2) != nil { return nil }
    if let port = rocketPort,
      x + lotX*spacing + spacing >= port.x-8 && x + lotX*spacing <= port.x+8,
      z + lotZ*spacing + spacing >= port.z-8 && z + lotZ*spacing <= port.z+8 { return nil }
    guard abs(lotX * spacing + spacing / 2) <= radius - spacing / 2,
      abs(lotZ * spacing + spacing / 2) <= radius - spacing / 2 else { return nil }
    let h = terrain.hash(lotX + x, lotZ + z, salt: id)
    let use = lotUse(x:lotX,z:lotZ,terrain:terrain)
    guard use != .park else { return nil }
    let styles: [ArchitectureStyle]
    if habitat == .aquatic { styles = [.reef, .shell] }
    else if habitat == .solar { styles = [.forge,.citadel,.furnace,.sunSpire,.caldera] }
    else if kind == .city { styles = use == .home ? [.townhouse,.timber,.garden] : [.modern,.artDeco,.townhouse,.modern] }
    else if biome == .desert || biome == .savanna { styles = [.adobe, .adobe, .garden] }
    else if biome == .alpine || biome == .taiga || biome == .tundra { styles = [.alpine, .alpine, .timber] }
    else if biome == .blossomGrove || biome == .rainforest { styles = [.garden, .timber, .garden] }
    else { styles = kind == .town ? [.townhouse, .timber, .artDeco] : [.timber, .alpine, .garden] }
    let style:ArchitectureStyle = use == .warehouse ? (habitat == .solar ? .furnace:.warehouse)
      : [.hospital,.library,.theatre,.fireStation].contains(use) && habitat == .surface ? .civic
      : use == .market && habitat == .surface ? .arcade:styles[Int(h % UInt64(styles.count))]
    // A tall downtown surrounded by lower neighborhoods gives the skyline a
    // readable shape, while every building stays within the voxel height cap.
    let downtown = max(abs(lotX*2+1),abs(lotZ*2+1)) <= 5
    let plannedHeight = kind == .village ? 8 + Int(h % 3)*4
      : kind == .town ? 16 + Int(h % 4)*8
      : (downtown ? 72 + Int(h % 5)*8 : 32 + Int(h % 6)*8)
    let height = min(ChunkData.height - floor - 7,
      use == .school || use == .warehouse || use == .fireStation ? 16 : use.shop ? 16
      : use == .home && kind != .village ? (downtown && kind == .city ? 24:Int(8+h%3*8)) : plannedHeight)
    let wall: Block = habitat == .solar ? .basalt : habitat == .aquatic ? .limestone : style == .adobe ? .sand : style == .townhouse ? .brick : style == .modern ? .stone : .limestone
    let frame: Block = habitat == .solar ? .brick : habitat == .aquatic ? .coral : style == .garden ? .wood : style == .alpine ? .spruceWood : style == .modern ? .limestone : style == .artDeco ? .sand : style == .townhouse ? .stone : .wood
    let roof: Block = habitat == .solar ? (style == .forge ? .brick : .basalt) : habitat == .aquatic ? (style == .reef ? .coral : .limestone) : style == .alpine ? .spruceWood : style == .garden ? .spruceLeaves : style == .adobe ? .sand : .brick
    let setback = buildingSetback + (kind == .city ? Int((h >> 12) % 4) : 0)
    return .init(style: style, height: height, minimum: setback,
      maximum: spacing - setback, wall: wall, frame: frame, roof: roof,
      roofRise: habitat == .aquatic ? 3 : [.timber, .alpine, .garden].contains(style) ? (style == .alpine ? 6 : 3) : 0, hash: h,use:use)
  }
}
