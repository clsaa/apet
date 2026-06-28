public enum PetKind: Equatable {
    case builtin(String)
    case custom(id: String)
}
public enum PetSelection {
    public static func parse(_ raw: String) -> PetKind {
        if raw == "shiba" || raw == "bichon" { return .builtin(raw) }
        if raw.hasPrefix("custom:") {
            let id = String(raw.dropFirst("custom:".count))
            return id.isEmpty ? .builtin("shiba") : .custom(id: id)
        }
        return .builtin("shiba")
    }
}
