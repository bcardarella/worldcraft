import Foundation

public enum VehicleKind: String, CaseIterable, Codable, Sendable {
  case touring, race, compact, pickup, deliveryVan, luxury, sports
  public var name: String {
    switch self {
    case .touring: "Town sedan"; case .race: "Circuit racer"; case .compact: "City runabout"
    case .pickup: "Work pickup"; case .deliveryVan: "Delivery van"; case .luxury: "Grand touring saloon"; case .sports: "Sports coupe"
    }
  }
  /// Speeds and dimensions use half-metre blocks; model geometry uses metres.
  public var topSpeed: Float {
    switch self { case .compact: 20; case .deliveryVan: 22; case .pickup: 25; case .touring: 28; case .luxury: 38; case .sports: 44; case .race: 48 }
  }
  public var acceleration: Float {
    switch self { case .compact: 9; case .deliveryVan: 8; case .pickup: 10; case .touring: 12; case .luxury: 16; case .sports: 22; case .race: 24 }
  }
  public var grip: Float {
    switch self { case .compact: 9; case .deliveryVan: 7.2; case .pickup: 6.7; case .touring: 8; case .luxury: 8.6; case .sports: 7.4; case .race: 11 }
  }
  public var wheelbase: Float {
    switch self { case .compact: 2.8; case .deliveryVan: 3.9; case .pickup: 4.2; case .touring, .race: 3.3; case .luxury: 4.1; case .sports: 3.5 }
  }
  public var steeringAngle: Float {
    switch self { case .compact: 0.54; case .deliveryVan, .luxury: 0.43; case .pickup: 0.44; case .sports: 0.51; default: 0.48 }
  }
  public var brakeDeceleration: Float { self == .race ? 48 : self == .sports ? 42 : self == .luxury ? 38 : 32 }
  public var halfWidth: Float { self == .compact ? 1.0 : self == .pickup ? 1.3 : self == .deliveryVan ? 1.25 : self == .luxury || self == .sports ? 1.2 : 1.1 }
  public var halfLength: Float { self == .compact ? 1.85 : self == .pickup ? 2.8 : self == .deliveryVan ? 2.6 : self == .luxury ? 2.7 : self == .sports ? 2.35 : 2.2 }
  public var height: Float { self == .compact ? 2.6 : self == .pickup ? 3.1 : self == .deliveryVan ? 3.3 : self == .sports ? 2.35 : 2.8 }
  public var seatHeight: Float { height * 0.79 }
  public var sporting: Bool { self == .sports || self == .race }

  /// Work vehicles dominate smaller settlements; saloons/coupes are common in cities.
  public static func spawned(id: UInt64, in settlement: SettlementKind) -> Self {
    let mix: [Self] = switch settlement {
    case .village: [.pickup,.compact,.deliveryVan,.touring,.pickup,.compact,.luxury,.sports]
    case .town: [.touring,.compact,.pickup,.deliveryVan,.luxury,.sports,.touring,.deliveryVan]
    case .city: [.luxury,.sports,.touring,.compact,.deliveryVan,.luxury,.pickup,.sports]
    }
    var hash = id &+ 0x9e3779b97f4a7c15
    hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
    hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
    return mix[Int((hash ^ (hash >> 31)) % UInt64(mix.count))]
  }
}
