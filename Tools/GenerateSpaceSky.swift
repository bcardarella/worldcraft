import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// An original seamless, equirectangular sky: spherical fractal dust, a tilted
// galactic disc and individually sampled stars. Offline only; no frame work.
let width=4096, height=2048
var pixels=[UInt8](repeating:255,count:width*height*4)
func hash(_ x:Int,_ y:Int,_ z:Int) -> Double {
  var h=UInt64(bitPattern:Int64(x &* 73856093 ^ y &* 19349663 ^ z &* 83492791)) &+ 0x9e3779b97f4a7c15
  h=(h ^ (h>>30)) &* 0xbf58476d1ce4e5b9; h=(h ^ (h>>27)) &* 0x94d049bb133111eb
  return Double((h ^ (h>>31)) & 0xffff)/65535
}
func noise(_ x:Double,_ y:Double,_ z:Double) -> Double {
  let ix=Int(floor(x)),iy=Int(floor(y)),iz=Int(floor(z))
  func smooth(_ t:Double)->Double { t*t*(3-2*t) }
  let u=smooth(x-Double(ix)),v=smooth(y-Double(iy)),w=smooth(z-Double(iz))
  var sum=0.0
  for a in 0...1 { for b in 0...1 { for c in 0...1 {
    sum += hash(ix+a,iy+b,iz+c)*(a==0 ? 1-u:u)*(b==0 ? 1-v:v)*(c==0 ? 1-w:w)
  } } }
  return sum
}
for y in 0..<height {
  let lat=(Double(y)/Double(height-1)-0.5)*Double.pi
  for x in 0..<width {
    let lon=Double(x)/Double(width)*Double.pi*2
    let vx=cos(lat)*cos(lon),vy=sin(lat),vz=cos(lat)*sin(lon)
    let plane=vx*0.24+vy*0.55+vz*0.800
    var f=0.0,weight=0.55,scale=3.0
    for _ in 0..<5 { f+=noise(vx*scale+14,vy*scale-7,vz*scale+31)*weight; weight *= 0.51;scale *= 2.05 }
    let warped=plane+(f-0.5)*0.12
    let band=exp(-pow(warped/0.125,2))
    let core=pow(max(0,vx*(-0.91)+vy*0.12+vz*0.37),12)
    let dust=exp(-pow((warped-0.014*sin(lon*5))/0.027,2))*(0.4+0.6*f)
    let glow=band*(0.24+f*f*1.8)*(1-dust*0.86)*(0.55+core*2)
    let blue=0.5+0.5*sin(lon*1.6+f*4)
    let values=[1.0+glow*(23+core*15),2+glow*(24+core*12),5+glow*(36+blue*12)]
    let offset=(y*width+x)*4
    for c in 0..<3 { pixels[offset+c]=UInt8(min(255,max(0,values[c]))) }
  }
}
var state:UInt64=0x574f524c44435241
func random()->Double { state=state &* 6364136223846793005 &+ 1442695040888963407; return Double(state>>11)/9007199254740992 }
for i in 0..<48_000 {
  let lon=random()*2*Double.pi,lat=asin(random()*2-1)
  let x=lon/(2*Double.pi)*Double(width),y=(lat/Double.pi+0.5)*Double(height-1)
  let brilliant=i<160, sigma=brilliant ? 0.65+random()*0.55:0.24+random()*0.3
  let radius=brilliant ? 8:2, luminosity=brilliant ? 155+random()*100:9+pow(random(),3)*135
  let tint=random(), color = tint<0.24 ? [1.0,0.73,0.48] : tint>0.79 ? [0.57,0.75,1.0]:[0.88,0.91,1.0]
  let stretch=min(5,1/max(0.1,cos(lat)))
  for dy in -radius...radius { for dx in -Int(Double(radius)*stretch)...Int(Double(radius)*stretch) {
    let px=(Int(x)+dx+width)%width,py=Int(y)+dy
    guard py>=0 && py<height else { continue }
    let sx=(Double(Int(x)+dx)+0.5-x)/stretch,sy=Double(py)+0.5-y,r2=sx*sx+sy*sy
    let energy=exp(-r2/(2*sigma*sigma))+(brilliant ? exp(-r2/11)*0.07:0)
    let offset=(py*width+px)*4
    for c in 0..<3 { pixels[offset+c]=UInt8(min(255,Double(pixels[offset+c])+luminosity*energy*color[c])) }
  } }
}
let destination=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1]:"Resources/SpaceSky.png")
let provider=CGDataProvider(data:Data(pixels) as CFData)!
let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
let file=CGImageDestinationCreateWithURL(destination as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(file,image,nil)
guard CGImageDestinationFinalize(file) else { fatalError("Unable to save sky") }
print("Generated seamless 4096 × 2048 galaxy and 48,000 stars: \(destination.lastPathComponent)")

// The visible sky stays sharp; lighting needs only its broad, diffuse colors.
let diffuse=CGContext(data:nil,width:512,height:256,bitsPerComponent:8,bytesPerRow:512*4,
  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
diffuse.interpolationQuality = .high
diffuse.draw(image,in:CGRect(x:0,y:0,width:512,height:256))
let diffuseURL=destination.deletingLastPathComponent().appendingPathComponent("SpaceLighting.png")
let diffuseFile=CGImageDestinationCreateWithURL(diffuseURL as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(diffuseFile,diffuse.makeImage()!,nil)
guard CGImageDestinationFinalize(diffuseFile) else { fatalError("Unable to save space lighting") }
