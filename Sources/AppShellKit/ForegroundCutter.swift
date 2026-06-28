import Foundation

public enum CutoutError: Error, Equatable {
    case platformUnsupported
    case noForegroundDetected
    case inferenceFailure(String)
    case outputWriteFailed(String)
}

public protocol ForegroundCutter {
    func cutout(srcPath: String, dstPath: String) async throws
}

public struct UnavailableForegroundCutter: ForegroundCutter {
    public init() {}
    public func cutout(srcPath: String, dstPath: String) async throws {
        throw CutoutError.platformUnsupported
    }
}

public enum CutoutOutcome: Equatable {
    case setAsPet(cutoutPath: String)
    case keepCurrent(message: String)
}

public enum CutoutDecision {
    public static func decide(result: Result<Void, CutoutError>, cutoutPath: String) -> CutoutOutcome {
        switch result {
        case .success:
            return .setAsPet(cutoutPath: cutoutPath)
        case .failure(let error):
            switch error {
            case .noForegroundDetected:
                return .keepCurrent(message: "未识别到宠物主体，请换张主体清晰的照片")
            case .outputWriteFailed:
                return .keepCurrent(message: "存储空间不足，抠图未完成")
            case .platformUnsupported:
                return .keepCurrent(message: "抠图需 macOS 14 及以上，可直接用原图")
            case .inferenceFailure:
                return .keepCurrent(message: "抠图未成功，可用原图")
            }
        }
    }
}
