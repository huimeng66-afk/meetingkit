# 构建与安装指南

> **一句话结论**：iOS 的 `.ipa` 只能在 macOS 上用 Apple 的 iOS SDK + `codesign` 产出。
> 手上只有 iPhone 和 Windows/Linux 电脑时，请走 **路径一（GitHub Actions 云端 Mac）**；
> 只想今天就看到界面，走 **路径三（网页测试包，10 分钟装到主屏）**。

## 三条路径怎么选

| | 路径一 · GitHub Actions | 路径二 · 本地 Mac | 路径三 · 网页测试包 |
|---|---|---|---|
| 需要什么 | 一个 GitHub 账号 + 一台 Windows/Linux/Mac | 一台 macOS + Xcode + 开发者账号 | 任意能部署静态文件的环境 |
| 首次耗时 | 约 20 分钟（含注册/装 Sideloadly） | 约 30 分钟（装 Xcode 最久） | 5～10 分钟 |
| 单次构建 | 5～10 分钟（排队另算） | 1～2 分钟 | 无需构建 |
| 金钱成本 | 0（公开仓库免费额度充足） | 0（Mac 本身除外） | 0 |
| 能验证什么 | 真机原生 UI、屏幕共享扩展 | 全部，含调试、断点 | 界面与交互逻辑（无音视频） |
| 有效期 | 免费 Apple ID 7 天 / 付费账号 1 年 | 同左 | 永久（就是个网页） |
| 适合谁 | 没有 Mac 的开发者、外包验收 | 有 Mac 的日常开发 | 产品/设计/客户快速看效果 |

---

# 路径一：GitHub Actions 出包（推荐，零 Mac）

整条链路是：**推送代码 → GitHub 的 macos-15 机器编译 → 下载未签名 IPA → 用你自己的 Apple ID 重签安装**。
仓库里不需要、也不应该存放任何人的证书和私钥。

## 1. 把仓库推到 GitHub

```bash
cd MeetingKit
git init
git add .
git commit -m "chore: init MeetingKit"

# 有 gh CLI 的话：
gh repo create MeetingKit --private --source=. --push

# 没有 gh CLI：先在 github.com 新建空仓库，然后
git remote add origin git@github.com:<你的用户名>/MeetingKit.git
git branch -M main
git push -u origin main
```

## 2. 触发构建

**方式 A：手动触发（推荐）**

GitHub 仓库页 → **Actions** → 左侧选 **iOS Build (unsigned IPA)** → 右侧 **Run workflow**
→ 分支选 `main` → 构建配置选 `Release` → **Run workflow**

**方式 B：打 tag 自动触发**

```bash
git tag v1.0.0
git push origin v1.0.0
```

工作流会依次执行：

```
checkout → brew install xcodegen → xcodegen generate → xcodebuild -version
        → scripts/build-ipa-unsigned.sh → upload-artifact
```

超时 30 分钟；同一分支重复触发时旧任务会被自动取消（`concurrency`）。

## 3. 下载产物

构建完成后进入那次运行页面，底部 **Artifacts** 区域：

- `MeetingKit-unsigned-ipa` —— 解压后是 `MeetingKit-Release-unsigned-<时间戳>.ipa`
- `MeetingKit-dSYM` —— 崩溃符号表，排查线上问题时才有用（可选）

**artifact 只保留 14 天**，过期需要重新构建。

## 4. 重签并安装（关键一步）

未签名的 IPA 双击是打不开的，必须用工具"用你自己的证书重签一遍"。

### 方案 A：Sideloadly（Windows / macOS，最省事）

1. 打开 <https://sideloadly.io> 下载并安装（Windows 需要先装 iTunes 或 Apple Devices）
2. 用数据线把 iPhone 连上电脑，手机上点 **信任此电脑**
3. 打开 Sideloadly，把 `.ipa` 拖进 **IPA** 输入框
4. **Apple ID** 填你自己的 Apple ID（只在本机使用，不会上传到我们这边）
5. 点 **Start**，等待进度条走完（会提示输入 Apple ID 密码，开了二步验证的话要用「App 专用密码」）

装好后首次打开会提示"未受信任的开发者"：

- **iOS 16 及以上**：设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启手机
- 设置 → 通用 → VPN 与设备管理 → 开发者 App → **信任**

### 方案 B：AltStore / SideStore（需要电脑常驻）

1. 电脑装 AltServer（<https://altstore.io>），手机装 AltStore
2. 手机与电脑连同一个 Wi-Fi，AltServer 菜单里选 **Install AltStore → 你的设备**
3. 把 `.ipa` 用 AirDrop/文件传到手机，AltStore 里 **My Apps → +** 选择它
4. AltStore 会每 7 天在后台帮你续签（需要电脑在线）

## 5. 有效期与限制（免费 Apple ID）

| 项目 | 免费 Apple ID | 付费开发者账号（$99/年） |
|---|---|---|
| 有效期 | **7 天**，过期需重装 | 1 年 |
| 同时安装 App 数 | 3 个 | 不限（受设备数限制） |
| 每周可注册 App ID | 10 个 | 不限 |
| 可安装设备 | 仅本机 | 最多 100 台已注册设备 |
| App Groups 能力 | **通常不授予** | 支持 |

7 天到期后 App 打不开（图标还在），重新执行一次第 4 步即可，聊天记录之类的本地数据不会丢。

## 6. ⚠️ App Groups 的现实问题

本项目用了 **App Group + ReplayKit 广播扩展** 来做屏幕共享。免费个人团队通常**不授予 App Groups 能力**，
重签时可能看到：

```
Provisioning profile doesn't support the App Groups capability
```

这时有三条路：

1. **升级到付费开发者账号**（唯一能完整验证屏幕共享的方式）
2. **只验证界面**：主 App 可以装，扩展装不上 → 会议 UI、聊天、参会人面板都能用，
   但点"共享屏幕"唤起系统选择器时会失败（`RPSystemBroadcastPickerView` 找不到可用扩展）
3. **看网页测试包**（路径三）：屏幕共享的交互流程在里面完整模拟了一遍，用来对齐设计足够

---

# 路径二：本地 Mac 出包

适合日常开发。前提：macOS + Xcode（App Store 装，约 10 GB）+ 已登录开发者账号。

## 1. 一次性准备

```bash
# 1) 装命令行工具链
xcode-select --install
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app

# 2) 装 XcodeGen（本工程用 project.yml 描述工程，不提交 .xcodeproj）
brew install xcodegen

# 3) Xcode 里登录账号：Xcode → Settings → Accounts → + → Apple ID
```

## 2. 出包

```bash
cd MeetingKit

# 有证书：自动签名 + 导出，产物可直接安装
./scripts/build-ipa.sh --team ABCDE12345

# 没有证书：产出未签名包，再走 Sideloadly（同路径一第 4 步）
./scripts/build-ipa.sh

# 想要 Debug 配置 / 自定义输出路径
./scripts/build-ipa.sh --configuration Debug --team ABCDE12345 --output ~/Desktop/MeetingKit.ipa
```

**Team ID 在哪找**：<https://developer.apple.com/account> → Membership → Team ID，
或 `security find-identity -v -p codesigning` 看证书名括号里的 10 位串。

产物固定在：

```
build/MeetingKit-<Release|Debug>-<yyyyMMdd-HHmm>.ipa
```

脚本会打印文件大小和后续安装提示；`build/archive.log`、`build/export.log` 保留完整日志。

## 3. 装到手机

**方式 A：Xcode 图形界面**

Xcode → **Window → Devices and Simulators** → 左侧选中 iPhone → **Installed Apps** 下的 **+** → 选 `.ipa`

**方式 B：命令行（Xcode 15+）**

```bash
# 先看设备 UDID
xcrun devicectl list devices

# 安装（devicectl 需要解包后的 .app，不是 .ipa）
unzip -q build/MeetingKit-Release-*.ipa -d /tmp/mk
xcrun devicectl device install app --device <UDID> /tmp/mk/Payload/MeetingKit.app
```

**方式 C：真机调试**

```bash
xcodegen generate
open MeetingKit.xcodeproj
# 选中 MeetingKit scheme → 选择已连接的 iPhone → ⌘R
```

**方式 D：TestFlight 分发（需要付费账号）**

把 `.ipa` 拖进 **Transporter** 上传 → App Store Connect → TestFlight 添加测试员。
这种方式不受 7 天限制，但要走一次审核（外部测试）。

---

# 路径三：网页测试包（今天就能装到主屏）

`webdemo/` 是一个纯静态单页应用，视觉与交互按原生版 1:1 还原，
**不含任何音视频能力**，用来给产品/设计/客户在真机上快速验收界面。

## 1. 部署（任选一种）

### A. 本地起服务（最快，同一 Wi-Fi 就能看）

```bash
cd MeetingKit/webdemo
python3 -m http.server 8000
```

手机和电脑连同一个 Wi-Fi，Safari 打开 `http://<电脑的局域网IP>:8000`
（Mac 上 `ipconfig getifaddr en0` 查 IP，Windows 上 `ipconfig` 看 IPv4）。

> ⚠️ 用 `http://局域网IP` 访问时 Service Worker 不会注册（浏览器要求 HTTPS 或 localhost），
> 也就是**没有离线缓存**，但页面功能完全正常。用 `python3 -m http.server` + `http://localhost:8000`
> 在电脑上会注册成功。

### B. GitHub Pages（推荐长期用）

```bash
# 把 webdemo 目录内容推到 gh-pages 分支
cd MeetingKit
git subtree push --prefix webdemo origin gh-pages
```

仓库 Settings → Pages → Source 选 `gh-pages` 分支 → 得到 `https://<用户名>.github.io/MeetingKit/`。
HTTPS 环境下 Service Worker 正常注册，断网也能打开。

### C. Vercel / Netlify / 任意静态托管

把 `webdemo/` 整个目录拖进去即可，无需构建命令，输出目录填 `webdemo`（或根目录）。

## 2. 添加到主屏幕

1. iPhone 用 **Safari** 打开上面的地址（必须是 Safari，Chrome 加到主屏不会全屏）
2. 点底部 **分享** 按钮
3. 下滑找到 **添加到主屏幕**
4. 名称保持 `MeetingKit` → **添加**

从主屏图标打开后是**全屏无地址栏**的（`display: standalone` + `apple-mobile-web-app-capable`），
状态栏透明覆盖在画面上，和原生版的沉浸式观感一致。

## 3. 能验什么、什么是模拟的

| 能力 | 状态 |
|---|---|
| 会议顶栏（标题/时长真实走秒/会议号/信号/布局切换/人数） | ✅ 真实逻辑 |
| 演讲者 / 宫格双布局切换 | ✅ 真实逻辑 |
| 麦克风、摄像头开关与红态、toast | ✅ 真实逻辑（不采集设备） |
| 共享屏幕全流程（选择面板 → 系统确认 → 红条 + 文档 + 计时 → 停止） | 🟡 流程真实，画面是静态模拟 |
| 参会人 / 聊天 / 更多 三档抽屉 | ✅ 真实逻辑 |
| 聊天输入发送、气泡、自动滚底、未读清零 | ✅ 真实逻辑（回复是预设话术） |
| 点画布隐藏/显示控件 | ✅ 真实逻辑 |
| 毛玻璃、1px 渐变描边、安全区适配 | ✅ CSS 真实渲染 |
| 音视频采集、ReplayKit 广播、信令 | ❌ 未实现（网页版不做） |

调试参数（验收用，已保留在代码里）：

```
?state=sharing   # 直接渲染「共享中」
?state=grid      # 直接渲染宫格
?state=chat      # 直接打开聊天抽屉
?state=people    # 直接打开参会人抽屉
?state=more      # 直接打开更多抽屉
```

---

# 为什么 Linux / Windows 不能直接编 iOS

这不是"工具没装好"，而是三件事同时卡住：

1. **没有 iOS SDK**。编译 iOS 目标需要 Apple 分发的 `iPhoneOS.sdk`（含 UIKit、ReplayKit 等私有头与
   二进制 stub）。它只随 Xcode 发布，而 Xcode 的许可协议限定在 **Apple 硬件**上运行。
2. **没有 `codesign`**。iOS 内核在启动进程前强制校验代码签名（CDHash + 描述文件 + 证书链）。
   `codesign` 是 macOS 独有的组件，签名格式（CodeDirectory、CMS blob）没有可用的跨平台实现。
3. **没有描述文件校验链**。`security cms`、`codesign_allocate`、`amfid` 校验都依赖 macOS 系统组件；
   哪怕你在 Linux 上手工拼出签名结构，也无法通过设备端的 `amfid` 校验。

常见的"绕过"方案都不成立：

| 方案 | 为什么不行 |
|---|---|
| osxcross / Darling 交叉编译 | 能产出 Mach-O，但拿不到合法 SDK 授权，且没有 `codesign`，产物装不上真机 |
| 自签名 + 越狱 | 需要设备越狱，且不是合规分发路径；企业内测也不接受 |
| 把 .app 直接改后缀成 .ipa | 只是换了壳，没有签名依然无法安装 |
| 用 Android 打包工具 | 平台完全不同 |

所以只有三条合规路径：**租/借一台 Mac**、**用云端 macOS（GitHub Actions / MacStadium / MacinCloud /
Codemagic）**、**用别人的 Mac 出一次包**。本仓库的路径一就是第二条。

---

# 常见失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `No signing certificate "iOS Development" found` | Xcode 没登录账号，或该账号没有开发证书 | Xcode → Settings → Accounts 登录；`--team` 传对 Team ID；脚本会自动 `-allowProvisioningUpdates` 申请证书 |
| `Provisioning profile doesn't support App Groups` | 免费个人团队不授予 App Groups（本项目扩展需要） | 升级付费账号；或只装主 App 验证 UI（见路径一第 6 节） |
| `MeetingKit 屏幕共享` 不出现在系统录屏列表 | 扩展没被内嵌到 `PlugIns/`，或 bundle id 前缀不对 | 运行 `./scripts/verify-project.sh` 检查 `embed: true`、bundle id 前缀、`NSExtensionPrincipalClass` |
| 装上后 7 天打不开 | 免费 Apple ID 签名过期 | 用 Sideloadly/AltStore 重签一次，数据保留 |
| `Unable to install "MeetingKit"`，提示设备未注册 | development 描述文件只允许已注册设备 | developer.apple.com → Devices 添加 UDID 后重新归档 |
| 打开就闪退，日志里是 `application-groups` 相关 | entitlements 与描述文件里的 App Group 不一致 | 核对 `Shared/AppGroupConfig.swift` 与两份 `.entitlements`（verify 脚本会查） |
| `xcodegen: command not found` | 没装 XcodeGen | `brew install xcodegen`（macOS）／CI 已内置安装步骤 |
| Actions 里 `xcodebuild: error: Unable to find a destination` | 模拟器/设备 destination 不匹配 | 本工程用 `generic/platform=iOS`，一般不会触发；检查 `project.yml` 的 deploymentTarget |
| `webdemo` 加到主屏后顶部有白边 | 用了 Chrome 添加，或没加 `viewport-fit=cover` | 用 Safari 添加；确认 `apple-mobile-web-app-status-bar-style=black-translucent` |
| 网页版断网打不开 | 用局域网 IP + HTTP 访问，Service Worker 未注册 | 部署到 HTTPS（GitHub Pages / Vercel）后再添加到主屏 |

---

# 命令速查

```bash
# 工程体检（Linux/macOS 都能跑，不依赖 Xcode）
./scripts/verify-project.sh

# 只打包不签名（CI 与本地共用）
./scripts/build-ipa-unsigned.sh --configuration Release

# 本地一键出包
./scripts/build-ipa.sh --team <TEAM_ID>

# 网页测试包
cd webdemo && python3 -m http.server 8000
```

相关文档：

- [`docs/screen-sharing.md`](./screen-sharing.md) —— 屏幕共享的 App Group / ReplayKit 实现说明
- [`docs/ui-preview.html`](./ui-preview.html) —— 设计稿级静态预览（三台手机并排）
- [`webdemo/README.md`](../webdemo/README.md) —— 网页测试包说明
