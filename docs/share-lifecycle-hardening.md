# 共享与后台生命周期加固

本轮仅修改 Core、Shared、BroadcastExtension 非 UI 实现及独立验证/本文档；不修改 Socket.IO 协议，不连接线上服务。目标是减少已确认竞态，不能保证 iOS 16–27 永不暂停或冻结。

## 修改及依据

- SharedFrameStore 与 ScreenShareStore：每次原子写入都指定 completeFileProtectionUntilFirstUserAuthentication。默认文件保护可能导致锁屏后访问失败；选择首次解锁后可访问而非完全取消数据保护。重启后首次解锁前仍不可用。
- SampleHandler：心跳检查停止标记及写入处于同一 stateLock 临界区；停止先获取同一锁，随后取消计时器和清状态，避免已通过检查的心跳在 reset 后回写。采样不再重复写心跳，独立定时器为唯一周期来源，恢复时可立即补发。
- ScreenShareStore：仅在 frameSeq 增加时更新 lastFrameAt，值来自帧文件修改时间，避免静态画面下每次心跳伪装成新帧。
- SampleHandler：ReplayKit 方向使用 CMGetAttachment 从 sampleBuffer 读取，替代 sample attachments array，以匹配 RPVideoSampleOrientationKey 的缓冲区附件位置。
- InAppScreenCapturer：重复启动幂等；不再对共享的 RPScreenRecorder 单例先异步 stop 随即 start，也不停止其他正在占用单例的录屏。启动时捕获 epoch，两类启动回调拒绝停止后及旧轮次事件。增加停止进行态，停止完成前不启动下一轮；失败时实际调用 stopCapture，避免仅改 running 留下录屏资源。
- RealRTCClient：后台、前台、音频中断结束、媒体服务重置事件进入 actor 后再次检查 isJoined，阻止已经离会但仍排队的通知重新激活音频或申请后台任务。
- PeerSession：保留显式 sendOnly transceiver 和 screen stream ID。共享 SDP 判定统一按 screenTransceiver.mid 定位本地/远端同一段，本地还需 screen msid；正确继承会话级 direction、默认 sendrecv，并拒绝 port=0（含 0/数量）。修复曾可能把其他 screen 段当作当前轨、把拒绝段误判可发送的问题。

未新增连接重建、自旋重试或信令消息。现有 offer 原样重投上限 3 次，未扩大恢复策略。

## 离线验证

运行 python3 ios/scripts/verify-share-lifecycle.py：2 个测试通过。包括 SDP 参考逻辑的缺省/继承/覆盖方向、MID 不匹配或为空、拒绝端口、多视频段案例，以及 Swift 源码关键约束检查。Python 是参考模型，不能替代 Swift 代码执行。

运行 bash ios/scripts/verify-project.sh：33 PASS、3 FAIL。两个 FAIL 是脚本仅匹配 static let 常量，不能识别现有 AppGroupConfig 的计算属性；第三个 FAIL 是当前 iSH /dev/fd process substitution 不可用，导致脚本未枚举 Swift 文件。未改该原有脚本，未将它报告成通过。环境没有 swift/swiftc/Xcode，未进行 Swift 语法、类型、链接或签名验证。

## 仍需验证和边界

- iOS 后台任务时长由系统决定，不能保证 30 秒，更不能靠 DispatchSourceTimer 让已挂起进程继续执行。实际持续后台媒体依赖系统授权、有效音频会话及系统调度；锁屏、低电量、热降频、来电、用户强杀都可能中断。
- iOS 27 的 ScreenCaptureKit 动态类/选择子/IMP 签名、框架存在性和行为未在真实 SDK/设备验证，现有注释不是平台证据。in-app ReplayKit 仅共享本 App，不能代替跨 App 共享。
- 本轮读取了修改点完整方法、共享存储及调用上下文，但没有完成所有大型 Core 文件的逐行全量审计。SCK 采样队列与 teardown 共享缓存/属性、in-app 回调检查之后与 stop 的小窗口、ScreenFramePusher 游标跨线程重置等仍需后续并发审计和真机压力测试，不能宣称并发问题全部消除。
- 显式 sendOnly screen m-line 只能表达本端发送；对端先发 offer 且没有对应媒体段时，answer 不能新增段，需要现有 stable 后补 offer 路径。当前实现有挂起协商标记与重投上限，但 glare、rollback 与旧异步 offer 完成的交错仍需双端实际验证。
- 现有媒体统计可能合并多个 peer，不是每个远端都已收到画面的证明。

真机矩阵：iOS 16、17、18、26 及可获取的 27 设备；每组做共享后跨 App 15/60 分钟、静态文档 5 分钟再滚动、锁屏/解锁、横竖屏、来电/闹钟中断、断网恢复、重复开始/停止 30 次、离会同时切后台、双方同时共享。记录 extension frameSeq/heartbeat、App pushed、每个 peer MID/direction/ICE/signaling、outbound framesEncoded/packets、接收端实际画面时间及内存。验收包含无 m-line 持续增长、无协商/重建风暴、停止后文件不重新生成、离会后音频不复活。必须区分静态画面自然无新帧与采集/编码真正停滞。
