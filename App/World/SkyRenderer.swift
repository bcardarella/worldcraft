import RealityKit
import UIKit
import WorldCore

@MainActor
final class SkyRenderer {
  let root = Entity()
  let lighting = Entity()
  private let sunLight = DirectionalLight()
  private let moonLight = DirectionalLight()
  private var dayDome = ModelEntity()
  private var duskDome = ModelEntity()
  private var nightDome = ModelEntity()
  private var spaceDome = ModelEntity()
  private var sun = Entity()
  private var moon = Entity()
  private var style: PlanetStyle = .verdant
  private var seed: UInt64 = 0
  private var cloudDrift=SIMD2<Float>.zero
  private var lastCloudTime: Double?
  private var clouds:
    [(entity: Entity, x: Float, z: Float, height: Float, speed: Float, width: Float, depth: Float)] =
      []
  private(set) var cloudDensity: Float = 0
  private var dayEnvironment: EnvironmentResource?
  private var duskEnvironment: EnvironmentResource?
  private var nightEnvironment: EnvironmentResource?
  private var lastLightingUpdate: Double = -.infinity
  private var lastCloudLighting = SIMD3<Float>(repeating: -1)
  private var lastImageLighting: SIMD3<Float>?

  func configure(seed: UInt64, style: PlanetStyle = .verdant, world: Entity) throws {
    clear()
    self.seed=seed
    root.scale = .init(repeating: WorldScale.metresPerBlock)
    self.style = style
    for (name, radius) in [("SkyNight", Float(16_384)), ("SkyDay", 16_383), ("SkyDusk", 16_382)] {
      let asset = name == "SkyNight" ? name : name + style.assetSuffix
      let texture = try TextureResource.load(named: "\(asset).png")
      var material = UnlitMaterial()
      material.color = .init(tint: .white, texture: .init(texture))
      material.faceCulling = .front
      let dome = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
      root.addChild(dome)
      if name == "SkyNight" { nightDome = dome }
      if name == "SkyDay" { dayDome = dome }
      if name == "SkyDusk" { duskDome = dome }
    }
    dayEnvironment = try environment(named: "SkyDay" + style.assetSuffix)
    duskEnvironment = try environment(named: "SkyDusk" + style.assetSuffix)
    nightEnvironment = try environment(named: "SkyNight")
    var stars = UnlitMaterial()
    stars.color = .init(
      tint: .white, texture: .init(try TextureResource.load(named: "SpaceSky.png")))
    stars.faceCulling = .front
    // Planet meshes extend several kilometres away. A nearby opaque sky sphere
    // would hide them, so space has its own distant background.
    spaceDome = ModelEntity(mesh: .generateSphere(radius: 30_000), materials: [stars])
    spaceDome.isEnabled = false
    root.addChild(spaceDome)
    world.addChild(lighting)
    world.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
    var shadow = DirectionalLightComponent.Shadow()
    shadow.shadowProjection = .automatic(maximumDistance: 65)
    sunLight.shadow = shadow
    world.addChild(sunLight)
    world.addChild(moonLight)
    sun = orb(radius: 7, color: UIColor(red: 1, green: 0.96, blue: 0.76, alpha: 1), glow: 17)
    moon = orb(radius: 5, color: UIColor(red: 0.80, green: 0.88, blue: 1, alpha: 1), glow: 9)
    sun.scale = .init(repeating: 8_192 / 360)
    moon.scale = sun.scale
    root.addChild(sun)
    root.addChild(moon)
    guard style != .solar else { return }
    let generator = TerrainGenerator(seed: seed)
    var cloudMeshes: [MeshResource] = []
    for i in 0..<8 {
      let source = CloudMesher.build(seed: seed &+ UInt64(i), cellSize: Float(6 + i % 3))
      var descriptor = MeshDescriptor(name: "Cloud shelf \(i)")
      descriptor.positions = .init(source.positions)
      descriptor.normals = .init(source.normals)
      descriptor.primitives = .triangles(source.indices)
      descriptor.materials = .perFace(source.materials)
      cloudMeshes.append(try MeshResource.generate(from: [descriptor]))
    }
    // A jittered 9x9 field gives an even canopy without periodic grid outlines.
    for i in 0..<81 {
      let h = generator.hash(i, 0, salt: 612)
      let shape = Int(h % 8)
      let width = Float(6 + shape % 3) * 8
      let cloud = ModelEntity(mesh: cloudMeshes[shape], materials: cloudMaterials(environment: .init()))
      root.addChild(cloud)
      clouds.append(
        (
          cloud, Float(i % 9 - 4) * 80 + Float(h % 25) - 12,
          Float(i / 9 - 4) * 80 + Float((h >> 16) % 25) - 12,
          Float(76 + (h >> 24) % 23), Float(0.75 + Double(h % 100) / 150), width, width
        ))
    }
  }

  private func cloudMaterials(environment e: WorldEnvironment, storminess: Float = 0) -> [any Material] {
    let daylight: [SIMD3<Float>] = [[0.98, 0.99, 1], [0.57, 0.82, 0.96], [0.87, 0.95, 1]]
    let sunset: [SIMD3<Float>] = [[1, 0.91, 0.76], [0.63, 0.61, 0.75], [1, 0.85, 0.66]]
    let night: [SIMD3<Float>] = [[0.08, 0.12, 0.22], [0.025, 0.045, 0.095], [0.045, 0.075, 0.15]]
    return (0..<3).map { i in
      let lit = night[i] + (daylight[i] - night[i]) * e.daylight
      let stormShade: Float = 1 - storminess * (i == 1 ? 0.58 : 0.32)
      let color = (lit + (sunset[i] - lit) * e.twilight) * style.skyTint * stormShade
      return UnlitMaterial(color: UIColor(
        red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1))
    }
  }

  private func environment(named name: String) throws -> EnvironmentResource {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
      let image = UIImage(contentsOfFile: url.path)?.cgImage
    else { throw CocoaError(.fileReadCorruptFile) }
    return try EnvironmentResource(equirectangular: image, withName: name)
  }

  private func orb(radius: Float, color: UIColor, glow: Float) -> Entity {
    let orb = Entity()
    orb.addChild(
      ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: color)]))
    var glowMaterial = UnlitMaterial(color: color)
    glowMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.065))
    orb.addChild(ModelEntity(mesh: .generateSphere(radius: glow), materials: [glowMaterial]))
    return orb
  }

  func update(
    environment e: WorldEnvironment, eye: SIMD3<Float>, worldRotation: simd_quatf,
    trackedPosition: SIMD3<Float>, space: Bool = false
  ) {
    root.orientation = worldRotation
    root.position = trackedPosition
    sun.position = e.sunDirection * 8_192
    moon.position = e.moonDirection * 8_192
    sun.isEnabled = !space && style != .solar && e.sunVisibility > 0
    moon.isEnabled = !space && style != .solar && e.moonVisibility > 0
    sun.components.set(OpacityComponent(opacity: e.sunVisibility))
    moon.components.set(OpacityComponent(opacity: e.moonVisibility))
    let atmosphere: Float = space ? 0 : SolarSystem.atmosphereDensity(height:eye.y)
    let daylight: Float = style == .solar ? 1 : e.daylight
    let twilight: Float = style == .solar ? 0 : e.twilight
    nightDome.isEnabled = atmosphere > 0.001
    nightDome.components.set(OpacityComponent(opacity:atmosphere))
    dayDome.isEnabled = !space && daylight * atmosphere > 0.001
    duskDome.isEnabled = !space && twilight * atmosphere > 0.001
    dayDome.components.set(OpacityComponent(opacity: daylight * atmosphere))
    duskDome.components.set(OpacityComponent(opacity: twilight * 0.85 * atmosphere))
    spaceDome.isEnabled = true
    let weather=WorldWeather.sample(seed:seed,time:e.elapsed,style:style)
    let wind=WorldWind.sample(seed:seed,time:e.elapsed,position:eye+[0,100,0],weather:weather)
    let dt=Float(min(0.1,max(0,e.elapsed-(lastCloudTime ?? e.elapsed))))
    lastCloudTime=e.elapsed
    cloudDrift += SIMD2(wind.velocity.x,wind.velocity.z)*dt*0.22
    let shape: SIMD3<Float> = switch weather.formation {
      case .cirrus: [1.8,0.22,0.65]
      case .cumulus: [1,1.3,1]
      case .stratus: [1.4,0.45,1.4]
      case .cumulonimbus: [1.15,3.5,1.15]
    }
    cloudDensity = 0
    for cloud in clouds {
      cloud.entity.isEnabled = !space && abs(cloud.height-eye.y) < 600
      cloud.entity.scale += (shape-cloud.entity.scale)*min(1,dt*0.25)
      func wrap(_ x: Float) -> Float { x - floor((x + 360) / 720) * 720 }
      cloud.entity.position = [
        wrap(cloud.x + cloudDrift.x*cloud.speed - eye.x), cloud.height - eye.y,
        wrap(cloud.z + cloudDrift.y*cloud.speed - eye.z),
      ]
      let p = cloud.entity.position
      let distance = sqrt(p.x * p.x + p.z * p.z)
      let opacity = (1 - smoothstep(315, 360, distance))*(0.45+0.55*weather.cloudCover)
      if opacity > 0.999 { cloud.entity.components.remove(OpacityComponent.self) }
      else { cloud.entity.components.set(OpacityComponent(opacity: opacity)) }
      if !space {
        let horizontal = max(abs(p.x) / (cloud.width * cloud.entity.scale.x * 0.5), abs(p.z) / (cloud.depth * cloud.entity.scale.z * 0.5))
        let vertical = abs(p.y + 1.5*cloud.entity.scale.y) / (2.2*cloud.entity.scale.y)
        cloudDensity = max(
          cloudDensity,
          (1 - smoothstep(0.6, 1.1, horizontal)) * (1 - smoothstep(0.6, 1.1, vertical)))
      }
    }
    guard e.elapsed - lastLightingUpdate > 0.15,
      let dayEnvironment, let duskEnvironment, let nightEnvironment
    else { return }
    lastLightingUpdate = e.elapsed
    let cloudLighting = SIMD3(e.daylight, e.twilight, weather.storminess)
    if simd_distance(cloudLighting, lastCloudLighting) > 0.015 {
      lastCloudLighting = cloudLighting
      let cloudMaterials = cloudMaterials(environment: e, storminess: weather.storminess)
      for cloud in clouds {
        guard var model = cloud.entity.components[ModelComponent.self] else { continue }
        model.materials = cloudMaterials
        cloud.entity.components.set(model)
      }
    }
    let imageLighting = SIMD3<Float>(twilight > 0.1 ? 1 : 0,
      twilight > 0.1 ? max(twilight, daylight * 0.8) : daylight, 0.15 + daylight * 0.85)
    // Most of the day/night cycle has an exactly constant IBL source. Replacing
    // its component at 6 Hz needlessly dirties lighting for the entire world.
    // Compare exact inputs so every real twilight/intensity change is retained.
    if lastImageLighting != imageLighting {
      let source: ImageBasedLightComponent.Source = twilight > 0.1
        ? .blend(nightEnvironment, duskEnvironment, imageLighting.y)
        : .blend(nightEnvironment, dayEnvironment, imageLighting.y)
      var ibl = ImageBasedLightComponent(source: source, intensityExponent: imageLighting.z)
      ibl.inheritsRotation = true
      lighting.components.set(ibl)
      lastImageLighting = imageLighting
    }
    sunLight.light.intensity = style == .solar ? 0 : max(0, e.sunDirection.y) * 28_000
    sunLight.light.color = UIColor(
      red: 1, green: CGFloat(0.78 + e.daylight * 0.20), blue: CGFloat(0.58 + e.daylight * 0.36),
      alpha: 1)
    sunLight.look(at: eye, from: eye + e.sunDirection * 50, relativeTo: sunLight.parent)
    moonLight.light.intensity = style == .solar ? 0 : (1 - e.daylight) * 320
    moonLight.light.color = UIColor(red: 0.48, green: 0.64, blue: 1, alpha: 1)
    moonLight.look(at: eye, from: eye + e.moonDirection * 50, relativeTo: moonLight.parent)
  }

  func clear() {
    cloudDrift = .zero;lastCloudTime=nil
    root.children.removeAll()
    lighting.removeFromParent()
    sunLight.removeFromParent()
    moonLight.removeFromParent()
    clouds.removeAll()
    cloudDensity = 0
    lastLightingUpdate = -.infinity
    lastCloudLighting = .init(repeating: -1)
    lastImageLighting = nil
    dayEnvironment = nil
    duskEnvironment = nil
    nightEnvironment = nil
  }
}
