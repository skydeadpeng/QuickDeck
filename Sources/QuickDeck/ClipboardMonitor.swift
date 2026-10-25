import AppKit
import Combine
import SwiftUI

struct ClipboardItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date

    var preview: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.count > 42 ? String(first.prefix(42)) + "…" : first
    }
}

/// 轮询系统剪贴板，自动收集复制过的文本（仅内存保存，退出即清空，不落盘）
final class ClipboardMonitor: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: VisibilityAwareTimer?
    static let maxItems = 50

    init() {
        timer = VisibilityAwareTimer(interval: 0.6) { [weak self] in
            self?.poll()
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        insert(text)
    }

    private func insert(_ text: String) {
        // 相同内容移到最前，避免重复堆积
        items.removeAll { $0.text == text }
        items.insert(ClipboardItem(text: text, date: Date()), at: 0)
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
    }

    /// 点击复制回剪贴板（自己写入的不再重复记录）
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        insert(item.text)
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        items.removeAll()
    }
}

// MARK: - 面板上的精简剪贴板区（最近 4 条）

struct ClipboardSection: View {
    @ObservedObject var monitor: ClipboardMonitor
    @State private var copiedID: UUID?
    @AppStorage("deck.clipboard.rows") private var visibleRows = 4

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text("剪贴板").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    WindowManager.presentClipboardHistory(monitor: monitor)
                } label: {
                    Text("全部 \(monitor.items.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(monitor.items.isEmpty)
                Button {
                    monitor.clearAll()
                } label: {
                    Text("清空").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(monitor.items.isEmpty)
            }
            ForEach(Array(monitor.items.prefix(max(1, visibleRows)))) { item in
                ClipboardRow(item: item, copied: copiedID == item.id) {
                    monitor.copy(item)
                    copiedID = item.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if copiedID == item.id { copiedID = nil }
                    }
                } onDelete: {
                    monitor.remove(item)
                }
            }
            if monitor.items.isEmpty {
                Text("复制过的内容会自动出现在这里")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }
        }
    }
}

struct ClipboardRow: View {
    let item: ClipboardItem
    let copied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copied ? Color.green : Color.secondary)
            Text(item.preview)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(hovering ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .contextMenu {
            Button("复制") { onCopy() }
            Button("删除") { onDelete() }
        }
        .help(item.text)
    }
}

// MARK: - 全部历史窗口

struct ClipboardHistoryView: View {
    @ObservedObject var monitor: ClipboardMonitor
    @State private var copiedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("共 \(monitor.items.count) 条 · 仅本次登录期间保留，退出自动清空")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部清空") { monitor.clearAll() }
                    .disabled(monitor.items.isEmpty)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(monitor.items) { item in
                        ClipboardHistoryRow(item: item, copied: copiedID == item.id) {
                            monitor.copy(item)
                            copiedID = item.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                if copiedID == item.id { copiedID = nil }
                            }
                        } onDelete: {
                            monitor.remove(item)
                        }
                    }
                    if monitor.items.isEmpty {
                        Text("暂无记录，随便复制点什么试试")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding(10)
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }
}

struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let copied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.timeFormatter.string(from: item.date))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if hovering {
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
    }
}
