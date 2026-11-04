//
//  AvatarView.swift
//  MeetingKit
//
//  头像。摄像头关闭的参会者、参会人列表、聊天里的发送者都用它，
//  保证同一个人的配色在任何位置一致（颜色索引来自模型，不在这里随机）。
//

import Foundation
import SwiftUI

struct AvatarView: View {

    let user: MeetingUser

    /// 直径。列表里 40，宫格里由上层按格子尺寸算，主画面里会更大。
    var size: CGFloat = 40

    /// 说话脉冲环。列表里为了不干扰阅读可以关掉。
    var showsSpeakingRing: Bool = true

    /// 脉冲动画需要一个可动画的标量，`user.isSpeaking` 本身只能触发，不能驱动循环。
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.avatarGradient(index: user.avatarColorIndex))

            Text(user.initials)
                .font(.system(size: max(9, size * 0.34), weight: .semibold))
                .foregroundColor(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, size * 0.16)
        }
        .frame(width: size, height: size)
        .overlay(ring)
        .onAppear {
            // 延后一帧再启动，否则 repeatForever 动画会因为"首帧还没有渲染"而不生效。
            DispatchQueue.main.async {
                isPulsing = user.isSpeaking
            }
        }
        .onChange(of: user.isSpeaking) { speaking in
            isPulsing = speaking
        }
    }

    // MARK: - 脉冲环

    private var ring: some View {
        Circle()
            .stroke(Theme.Palette.accent, lineWidth: 2)
            .scaleEffect(isPulsing ? 1.08 : 1.0)
            .opacity(ringOpacity)
            .animationCompat(ringAnimation, value: isPulsing)
    }

    private var ringOpacity: Double {
        guard showsSpeakingRing, user.isSpeaking else { return 0 }
        // 呼吸到最大时淡一些，避免"看起来像边框在闪"。
        return isPulsing ? 0.45 : 1.0
    }

    private var ringAnimation: Animation {
        guard showsSpeakingRing, user.isSpeaking else { return Theme.Motion.standard }
        return Theme.Motion.breathing
    }
}

struct AvatarView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.background
            HStack(spacing: 16) {
                AvatarView(user: MeetingUser(
                    id: "1",
                    name: "陈思远",
                    role: .coHost,
                    isMicOn: true,
                    isCameraOn: false,
                    isHandRaised: false,
                    isSpeaking: true,
                    isLocal: false,
                    avatarColorIndex: 1
                ), size: 64)
                AvatarView(user: MeetingUser(
                    id: "2",
                    name: "Alex Chen",
                    role: .participant,
                    isMicOn: false,
                    isCameraOn: false,
                    isHandRaised: false,
                    isSpeaking: false,
                    isLocal: false,
                    avatarColorIndex: 3
                ), size: 64)
            }
        }
        .preferredColorScheme(.dark)
    }
}
