import SwiftUI

// MARK: - Menu bar (slim — Typeless density)

struct MenuPanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                NexVoiceMark(size: 32, active: model.isEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NexVoice")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(NV.ink)
                    Text(statusLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NV.secondary)
                }
                Spacer(minLength: 0)
            }

            if !model.permissionsReady {
                VStack(alignment: .leading, spacing: 10) {
                    Text("完成設定即可聽寫")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(NV.ink)
                    permissionMini(title: "麥克風", ok: model.microphoneGranted)
                    permissionMini(title: "輔助使用", ok: model.accessibilityGranted)
                    Button("繼續設定") {
                        model.reopenOnboarding()
                        openWindow(id: "onboarding")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(NVPrimaryButton())
                }
                .nvCard()
            } else {
                VStack(spacing: 8) {
                    if model.isEnabled {
                        Button("停用 NexVoice") { model.disableNexVoice() }
                            .buttonStyle(NVSecondaryButton())
                            .frame(maxWidth: .infinity)
                        Button("切到 Typeless") { model.switchToTypeless() }
                            .buttonStyle(NVSecondaryButton())
                            .frame(maxWidth: .infinity)
                        Button("重貼上一筆") { model.repasteLast() }
                            .buttonStyle(NVSecondaryButton())
                            .frame(maxWidth: .infinity)
                            .disabled(model.lastTranscript.isEmpty)
                    } else {
                        Button("使用 NexVoice") { model.switchToNexVoice() }
                            .buttonStyle(NVPrimaryButton())
                            .frame(maxWidth: .infinity)
                        Button("切到 Typeless") { model.switchToTypeless() }
                            .buttonStyle(NVSecondaryButton())
                            .frame(maxWidth: .infinity)
                    }
                }

                Divider().overlay(NV.hairline)

                Button("打開 NexVoice…") {
                    // Focus existing main window; open only if none.
                    if AppDelegate.mainWindows().isEmpty {
                        openWindow(id: "dashboard")
                    } else {
                        AppDelegate.focusExistingUI(
                            openMainIfNeeded: false,
                            openOnboardingIfNeeded: false
                        )
                    }
                }
                .buttonStyle(NVSecondaryButton())
                .frame(maxWidth: .infinity)

                Button("結束") { NSApp.terminate(nil) }
                    .buttonStyle(NVSecondaryButton())
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(NV.bg)
        .preferredColorScheme(model.productPreferences.appTheme.colorScheme)
    }

    private var statusLine: String {
        if !model.permissionsReady { return "需要完成權限設定" }
        if model.isEnabled { return model.runtimeState.label }
        return "待命 · 可與 Typeless 切換"
    }

    private func permissionMini(title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? NV.ok : NV.warn)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NV.ink)
            Spacer()
            Text(ok ? "已授權" : "未授權")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ok ? NV.ok : NV.warn)
        }
    }
}

// MARK: - Main app shell (Typeless: sidebar + content)

enum AppPage: String, CaseIterable, Identifiable {
    case home = "首頁"
    case history = "歷史紀錄"
    case dictionary = "詞彙"
    case settings = "設定"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "text.book.closed"
        case .settings: "gearshape"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: AppPage = .home

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(page: $page)
                .frame(width: 200)
            Rectangle()
                .fill(NV.hairline)
                .frame(width: 1)
            Group {
                switch page {
                case .home: HomePage()
                case .history: HistoryPage()
                case .dictionary: DictionaryPage()
                case .settings: SettingsPage()
                }
            }
            .id(page)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.14), value: page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NV.bg)
        }
        .frame(minWidth: 880, minHeight: 580)
        .nvTheme(model.productPreferences.appTheme)
        .background(OnboardingPresenter().environmentObject(model))
        .onAppear {
            model.reloadHistory()
            model.reloadVocab()
        }
        .id(model.productPreferences.appTheme)
    }

}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Binding var page: AppPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                NexVoiceMark(size: 34, active: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("NexVoice")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(NV.ink)
                    Text("本機")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NV.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(NV.selected, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 20)

            VStack(spacing: 4) {
                ForEach(AppPage.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) { page = item }
                        if item == .history { model.reloadHistory() }
                        if item == .dictionary { model.reloadVocab() }
                    } label: {
                        let isCurrent = page == item
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isCurrent ? NV.blue : NV.secondary)
                                .frame(width: 18)
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                                .foregroundStyle(isCurrent ? NV.ink : NV.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            isCurrent ? NV.selected : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        // Color.clear draws no pixels, and .buttonStyle(.plain)
                        // otherwise only hit-tests the visible glyphs -- without
                        // this, clicking anywhere except literally on the text/
                        // icon of an unselected tab does nothing.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            if !model.permissionsReady {
                Button {
                    model.reopenOnboarding()
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Image(systemName: "checklist")
                        Text("完成設定引導")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(NV.blue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Text("v0.1 · local-first")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NV.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
        }
        .background(NV.sidebar)
    }
}

// MARK: - Home

private struct HomePage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageTitle("首頁", subtitle: model.isEnabled
                          ? model.hotkeyProfile.userInstruction
                          : "與 Typeless 並存：一次只啟用一個語音工具")

                if !model.permissionsReady {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("尚未完成權限", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(NV.warn)
                        Text("需要麥克風與輔助使用。點下方會開啟引導，並可直接跳到系統設定勾選 NexVoice。")
                            .font(.system(size: 13))
                            .foregroundStyle(NV.secondary)
                        Button("開始設定引導") {
                            model.reopenOnboarding()
                            openWindow(id: "onboarding")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        .buttonStyle(NVPrimaryButton())
                    }
                    .nvCard()
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("語音工具")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(NV.ink)
                        Spacer()
                        statusPill
                    }
                    Text(model.isEnabled
                         ? "NexVoice 已接管 Option。"
                         : "NexVoice 不攔截快捷鍵，可安全使用 Typeless。")
                        .font(.system(size: 13))
                        .foregroundStyle(NV.secondary)

                    HStack(spacing: 10) {
                        if model.isEnabled {
                            Button("停用") { model.disableNexVoice() }
                                .buttonStyle(NVSecondaryButton())
                            Button("切到 Typeless") { model.switchToTypeless() }
                                .buttonStyle(NVSecondaryButton())
                        } else {
                            // Always clickable — action explains what's missing.
                            Button("使用 NexVoice") { model.switchToNexVoice() }
                                .buttonStyle(NVPrimaryButton())
                            Button("切到 Typeless") { model.switchToTypeless() }
                                .buttonStyle(NVSecondaryButton())
                        }
                    }

                    if model.typelessRunning {
                        Label("Typeless 正在執行 — 點「使用 NexVoice」會詢問是否結束它", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(NV.warn)
                    }
                    if !model.accessibilityGranted {
                        Button("打開輔助使用設定") { model.requestAccessibilityAccess() }
                            .buttonStyle(NVSecondaryButton())
                    }
                    if let notice = model.notice, !notice.isEmpty {
                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundStyle(NV.secondary)
                    }
                }
                .nvCard()

                // fixedSize pins the row to the tallest card's intrinsic height
                // so a two-line tip no longer leaves its neighbours short.
                HStack(alignment: .top, spacing: 12) {
                    tipCard(symbol: "mic.fill", title: "聽寫", text: model.hotkeyProfile.userInstruction)
                    tipCard(symbol: "xmark.circle", title: "取消", text: "Esc 或 HUD 上的 ✕")
                    tipCard(symbol: "doc.on.clipboard", title: "重貼", text: "⌥⌘V 重貼上一筆")
                }
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("操作方式", systemImage: "keyboard")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(NV.ink)
                        Spacer()
                        Text(model.hotkeyProfile.bindingName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(NV.blue)
                    }
                    Text(model.hotkeyProfile.behavior == .toggle
                         ? "Toggle：按下開始，再按一下停止"
                         : "Push-to-talk：按住開始，放開立即停止並轉錄")
                        .font(.system(size: 12.5))
                        .foregroundStyle(NV.secondary)
                    Text("可在設定錄製任意按鍵；Option、Command、Control、Fn、Space、Return、Tab 都支援。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(NV.secondary)
                }
                .nvCard()

                if !model.lastTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: "quote.bubble.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(NV.blue)
                                Text("即時轉錄結果")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(NV.ink)
                            }
                            Spacer()
                            Text("最新轉錄")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(NV.blue)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(NV.selected, in: Capsule())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.lastTranscript)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(NV.ink)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(
                            NV.fill,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(NV.hairline, lineWidth: 1)
                        )

                        HStack(spacing: 10) {
                            Button {
                                model.repasteLast()
                            } label: {
                                Label("重新貼上 (⌥⌘V)", systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(NVPrimaryButton())

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.lastTranscript, forType: .string)
                                model.notice = "已複製轉錄文字。"
                            } label: {
                                Label("複製文字", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(NVSecondaryButton())
                        }
                    }
                    .nvCard()
                }
            }
            .padding(28)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isEnabled ? NV.ok : NV.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(model.isEnabled ? "聽寫就緒" : "Typeless 可用")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NV.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(NV.selected, in: Capsule())
    }

    private func tipCard(symbol: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Fixed glyph box: SF Symbols have differing bounding boxes, so
            // without it the three icons sit at three different baselines.
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NV.blue)
                .frame(height: 20, alignment: .center)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(NV.ink)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(NV.secondary)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .nvCard()
    }
}

// MARK: - History (Typeless list + legacy Hammerspoon import)

private struct HistoryPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var editingID: String?
    @State private var draft = ""

    private var filteredHistory: [HistoryEntry] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.history }
        return model.history.filter {
            $0.text.localizedCaseInsensitiveContains(value)
                || $0.route.localizedCaseInsensitiveContains(value)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageTitle(
                    "歷史紀錄",
                    subtitle: "讀取 ~/.cache/nexvoice/local-history.json（含舊版 Hammerspoon 紀錄）。"
                )

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("本機歷史")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(NV.ink)
                            Text("共 \(model.history.count) 筆 · 只存在這台 Mac")
                                .font(.system(size: 12))
                                .foregroundStyle(NV.secondary)
                        }
                        Spacer()
                        TextField("搜尋內容…", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                        Button("重新整理") { model.reloadHistory() }
                            .buttonStyle(NVSecondaryButton())
                    }
                }
                .nvCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text(query.isEmpty ? "最近" : "搜尋結果 · \(filteredHistory.count) 筆")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NV.secondary)

                    if filteredHistory.isEmpty {
                        Text(query.isEmpty ? "還沒有紀錄。啟用 NexVoice 聽寫後會出現在這裡。" : "找不到符合的內容。")
                            .font(.system(size: 13))
                            .foregroundStyle(NV.secondary)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredHistory) { entry in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(formatTime(entry.createdAt))
                                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(NV.secondary)
                                        Text(entry.route)
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(NV.secondary)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(NV.selected, in: Capsule())
                                        Spacer()
                                        historyAction("複製", symbol: "doc.on.doc") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(entry.text, forType: .string)
                                            model.notice = "已複製到剪貼簿。"
                                        }
                                        historyAction("編輯", symbol: "pencil") {
                                            editingID = entry.id; draft = entry.text
                                        }
                                        historyAction("刪除", symbol: "trash", destructive: true) {
                                            model.deleteHistory(id: entry.id)
                                        }
                                    }

                                    if editingID == entry.id {
                                        TextEditor(text: $draft)
                                            .font(.system(size: 13.5))
                                            .frame(minHeight: 86)
                                            .padding(7)
                                            .background(NV.bg, in: RoundedRectangle(cornerRadius: 9))
                                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(NV.hairline))
                                        HStack {
                                            Spacer()
                                            Button("取消") { editingID = nil; draft = "" }
                                                .buttonStyle(NVSecondaryButton())
                                            Button("儲存") {
                                                model.updateHistory(id: entry.id, text: draft)
                                                editingID = nil; draft = ""
                                            }
                                            .buttonStyle(NVPrimaryButton())
                                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        }
                                    } else {
                                        Text(entry.text)
                                            .font(.system(size: 14))
                                            .foregroundStyle(NV.ink)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineSpacing(3)
                                    }
                                }
                                .padding(14)
                                .background(NV.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(NV.hairline))
                            }
                        }
                    }
                }

            }
            .padding(28)
        }
        .onAppear { model.reloadHistory() }
    }

    private func historyAction(
        _ title: String,
        symbol: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(destructive ? Color.red : NV.secondary)
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: iso)
        if date == nil {
            let p2 = ISO8601DateFormatter()
            date = p2.date(from: iso)
        }
        guard let date else { return String(iso.prefix(16)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Dictionary / vocab (gateway :5111)

private struct DictionaryPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var phrase = ""
    @State private var soundsLike = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageTitle(
                    "詞彙",
                    subtitle: "教 NexVoice 正確辨識人名、品牌與專有名詞；會套用到本機 MLX 與最終文字修正。"
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Label("MLX 辨識提示", systemImage: "waveform.badge.mic")
                        Label("轉錄後修正", systemImage: "text.badge.checkmark")
                        Label("離線快取", systemImage: "lock.shield")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NV.secondary)
                    Text("新增單字")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NV.ink)
                    TextField("詞彙（例如 NexVoice）", text: $phrase)
                        .textFieldStyle(.roundedBorder)
                    TextField("聽起來像（可選，逗號分隔）", text: $soundsLike)
                        .textFieldStyle(.roundedBorder)
                    Text("例如：詞彙填 NexVoice，聽起來像填 next voice、nex voice。下一次錄音立即生效。")
                        .font(.system(size: 11))
                        .foregroundStyle(NV.secondary)
                    HStack {
                        Button("新增") {
                            let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !p.isEmpty else { return }
                            model.addVocab(phrase: p, soundsLike: soundsLike)
                            phrase = ""
                            soundsLike = ""
                        }
                        .buttonStyle(NVPrimaryButton())
                        Button("重新整理") { model.reloadVocab() }
                            .buttonStyle(NVSecondaryButton())
                        Spacer()
                        Text("\(model.vocab.count) 詞")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NV.secondary)
                    }
                }
                .nvCard()

                if model.vocab.isEmpty {
                    Text("尚未建立詞彙。新增後會同時改善 MLX 辨識與最終文字；資料服務暫時離線時會沿用最後一份安全快取。")
                        .font(.system(size: 13))
                        .foregroundStyle(NV.secondary)
                        .nvCard()
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(model.vocab) { entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.phrase)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(NV.ink)
                                        .lineLimit(1)
                                    if !entry.soundsLike.isEmpty {
                                        Text(entry.soundsLike)
                                            .font(.system(size: 10))
                                            .foregroundStyle(NV.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button {
                                    model.deleteVocab(id: entry.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(NV.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(NV.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(NV.hairline, lineWidth: 1)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .onAppear { model.reloadVocab() }
    }
}

// MARK: - Settings

/// The settings page carries a dozen distinct concerns. Flat-stacking them
/// made a ~3000pt scroll where nothing was findable; these four groups keep
/// each section to roughly one screen.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "一般"
    case hotkeys = "快捷鍵"
    case appearance = "外觀"
    case engine = "引擎與隱私"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .hotkeys: "keyboard"
        case .appearance: "paintbrush"
        case .engine: "cpu"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "權限、語言與音訊，以及 App 啟動行為。"
        case .hotkeys: "錄音按鍵與三種語音模式各自的觸發方式。"
        case .appearance: "HUD 波形、外框、字幕樣式與整個 App 的配色主題。"
        case .engine: "本機 MLX、雲端備援與隱私開關；服務狀態可摺疊查看。"
        }
    }
}

private struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    // Scene storage, not @State: switching the app theme re-identifies the
    // whole dashboard subtree (`.id(appTheme)` on DashboardView), which would
    // throw away plain view state and bounce the user back to 一般 -- right
    // after they came to 外觀 to compare themes.
    @SceneStorage("settings.section") private var sectionRaw = SettingsSection.general.rawValue

    private var section: SettingsSection {
        get { SettingsSection(rawValue: sectionRaw) ?? .general }
        nonmutating set { sectionRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                pageTitle("設定", subtitle: section.subtitle)
                sectionTabs
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionBody
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            // Each group starts at its own top rather than inheriting the
            // previous group's scroll offset.
            .id(section)
        }
    }

    private var sectionTabs: some View {
        HStack(spacing: 4) {
            ForEach(SettingsSection.allCases) { item in
                let isCurrent = item == section
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { section = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.rawValue)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(isCurrent ? NV.ink : NV.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(isCurrent ? NV.card : Color.clear, in: Capsule())
                    .overlay {
                        if isCurrent { Capsule().stroke(NV.hairline, lineWidth: 1) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(NV.fill, in: Capsule())
        .fixedSize()
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .general:
            permissionsCard
            languageAudioCard
            startupCard
        case .hotkeys:
            recordKeyCard
            modeHotkeysCard
        case .appearance:
            appThemeCard
            hudStyleCard
            hudChromeCard
            subtitleStyleCard
        case .engine:
            localModelCard
            cloudKeysCard
            privacyCard
            serviceStatusCard
        }
    }

    // MARK: General

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("權限", "沒有這兩項就無法錄音與貼上")
            settingsRow(
                title: "麥克風",
                detail: model.microphoneGranted ? "已授權" : "未授權 — 需在系統設定勾選 NexVoice",
                trailing: {
                    if model.microphoneGranted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(NV.ok)
                    } else {
                        Button("打開設定") {
                            Task { _ = await model.requestMicrophoneAccess() }
                        }
                        .buttonStyle(NVSecondaryButton())
                    }
                }
            )
            Divider().overlay(NV.hairline)
            settingsRow(
                title: "輔助使用（貼上）",
                detail: model.accessibilityGranted ? "已授權" : "未授權 — 需在系統設定勾選 NexVoice",
                trailing: {
                    if model.accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(NV.ok)
                    } else {
                        Button("打開設定") { model.requestAccessibilityAccess() }
                            .buttonStyle(NVSecondaryButton())
                    }
                }
            )
            Divider().overlay(NV.hairline)
            settingsRow(
                title: "設定引導",
                detail: "分步教學，可再次開啟",
                trailing: {
                    Button("開啟") {
                        model.reopenOnboarding()
                        openWindow(id: "onboarding")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(NVSecondaryButton())
                }
            )
        }
        .nvCard()
    }

    private var languageAudioCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("語言與音訊")
            settingsRow(title: "介面語言", detail: "App 顯示語言", trailing: {
                Picker("介面語言", selection: $model.productPreferences.interfaceLanguage) {
                    Text("繁體中文（台灣）").tag("繁體中文（台灣）")
                    Text("English").tag("English")
                }
                .labelsHidden()
                .frame(width: 170)
            })
            Divider().overlay(NV.hairline)
            settingsRow(title: "翻譯目標", detail: "Translate 模式的預設語言", trailing: {
                Picker("翻譯目標", selection: $model.productPreferences.translationTarget) {
                    Text("英語（美國）").tag("英語（美國）")
                    Text("日語").tag("日語")
                    Text("韓語").tag("韓語")
                    Text("繁體中文").tag("繁體中文")
                }
                .labelsHidden()
                .frame(width: 170)
            })
            Divider().overlay(NV.hairline)
            toggleRow(title: "互動聲音", detail: "開始／停止時播放提示音", isOn: $model.productPreferences.interactionSounds)
            Divider().overlay(NV.hairline)
            toggleRow(title: "語音輸入時靜音", detail: "錄音期間暫停其他系統音訊", isOn: $model.productPreferences.muteOtherAudio)
        }
        .nvCard()
    }

    private var startupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("啟動與 Dock")
            toggleRow(
                title: "登入時啟動",
                detail: "放在選單列，不自動搶 Option",
                isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.setOpenAtLogin($0) }
                )
            )
            Divider().overlay(NV.hairline)
            toggleRow(title: "在 Dock 顯示", detail: "顯示或隱藏 Dock 圖示", isOn: $model.productPreferences.showDockIcon)
        }
        .nvCard()
    }

    // MARK: Hotkeys

    private var recordKeyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("主要觸發", "所有模式共用；下方可為個別模式另外指定")
            settingsRow(
                title: "錄音按鍵",
                detail: "點擊後直接按下 Option／Command／Control／Fn 設定",
                trailing: {
                    HotkeyCaptureButton(trigger: Binding(
                        get: { model.hotkeyProfile.trigger },
                        set: { trigger in
                            model.hotkeyProfile = HotkeyProfile(
                                trigger: trigger,
                                behavior: model.hotkeyProfile.behavior,
                                keyCode: nil
                            )
                        }
                    ), keyCode: Binding(
                        get: { model.hotkeyProfile.keyCode },
                        set: { code in
                            model.hotkeyProfile = HotkeyProfile(
                                trigger: model.hotkeyProfile.trigger,
                                behavior: model.hotkeyProfile.behavior,
                                keyCode: code
                            )
                        }
                    ))
                }
            )
            Divider().overlay(NV.hairline)
            settingsRow(
                title: "操作方式",
                detail: model.hotkeyProfile.behavior == .toggle
                    ? "按一下開始，再按一下停止"
                    : "按住錄音，放開後停止並轉錄",
                trailing: {
                    Picker("操作方式", selection: Binding(
                        get: { model.hotkeyProfile.behavior },
                        set: { behavior in
                            model.hotkeyProfile = HotkeyProfile(
                                trigger: model.hotkeyProfile.trigger,
                                behavior: behavior,
                                keyCode: model.hotkeyProfile.keyCode
                            )
                        }
                    )) {
                        ForEach(TriggerBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            )
        }
        .nvCard()
    }

    private var modeHotkeysCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("快捷鍵模式", "每個模式可綁不同按鍵與觸發方式")
            modeHotkeyRow(.dictate, title: "聽寫", detail: "按下開始／停止並貼上")
            Divider().overlay(NV.hairline)
            modeHotkeyRow(.translate, title: "翻譯", detail: "按下開始／停止翻譯到目標語言")
            Divider().overlay(NV.hairline)
            modeHotkeyRow(.ask, title: "隨便問", detail: "按下開始／停止，回答目前問題")
        }
        .nvCard()
    }

    // MARK: Appearance

    private var appThemeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeader("外觀主題", "整個 App 視窗的配色風格")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    let swatch = nvPreviewPalette(for: theme)
                    Button {
                        model.productPreferences.appTheme = theme
                    } label: {
                        tileChrome(selected: model.productPreferences.appTheme == theme) {
                            VStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(swatch.bg)
                                    .overlay(alignment: .topLeading) {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(swatch.card)
                                            .frame(width: 28, height: 18)
                                            .padding(6)
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(swatch.accent)
                                            .frame(width: 12, height: 12)
                                            .padding(6)
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(NV.hairline, lineWidth: 1)
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)

                                tileLabel(theme.displayName, selected: model.productPreferences.appTheme == theme)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .nvCard()
    }

    private var hudStyleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeader("語音 HUD 樣式", "錄音時顯示在畫面下方的小型浮動控制器動畫與聲波型態")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(HUDStyle.allCases, id: \.self) { style in
                    Button {
                        model.productPreferences.hudStyle = style
                    } label: {
                        tileChrome(selected: model.productPreferences.hudStyle == style) {
                            VStack(spacing: 10) {
                                TimelineView(.animation(minimumInterval: 0.04)) { context in
                                    // No microphone here, so drive the tile from the
                                    // same motion law the live HUD uses, fed by a
                                    // synthetic breath: the preview then shows the
                                    // real behaviour -- slow when quiet, lively when
                                    // loud -- instead of a constant-speed animation.
                                    let signal = nexVoiceHUDPreviewSignal(
                                        at: context.date.timeIntervalSinceReferenceDate
                                    )
                                    let synthetic: [Double] = (0..<11).map { i in
                                        // Trailing history: older samples lag the breath.
                                        let lag = Double(10 - i) * 0.09
                                        return nexVoiceHUDPreviewSignal(
                                            at: context.date.timeIntervalSinceReferenceDate - lag
                                        ).level
                                    }
                                    HUDVisualization(style: style, levels: synthetic)
                                        .environment(\.hudPhase, signal.phase)
                                }
                                .frame(width: 110, height: 50)
                                .frame(maxWidth: .infinity)
                                .background(hudPlate, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                tileLabel(style.displayName, selected: model.productPreferences.hudStyle == style)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .nvCard()
    }

    private var hudChromeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeader("HUD 外框", "套在膠囊背景上的外框樣式，與波形樣式可自由搭配")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(HUDChrome.allCases, id: \.self) { chrome in
                    Button {
                        model.productPreferences.hudChrome = chrome
                    } label: {
                        tileChrome(selected: model.productPreferences.hudChrome == chrome) {
                            VStack(spacing: 10) {
                                HUDCapsuleChrome(chrome: chrome)
                                    .frame(width: 80, height: 36)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)

                                tileLabel(chrome.displayName, selected: model.productPreferences.hudChrome == chrome)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .nvCard()
    }

    private var subtitleStyleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The enable switch lives with the styles it governs rather than
            // on the HUD card, which configures a different surface.
            HStack(alignment: .top) {
                cardHeader("即時字幕", "錄音時懸浮在 HUD 控制器上方同步顯示的動態字幕")
                Spacer(minLength: 12)
                Toggle("", isOn: $model.productPreferences.liveCaptionsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(NV.blue)
            }

            Text(model.productPreferences.liveCaptionsEnabled
                 ? "已開啟：錄音中會在 HUD 上方自動同步顯示 partial 聽寫文字。"
                 : "已關閉：停止錄音後執行最終高精準度轉錄，資源佔用最省。")
                .font(.system(size: 12))
                .foregroundStyle(NV.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(SubtitleStyle.allCases, id: \.self) { style in
                    let selected = model.productPreferences.subtitleStyle == style
                    Button {
                        model.productPreferences.subtitleStyle = style
                    } label: {
                        tileChrome(selected: selected) {
                            VStack(spacing: 10) {
                                SubtitleStylePreview(style: style, text: "今天開會，明天再做。")
                                    .fixedSize()
                                    .scaleEffect(0.55)
                                    .frame(height: 50)
                                    .frame(maxWidth: .infinity)
                                    .background(hudPlate, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                tileLabel(style.displayName, selected: selected)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(model.productPreferences.liveCaptionsEnabled ? 1 : 0.4)
            .disabled(!model.productPreferences.liveCaptionsEnabled)
        }
        .nvCard()
    }

    // MARK: Engine & privacy

    private var localModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("本地 MLX 模型")
            TextField("Hugging Face / 本地模型名稱", text: $model.localModelName)
                .textFieldStyle(.roundedBorder)
            TextField("本地 API endpoint（只允許 127.0.0.1:5112）", text: $model.localEndpoint)
                .textFieldStyle(.roundedBorder)
            Text("App 以 bytes + token 呼叫本機 runtime，不傳送檔案路徑。")
                .font(.system(size: 11.5))
                .foregroundStyle(NV.secondary)
        }
        .nvCard()
    }

    private var cloudKeysCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("免費雲端 API（選填）")
            SecureField("Groq API key（選填）", text: $model.groqAPIKeyInput)
                .textFieldStyle(.roundedBorder)
            SecureField("Gemini API key（選填）", text: $model.geminiAPIKeyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Groq：\(model.groqConfigured ? "已設定" : "未設定") · Gemini：\(model.geminiConfigured ? "已設定" : "未設定")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(NV.secondary)
                Spacer()
                if model.providerTestInProgress { ProgressView().controlSize(.small) }
                Button("儲存、測試並啟用") { model.saveTestAndEnableProviders() }
                    .buttonStyle(NVSecondaryButton())
                    .disabled(model.providerTestInProgress)
            }
            if !model.providerTestStatus.isEmpty {
                Text(model.providerTestStatus)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(model.providerTestStatus.contains("✕") ? NV.warn : NV.ok)
            }
            Text("按下按鈕代表允許雲端備援；key 只寫入本機 0600 檔案，並會立即驗證是否真的可用。")
                .font(.system(size: 11.5))
                .foregroundStyle(NV.secondary)
        }
        .nvCard()
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("隱私與成本")
            toggleRow(
                title: "零費用模式（建議）",
                detail: "只用本機服務；API 月支出預設為 0",
                isOn: $model.zeroCostMode
            )
            Divider().overlay(NV.hairline)
            toggleRow(
                title: "僅限本機（隱私）",
                detail: "關閉雲端 STT／整理，本機不可用時直接失敗",
                isOn: $model.privacyMode
            )
            Divider().overlay(NV.hairline)
            toggleRow(
                title: "雲端轉錄備援",
                detail: model.zeroCostMode
                    ? "零費用模式下停用"
                    : "使用自備 Groq API；可能消耗供應商額度",
                isOn: $model.cloudFallbackEnabled
            )
            .disabled(model.zeroCostMode || model.privacyMode)
            Divider().overlay(NV.hairline)
            toggleRow(
                title: "雲端 AI 整理",
                detail: model.zeroCostMode || model.privacyMode
                    ? "本機／零費用模式下停用"
                    : "Groq → Gemini → 原文；可能消耗 API 額度",
                isOn: $model.cleanupEnabled
            )
            .disabled(model.zeroCostMode || model.privacyMode)
            Divider().overlay(NV.hairline)
            toggleRow(
                title: "長內容自動整理重點",
                detail: model.zeroCostMode || model.privacyMode
                    ? "本機／零費用模式下停用"
                    : "口述超過約 200 字時自動整理成條列重點；短內容不受影響",
                isOn: $model.smartFormatEnabled
            )
            .disabled(model.zeroCostMode || model.privacyMode)
        }
        .nvCard()
    }

    private var serviceStatusCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                serviceLine(name: "Local MLX", status: model.mlx)
                serviceLine(name: "資料服務", status: model.gateway)
                HStack {
                    Text("快捷鍵操控權")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(NV.ink)
                    Spacer()
                    Text(model.currentHotkeyOwner.displayName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(NV.secondary)
                }
                Text("路由：\(model.currentRoute.rawValue)")
                    .font(.system(size: 12))
                    .foregroundStyle(NV.secondary)
            }
            .padding(.top, 8)
        } label: {
            Text("進階：服務狀態")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NV.ink)
        }
        .padding(16)
        .background(NV.card, in: RoundedRectangle(cornerRadius: NV.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NV.radius, style: .continuous)
                .stroke(NV.hairline, lineWidth: 1)
        }
    }

    // MARK: Card chrome

    private func cardHeader(_ title: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(NV.ink)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(NV.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    /// Selection chrome shared by all four picker grids (HUD style, chrome,
    /// theme, subtitle) -- they were four copies of the same border logic.
    private func tileChrome<Content: View>(
        selected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                selected ? NV.selected : NV.card,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? NV.blue : NV.hairline, lineWidth: selected ? 1.5 : 1)
            }
    }

    private func tileLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? NV.blue : NV.ink)
            .lineLimit(1)
    }

    /// The HUD always renders on a dark capsule, so its previews keep a fixed
    /// dark plate regardless of the app theme.
    private var hudPlate: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.12, green: 0.13, blue: 0.17), Color(red: 0.08, green: 0.09, blue: 0.12)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func settingsRow<T: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(NV.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(NV.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func modeHotkeyRow(_ mode: VoiceMode, title: String, detail: String) -> some View {
        let profile = mode == .dictate ? model.productPreferences.dictate
            : mode == .translate ? model.productPreferences.translate : model.productPreferences.ask
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(NV.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(NV.secondary)
                Text(profile.behavior == .toggle ? "按一下切換" : "按住放開")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(NV.blue)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                HotkeyCaptureButton(
                    trigger: Binding(get: { profile.trigger }, set: { newTrigger in
                        var next = profile; next = HotkeyProfile(trigger: newTrigger, behavior: next.behavior)
                        setModeProfile(mode, next)
                    }),
                    keyCode: Binding(get: { profile.keyCode }, set: { code in
                        let next = HotkeyProfile(trigger: profile.trigger, behavior: profile.behavior, keyCode: code)
                        setModeProfile(mode, next)
                    })
                )
                Picker("模式", selection: Binding(get: { profile.behavior }, set: { behavior in
                    setModeProfile(mode, HotkeyProfile(trigger: profile.trigger, behavior: behavior, keyCode: profile.keyCode))
                })) {
                    ForEach(TriggerBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 118)
            }
        }
        .padding(.vertical, 12)
    }

    private func setModeProfile(_ mode: VoiceMode, _ profile: HotkeyProfile) {
        switch mode {
        case .dictate: model.productPreferences.dictate = profile
        case .translate: model.productPreferences.translate = profile
        case .ask: model.productPreferences.ask = profile
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(NV.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(NV.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(NV.blue)
        }
        .padding(.vertical, 12)
    }

    private func serviceLine(name: String, status: ServiceStatus) -> some View {
        HStack {
            Circle()
                .fill(status.isHealthy ? NV.ok : NV.warn)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(NV.ink)
            Spacer()
            Text(status.latencyMilliseconds.map { "\($0) ms" } ?? (status.isHealthy ? "正常" : "未連線"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(NV.secondary)
        }
    }
}

private struct HotkeyCaptureButton: View {
    @Binding var trigger: TriggerKey
    @Binding var keyCode: UInt16?
    @State private var capturing = false

    var body: some View {
        Button(capturing ? "請按按鍵…" : (keyCode.map(HotkeyDisplay.name) ?? trigger.displayName)) {
            capturing = true
        }
        .buttonStyle(NVSecondaryButton())
        .background(
            HotkeyCaptureField(isCapturing: $capturing, trigger: $trigger, keyCode: $keyCode)
                .frame(width: 1, height: 1)
        )
        .accessibilityLabel("錄音快捷鍵")
    }
}

private enum HotkeyDisplay {
    static func name(_ code: UInt16) -> String {
        switch code {
        case 49: "Space"
        case 36: "Return"
        case 48: "Tab"
        case 53: "Escape"
        default: "自訂按鍵 · \(code)"
        }
    }
}

private struct HotkeyCaptureField: NSViewRepresentable {
    @Binding var isCapturing: Bool
    @Binding var trigger: TriggerKey
    @Binding var keyCode: UInt16?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onKey = { code in
            guard isCapturing else { return }
            keyCode = code
            isCapturing = false
        }
        view.onFlags = { flags in
            guard isCapturing else { return }
            keyCode = nil
            if flags.contains(.option) { trigger = .option }
            else if flags.contains(.command) { trigger = .leftCommand }
            else if flags.contains(.control) { trigger = .leftControl }
            else if flags.contains(.function) { trigger = .function }
            else { return }
            isCapturing = false
        }
        return view
    }
    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        if isCapturing { nsView.window?.makeFirstResponder(nsView) }
    }
    final class Coordinator {}
}

private final class CaptureNSView: NSView {
    var onFlags: ((NSEvent.ModifierFlags) -> Void)?
    var onKey: ((UInt16) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event.keyCode) }
    override func flagsChanged(with event: NSEvent) { onFlags?(event.modifierFlags) }
}

private extension HotkeyOwner {
    var displayName: String {
        switch self {
        case .legacy: "Hammerspoon／舊版"
        case .native: "NexVoice"
        case .typeless: "Typeless"
        case .unknown: "未知／需恢復"
        }
    }
}

// MARK: - Shared chrome

private func pageTitle(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(NV.ink)
        Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(NV.secondary)
    }
    .padding(.bottom, 4)
}
