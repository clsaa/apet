import Foundation
import AgentPetCore

#if canImport(ServiceManagement)
import ServiceManagement
#endif

// MARK: - Seam

/// 开机自启的可注入缝。真实实现走 `SMAppService.mainApp`，测试用 Mock。
public protocol LoginItemControlling {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

// MARK: - Coordinator

/// 按 `LoginItemDecider` 决策驱动 `LoginItemControlling`，返回应用后的最终注册态；
/// 错误透传供 UI 提示。纯胶水——决策在 core，副作用在注入的 control。
public struct LoginItemCoordinator {
    private let control: LoginItemControlling
    public init(control: LoginItemControlling) { self.control = control }

    /// 应用期望态。成功返回最终 registered 态；register/unregister 抛错则 `.failure`。
    public func apply(desiredEnabled: Bool) -> Result<Bool, Error> {
        let action = LoginItemDecider.plan(
            desiredEnabled: desiredEnabled,
            currentlyRegistered: control.isRegistered
        )
        do {
            switch action {
            case .register:
                try control.register()
                return .success(true)
            case .unregister:
                try control.unregister()
                return .success(false)
            case .noop:
                return .success(control.isRegistered)
            }
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Real implementation (SMAppService, macOS 13+)

#if canImport(ServiceManagement)
/// 基于 `SMAppService.mainApp`（macOS 13+）的真实登录项控制。
@available(macOS 13.0, *)
public struct SMAppServiceLoginItem: LoginItemControlling {
    public init() {}

    public var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
#endif
