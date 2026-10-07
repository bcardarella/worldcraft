import Foundation
import simd

public struct MarinaBox: Sendable {
  public let low, high: SIMD3<Int>
  public let block: Block
  func contains(_ p: SIMD3<Int>) -> Bool {
    p.x >= low.x && p.x < high.x && p.y >= low.y && p.y < high.y && p.z >= low.z && p.z < high.z
  }
}

/// Local -Z faces open water. A wide quay and clubhouse connect to three
/// tiered finger piers, leaving broad, unobstructed sailing lanes between berths.
public enum YachtClubTier:Int,CaseIterable,Sendable {
  case volunteer, sailingClub, regional, premier
  public var title:String { ["Community Sailing Club","Sailing Club","Yacht Club","Grand Yacht Club"][rawValue] }
  public var amenities:[String] {
    let basic=["Launch ramp","Rigging lawn","Boat storage","Changing rooms","Club kitchen"]
    switch self {
    case .volunteer:return basic
    case .sailingClub:return basic+["Sailing school","Workshop","Club terrace"]
    case .regional:return basic+["Chandlery","Restaurant","Harbour office","Fuel berth","Visitor berths"]
    case .premier:return basic+["Restaurant","Library","Gym","Pool terrace","Crew lounge","Laundry","Fuel berth","Superyacht berths","Mooring field"]
    }
  }
}
public struct Marina: Sendable {
  public let id: UInt64
  public let x,z,floor,quarterTurn: Int
  public let body: WaterBody
  public let tier:YachtClubTier
  public var halfWidth:Int {tier == .premier ? 128:68}
  public var seawardExtent:Int {body.kind == .ocean ? (tier == .premier ? 440:272):148}
  public let structures: [MarinaBox]
  public var name: String { ["Bluewater", "Fairwind", "Seabird", "Sunhaven"][Int((id >> 3)%4)] + " " + tier.title }
  public init(id: UInt64, x:Int, z:Int, floor:Int, quarterTurn:Int, body:WaterBody, tier:YachtClubTier?=nil) {
    self.id=id; self.x=x; self.z=z; self.floor=floor; self.quarterTurn=quarterTurn; self.body=body
    let chosen=tier ?? YachtClubTier(rawValue:Int((id>>8)%4))!
    self.tier=body.kind == .ocean ? chosen : (chosen == .premier ? .regional:chosen)
    structures=Self.layouts[self.tier.rawValue]
  }
  public func local(x:Int,z:Int) -> SIMD2<Int> {
    let a=x-self.x,b=z-self.z
    switch quarterTurn { case 1:return [-b-1,a];case 2:return [-a-1,-b-1];case 3:return [b,-a-1];default:return [a,b] }
  }
  public func world(_ p:SIMD3<Float>) -> SIMD3<Float> {
    let q:SIMD3<Float>
    switch quarterTurn {case 1:q=[p.z,p.y,-p.x];case 2:q=[-p.x,p.y,-p.z];case 3:q=[-p.z,p.y,p.x];default:q=p}
    return q+[Float(x),Float(floor),Float(z)]
  }
  public func contains(x:Int,z:Int) -> Bool {
    let p=local(x:x,z:z); return (-halfWidth..<halfWidth+1).contains(p.x) && (-seawardExtent..<49).contains(p.y)
  }
  public func overlaps(x:Int,z:Int,width:Int) -> Bool {
    let low=world([Float(-halfWidth),0,Float(-seawardExtent)]),high=world([Float(halfWidth+1),0,49])
    return max(low.x,high.x)>=Float(x) && min(low.x,high.x)<=Float(x+width)
      && max(low.z,high.z)>=Float(z) && min(low.z,high.z)<=Float(z+width)
  }
  public func column(x:Int,z:Int) -> [MarinaBox] {
    let p=local(x:x,z:z)
    return structures.filter { p.x >= $0.low.x && p.x < $0.high.x && p.y >= $0.low.z && p.y < $0.high.z }
  }
  /// Coastal shoals need a dredged harbour and approach channel. Only approved
  /// ocean sites get this small local edit; lakes use their natural deep basin.
  public func waterColumn(_ natural:TerrainColumn,x:Int,z:Int)->TerrainColumn {
    let p=local(x:x,z:z)
    guard body.kind == .ocean,contains(x:x,z:z),p.y < -24,
      abs(p.x)<=(tier == .premier ? max(48,128-max(0,-p.y-360)):Self.channelHalfWidth(at:p.y)) else {return natural}
    let dredged=min(natural.height,Int(body.level)-(tier == .premier ? 12:8))
    return .init(height:dredged,surface:.sand,water:body)
  }
  private static func channelHalfWidth(at z:Int)->Int {
    // Leave enough turning room beyond the last pontoon for an 18-metre hull,
    // then taper into the approach instead of narrowing abruptly at its bow.
    z >= -208 ? 68:max(28,68-(-z-208)*40/64)
  }
  static func approachHalfWidth(at z:Int)->Int {channelHalfWidth(at:z)}
  public func block(at p:BlockPosition, natural:Int, column:[MarinaBox]? = nil) -> Block? {
    guard contains(x:p.x,z:p.z) else { return nil }
    let local=local(x:p.x,z:p.z), y=p.y-floor
    let boxes=column ?? self.column(x:p.x,z:p.z)
    if let box=boxes.last(where:{ y >= $0.low.y && y < $0.high.y }) { return box.block }
    // Quay foundations grade the shore only; never fill the harbour with land.
    if (-56..<57).contains(local.x) && (0..<33).contains(local.y) {
      if y < 0 && p.y > min(natural-1,floor-16) { return .limestone }
      if y >= 0 { return .air }
    }
    // Eight broad steps connect the quay to the existing landward grade.
    if abs(local.x)<=5 && (33..<49).contains(local.y) {
      let t=Float(local.y-33)/16
      let level=Int((Float(floor)*(1-t)+Float(natural+1)*t).rounded())
      if p.y == level-1 { return .stone }
      if p.y >= level { return .air }
      if p.y>natural { return .limestone }
    }
    if Float(p.y)>=body.level && p.y>natural { return .air }
    return nil
  }
  public var boats: [BoatRecord] {
    var result:[BoatRecord]=[]
    func add(_ kind:BoatKind,_ x:Float,_ z:Float,_ side:Int) {
      var p=world([x,0,z]);p.y=body.level
      let slot=result.count
      result.append(.init(id:id &+ UInt64(slot+1),marina:id,
        physics:.init(kind:kind,position:p,heading:Float(quarterTurn)*Float.pi/2-Float(side)*Float.pi/2)))
    }
    let rows=tier == .volunteer ? 1:tier == .sailingClub ? 2:3
    let kinds:[BoatKind]=tier == .volunteer ? [.dinghy,.dinghy] : tier == .sailingClub ? [.dinghy,.dinghy,.sloop,.cutter] : [.dinghy,.motorboat,.sloop,.cutter,.yacht,.catamaran]
    for row in 0..<rows {for side in [-1,1] {
      let kind=kinds[row*2+(side>0 ? 1:0)]
      add(kind,Float(side)*27,Float(-40-row*44)-WorldScale.blocks(kind.beam/2)-2,side)
    }}
    if tier == .premier {
      for side in [-1,1] {
        add(.megaYacht,Float(side)*74,-242,side)
        add(.jetSki,Float(side)*16,-28,side)
        add(.yacht,Float(side)*72,-332,side)
        add(.cutter,Float(side)*72,-390,side)
      }
    }
    return result
  }
  private static let layouts=YachtClubTier.allCases.map {makeStructures(tier:$0)}
  private static func makeStructures(tier:YachtClubTier) -> [MarinaBox] {
    var boxes:[MarinaBox]=[]
    func box(_ low:SIMD3<Int>,_ high:SIMD3<Int>,_ block:Block) { boxes.append(.init(low:low,high:high,block:block)) }
    box([-56,-1,0],[57,0,33],.limestone)
    let piers=tier == .volunteer ? [-40]:tier == .sailingClub ? [-40,-84]:[-40,-84,-128]
    let end=(piers.last ?? -40)-16
    box([-3,-1,end],[4,0,1],.wood)
    for v in piers {
      box([-49,-1,v],[50,0,v+3],.wood)
      for u in [-48,-24,0,24,48] { box([u,-12,v],[u+1,2,v+1],.wood) }
    }
    for v in stride(from:end,through:-4,by:16) { for u in [-3,3] { box([u,-12,v],[u+1,1,v+1],.wood) } }
    // Walk-in shingled clubhouse, veranda and a small chandlery counter.
    box([-48,0,6],[-12,1,29],.wood)
    box([-48,1,8],[-47,10,29],.limestone)
    box([-13,1,8],[-12,10,29],.limestone)
    box([-48,1,28],[-12,10,29],.limestone)
    box([-48,1,8],[-33,10,9],.limestone)
    box([-27,1,8],[-12,10,9],.limestone)
    box([-33,7,8],[-27,10,9],.limestone) // three-metre clear entrance
    for u in [-44,-22] { box([u,3,8],[u+6,7,9],.glass); box([u,3,28],[u+6,7,29],.glass) }
    for u in [-47,-13] { for v in [13,22] { box([u,3,v],[u+1,7,v+4],.glass) } }
    if tier != .premier {for step in 0..<12 { box([-50,10+step/2,6+step],[-10,11+step/2,31-step],.basalt) }}
    for u in [-48,-30,-12] { box([u,0,2],[u+1,9,3],.wood) }
    box([-49,9,1],[-10,10,8],.wood)
    box([-43,1,22],[-18,3,25],.wood)
    box([-43,3,22],[-18,4,25],.limestone)
    for u in [-42,-22] { box([u,1,13],[u+6,2,16],.wood) }
    // Slip bollards and lanterns are voxels, not per-berth dynamic lights.
    for v in piers { for u in [-42,42] {
      box([u,0,v],[u+1,2,v+1],.basalt)
      box([u,2,v],[u+1,3,v+1],.lantern)
    } }
    // Flagstaff, contrasting sail burgee, harbour office and launch ramp.
    box([12,0,5],[13,20,6],.wood)
    for i in 0..<6 { box([13+i,16+i/2,5],[14+i,20-i/2,6],.brick) }
    box([24,0,15],[48,1,29],.wood)
    box([24,1,28],[48,8,29],.wood)
    box([24,1,15],[25,8,29],.wood); box([47,1,15],[48,8,29],.wood)
    box([23,8,14],[49,9,30],.basalt)
    // Amenities are represented by usable rooms and solid voxel fittings.
    // Community clubs keep a modest shared hall; larger clubs gain distinct facilities.
    box([0,-1,4],[10,0,28],.grass)
    for v in stride(from:5,through:23,by:6) {
      box([30,1,v],[45,2,v+1],.wood) // boat racks / workshop benches
      box([30,2,v],[31,5,v+1],.wood)
    }
    // Changing cubicles, kitchen sink and storage lockers in the clubhouse.
    for u in stride(from:-44,through:-36,by:4) {
      box([u,1,25],[u+2,5,27],.wood);box([u,3,24],[u+1,4,25],.basalt)
    }
    box([-21,4,23],[-18,5,25],.glass)
    if tier.rawValue>=YachtClubTier.sailingClub.rawValue {
      for u in [-42,-32,-22] {box([u,1,3],[u+5,2,6],.wood);box([u+2,2,4],[u+3,3,5],.wood)}
      box([25,1,16],[45,3,18],.limestone) // instruction / chandlery counter
    }
    if tier == .regional || tier == .premier {
      box([34,0,-8],[51,1,1],.wood)
      box([47,1,-5],[49,4,-3],.brick) // fuel pedestal on service berth
      for u in [-42,-30,-18] {for v in [13,19] {
        box([u,2,v],[u+3,3,v+3],.wood)
        box([u,1,v-1],[u+3,2,v],.wood);box([u,1,v+3],[u+3,2,v+4],.wood)
      }}
    }
    if tier == .premier {
      // An ocean harbour has a second, much wider dock and offshore moorings.
      box([-4,-1,-252],[5,0,-128],.wood)
      box([-116,-1,-230],[117,0,-224],.wood)
      for u in [-112,-72,-32,32,72,112] {
        box([u,-18,-230],[u+1,3,-229],.basalt);box([u,3,-230],[u+1,4,-229],.lantern)
      }
      // Buoys sit alongside the hulls, clear of their keels and departure lanes.
      for u in [-72,72] {for v in [-332,-390] {box([u,-5,v+10],[u+2,-3,v+12],.brick)}}
      // Roof terrace reached by a broad external stair, with library and gym below.
      box([-50,10,6],[-10,11,31],.limestone)
      for n in 0..<20 {box([-9,n/2,8+n],[-5,n/2+1,9+n],n%2 == 0 ? .stoneStairsSouth:.limestone)}
      for u in [-48,-12] {box([u,11,6],[u+1,13,31],.glass)}
      box([-48,11,29],[-11,13,30],.glass)
      box([-45,11,17],[-31,12,27],.limestone)
      box([-44,12,18],[-32,13,26],.water) // terrace pool
      for u in [-27,-21] {box([u,11,18],[u+3,12,26],.wood)}
      for u in [-46,-42,-38] {box([u,1,26],[u+3,6,28],.brick)}
      for u in [-42,-36] { // washing machines in the crew service room
        box([u,1,9],[u+3,4,12],.limestone);box([u+1,2,8],[u+2,3,9],.glass)
      }
      box([-30,1,8],[-23,2,10],.wood);box([-30,2,9],[-23,4,10],.wood)
      for v in [12,17] {box([-19,1,v],[-15,2,v+3],.basalt);box([-18,2,v],[-16,4,v+1],.basalt)}
    }
    return boxes
  }
}

/// Deterministic, bounded regional shoreline surveys. Streaming workers and a
/// background boat survey normally warm this cache ahead of collision queries.
public enum MarinaGenerator {
  public static let regionSize=1_024
  private struct Key:Hashable, Sendable { let seed:UInt64;let style:PlanetStyle;let region:ChunkCoordinate }
  private static let cache = RegionalPlanCache<Key, Marina?>(capacity: 128)
  static var cacheMetrics: RegionalCacheMetrics { cache.metrics }
  public static func site(in region:ChunkCoordinate,terrain:TerrainGenerator) -> Marina? {
    guard terrain.style != .solar else { return nil }
    let key = Key(seed: terrain.seed, style: terrain.style, region: region)
    return cache.value(for: key) { survey(region, terrain: terrain.marinaSurveyTerrain) }
  }
  public static func sites(x:Int,z:Int,width:Int,terrain:TerrainGenerator) -> [Marina] {
    var result:[Marina]=[]
    for rz in floorDivide(z,by:regionSize)...floorDivide(z+width,by:regionSize) {
      for rx in floorDivide(x,by:regionSize)...floorDivide(x+width,by:regionSize) {
        if let site=site(in:.init(rx,rz),terrain:terrain),site.overlaps(x:x,z:z,width:width) { result.append(site) }
      }
    }
    return result
  }
  public static func eligibleBody(_ body:WaterBody, lake:InlandLake?) -> Bool {
    if body.kind == .ocean { return true }
    guard body.kind == .lake,let lake,lake.id == body.id else { return false }
    // At least ~190 m across; small ponds, streams and molten seas never qualify.
    return min(lake.radiusX,lake.radiusZ)>=190 && lake.radiusX*lake.radiusZ >= 42_000
  }
  private static func survey(_ region:ChunkCoordinate,terrain:TerrainGenerator) -> Marina? {
    let ox=region.x*regionSize,oz=region.z*regionSize
    let rotation=Int(terrain.hash(region.x,region.z,salt:41_743)%4)
    // Shore origins stay 176 blocks inside the region, so plans cannot overlap.
    for dz in stride(from:192,through:832,by:64) { for dx in stride(from:192,through:832,by:64) {
      if Task.isCancelled { return nil }
      let x=ox+dx,z=oz+dz,land=terrain.naturalColumn(atX:x,z:z)
      guard land.water == nil else { continue }
      for i in 0..<4 {
        let turn=(i+rotation)%4
        let provisional=Marina(id:0,x:x,z:z,floor:0,quarterTurn:turn,body:.ocean)
        let sea=provisional.world([0,0,-72]), c=terrain.naturalColumn(atX:Int(sea.x),z:Int(sea.z))
        guard let body=c.water, eligibleBody(body,lake:terrain.lake(nearX:Int(sea.x),z:Int(sea.z))),
          abs(Float(land.height+1)-body.level)<9 else { continue }
        // Refine the coarse search to the actual shoreline. A grid sample may
        // sit tens of metres inland even though the next sample is deep water.
        var shore=0
        for v in stride(from:0,through:-64,by:-4) {
          let p=provisional.world([0,0,Float(v)])
          if terrain.naturalColumn(atX:Int(p.x),z:Int(p.z)).water != nil { break }
          shore=v
        }
        let origin=provisional.world([0,0,Float(shore+4)])
        let sx=Int(origin.x),sz=Int(origin.z)
        guard sx-ox>=176,sx-ox<848,sz-oz>=176,sz-oz<848 else {continue}
        let id=terrain.hash(sx,sz,salt:63_823) & ~UInt64(31)
        let site=Marina(id:id,x:sx,z:sz,floor:Int(ceil(body.level))+3,quarterTurn:turn,body:body)
        let lo=site.world([Float(-site.halfWidth),0,Float(-site.seawardExtent)]),hi=site.world([Float(site.halfWidth+1),0,49])
        guard min(lo.x,hi.x)>=Float(ox),max(lo.x,hi.x)<Float(ox+regionSize),
          min(lo.z,hi.z)>=Float(oz),max(lo.z,hi.z)<Float(oz+regionSize) else {continue}
        guard validSite(site,terrain:terrain) else { continue }
        return site
      }
    } }
    return nil
  }
  public static func validSite(_ site:Marina,terrain:TerrainGenerator) -> Bool {
    guard eligibleBody(site.body,lake:terrain.lake(nearX:Int(site.world([0,0,-72]).x),z:Int(site.world([0,0,-72]).z))) else {return false}
    // Sample the entire basin and a broad exit, not just a single wet column.
    for v in stride(from:site.tier == .premier ? -432:-144,through:-36,by:12) { for u in stride(from:-site.halfWidth+8,through:site.halfWidth-8,by:12) {
      let p=site.world([Float(u),0,Float(v)]),c=terrain.naturalColumn(atX:Int(p.x),z:Int(p.z))
      if site.body.kind == .ocean {
        // A harbour may cut through shallow sandbars, never a hillside/lake/river.
        guard c.height<=Int(site.body.level)+6,c.water == nil || c.water?.kind == .ocean else {return false}
        continue
      }
      let depth:Float=v < -100 ? 5.2:v < -60 ? 3.6:1.8
      guard c.water?.id == site.body.id,c.water?.kind == site.body.kind,
        Float(c.height+1)<site.body.level-depth else {return false}
    } }
    if site.body.kind == .ocean {
      var open=0
      for v in [-272,-336,-400,-464,-528] {for u in [-96,-48,0,48,96] {
        let p=site.world([Float(u),0,Float(v)]),c=terrain.naturalColumn(atX:Int(p.x),z:Int(p.z))
        if c.water?.kind == .ocean && Float(c.height+1)<site.body.level-3 {open+=1}
      }}
      guard open>=17 else {return false}
      for v in stride(from:-160,through:-264,by:-16) {
        let half=Marina.approachHalfWidth(at:v)-5
        for u in [-half,0,half] {
          let p=site.world([Float(u),0,Float(v)]),c=terrain.naturalColumn(atX:Int(p.x),z:Int(p.z))
          guard c.height<=Int(site.body.level)+6,c.water == nil || c.water?.kind == .ocean else {return false}
        }
      }
    }
    for v in (site.body.kind == .ocean ? (site.tier == .premier ? [-448,-480]:[-280,-304]):[-176,-208,-240]) { for u in [-24,0,24] {
      let p=site.world([Float(u),0,Float(v)]),c=terrain.naturalColumn(atX:Int(p.x),z:Int(p.z))
      guard c.water?.id == site.body.id,c.water?.kind == site.body.kind,
        Float(c.height+1)<site.body.level-5.2 else {return false}
    } }
    for u in [-54,0,54] { for v in [12,32,48] {
      let p=site.world([Float(u),0,Float(v)]),c=terrain.naturalColumn(atX:Int(p.x),z:Int(p.z))
      guard c.water == nil,abs(c.height+1-site.floor)<10,
        SettlementGenerator.site(at:.init(p),terrain:terrain) == nil,
        !terrain.landmarks.contains(where:{$0.contains(x:Int(p.x),z:Int(p.z))}) else {return false}
    } }
    for boat in site.boats {
      let p=boat.physics
      for side:Float in [-0.5,0,0.5] {for fore:Float in [-0.5,0,0.5] {
        let sample=p.worldPoint([side*p.kind.beam,0,fore*p.kind.length])
        let c=site.waterColumn(terrain.naturalColumn(atX:Int(sample.x),z:Int(sample.z)),x:Int(sample.x),z:Int(sample.z))
        guard c.water?.id == site.body.id,Float(c.height+1)<site.body.level-WorldScale.blocks(p.kind.draft) else {return false}
      }}
    }
    return true
  }
}

/// Far docks and clubhouses use the very same static boxes as collision. Keep
/// the complete silhouette at every draw distance, without a scene per prop.
public enum MarinaMesher {
  public static func build(_ tile:TerrainTile,sites:[Marina]) -> VoxelMesh {
    var mesh=VoxelMesh()
    let origin=SIMD3<Float>(Float(tile.x*16),0,Float(tile.z*16)),size=Float(tile.blockSize)
    for site in sites {
      for b in site.structures {
        let a=site.world(SIMD3<Float>(b.low)),c=site.world(SIMD3<Float>(b.high))
        var low=simd_min(a,c)-origin,high=simd_max(a,c)-origin
        low.x=max(0,low.x);low.z=max(0,low.z);high.x=min(size,high.x);high.z=min(size,high.z)
        guard low.x<high.x,low.z<high.z else {continue}
        for face in 0..<6 {
          let d=VoxelMesher.offsets[face]
          mesh.appendQuad(VoxelMesher.corners[face].map{low+$0*(high-low)},normal:[Float(d.x),Float(d.y),Float(d.z)],block:b.block,face:face)
        }
      }
    }
    return mesh
  }
}
