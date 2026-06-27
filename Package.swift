// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentPet",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentPetCore", targets: ["AgentPetCore"]),
    ],
    targets: [
        .target(name: "AgentPetCore"),
        .testTarget(name: "AgentPetCoreTests", dependencies: ["AgentPetCore"]),
    ]
)
