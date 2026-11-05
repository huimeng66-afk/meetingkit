# 屏幕共享：跨进程设计说明

这份文档只讲一件事——**主 App 与 Broadcast Upload Extension 之间那条链路为什么这样设计**。
UI 部分看代码即可，但这条链路如果改错，表现是"偶发不生效"，很难查。

---

## 1. 为什么必须是两个进程

iOS 的系统级屏幕共享（共享其他 App、共享桌面）只能由 **Broadcast Upload Extension** 采集。
扩展由系统在用户点「开始直播」时拉起，生命周期完全独立于主 App：主 App 被杀，它可能还在跑；主 App 在前台，它也可能已经被系统回收。

于是有两个硬约束：

1. 扩展**不能**直接调用主 App 的任何对象（不同进程、不同地址空间）
2. 主 App **不能**结束扩展进程，只能发信号让它自己调用 `finishBroadcastWithError`

所有跨进程能力都建立在两个原语上：

| 原语 | 用途 | 特性 |
|---|---|---|
| App Group（共享容器 + UserDefaults） | 传状态、传帧、传心跳 | 有数据，无事件；cfprefsd 跨进程可见性是异步的 |
| Darwin 通知（`CFNotificationCenterGetDarwinNotifyCenter`） | 传事件（"状态变了""有新帧""请停止"） | 只有事件，没有数据；不能带 userInfo |

所以设计上是**数据走 App Group，事件走 Darwin**，两者缺一不可：只写数据不发通知，对端不知道何时读；只发通知不写数据，对端读到的是旧值。

---

## 2. 四条通道

| 通道 | 方向 | 载体 | 频率 | 代码 |
|---|---|---|---|---|
| 共享状态 | 扩展 → App | `UserDefaults(suiteName:)`：`screenShare.state` / `screenShare.startedAt` | 状态跃迁时 | `ScreenShareStore` |
| 心跳 | 扩展 → App | 同上：`screenShare.heartbeat` | 2 秒 / 次 | `ScreenShareStore.touchHeartbeat()` |
| 画面帧 | 扩展 → App | 共享容器文件 `screen-share-latest.jpg`（原子写） | 24 fps 写；小窗预览 10 fps 读上限；上行推流 24 fps 轮询 | `SharedFrameStore` |
| 停止指令 | App → 扩展 | Darwin 通知 `...screenshare.stopRequested` | 用户点击时 | `ScreenShareBridge.requestStop()` |

Darwin 通知名（三端必须逐字一致）：

```
com.example.meetingkit.screenshare.stateChanged
com.example.meetingkit.screenshare.frameUpdated
com.example.meetingkit.screenshare.stopRequested
```

> 通知名里带 Bundle ID 是为了避免与其他 App 的 Darwin 通知撞名——Darwin 通知是**全系统广播**，不加前缀可能收到别人的事件。

### 2.1 App Group 的名字是"签名的产物"，必须运行时探测

工程里写的是 `group.com.tianqiong.meetingkit`，但这只是**用自己的开发者账号签名时**生效的名字。
侧载 / 代签工具重签后，实际生效的 group 由那张证书的 provisioning profile 决定，
往往长成 `group.e2904eee920f2ee6.3` 这样。写死名字的后果不是报错，而是
`containerURL(forSecurityApplicationGroupIdentifier:)` 返回 `nil`——扩展一句话都写不出来。

`AppGroupConfig` 因此按三层探测（每一层都只是**候选**，最终仍由 `containerURL` 实测把关）：

```
① Bundle.main 自己的 embedded.mobileprovision
② 从 .appex 往上两级 → 主 App 根目录的 embedded.mobileprovision   ← 重签工具只放这一份
③ SecTaskCreateFromSelf + SecTaskCopyValueForEntitlement（读本进程代码签名）
```

> **1.5.4 的真机根因就在这里**：① 对扩展永远失败（`.appex` 里没有 profile），
> ② 在 1.5.3 里不存在，于是扩展回退到未授权的 `group.com.tianqiong.meetingkit`，
> `broadcastStarted` 第一道 guard 直接结束广播。诊断表现为
> "App 侧 App Group 可用、扩展 idle、心跳无、出帧却是上一场的旧文件"。

排查只需要看诊断里这两行：

```
App Group（App）：可用（group.e2904eee920f2ee6.3）
App Group（扩展）：group.e2904eee920f2ee6.3 · 一致
```

不一致 = 签名没给扩展授权，改代码无用。

---

## 3. 完整时序

### 3.1 开始共享

```
用户点「开始共享」
  └─ BroadcastPickerPresenter.present()      唤起 RPSystemBroadcastPickerView
       └─ 用户选扩展 → 点「开始直播」
            └─ 系统启动 MeetingBroadcast 进程
                 ├─ SampleHandler.broadcastStarted
                 │    ├─ ScreenShareStore.state = .active
                 │    ├─ startedAt = now，touchHeartbeat()
                 │    └─ post(stateChanged)
                 ├─ 主 App ScreenShareBridge 收到通知
                 │    └─ refreshState() → isBroadcasting = true
                 │         └─ MeetingViewModel.applyScreenSharing(true)
                 │              ├─ 顶栏红条 + 底栏红色 + 画布切共享态
                 │              └─ rtc.startScreenShare()
                 └─ 每帧视频样本 → 节流 24fps → JPEG → 写文件 → post(frameUpdated)
                      └─ App 读文件（modificationDate 去重）→ UIImage → sharedFrame
```

**关键点**：`isScreenSharing` 只在收到 `stateChanged` 之后才变 true。用户点「开始共享」的瞬间不能乐观置 true——系统可能取消选择器，也可能扩展启动失败。

### 3.2 停止共享

```
用户点「停止共享」
  ├─ VM.stopScreenShare()：只发信号 + toast「正在停止共享…」（不乐观置 false）
  │    └─ post(stopRequested)
  └─ 扩展收到 stopRequested
       ├─ ScreenShareStore.reset()      ← 必须先清
       ├─ SharedFrameStore.clear()
       ├─ post(stateChanged)
       └─ finishBroadcastWithError(...) ← 后结束，系统会弹一次提示
            └─ App refreshState() → isBroadcasting = false
                 └─ applyScreenSharing(false) → 红条消失 + toast「已结束」
```

**为什么 reset 要在 finish 之前**：不能假设系统一定会回调 `broadcastFinished`（实现细节，跨版本不一定稳定）。先把状态清干净，即使回调丢失，App 侧也能立刻正确复位。`broadcastFinished` 里再 reset 一次是幂等的。

**为什么 App 侧不做乐观置值**：一旦提前把 `isScreenSharing` 置 false，
① 红条和"停止共享"按钮立刻消失，用户没有重试入口；
② 真实状态回来时 `applyScreenSharing` 被 `isScreenSharing != broadcasting` 短路，永远纠正不回来；
③ 扩展没收到请求时，用户连"再点一次"的机会都没有。

### 3.3 扩展异常死亡

扩展被 jetsam 杀掉、崩溃、或用户从控制中心强停，**不会有任何回调**。App 侧只能靠心跳判活：

```
扩展每 2s 写 heartbeat
  └─ App 每 4s validateLiveness()
       ├─ state != .active        → 不判
       ├─ heartbeat 距今 > 12s    → 判定死亡
       └─ 无 heartbeat：
            ├─ startedAt 距今 > 12s → 判定死亡
            └─ 连 startedAt 都没有  → 判定死亡（脏数据）
                 └─ reset() + clear() + refreshState()
```

**为什么不用"多久没收到帧"判活**：ReplayKit 在画面静止时会降低甚至停发 sample（用户只是说话、文档没翻页），此时进程完全健康却一帧都没有。用帧判活会把正常广播误杀成"已中断"，叠加乐观置值就变成"广播还在推、App 里停不掉"。

**为什么 `.paused` 不判**：暂停期间系统不一定继续回调采样，心跳可能停。判了只会误伤。

**延迟上限**：心跳超时 12s + 轮询粒度 4s ≈ 最长 16s 复位。这是"宁可多等，不误杀"的取舍。

---

## 4. 帧通道的实现取舍

```
processSampleBuffer(.video)
  ├─ 心跳（2s 节流，与帧节流解耦）        ← 只要系统还在回调，就说明进程活着
  └─ 帧处理
       ├─ 24fps 节流（1080p 文字滚动不拖影；单帧 210~300KB，跨进程落盘的上限）
       ├─ isEncoding 防重入（同时只有 1 帧在编码）
       ├─ 串行队列 encodeQueue
       ├─ CVPixelBuffer → CIImage → 短边缩到 1080（横屏 1920×1080 / 竖屏 1080×1920）
       ├─ 复用 CIContext（创建昂贵，不能每帧 new；`cacheIntermediates: false` 省内存）
       ├─ CIContext.jpegRepresentation(quality 0.78)   ← 1.5.4 起不再过 UIImage
       ├─ SharedFrameStore.write（queue.sync，写完才算数）
       └─ post(frameUpdated)
```

> 1.5.4 之前是 `CGImage → UIImage → jpegData`，三份大对象同时驻留，1080p 下峰值接近 40MB，
> 而扩展上限约 50MB —— 表现为"共享十几秒后自己停了"。
> `jpegRepresentation(of:colorSpace:options:)` 在渲染管线内直接编码，
> options 的类型是 `[CIImageRepresentationOption: Any]`（不是 `CIContextOption`）。

三个容易踩的点：

1. **不能用 `queue.async` 写帧**：必须先落盘再发通知，否则 App 收到通知时读到的还是上一帧，画面永远慢一拍
2. **不能在采样回调里做编码**：`processSampleBuffer` 是高频回调，阻塞它会直接导致丢帧甚至被系统降级
3. **扩展内存上限约 50MB**：1080p BGRA 位图约 8.3MB/帧，必须保证同一时刻只有一帧在内存里（`autoreleasepool` + `isEncoding` + 复用 `CIContext`）

> 这套 JPEG 通道只服务于**App 内预览**，不是推流方案。生产环境把 `CVPixelBuffer` 直接交给 WebRTC / SDK 的自定义采集接口，预览链路可以整段删掉。

---

## 5. 失败模式对照表

| 现象 | 最可能的原因 | 排查 |
|---|---|---|
| 系统录屏列表里没有扩展 | 扩展 Bundle ID 不是主 App 的前缀；未 embed 到 PlugIns | `xcodebuild -showBuildSettings` 看 `PRODUCT_BUNDLE_IDENTIFIER`；解包 ipa 看 `PlugIns/` |
| 扩展启动后 App 无反应（诊断：`扩展状态 idle`） | 扩展拿到的 App Group 与主 App 不一致 | 看诊断的 `App Group（扩展）` 一行；不一致就是签名没授权 |
| 扩展启动了但 App 一帧都读不到 | 帧文件写入失败（容器路径 nil）或解码失败 | 看 `主 App 读到` 是否在涨；对比 `扩展出帧` |
| 停止共享后红条不消失 | 扩展没收到 `stopRequested`（通知名不一致）| 断点 `SampleHandler` 的观察者回调 |
| 共享 10 秒后自动"结束" | 心跳停了（扩展被挂起 / 采样停了）| 打印 `ScreenShareStore.heartbeat` 时间差 |
| 重开 App 显示"正在共享"但实际没有 | 上次残留状态（进程被强杀）| 等 12s 看是否自动复位；否则查 `broadcastFinished` 是否被调用 |
| 共享画面卡顿 | 扩展编码跟不上（24fps 都做不到）| Instruments 看扩展 CPU；降低分辨率 / 质量 |

---

## 6. 接真实 RTC 时要改什么

| 位置 | 改动 |
|---|---|
| `SampleHandler.processSampleBuffer` 的 `.video` 分支 | 删掉 JPEG 编码，改为 `sendVideoSampleBuffer:` / `pushExternalVideoFrame:` |
| `SampleHandler.processSampleBuffer` 的 `.audio` 分支 | 把 `CMSampleBuffer` 交给 SDK 的音频自定义采集接口 |
| 心跳 / 状态写入 | **保留**。SDK 接管推流后，主 App 仍然只能靠这条链路感知广播存活 |
| 主 App `RTCClient` 实现 | `startScreenShare()` 里调 SDK 的开始共享；`join/leave` 映射到 SDK 的房间生命周期 |
| delegate 回调 | 全部切主线程再回调（`MeetingViewModel` 的状态都在主线程写） |

---

## 7. 一句话总结

**状态走 App Group、事件走 Darwin、存活看心跳、停止要确认。**
这四句话对应了这条链路上 90% 的坑。
