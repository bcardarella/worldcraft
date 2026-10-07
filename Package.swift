// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorldcraftCore",
    platforms: [.macOS(.v14), .visionOS(.v2), .iOS(.v18)],
    products: [.library(name: "WorldCore", targets: ["WorldCore"])],
    targets: [
        .target(name: "WorldCore"),
        .testTarget(name: "WorldCoreTests", dependencies: ["WorldCore"]),
        // Compile the real input adapter on macOS for controller lifecycle tests.
        // Exercise the same asynchronous life controllers used by the headset app.
        .target(name: "WorldLife", dependencies: ["WorldCore"], path: "App/World",
            exclude: ["ActorModelRenderer.swift", "DinosaurRenderer.swift", "FireRenderer.swift", "LampRenderer.swift", "ElevatorRenderer.swift", "DoorRenderer.swift", "ItemDropRenderer.swift", "JevCredentials.swift", "LavaMaterial.swift", "OpenRouterCredentials.swift", "PerformanceTrace.swift", "PlayerHands.swift", "PlayerAvatarRenderer.swift", "PrecipitationRenderer.swift", "RocketRenderer.swift", "SculptureBuilder.swift", "SettlementLife.swift", "SkyRenderer.swift", "TerrainMeshResource.swift", "TerrainRenderResources.swift", "StadiumSeatRenderer.swift", "SportsRenderer.swift", "TerrainAtlasMaterial.swift", "UniverseRenderer.swift", "VehicleRenderer.swift", "BoatRenderer.swift", "VehicleModelRenderer.swift", "WaterMaterial.swift", "WaterRenderer.swift", "WildlifeRenderer.swift", "WindRenderer.swift", "WorldRenderer.swift", "WorldSave.swift"],
            sources: ["CreatureSimulation.swift", "DeliberationService.swift", "HomesteadLife.swift", "FaunaLife.swift", "SettlementSimulation.swift", "LifeExchange.swift", "LifeWorker.swift", "LifeCoordinator.swift"]),
        .testTarget(name: "WorldLifeTests", dependencies: ["WorldLife", "WorldCore"]),
        .target(name: "WorldInput", dependencies: ["WorldCore"], path: "App/Input"),
        .testTarget(name: "WorldInputTests", dependencies: ["WorldInput"])
    ]
)
