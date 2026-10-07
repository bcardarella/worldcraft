import Foundation
import simd

public struct PlanetSurfaceMap: Sendable {
  public let width, height: Int
  public var color, roughness, normal, clouds: [UInt8]
  /// RealityKit's opacity texture reads red, not the color texture's alpha.
  public var cloudOpacity:[UInt8] {
    var result=clouds
    for i in stride(from:0,to:result.count,by:4) {
      let density=clouds[i+3]
      result[i]=density;result[i+1]=density;result[i+2]=density;result[i+3]=255
    }
    return result
  }
  public static func generate(_ planet:PlanetDescriptor,width:Int=1024) -> Self {
    let width=max(8,width),height=max(4,width/2),terrain=planet.terrain
    var color=[UInt8](repeating:255,count:width*height*4),roughness=color,normal=color,clouds=color
    var relief=[Float](repeating:0,count:width*height)
    let seed=Double(planet.seed%10_000)*0.01
    for y in 0..<height {
      let latitude=(Double(y)/Double(height-1)-0.5) * .pi
      for x in 0..<width {
        // Duplicated longitude edge and uniform poles avoid texture seams.
        let longitude=Double(x)/Double(width-1) * .pi*2
        let vx=cos(latitude)*cos(longitude), vy=sin(latitude), vz=cos(latitude)*sin(longitude)
        let sx=Int((vx*1_100+vy*730).rounded()),sz=Int((vz*1_100+vy*191).rounded())
        let elevation=terrain.rawHeight(atX:sx,z:sz), sea=TerrainGenerator.seaLevel
        let water=elevation<=sea, depth=Float(max(0,sea-elevation))
        let fine=Float(terrain.noise(Double(sx)/13,Double(sz)/13,salt:174))
        let climate=Float(terrain.noise(Double(sx)/160,Double(sz)/160,salt:273))
        var rgb=planet.style.landColor
        if water {
          let shallow=exp(-depth*0.13)
          rgb=planet.style.waterColor*(0.38+0.55*shallow)
          if !planet.isStar { rgb += SIMD3<Float>(0.10,0.20,0.12)*shallow }
          else { rgb=SIMD3<Float>(1,0.20+0.42*shallow,0.012)*(0.8+fine*0.2) }
        } else {
          rgb *= 0.70+climate*0.22+fine*0.14
          if elevation<sea+3 && !planet.isStar { rgb=rgb*0.4+SIMD3<Float>(0.75,0.67,0.39)*0.6 }
          if elevation>65 && !planet.isStar {
            let rock=min(0.75,Float(elevation-65)/90)
            rgb=rgb*(1-rock)+SIMD3<Float>(0.38,0.36,0.34)*rock
          }
          let snow=planet.style != .dune && planet.style != .ember && !planet.isStar
          if snow && (elevation>108 || abs(latitude)>1.19+Double(fine)*0.09) { rgb=SIMD3<Float>(0.77,0.87,0.94)*(0.9+fine*0.1) }
          if planet.isStar { rgb *= 0.3+fine*0.5 }
        }
        let offset=(y*width+x)*4
        for c in 0..<3 { color[offset+c]=UInt8(max(0,min(255,rgb[c]*255))); roughness[offset+c]=water ? 52:224 }
        relief[y*width+x]=water ? 0:Float(elevation-sea)*0.015
        // Spherical weather bands; alpha includes sparse wisps and denser storm swirls.
        let swirl=sin(vx*12+vy*5+seed)*0.5+cos(vz*14-vy*9)*0.35
        let cloud=Float(sin(vx*21+vz*13+swirl*3+seed)*0.35+cos(vy*25+vx*7+swirl)*0.3+0.42)
        let density=planet.isStar ? 0:smoothstep(0.52,0.88,cloud)*(planet.style == .dune ? 0.28:0.78)
        clouds[offset]=231;clouds[offset+1]=240;clouds[offset+2]=248;clouds[offset+3]=UInt8(density*255)
      }
    }
    for y in 0..<height { for x in 0..<width {
      let u=x == width-1 ? 0:x
      let west=u==0 ? width-2:u-1,east=u==width-2 ? 0:u+1
      let dx=relief[y*width+east]-relief[y*width+west]
      let dy=relief[min(height-1,y+1)*width+x]-relief[max(0,y-1)*width+x]
      let n=simd_normalize(SIMD3<Float>(-dx,-dy,1)),offset=(y*width+x)*4
      for c in 0..<3 { normal[offset+c]=UInt8(max(0,min(255,(n[c]*0.5+0.5)*255))) }
    } }
    return .init(width:width,height:height,color:color,roughness:roughness,normal:normal,clouds:clouds)
  }
}
