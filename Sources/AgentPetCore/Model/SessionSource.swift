/// 进程内来源标记——区分 hook 实时事件与 jsonl 合成事件。
/// 仅存活于内存，绝不序列化到 wire 格式。
public enum SessionSource: Equatable {
    case hook
    case jsonl
}
