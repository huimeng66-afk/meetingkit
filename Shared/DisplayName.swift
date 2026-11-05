//
//  DisplayName.swift
//  Shared
//
//  昵称兜底。存在的唯一原因：服务端、历史数据、重签后的老包都可能把
//  “空值”以一种**看起来像文本**的形式送到界面上——
//    · JSON null 被某层序列化成字符串 "null"
//    · JS 模板字符串把 undefined 拼成 "undefined"
//    · Objective-C 的 NSNull.description 是 "<null>"
//  这些字符串会原样出现在“\(name) 正在共享屏幕”里，用户看到的就是
//  “null 正在共享屏幕”，像极了程序崩溃。所有进入 UI 的名字都必须过这里。
//

import Foundation

enum DisplayName {

    /// 占位串（小写比较）。命中就认为“这个名字没有意义”。
    private static let placeholders: Set<String> = [
        "null", "nil", "undefined", "nan",
        "(null)", "<null>", "optional(\"null\")",
    ]

    /// 清洗一个可能为空的昵称；无法使用时返回空串，由调用方给业务兜底文案。
    static func clean(_ raw: String?) -> String {
        guard let raw = raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if placeholders.contains(trimmed.lowercased()) { return "" }
        return trimmed
    }

    /// 带业务兜底的名字：清洗后仍为空就用 `fallback`。
    static func clean(_ raw: String?, fallback: String) -> String {
        let value = clean(raw)
        return value.isEmpty ? fallback : value
    }
}
