# 发布指南

## 日常发布
1. 确保 main 全绿(CI 会再验)
2. 打 tag 并推送:`git tag v0.x.0 && git push origin v0.x.0`
3. Release workflow 自动:swift test → package → ad-hoc 签名 → zip → GitHub Release

## 用户安装(ad-hoc 签名版)
下载 zip 解压到 /Applications,**首次右键 → 打开**(绕过 Gatekeeper 未公证提示)。

## 升级到正式签名+公证(需 Apple Developer 账号,$99/年)
1. 导出 Developer ID Application 证书为 .p12,连同密码存入 repo secrets:
   `DEVELOPER_ID_CERT_P12_BASE64` / `DEVELOPER_ID_CERT_PASSWORD`
2. App Store Connect API key 存入:`NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` / `NOTARY_KEY_P8_BASE64`
3. release.yml 的 Ad-hoc sign 步骤替换为:
   - 导入证书到临时 keychain → `codesign --sign "Developer ID Application: <名字>" --options runtime`
   - `xcrun notarytool submit --wait` → `xcrun stapler staple AgentPet.app`
4. 之后可加 Homebrew cask(需正式公证)。
