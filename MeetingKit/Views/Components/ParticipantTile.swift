//
//  ParticipantTile.swift
//  MeetingKit
//
//  一个参会者的画面格子：宫格、演讲者模式的缩略图条、主画面都用它。
//
//  画面两级渲染：
//    - `videoView` 有值（真实链路的 RTCMTLVideoView / RTCCameraPreviewView）→ 渲染真视频；
//    - 否则用 `UserVideoBackdrop` 占位（Mock 或摄像头关闭时）。
//

import SwiftUI
import UIKit

struct ParticipantTile: View {

    let user: MeetingUser

    /// 真实视频渲染视图（远端 RTCMTLVideoView / 本地 RTCCameraPreviewView）。
    /// nil 时回退 UserVideoBackdrop 占位。
    var videoView: UIView? = nil

    var cornerRadius: CGFloat = Theme.Metrics.tileRadius

    /// 当前发言人：2pt 蓝边 + 外发光。
    var isActiveSpeaker: Bool = false

    /// 常态描边（玻璃描边）。缩略图条里由外层自己画更细的边，可关掉。
    var showsBorder: Bool = true

    /// 共享者角标。屏幕共享时该用户的格子左上角出现绿色"共享中"。
    var showsSharingBadge: Bool = false

    /// 说话高亮色。设计稿指定 #007FFF，比全局 accent 更冷、更"视频"。
    var speakerHighlight: Color = Color(hex: 0x007FFF)

    var body: some View {
        ZStack(alignment: .topLeading) {
            videoLayer

            if showsSharingBadge {
                sharingBadge
                    .padding(6)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomInfoBar
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(borderOverlay)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayName)
        .accessibilityValue("\(user.isMicOn ? "麦克风已开启" : "已静音")，\(user.isCameraOn ? "摄像头已开启" : "摄像头已关闭")\(isActiveSpeaker ? "，正在发言" : "")\(user.isHandRaised ? "，已举手" : "")\(showsSharingBadge ? "，正在共享" : "")")
        .shadow(
            color: isActiveSpeaker ? speakerHighlight.opacity(0.18) : Color.clear,
            radius: isActiveSpeaker ? 4 : 0,
            x: 0,
            y: 0
        )
    }

    // MARK: - 画面层

    @ViewBuilder
    private var videoLayer: some View {
        if let videoView = videoView {
            // 黑底 + 等比：竖屏画面放进横向格子时两侧是纯黑，而不是把画面裁掉。
            ZStack {
                Color.black
                // 本机前置摄像头画面镜像，符合"照镜子"直觉。
                RemoteVideoViewRepresentable(view: videoView)
                    .rotation3DEffect(
                        .degrees(user.isLocal ? 180 : 0),
                        axis: (x: 0, y: 1, z: 0)
                    )
            }
        } else {
            UserVideoBackdrop(user: user)
        }
    }

    // MARK: - 共享角标

    private var sharingBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Theme.Palette.success)
                .frame(width: 5, height: 5)

            Text("共享中")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().stroke(Theme.Palette.success.opacity(0.45), lineWidth: 1))
    }

    // MARK: - 底部信息条

    private var bottomInfoBar: some View {
        HStack(spacing: 4) {
            if user.isHandRaised {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Palette.accent)
            }

            Text(displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if !user.isMicOn {
                Image(systemName: SymbolCompat.name("mic.slash.fill", "mic.slash"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.Palette.danger)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 5)
        .padding(.top, 16)
        // 从透明渐变到黑 0.6：浅色画面上文字也能读，同时不遮住主体。
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var displayName: String {
        user.isLocal ? "\(user.name)（我）" : user.name
    }

    // MARK: - 描边

    @ViewBuilder
    private var borderOverlay: some View {
        if isActiveSpeaker {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(speakerHighlight, lineWidth: 2)
        } else if showsBorder {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Theme.Palette.glassStroke, lineWidth: 1)
        }
    }
}

// MARK: - 画面占位

/// 参会者画面的"假视频"占位。真实视频视图缺失（Mock / 摄像头关闭）时使用。
struct UserVideoBackdrop: View {

    let user: MeetingUser

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                if user.isCameraOn {
                    Rectangle()
                        .fill(Theme.videoGradient(index: user.avatarColorIndex))

                    // 左上角一抹柔光，模拟人物被主光打亮的那一侧。
                    RadialGradient(
                        colors: [Color.white.opacity(0.10), Color.clear],
                        center: UnitPoint(x: 0.32, y: 0.18),
                        startRadius: 2,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.85
                    )
                } else {
                    Theme.Palette.tileBackground

                    RadialGradient(
                        colors: [Color.white.opacity(0.05), Color.clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.62
                    )

                    AvatarView(
                        user: user,
                        size: max(28, side * 0.42),
                        showsSpeakingRing: true
                    )
                    .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - 真实视频桥接

/// 把 UIKit 的 WebRTC 渲染视图（RTCMTLVideoView / RTCCameraPreviewView）
/// 桥接进 SwiftUI。视频帧由 WebRTC 内部直接写 GPU 纹理，不经 SwiftUI 重绘，
/// 性能与原生渲染一致。
struct RemoteVideoViewRepresentable: UIViewRepresentable {

    let view: UIView

    func makeUIView(context: Context) -> UIView {
        view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 视图由 RTC 层持有并更新，SwiftUI 只负责把它挂进布局树。
    }
}

struct ParticipantTile_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            HStack(spacing: 8) {
                ParticipantTile(user: MeetingUser(
                    id: "1",
                    name: "陈思远",
                    role: .coHost,
                    isMicOn: true,
                    isCameraOn: true,
                    isHandRaised: false,
                    isSpeaking: true,
                    isLocal: false,
                    avatarColorIndex: 1
                ), isActiveSpeaker: true)
                .frame(width: 140, height: 186)

                ParticipantTile(user: MeetingUser(
                    id: "2",
                    name: "林悦",
                    role: .participant,
                    isMicOn: false,
                    isCameraOn: false,
                    isHandRaised: true,
                    isSpeaking: false,
                    isLocal: false,
                    avatarColorIndex: 2
                ))
                .frame(width: 140, height: 186)
            }
        }
        .preferredColorScheme(.dark)
    }
}
