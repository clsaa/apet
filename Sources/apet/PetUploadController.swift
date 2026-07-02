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
    /// F5：上传即命名——名字落 PetNameStore（与首选项共用同一文件）。
    private let nameStore: PetNameStore
    /// In-flight cutout task — cancelled before starting a new one (MINOR-6).
    private var cutoutTask: Task<Void, Never>?

    init(store: CustomPetStore, applyPet: @escaping (PetKind) -> Void) {
        self.store = store
        self.applyPet = applyPet
        let appSupport = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/AgentPet")
        self.nameStore = PetNameStore(
            url: URL(fileURLWithPath: (appSupport as NSString).appendingPathComponent("pet-names.json")))
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
            self.promptNameAndCutout(id: id)
        }
    }

    /// F5 + 评审修复（用户 M2 三连弹窗）：命名与「抠图/用原图」合并为**一个**弹窗。
    /// 取消 → 删除导入、不留名字（无孤儿）。名字留空则沿用默认编号（首张自动 01=你本人）。
    private func promptNameAndCutout(id: String) {
        let alert = NSAlert()
        alert.messageText = "给这只宠物起个名字"
        let visionAvailable: Bool
        if #available(macOS 14.0, *) { visionAvailable = true } else { visionAvailable = false }
        alert.informativeText = visionAvailable
            ? "比如对应的人或宠物的名字（留空用默认编号）。\n「抠图」在本地识别主体去背景（零网络）；「用原图」则圆形裁切显示。"
            : "比如对应的人或宠物的名字（留空用默认编号）。将使用原图（圆形裁切显示）。"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.placeholderString = "名字（可留空）"
        alert.accessoryView = tf
        alert.window.initialFirstResponder = tf
        if visionAvailable {
            alert.addButton(withTitle: "抠图")
            alert.addButton(withTitle: "用原图")
            alert.addButton(withTitle: "取消")
        } else {
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "取消")
        }
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement：确保弹窗在最前
        let response = alert.runModal()

        // 取消（有 Vision 时第三键，无 Vision 时第二键）→ 清理导入，不留任何痕迹。
        let cancelReturn: NSApplication.ModalResponse =
            visionAvailable ? .alertThirdButtonReturn : .alertSecondButtonReturn
        if response == cancelReturn {
            try? store.delete(id: id)
            return
        }

        // 保存名字（非取消才落盘，杜绝孤儿名字）。
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            var names = nameStore.load()
            names[id] = name
            try? nameStore.save(names)
            NotificationCenter.default.post(name: .apetPetNamesChanged, object: nil)
        }

        if visionAvailable && response == .alertFirstButtonReturn {
            runCutout(
                id: id,
                srcPath: store.originalPath(id: id),
                dstPath: store.cutoutPath(id: id),
                onFailureTitle: "抠图未完成"
            )
        } else {
            // 用原图（或 macOS 13 无 Vision）——PetView 圆形裁切。
            applyPet(.custom(id: id))
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

    /// Runs Vision cutout asynchronously.
    /// - On success: `applyPet(.custom(id:))`.
    /// - On failure: show `onFailureTitle` + error detail; **never call applyPet** (spec §3 产品B-1).
    private func runCutout(id: String, srcPath: String, dstPath: String, onFailureTitle: String) {
        // MINOR-6: 取消上一个未完成的抠图任务，防止快速多次点击开启并发抠图。
        cutoutTask?.cancel()
        cutoutTask = Task { [weak self] in
            guard let self else { return }
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
            // 任务被取消后不处理结果（避免向已取消任务的 id 调用 applyPet）。
            guard !Task.isCancelled else { return }
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
