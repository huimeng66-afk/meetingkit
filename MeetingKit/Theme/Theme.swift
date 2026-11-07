//
//  Theme.swift
//  MeetingKit
//
//  设计令牌（颜色 / 圆角 / 间距 / 字号 / 头像调色板）。
//
//  为什么集中一处：会议界面里同一个"红"会同时出现在警示条、麦克风关闭按钮、
//  结束会议文字上，任何一处手写 hex 都会在后续调色时漏改。所有视图只允许读 Theme，
//  不允许自己写 Color(hex:)，这样换肤（例如白天版）时只需要改这一个文件。
//
//  首页与网页端（public/assets/css/base.css）同源：浅灰页面 #f4f5f7、
//  白色卡片 #ffffff、主蓝 #1677ff。属性名一个都不改，只换值——
//  会议室 20 多个视图都在读这些名字，换肤只能换值，不能换 API。
//

import SwiftUI
import UIKit

// MARK: - 主题

enum Theme {

    // MARK: 色板

    enum Palette {

        // 天穹令牌（docs/design-tianqiong.md 第 1 节）。属性名一个都不能删：
        // 会议室 20 多个视图都在读这些名字，换肤只能换值，不能换 API。

        /// 页面底色。与网页端 `--bg` 同一个值，保证两端截图能对上。
        static let background = Color.adaptive(light: 0xF4F5F7, dark: 0x0D1420)
        /// 面板 / 卡片的抬高底。浅色下"抬高"是变白，不是变亮。
        static let backgroundElevated = Color.adaptive(light: 0xFFFFFF, dark: 0x192332)

        static let textPrimary = Color.adaptive(light: 0x191C21, dark: 0xF3F6FC)
        static let textSecondary = Color.adaptive(light: 0x545B66, dark: 0xBBC6D6)
        /// 三级文字（会议号、时间戳）。
        /// 网页端这一档是 --ink-400 #8d95a1，压在 #ffffff 上是 3.4:1，
        /// 只够大字；正文位置一律用 secondary，这一档只给角标和占位符。
        static let textTertiary = Color.adaptive(light: 0x8D95A1, dark: 0x8796AB)

        /// 一级文字的语义别名，首页等新页面按设计稿用 ink 命名。
        static let ink = Color.adaptive(light: 0x191C21, dark: 0xF3F6FC)
        static let ink2 = Color.adaptive(light: 0x545B66, dark: 0xBBC6D6)
        static let ink3 = Color.adaptive(light: 0x8D95A1, dark: 0x8796AB)

        /// 强调蓝。对齐网页端 --blue-600 #1677ff（按钮/链接的主色）。
        static let accent = Color.adaptive(light: 0x1677FF, dark: 0x69A7FF)
        /// 辅助青。加入会议、共享角标。
        static let accent2 = Color.adaptive(light: 0x0EA5E9, dark: 0x62CAF2)
        /// 渐变第二色、联席主持人。网页端 --violet #6e56cf。
        static let violet = Color(hex: 0x6E56CF)
        /// 品牌渐变 #3B82F6 → #7C3AED。
        static let brandGradient = LinearGradient(
            gradient: Gradient(colors: [Color(hex: 0x3B82F6), Color(hex: 0x7C3AED)]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// 危险红。共享警示条、麦克风/摄像头关闭、结束会议。
        static let danger = Color.adaptive(light: 0xE5484D, dark: 0xFF747D)
        static let success = Color.adaptive(light: 0x12A150, dark: 0x50D49A)
        static let warning = Color.adaptive(light: 0xC77405, dark: 0xF1BA61)
        static let coHost = Color(hex: 0x6E56CF)

        /// 玻璃描边。浅色底上玻璃靠"压暗的边缘"成形，白描边会完全看不见。
        static let glassStroke = Color.adaptive(light: 0xDCE2EA, dark: 0x3B4A5F)
        /// 玻璃底色。浅色下要把内容提亮而不是压暗，所以是白色而不是黑色。
        static let glassTint = Color.adaptive(light: 0xFFFFFF, dark: 0x192332).opacity(0.86)
        /// 不透明实色底。玻璃被关掉（低端机 / 录屏降负载）或用户开了
        /// "降低透明度"时用它，必须完全不透明：半透明实色会和下面的内容混成一块脏色。
        static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x192332)
        /// 浅色模式下的实色底（页面级）。与 surface 的区别：surface 是卡片，
        /// 这个是贴在页面底色上的整块区域。
        static let surfaceLight = Color.adaptive(light: 0xF9FAFB, dark: 0x111B29)
        /// 控件常态底（底栏圆钮、面板内按钮）。网页端浅灰块 #f4f5f7。
        static let controlFill = Color.adaptive(light: 0xF4F5F7, dark: 0x263345)
        /// 面板内浅色块（说明卡、输入框、他人气泡）。
        static let surfaceSubtle = Color.adaptive(light: 0xF4F5F7, dark: 0x202D3E)
        static let bubbleOther = Color.adaptive(light: 0xEEF0F3, dark: 0x263345)
        /// 摄像头关闭时的画面底。浅灰，和白色卡片拉开一档。
        static let tileBackground = Color.adaptive(light: 0xEEF0F3, dark: 0x1B2738)
        /// 分割线。网页端 --line #e7e9ed。
        static let hairline = Color.adaptive(light: 0xE7E9ED, dark: 0x334155)

        /// 彩色底（accent / danger / 头像渐变）上的文字色。
        /// 浅色主题下"白色文字"只剩这一个合法用途，不要再手写 .white。
        static let onAccent = Color.white
    }

    // MARK: 圆角

    enum Metrics {
        /// 宫格 / 缩略图
        static let tileRadius: CGFloat = 14
        /// 本地小窗、共享角标
        static let smallRadius: CGFloat = 12
        /// 卡片（说明卡、头像卡）
        static let cardRadius: CGFloat = 16
        /// 底部抽屉
        static let panelRadius: CGFloat = 28
        /// 底栏玻璃条
        static let controlBarRadius: CGFloat = 26
        /// 主按钮
        static let buttonRadius: CGFloat = 14

        /// 页面水平边距，全项目唯一的横向基准。
        static let horizontal: CGFloat = 16

        // 间距全部取 4 的倍数，避免出现 6/10/15 这类无法对齐的数值。
        static let space1: CGFloat = 4
        static let space2: CGFloat = 8
        static let space3: CGFloat = 12
        static let space4: CGFloat = 16
        static let space5: CGFloat = 20
        static let space6: CGFloat = 24

        /// 底栏圆钮直径。
        static let controlSize: CGFloat = 56
        /// 顶栏状态按钮直径。
        static let statusButtonSize: CGFloat = 44
        /// 参会人列表行高。
        static let rowHeight: CGFloat = 56
    }

    // MARK: 字号

    enum Typography {
        /// 面板标题、主按钮
        static let sectionTitle = Font.headline
        /// 顶栏会议标题
        static let title = Font.system(.subheadline, design: .default).weight(.semibold)
        /// 正文
        static let body = Font.subheadline
        /// 次级正文
        static let bodySmall = Font.footnote
        /// 胶囊按钮 / 播放控制
        static let control = Font.system(.footnote, design: .default).weight(.medium)
        /// 说明文字
        static let caption = Font.caption
        /// 底栏按钮标签、头像角标
        static let label = Font.system(.caption2, design: .default).weight(.medium)
        /// 时间戳、极小的辅助信息
        static let micro = Font.caption2
    }

    // MARK: 动效

    enum Motion {
        /// 全项目统一的一档弹性动画。交互反馈都用它，避免出现 0.2s easeInOut 那种廉价感。
        static var standard: Animation { GlassMotion.isReduceMotion ? .linear(duration: 0.01) : Animation.spring(response: 0.30, dampingFraction: 0.92) }

        /// 抽屉 / 侧边栏 / 整页位移。行程比普通控件长，必须给更长的响应时间，
        /// 否则 320pt 的位移会在 0.2s 内"弹"完，看起来像被甩出去而不是被拉开。
        static var sheet: Animation { GlassMotion.isReduceMotion ? .linear(duration: 0.01) : Animation.spring(response: 0.38, dampingFraction: 0.94) }

        /// 小面积、需要紧跟手指的反馈（选中、切换）。比 standard 快一档。
        static var snappy: Animation { GlassMotion.isReduceMotion ? .linear(duration: 0.01) : Animation.easeOut(duration: 0.16) }

        /// 呼吸 / 脉冲这类需要无限循环的动画必须是线性往复，
        /// 弹簧动画无法形成稳定的呼吸节奏，这里是有意的例外。
        static var breathing: Animation { GlassMotion.isReduceMotion ? .linear(duration: 0.01) : Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true) }

        /// 三点加载动画的单点节奏（配合 delay 形成波浪）。
        static var blink: Animation { GlassMotion.isReduceMotion ? .linear(duration: 0.01) : Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true) }
    }

    // MARK: 头像调色板

    /// 8 组低饱和渐变。索引由 `MeetingUser.avatarColorIndex` 决定，
    /// 同一用户在任何列表里的头像颜色必须一致，所以取色只允许走 `avatarGradient(index:)`。
    private static let avatarPalette: [(Color, Color)] = [
        (Color(hex: 0x7C8CFF), Color(hex: 0x3B2FB0)),  // 0 蓝紫
        (Color(hex: 0x35C6A8), Color(hex: 0x11705F)),  // 1 青绿
        (Color(hex: 0xFFA27A), Color(hex: 0xC4466F)),  // 2 橙粉
        (Color(hex: 0x6E9BFF), Color(hex: 0x274B9F)),  // 3 靛蓝
        (Color(hex: 0xB67CFF), Color(hex: 0x6B31B8)),  // 4 紫罗兰
        (Color(hex: 0xFFC46B), Color(hex: 0xB9761F)),  // 5 琥珀
        (Color(hex: 0x54D0E0), Color(hex: 0x14708C)),  // 6 青蓝
        (Color(hex: 0xFF86A6), Color(hex: 0xA83355))   // 7 玫红
    ]

    /// 摄像头画面占位（本项目没有真实视频帧）。
    /// 用深蓝灰渐变模拟暗光下的镜头，比纯灰更有"视频"质感。
    private static let videoPalette: [(Color, Color)] = [
        (Color(hex: 0x2A3350), Color(hex: 0x0E1118)),
        (Color(hex: 0x1D3B36), Color(hex: 0x0D1513)),
        (Color(hex: 0x3A2A2E), Color(hex: 0x120F11)),
        (Color(hex: 0x24304A), Color(hex: 0x0E1119)),
        (Color(hex: 0x322846), Color(hex: 0x110E15)),
        (Color(hex: 0x3A3220), Color(hex: 0x12100C)),
        (Color(hex: 0x1C3540), Color(hex: 0x0C1216)),
        (Color(hex: 0x38222C), Color(hex: 0x130E11))
    ]

    static func avatarGradient(index: Int) -> LinearGradient {
        let pair = avatarPalette[normalizedIndex(index, count: avatarPalette.count)]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func videoGradient(index: Int) -> LinearGradient {
        let pair = videoPalette[normalizedIndex(index, count: videoPalette.count)]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 负索引与越界索引都收敛到合法区间：模型层随时可能换数据源，
    /// 让 UI 因为 `-1` 而 crash 是不划算的。
    private static func normalizedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }
}

// MARK: - 十六进制颜色

extension Color {

    /// Resolve in the local SwiftUI color scheme; the meeting subtree is dark,
    /// while account, enterprise and join forms remain light.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func uiColor(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        let lightColor = uiColor(light)
        let darkColor = uiColor(dark)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }


    /// 用 0xRRGGBB 直接构造颜色。
    ///
    /// 为什么不走 `UIColor(red:green:blue:)`：那条链要除以 255、构造 UIColor、
    /// 再桥接回 Color，读起来噪音大且在 Preview 里偶发色差；这里一次算完最省事。
    init(hex: UInt32) {
        let red = Double((hex & 0xFF0000) >> 16) / 255.0
        let green = Double((hex & 0x00FF00) >> 8) / 255.0
        let blue = Double(hex & 0x0000FF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}
