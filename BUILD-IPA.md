# 打包 IPA（三条路径，按需选一条）

> 结论先说：**这台 Linux 服务器出不了 IPA**。iOS 的编译链（Xcode / iOS SDK / 签名）只随 macOS 分发，
> 沙箱里既没有 `xcodebuild`，也没有 iOS 的 Swift 运行时；交叉编译只能做出 Mach-O，做不出可安装的 App。
> 所以这里给的是「源码 + 一条命令」的完整出包环境，三条路径都能拿到 IPA。

| 路径 | 需要什么 | 耗时 | 产物 |
| --- | --- | --- | --- |
| A. GitHub Actions | 一个 GitHub 账号（不用 Mac） | ~8 分钟 | 未签名 IPA，Sideloadly 重签后可装 |
| B. 本地 Mac | macOS + Xcode 15/16 | ~3 分钟 | 有证书：直接可装；无证书：未签名 IPA |
| C. 不打包（现在就能用） | iPhone Safari | 10 秒 | 主屏图标，全屏运行，功能与网页一致 |

---

## A. GitHub Actions（无 Mac，推荐）

仓库里已经放好 `.github/workflows/ios-build.yml`，runner 是 `macos-15` + Xcode 16。

1. 打开 <https://github.com/new>，新建一个 **Private** 仓库（例如 `meetingkit`），不要勾选 README。
2. 解压 `MeetingKit-source.zip`，把**解压出来的内容**（能看到 `project.yml`、`MeetingKit/`、`.github/`）
   拖进仓库页面 → `uploading an existing file` → Commit。
   > `.github` 是隐藏目录，网页拖拽可能漏掉；漏了的话在仓库里新建文件
   > `.github/workflows/ios-build.yml`，把压缩包里的同名文件内容粘进去即可。
3. 进入 **Actions** → 左侧 `iOS Build (unsigned IPA)` → **Run workflow** → `Release` → 运行。
4. 约 6~8 分钟后，在该次运行页面底部 **Artifacts** 下载 `MeetingKit-unsigned-ipa`。

也可以在装有 `gh` 的机器上一条命令跑完：

```bash
cd MeetingKit
./scripts/gh-build.sh          # 自动建私有仓库、推送、触发、等待、下载 IPA 到 build/
```

### 装到 iPhone

未签名 IPA 不能直接安装，用下面任一工具，填入**你自己的 Apple ID** 重签：

- **Sideloadly**（Windows / macOS）：拖入 IPA → 输入 Apple ID → Start
- **AltStore / SideStore**（iPhone 上自签）

注意：
- 免费 Apple ID 签出的 App **7 天过期**，到期重签一次即可，数据不丢。
- 免费个人团队通常**没有 App Groups 能力**，屏幕共享扩展会装不上；主 App 的会议、音视频、聊天都正常。
- 首次安装后，iPhone 设置 → 通用 → VPN与设备管理 → 信任你的开发者证书；
  iOS 16+ 还需在 设置 → 隐私与安全性 → 开发者模式 打开。

---

## B. 本地 Mac（有 Xcode）

```bash
cd MeetingKit
brew install xcodegen          # 只需一次
xcodegen generate
./scripts/build-ipa.sh --team <你的TeamID>   # 有证书，直接可装
# 或者
./scripts/build-ipa-unsigned.sh              # 无证书，产出未签名 IPA
```

产物在 `build/`。Team ID 在 <https://developer.apple.com/account> → Membership 里看。

> 服务地址只在 `MeetingKit/Info.plist` 的 `TQServerOrigin` 配一处，默认 `https://xn--6oqu09l.shop`。
> 换域名只改这一项，REST 与 Socket.IO 都从它派生。

---

## C. 现在就能用：添加到主屏幕

iPhone Safari 打开 <https://会议.shop> → 底部「分享」→ **添加到主屏幕**。

- 全屏运行，没有地址栏，图标与原生 App 一致；
- 摄像头 / 麦克风 / 屏幕共享都走浏览器能力，和网页版完全同步；
- 不受 7 天签名限制，升级即时生效。

本次 iOS 闭麦失声的修复就是针对这条路径（Safari 的 audio session 重配），
已经用增益门控 + 常驻音频节点 + 看门狗彻底绕开。

---

## 附：本次为 iOS 改了什么

- `MeetingKit/Models/JoinInfo.swift`：`cameraOn` 默认改为 `false`（入会默认只开麦克风）。
- Web 端 `room.js`：麦克风走 `GainNode` 门控，闭麦不再 `track.enabled = false`；
  远端音频独立 `<audio>` 常驻节点 + 4 秒看门狗 + 前后台恢复。
- Web 端共享者视图：不再渲染自己的共享画面，改为「正在共享屏幕中 / 停止共享」状态卡。
