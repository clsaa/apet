import AppKit
import UniformTypeIdentifiers
import AppShellKit
import AgentPetCore

/// Drives the photo-upload → optional-cutout flow for custom pet photos.
///
/// Injected into ``PreferencesView`` so the «上传照片» and «重新抠图» buttons
/// can trigger these actions without ``PreferencesView`` owning the logic.
///
/// **Upload flow** (spec §3 上传动线):
/// 1. NSOpenPanel (PNG/JPG) → user picks file.
/// 2. `store.importPhoto` called **synchronously inside the completionHandler**
///    (沙盒迁移留口：panel.begin completionHandler 持有 security-scope URL 访问权限).
/// 3. Alert: «抠图» → ``runCutout``; «用原图» → ``applyPet(.custom(id:))``; «取消» → no-op.
/// 4. Cutout success → `applyPet(.custom(id:))`; failure → show error, keep current pet.
///    **绝不把白底方块静默贴桌面**（spec §3 产品B-1）.
@MainActor
final class PetUploadController {

    private let store: CustomPetStore
    /// AppCoordinator-supplied callback: updates live pet + writes config.selectedPet + saves.
    private let applyPet: (PetKind) -> Void

    init(store: CustomPetStore, applyPet: @escaping (PetKind) -> Void) {
        self.store = store
        self.applyPet = applyPet
    }

    // MARK: - Upload

    /// Opens a file picker, imports the photo, then presents the cutout-or-original dialog.
    func upload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择宠物照片"
        panel.message = "支持 PNG / JPG（自动压缩至 512 px，剥除 GPS/EXIF 元数据）"

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // ⚠️ importPhoto must run synchronously here while the security scope is open.
            let id: String
            do {
                id = try self.store.importPhoto(srcPath: url.path)
            } catch {
                self.showAlert("导入失败", detail: error.localizedDescription)
                return
            }
            self.promptCutout(id: id)
        }
    }

    // MARK: - Re-cutout

    /// Re-runs Vision cutout for an already-imported pet.
    /// On success, sets the pet as current; on failure, shows an error and keeps the current pet.
    func recutout(id: String) {
        runCutout(
            id: id,
            srcPath: store.originalPath(id: id),
            dstPath: store.cutoutPath(id: id),
            onFailureTitle: "重新抠图未完成"
        )
    }

    // MARK: - Set as current

    /// Immediately applies an existing custom pet (builtin-to-custom switch in prefs).
    func setCurrent(id: String) {
        applyPet(.custom(id: id))
    }

    // MARK: - Private helpers

    private func promptCutout(id: String) {
        let alert = NSAlert()
        alert.messageText = "一键抠图？"
        alert.informativeText = """
            apet 将在本地识别宠物主体并去除背景（macOS 14+，零网络）。
            或直接使用原图（圆形裁切显示）。
            """
        alert.addButton(withTitle: "抠图")
        alert.addButton(withTitle: "用原图")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            runCutout(
                id: id,
                srcPath: store.originalPath(id: id),
                dstPath: store.cutoutPath(id: id),
                onFailureTitle: "抠图未完成"
            )
        case .alertSecondButtonReturn:
            // User explicitly chose original — PetView circle-clips it (spec §3 用原图).
            applyPet(.custom(id: id))
        default:
            // 取消：不更改当前宠物，已导入的图片仍保留（可从首选项管理）.
            break
        }
    }

    /// Runs Vision cutout asynchronously.
    /// - On success: `applyPet(.custom(id:))`.
    /// - On failure: show `onFailureTitle` + error detail; **never call applyPet** (spec §3 产品B-1).
    private func runCutout(id: String, srcPath: String, dstPath: String, onFailureTitle: String) {
        Task {
            let cutter = makeForegroundCutter()
            let result: Result<Void, CutoutError>
            do {
                try await cutter.cutout(srcPath: srcPath, dstPath: dstPath)
                result = .success(())
            } catch let e as CutoutError {
                result = .failure(e)
            } catch {
                result = .failure(.inferenceFailure("\(error)"))
            }
            switch CutoutDecision.decide(result: result, cutoutPath: dstPath) {
            case .setAsPet:
                applyPet(.custom(id: id))
            case .keepCurrent(let msg):
                // 失败→保持当前宠物，绝不把白底方块贴桌面（spec §3 产品B-1）.
                showAlert(onFailureTitle, detail: msg)
            }
        }
    }

    private func showAlert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
