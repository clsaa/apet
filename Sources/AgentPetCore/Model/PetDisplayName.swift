/// 内置宠物展示名（F5）。未知名回退原始 key。自定义宠物名另由 store 提供。
public enum PetDisplayName {
    public static func builtin(_ name: String) -> String {
        switch name {
        case "author": return "01 默认"
        case "shiba":  return "02 柴犬"
        case "bichon": return "03 比熊"
        default:       return name
        }
    }
}
