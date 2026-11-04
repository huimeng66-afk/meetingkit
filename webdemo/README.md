# MeetingKit 网页测试版

一个**纯静态、零依赖、可离线**的单页应用，用来在没有 Mac / 没有 TestFlight 的情况下，
把 MeetingKit 的会议界面装到 iPhone 主屏上做真机验收。

- 视觉与交互对齐 `docs/ui-preview.html` 与 SwiftUI 实现（同一套 design token）
- **不含任何音视频能力**：所有摄像头/麦克风/屏幕共享都是界面模拟
- 不使用任何 CDN、外链字体、外链图片，断网可用

## 文件

```
webdemo/
├── index.html              # 单页应用（HTML + CSS + 原生 JS，无框架）
├── manifest.webmanifest    # PWA 清单（standalone / 主题色 / 图标）
├── sw.js                   # Service Worker（cache-first 预缓存，离线可开）
├── icons/
│   ├── icon-192.png        # 来自 AppIcon-1024.png
│   ├── icon-512.png
│   └── apple-touch-icon.png   # 180×180，iOS 主屏图标
└── README.md
```

## 部署

### 本地（同一 Wi-Fi，最快）

```bash
cd MeetingKit/webdemo
python3 -m http.server 8000
```

- 电脑上开 `http://localhost:8000` —— Service Worker 会注册，可离线
- 手机上开 `http://<电脑局域网IP>:8000` —— HTTP 下 Service Worker 不注册（浏览器限制），
  功能正常但没有离线缓存

### GitHub Pages

```bash
cd MeetingKit
git subtree push --prefix webdemo origin gh-pages
```

仓库 Settings → Pages → Source 选 `gh-pages` → 访问 `https://<用户名>.github.io/MeetingKit/`。
HTTPS 下 Service Worker 正常注册。

### Vercel / Netlify / 对象存储

把 `webdemo/` 整个目录上传即可，无构建步骤、无环境变量。
注意 `manifest.webmanifest` 的 MIME 需要是 `application/manifest+json`（常见托管平台默认就支持）。

## 添加到主屏

1. **用 Safari** 打开部署好的地址（Chrome 加到主屏不会进入全屏模式）
2. 点底部 **分享** → **添加到主屏幕**
3. 名称保持 `MeetingKit` → **添加**

从主屏图标启动后是全屏的（`display: standalone`），状态栏透明覆盖在画面上。

## 已实现的交互

| 区域 | 行为 |
|---|---|
| 顶栏 | 会议时长每秒真实递增；信号格；布局切换（演讲者 ⇄ 宫格）；参会人数 |
| 演讲者视图 | 渐变画布 + 中心头像 + 顶部缩略图条（当前发言人高亮）+ 右下本地小窗 |
| 宫格视图 | 8 人 2 列，主持人高亮描边，静音成员显示红点 |
| 麦克风 | 点击 → 圆圈变红 + 文案变「取消静音」+ toast |
| 摄像头 | 点击 → 圆圈变红 + 本地小窗盖上「摄像头已关闭」+ toast |
| 共享屏幕 | 点 → 底部弹出「共享选择」→ 选整个屏幕/窗口/白板 → 点「开始共享屏幕」→ toast 模拟系统确认 → 顶部红色警示条 + 共享文档画面 + 双计时器 + 底栏共享键转红（文案变「停止共享」）→ 点「停止共享」恢复 |
| 参会人 | 毛玻璃抽屉，8 人列表，主持人标签、静音状态 |
| 聊天 | 抽屉 + 未读角标（初始 2，打开即清零）+ 输入发送 + 气泡追加 + 自动滚底 + 1.4s 后一条预设回复（面板关闭时未读 +1） |
| 更多 | 抽屉，8 个功能入口（点击提示「网页版未实现」） |
| 画布 | 点空白处隐藏/显示顶栏与底栏 |
| 提示条 | 首次进入显示 3 秒：「网页测试版 · 仅用于验证界面与交互，不含音视频」（`sessionStorage` 记录，同一次会话不重复） |
| 安全区 | `viewport-fit=cover` + `env(safe-area-inset-*)`，适配刘海与底部横条 |
| 离线 | Service Worker 预缓存全部资源，断网后主屏打开仍是完整界面 |

## 哪些是模拟的

- **没有摄像头/麦克风**：不调用 `getUserMedia`，不申请任何权限
- **没有屏幕共享**：红色警示条、共享文档、计时器都是状态机模拟
- **没有网络与信令**：参会人、聊天对象都是写死的数据，回复是预设话术
- **没有真实会议号**：`862 447 109` 是静态文案
- **没有推送/来电**：网页版不涉及

## 验收调试参数

```
?state=sharing   # 直接渲染「共享中」状态
?state=grid      # 直接进入宫格
?state=chat      # 直接打开聊天抽屉
?state=people    # 直接打开参会人抽屉
?state=more      # 直接打开更多抽屉
?state=share     # 直接打开发起共享的选择面板
```

例如：`http://localhost:8000/index.html?state=sharing`

这些参数保留在代码里，方便截图验收与回归对比。

## 更新资源后

改了 `index.html` / 图标后，把 `sw.js` 顶部的 `CACHE_VERSION` 加一（`v1` → `v2`），
否则已安装的客户端会一直用旧缓存。
