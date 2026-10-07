import RealityKit
import UIKit
import WorldCore

/// Seven geometry sets and cloned paint variants, never an Entity per voxel.
@MainActor final class VehicleModelLibrary {
  private struct Key: Hashable { let kind: VehicleKind; let variant: Int; let solar: Bool }
  private var prepared: [VehicleKind:PreparedVehicleModel] = [:]
  private var meshes: [VehicleKind:[MeshResource]] = [:]
  private var prototypes: [Key:Entity] = [:]
  private var preparing: Task<Void,Never>?
  func model(kind: VehicleKind, variant: Int, solar: Bool) -> Entity? {
    let key=Key(kind:kind,variant:variant,solar:solar)
    if let prototype=prototypes[key] { return prototype.clone(recursive:true) }
    guard let geometry=prepared[kind] else {
      if preparing == nil {
        preparing=Task { [weak self] in
          let geometry=await VehicleMeshPreparation.shared.prepare(kind)
          self?.prepared[kind]=geometry; self?.preparing=nil
        }
      }
      return nil
    }
    if meshes[kind] == nil {
      do { meshes[kind]=try geometry.meshes.map { try TerrainMeshResource.make($0) } }
      catch { print("WORLDCRAFT_VEHICLE mesh error: \(error)"); return nil }
    }
    guard let meshes=meshes[kind] else { return nil }
    var glass=PhysicallyBasedMaterial()
    glass.baseColor = .init(tint:.init(red:0.48,green:0.70,blue:0.76,alpha:1))
    glass.blending = .transparent(opacity:.init(floatLiteral:0.12)); glass.roughness = .init(floatLiteral:0.08)
    glass.faceCulling = .none
    let colors: [UIColor] = switch kind {
    case .luxury: [.init(white:0.12,alpha:1),.init(white:0.91,alpha:1),.init(red:0.12,green:0.32,blue:0.27,alpha:1)]
    case .pickup,.deliveryVan: [.init(red:0.94,green:0.65,blue:0.13,alpha:1),.init(white:0.86,alpha:1),.init(red:0.22,green:0.44,blue:0.67,alpha:1)]
    default: [.init(red:0.93,green:0.66,blue:0.15,alpha:1),.init(red:0.76,green:0.13,blue:0.20,alpha:1),.init(red:0.08,green:0.53,blue:0.57,alpha:1)]
    }
    let paint=solar ? UIColor(red:0.26,green:0.17,blue:0.19,alpha:1):colors[variant % colors.count]
    let materials: [any Material] = [
      SimpleMaterial(color:paint,roughness:kind == .luxury ? 0.20:kind.sporting ? 0.25:0.37,isMetallic:true),glass,
      SimpleMaterial(color:.init(white:0.055,alpha:1),roughness:0.95,isMetallic:false),
      UnlitMaterial(color:solar ? .orange:.init(red:1,green:0.93,blue:0.74,alpha:1)),
      SimpleMaterial(color:.init(white:0.62,alpha:1),roughness:0.23,isMetallic:true),
      UnlitMaterial(color:.init(red:0.78,green:0.055,blue:0.025,alpha:1)),
      SimpleMaterial(color:kind == .luxury ? .init(red:0.50,green:0.32,blue:0.19,alpha:1):.init(red:0.24,green:0.22,blue:0.19,alpha:1),roughness:0.75,isMetallic:false),
      SimpleMaterial(color:.init(white:0.13,alpha:1),roughness:0.55,isMetallic:false),
      UnlitMaterial(color:.init(red:0.36,green:0.77,blue:0.78,alpha:1))]
    let root=Entity(); root.name=kind.name; root.scale = .init(repeating:WorldScale.blocks(1))
    for (index,part) in geometry.parts.enumerated() {
      let node=Entity(); node.name=part.name; node.position=part.pivot
      node.addChild(ModelEntity(mesh:meshes[index],materials:materials)); root.addChild(node)
    }
    let headlights=Entity(); headlights.name="Headlight beam"
    headlights.position=[0,WorldScale.metres(kind.height)*0.55-0.12,-WorldScale.metres(kind.halfLength)-0.02]
    headlights.orientation=simd_quatf(angle:-0.075,axis:[1,0,0])
    headlights.components.set(SpotLightComponent(color:.init(red:1,green:0.95,blue:0.82,alpha:1),
      intensity:4_800,innerAngleInDegrees:22,outerAngleInDegrees:58,attenuationRadius:40))
    headlights.isEnabled=false; root.addChild(headlights)
    prototypes[key]=root.clone(recursive:true)
    return root
  }
}
