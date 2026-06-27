// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentPet",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentPetCore", targets: ["AgentPetCore"]),
        .library(name: "AppShellKit", targets: ["AppShellKit"]),
    ],
    targets: [
        .target(name: "AgentPetCore"),
        .testTarget(name: "AgentPetCoreTests", dependencies: ["AgentPetCore"]),
        .target(name: "AppShellKit", dependencies: ["AgentPetCore"]),
        .testTarget(name: "AppShellKitTests", dependencies: ["AppShellKit", "AgentPetCore"]),
        .executableTarget(name: "apet", dependencies: ["AgentPetCore", "AppShellKit"]),
    ]
)
