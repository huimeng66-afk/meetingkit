//
//  Enums.swift
//  MeetingKit
//
//  与具体页面无关的展示层枚举。
//

import Foundation

/// 会议画面布局。
/// speaker：一人独占大画面 + 他人小窗（适合有明确发言人时）；
/// grid：等分宫格（适合讨论型会议）。
enum LayoutMode {
    case speaker
    case grid

    /// 切换后的另一个布局。把它做成属性而不是在视图里写 if/else，
    /// 是为了让"当前布局"只有一处定义，新增布局时不会漏改某处 toggle 逻辑。
    var toggled: LayoutMode {
        switch self {
        case .speaker:
            return .grid
        case .grid:
            return .speaker
        }
    }
}
