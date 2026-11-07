# 离线签名权限审计

在 ios 目录执行：

```sh
python3 scripts/audit-signing.py --manifest /local/audit.json
python3 scripts/test-signing-audit.py
bash scripts/verify-project.sh
bash scripts/verify-project.sh --strict
```

manifest 是 JSON 数组，每个主 app / appex 都必须单独列出。路径相对于 manifest 所在目录：

```json
[
  {"bundle_id":"com.example.app","profile":"app.mobileprovision","entitlements":"app.entitlements","info":"App/Info.plist"},
  {"bundle_id":"com.example.app.Broadcast","profile":"extension.mobileprovision","entitlements":"extension.entitlements","info":"App/PlugIns/Broadcast.appex/Info.plist"}
]
```

`entitlements` 必须是该 bundle 实际计划使用的权限 plist；`info` 可选，但产物审计应提供，检查实际 CFBundleIdentifier。审计者负责列全 bundle；工具不自动证明 manifest 覆盖整个 IPA。不要直接把包含未展开 Xcode 变量的源 plist 当作最终权限。

每个 profile 使用 openssl cms 解码（macOS 也可回退 security cms），检查 application-identifier 对 bundle 的授权、TeamIdentifier 与 entitlement team、申请的 team/application identifier（如存在）、CreationDate/ExpirationDate、申请的 App Groups 是否被授权，以及多个 bundle 是否拥有共同的已申请且已授权 App Group。各 bundle team 必须一致。App ID 支持精确值及末尾 `.*`，App Group 不接受通配符。ApplicationIdentifierPrefix 与 TeamIdentifier 分开处理，允许历史 App ID prefix 与 team 不同。

输出仅含 bundle 序号和检查状态，不输出 profile、证书、设备列表、路径、team/group 值或解析异常。错误统一隐藏输入细节，避免恶意输入使凭据进入日志。

这是离线授权检查，不验证 Apple CMS 信任链/撤销、证书与私钥匹配、签名有效性、设备授权或所有 entitlement 类型。openssl 的 `-noverify` 不进行证书信任链验证，不能把审计 PASS 当作可安装或可发布证明。`--fixture-plists` 仅用于合成测试，明确绕过 CMS，不可用于签名。

`sign-ipa.sh` 现在遇到任何内嵌 app/appex 直接拒绝，不会继续把同一个 profile 分发到扩展。单主 app 路径在复制 profile 和调用 zsign 之前运行审计。zsign 调用参数保持原样；未核验递归签名语义，因此本次没有启用多 profile 递归签名。测试不执行真实签名，也不接入外部服务。

工程检查现在从 project.yml 与 Info.plist 校验 Bundle ID，并识别 Swift 运行时解析形式，不再要求动态属性是字符串常量。源文件通过 NUL 分隔临时文件枚举，避免 iSH 的 /dev/fd 进程替换失败。缺少 swiftc 输出 SKIP，普通模式允许返回 0，但明确显示检查不完整；`--strict` 将任何 SKIP 作为非零退出。显式提供无效 MK_SWIFTC 会产生 FAIL。swiftc -parse 仅验证语法，完整 iOS 构建仍需要 macOS/Xcode。

离线测试运行时在临时目录生成不含真实证书的 fixtures，覆盖有效授权、过期、未生效、缺日期、错误 bundle/team/group、不同 team、无公共 group、错误组类型、重复 bundle、Info.plist 不一致、通配授权、申请标识不一致、损坏 CMS、空 manifest 和日志脱敏。
