import RealityKit
import UIKit
import WorldCore

@MainActor
final class UniverseRenderer {
  let root = Entity()
  let lighting = Entity()
  private let sun = PointLight()
  private var labels: [(Entity, Int)] = []
  private var planets: [Int: ModelEntity] = [:]
  private var cloudLayers: [Int: ModelEntity] = [:]
  private var bodies: [Int: Entity] = [:]
  private var corona = Entity()
  private var generation = UUID()
  private(set) var isReady = false

  func configure(_ system: SolarSystem) async throws {
    clear()
    root.scale = .init(repeating: WorldScale.metresPerBlock)
    let lifetime = generation
    try Task.checkCancellation()
    guard let url = Bundle.main.url(forResource: "SpaceLighting", withExtension: "png"),
      let image = UIImage(contentsOfFile: url.path)?.cgImage
    else { throw CocoaError(.fileReadCorruptFile) }
    let environment = try await EnvironmentResource(equirectangular: image, withName: "Space")
    guard !Task.isCancelled, generation == lifetime else { return }
    lighting.components.set(
      ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.25))
    root.addChild(lighting)
    root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
    // Scene units are metres; a kilometre-scale solar source needs a correspondingly
    // large lumen value. Lighting directions now come from the visible star.
    sun.light.intensity = 7.0e9
    sun.light.attenuationRadius = 7_000
    sun.light.color = UIColor(red: 1, green: 0.94, blue: 0.84, alpha: 1)
    sun.position = system.sun.center
    root.addChild(sun)
    for planet in system.planets {
      // Keep at most one set of full-resolution maps in flight. Texture uploads
      // yield to the scene instead of synchronously queuing all six planets.
      let worker = Task.detached(priority: .utility) { PlanetSurfaceMap.generate(planet) }
      let map = await withTaskCancellationHandler(
        operation: { await worker.value }, onCancel: { worker.cancel() })
      guard !Task.isCancelled, generation == lifetime else { return }
      let albedo = try await texture(map.color, width: map.width, height: map.height)
      guard !Task.isCancelled, generation == lifetime else { return }
      let roughness = try await texture(map.roughness, width: map.width, height: map.height, semantic: .raw)
      guard !Task.isCancelled, generation == lifetime else { return }
      let normal = try await texture(map.normal, width: map.width, height: map.height, semantic: .normal)
      guard !Task.isCancelled, generation == lifetime else { return }
      let cloudTexture = planet.isStar ? nil : try await texture(map.cloudOpacity, width: map.width, height: map.height, semantic:.raw)
      guard !Task.isCancelled, generation == lifetime else { return }
      let body = Entity()
      body.position = planet.center
      root.addChild(body)
      bodies[planet.index] = body
      var material = PhysicallyBasedMaterial()
      material.baseColor = .init(
        tint: .white, texture: .init(albedo))
      material.roughness = .init(texture: .init(roughness))
      material.normal = .init(texture: .init(normal))
      material.specular = .init(floatLiteral:0.12)
      material.emissiveColor = .init(color:.white,texture:.init(albedo))
      material.emissiveIntensity = 0.10
      if planet.isStar {
        material.emissiveColor = .init(color: .white, texture: .init(albedo))
        material.emissiveIntensity = 0.95
        material.baseColor.tint = .black
      }
      let globe = ModelEntity(mesh: .generateSphere(radius: planet.radius), materials: [material])
      body.addChild(globe)
      planets[planet.index] = globe
      if let cloudTexture {
        var cloud=UnlitMaterial()
        cloud.color = .init(tint:UIColor(red:0.86,green:0.92,blue:1,alpha:1))
        cloud.blending = .transparent(opacity:.init(texture:.init(cloudTexture)))
        let shell=ModelEntity(mesh:.generateSphere(radius:planet.radius+2),materials:[cloud])
        globe.addChild(shell); cloudLayers[planet.index]=shell
      }
      let color = planet.style.skyTint
      var haze = UnlitMaterial(
        color: UIColor(
          red: CGFloat(color.x * 0.5), green: CGFloat(color.y * 0.65), blue: CGFloat(color.z),
          alpha: 1))
      haze.blending = .transparent(opacity: .init(floatLiteral: 0.055))
      if planet.isStar {
        corona = Entity()
        for (extra, opacity) in [(Float(35), Float(0.14)), (80, 0.075), (140, 0.025)] {
          var glow = UnlitMaterial(color: UIColor(red: 1, green: 0.40, blue: 0.045, alpha: 1))
          glow.blending = .transparent(opacity: .init(floatLiteral: opacity))
          corona.addChild(ModelEntity(mesh: .generateSphere(radius: planet.radius + extra), materials: [glow]))
        }
        body.addChild(corona)
      } else {
        body.addChild(ModelEntity(mesh: .generateSphere(radius: planet.radius + 9), materials: [haze]))
      }
      let label = ModelEntity(
        mesh: .generateText(
          planet.isStar ? "Sun · Lava world" : planet.name, extrusionDepth: 0.01, font: .systemFont(ofSize: 10, weight: .semibold),
          alignment: .center),
        materials: [UnlitMaterial(color: .white)])
      let bounds = label.visualBounds(relativeTo: label)
      let wrapper = Entity()
      label.position.x = -bounds.center.x
      wrapper.addChild(label)
      wrapper.position = [0, planet.radius + 35, 0]
      body.addChild(wrapper)
      labels.append((wrapper, planet.index))
      print("WORLDCRAFT_STARTUP stage=planet_ready index=\(planet.index)")
    }
    isReady = true
  }

  private func texture(_ pixels: [UInt8], width: Int, height: Int, semantic: TextureResource.Semantic = .color) async throws -> TextureResource {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { throw CocoaError(.fileReadCorruptFile) }
    return try await TextureResource(image: image, options: .init(semantic: semantic))
  }

  func update(
    _ space: SpaceFlight, frame: PlayerFrame, selectedPlanet: Int,
    system: SolarSystem, time: Double
  ) {
    root.isEnabled = true
    root.orientation = frame.trackingFromWorldRotation
    root.position = frame.worldOriginInTracking
    for planet in system.planets {
      bodies[planet.index]?.position = planet.position(at: time)
      cloudLayers[planet.index]?.orientation=simd_quatf(angle:Float(time.truncatingRemainder(dividingBy:1800)/1800*2 * .pi),axis:[0,1,0])
      planets[planet.index]?.orientation = simd_quatf(
        angle: Float(time.truncatingRemainder(dividingBy: 1_200) / 1_200 * 2 * .pi), axis: [0, 1, 0])
    }
    corona.scale = .init(repeating: 1 + sin(Float(time.truncatingRemainder(dividingBy: 1_000)) * 0.7) * 0.012)
    for (label, index) in labels {
      let position = system.planets[index].position(at: time) + label.position
      let direction = space.position - position
      if simd_length_squared(direction) > 1 {
        label.orientation = simd_quatf(from: [0, 0, 1], to: simd_normalize(direction))
      }
    }
    for (index, planet) in planets {
      planet.name = index == selectedPlanet ? "Destination" : "Planet"
    }
  }
  func clear() {
    generation = UUID()
    isReady = false
    root.children.removeAll()
    root.isEnabled = false
    labels.removeAll()
    planets.removeAll(); cloudLayers.removeAll()
    bodies.removeAll()
  }
}
