import AppKit
import SwiftUI

// MARK: - 迷你计算器（递归下降解析，支持 + - * / % ^ 括号和全角符号）

enum MathParser {
    private struct Parser {
        let chars: [Character]
        var pos = 0

        mutating func parseExpression() -> Double? {
            guard var left = parseTerm() else { return nil }
            while let op = peekOp("+-") {
                advance()
                guard let right = parseTerm() else { return nil }
                if op == "+" { left += right } else { left -= right }
            }
            return left
        }

        mutating func parseTerm() -> Double? {
            guard var left = parseFactor() else { return nil }
            while let op = peekOp("*/%") {
                advance()
                guard let right = parseFactor() else { return nil }
                switch op {
                case "*": left *= right
                case "/":
                    guard right != 0 else { return nil }
                    left /= right
                default:
                    guard right != 0 else { return nil }
                    left = left.truncatingRemainder(dividingBy: right)
                }
            }
            return left
        }

        mutating func parseFactor() -> Double? {
            let base = parseUnary()
            guard let b = base else { return nil }
            if peekOp("^") != nil {
                advance()
                guard let exp = parseFactor() else { return nil } // 右结合
                return pow(b, exp)
            }
            return b
        }

        mutating func parseUnary() -> Double? {
            if peekOp("-") != nil {
                advance()
                return parseUnary().map { -$0 }
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Double? {
            if peekOp("(") != nil {
                advance()
                guard let value = parseExpression() else { return nil }
                guard peekOp(")") != nil else { return nil }
                advance()
                return value
            }
            var text = ""
            while let c = current, c.isNumber || c == "." {
                text.append(c)
                advance()
            }
            guard !text.isEmpty, text != ".", let value = Double(text) else { return nil }
            return value
        }

        private var current: Character? { pos < chars.count ? chars[pos] : nil }

        private func peekOp(_ set: String) -> Character? {
            guard let c = current, set.contains(c) else { return nil }
            return c
        }

        private mutating func advance() { pos += 1 }
    }

    /// 纯数字/文字不打扰，只有包含运算符才尝试求值
    static func evaluate(_ raw: String) -> Double? {
        let map: [Character: Character] = ["×": "*", "÷": "/", "＋": "+", "－": "-",
                                           "（": "(", "）": ")", "，": ".", "。": "."]
        let chars = raw.map { map[$0] ?? $0 }.filter { !$0.isWhitespace }
        guard chars.contains(where: { $0.isNumber }),
              chars.contains(where: { "+-*/%^()".contains($0) })
        else { return nil }
        var parser = Parser(chars: chars)
        guard let value = parser.parseExpression(),
              parser.pos == chars.count,
              value.isFinite
        else { return nil }
        return value
    }

    static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.6g", value)
    }
}

// MARK: - 农历

enum LunarDate {
    private static let monthNames = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    private static let dayNames = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]

    static func string(from date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .chinese)
        let comps = calendar.dateComponents([.month, .day], from: date)
        guard let month = comps.month, let day = comps.day,
              month >= 1, month <= 12, day >= 1, day <= 30
        else { return "" }
        let leap = (comps.isLeapMonth == true) ? "闰" : ""
        return leap + monthNames[month - 1] + "月" + dayNames[day - 1]
    }
}

// MARK: - 搜索逻辑（面板项 + 已安装 App + 算式）

enum SearchEngine {
    static func shortcutMatches(_ store: ShortcutStore, _ query: String) -> [ShortcutItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return store.items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    static func appMatches(_ apps: [InstalledApp], _ store: ShortcutStore, _ query: String) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Array(apps.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                && !store.appItems.contains(where: { $0.path == $0.path })
        }.prefix(6))
    }
}

// MARK: - 搜索结果界面

struct SearchResultsView: View {
    @ObservedObject var store: ShortcutStore
    let query: String
    let allApps: [InstalledApp]
    let onFinish: () -> Void

    private var mathResult: Double? { MathParser.evaluate(query) }
    private var shortcutMatches: [ShortcutItem] { SearchEngine.shortcutMatches(store, query) }
    private var appMatches: [InstalledApp] { SearchEngine.appMatches(allApps, store, query) }

    private var hasAnyResult: Bool {
        mathResult != nil || !shortcutMatches.isEmpty || !appMatches.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let mathResult {
                    MathResultRow(value: mathResult)
                }
                ForEach(shortcutMatches.prefix(5)) { item in
                    SearchRow(title: item.title, detail: kindDetail(item), icon: { ShortcutRowIcon(item: item) }) {
                        store.performShortcut(item)
                        onFinish()
                    }
                }
                ForEach(appMatches) { app in
                    SearchRow(title: app.name, detail: "已安装 · 点击打开", icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable().frame(width: 20, height: 20)
                    }, action: {
                        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
                        onFinish()
                    }, trailing: {
                        Button {
                            store.addApp(name: app.name, path: app.path)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("加入面板")
                    })
                }
                if !hasAnyResult {
                    Text("没有匹配「\(query)」的结果")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 320)
    }

    private func kindDetail(_ item: ShortcutItem) -> String {
        switch item.kind {
        case .app: return "面板 App"
        case .action: return "系统功能"
        case .url: return item.urlString ?? "网址"
        case .folder: return item.path ?? "文件夹"
        }
    }
}

private struct MathResultRow: View {
    let value: Double
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "equal.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.orange)
            Text(MathParser.formatNumber(value))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Spacer()
            Text(copied ? "已复制" : "回车复制")
                .font(.system(size: 10))
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(MathParser.formatNumber(value), forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
    }
}

private struct SearchRow<Icon: View, Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let icon: Icon
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    init(title: String, detail: String,
         @ViewBuilder icon: () -> Icon,
         action: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.icon = icon()
        self.action = action
        self.trailing = trailing()
    }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12)).lineLimit(1)
                Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

struct ShortcutRowIcon: View {
    let item: ShortcutItem

    var body: some View {
        switch item.kind {
        case .app:
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path ?? "/"))
                .resizable().frame(width: 20, height: 20)
        case .action:
            Image(systemName: SystemActions.action(item.actionID ?? "")?.symbol ?? "gearshape")
                .font(.system(size: 12))
        case .url:
            Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(Color.blue)
        case .folder:
            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Color.yellow)
        }
    }
}
