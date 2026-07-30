import SwiftUI

/// Single-focus setup wizard (light shell, one step at a time).
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NexVoiceMark(size: 36, active: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("設定引導")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NV.ink)
                    Text("步驟 \(min(step + 1, 4)) / 4")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NV.secondary)
                }
                Spacer()
                Button("稍後") {
                    model.dismissOnboarding(completed: false)
                    dismiss()
                }
                .buttonStyle(NVSecondaryButton())
            }
            .padding(20)

            progress
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepBody
                    permissionSummary
                    stepActions
                }
                .padding(20)
            }

            HStack {
                if step > 0 {
                    Button("上一步") { step = max(0, step - 1) }
                        .buttonStyle(NVSecondaryButton())
                }
                Spacer()
                Text("勾選後回到此窗，狀態會自動更新")
                    .font(.system(size: 11))
                    .foregroundStyle(NV.secondary)
            }
            .padding(16)
            .background(NV.sidebar)
        }
        .frame(width: 440, height: 520)
        .background(NV.bg)
        .nvTheme(model.productPreferences.appTheme)
        .task {
            await model.refreshPermissions()
            step = model.suggestedOnboardingStep
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refreshPermissions()
                // If system toggle is on but process still untrusted, ad-hoc
                // rebuild often needs a full relaunch to bind TCC.
                if model.microphoneGranted && !model.accessibilityGranted {
                    // Nudge another AX check after Settings focus returns.
                    try? await Task.sleep(for: .milliseconds(400))
                    await model.refreshPermissions()
                }
            }
        }
        .id(model.productPreferences.appTheme)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? NV.blue : Color.black.opacity(0.08))
                    .frame(width: i == step ? 28 : 8, height: 5)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        let copy: (String, String, String) = {
            switch step {
            case 0:
                return ("hand.wave.fill", "歡迎使用 NexVoice", "和 Typeless 一樣掛在選單列。完成權限後，Option 聽寫；可隨時切回 Typeless。")
            case 1:
                return ("mic.fill", "允許麥克風", "請先點「開啟麥克風權限」——系統會跳出授權對話框，NexVoice 才會出現在列表裡（含 logo）。若已拒絕，再到系統設定打開開關。列表裡沒看到 = 還沒按過這個按鈕。")
            case 2:
                return ("accessibility", "允許輔助使用", "請點「開啟輔助使用設定」。系統會登記 NexVoice 後打開列表，找到 NexVoice 打開開關。")
            default:
                return ("checkmark.circle.fill", "可以開始了", "Option 單按開始，再按完成。Esc 取消。準備好就啟用 NexVoice。")
            }
        }()

        HStack(alignment: .top, spacing: 14) {
            Image(systemName: copy.0)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(NV.blue)
                .frame(width: 48, height: 48)
                .background(NV.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.1)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(NV.ink)
                Text(copy.2)
                    .font(.system(size: 13))
                    .foregroundStyle(NV.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionSummary: some View {
        VStack(spacing: 8) {
            permRow(title: "麥克風", ok: model.microphoneGranted) {
                Task { _ = await model.requestMicrophoneAccess() }
            }
            permRow(title: "輔助使用（貼上）", ok: model.accessibilityGranted) {
                model.requestAccessibilityAccess()
            }
        }
    }

    private func permRow(title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? NV.ok : NV.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NV.ink)
                Text(ok ? "已授權" : "尚未授權")
                    .font(.system(size: 11))
                    .foregroundStyle(ok ? NV.ok : NV.secondary)
            }
            Spacer()
            if !ok {
                Button("打開設定", action: action)
                    .buttonStyle(NVSecondaryButton())
            }
        }
        .padding(12)
        .background(NV.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(NV.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var stepActions: some View {
        switch step {
        case 0:
            Button("開始設定") { step = 1 }
                .buttonStyle(NVPrimaryButton())
        case 1:
            HStack(spacing: 10) {
                Button("開啟麥克風權限") {
                    Task {
                        _ = await model.requestMicrophoneAccess()
                        if model.microphoneGranted { step = 2 }
                    }
                }
                .buttonStyle(NVPrimaryButton())
                Button("下一步") { step = 2 }
                    .buttonStyle(NVSecondaryButton())
            }
        case 2:
            VStack(alignment: .leading, spacing: 10) {
                Text("在系統設定列表找到 NexVoice，把右側開關打開（現在是關閉的話 App 仍算未授權）。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(NV.secondary)
                HStack(spacing: 10) {
                    Button("開啟輔助使用設定") {
                        model.requestAccessibilityAccess()
                    }
                    .buttonStyle(NVPrimaryButton())
                    Button(model.accessibilityGranted ? "已打開，下一步" : "下一步") {
                        step = 3
                    }
                    .buttonStyle(NVSecondaryButton())
                }
            }
        default:
            VStack(alignment: .leading, spacing: 12) {
                if !model.permissionsReady {
                    Text("若系統設定顯示已開啟但這裡仍未授權，請把 NexVoice 開關關閉後再開啟一次，然後回來重新檢查。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(NV.warn)
                    Button("重新檢查") {
                        Task { await model.refreshPermissions() }
                    }
                    .buttonStyle(NVSecondaryButton())
                }
                HStack(spacing: 10) {
                    Button("使用 NexVoice") {
                        model.switchToNexVoice()
                    }
                    .buttonStyle(NVPrimaryButton(enabled: model.permissionsReady))
                    .disabled(!model.permissionsReady)

                    Button("完成") {
                        model.dismissOnboarding(completed: true)
                        dismiss()
                    }
                    .buttonStyle(NVSecondaryButton())
                    .disabled(!model.permissionsReady)
                }
                if model.typelessRunning {
                    Text("Typeless 正在執行。按「使用 NexVoice」會詢問是否結束 Typeless。")
                        .font(.system(size: 12))
                        .foregroundStyle(NV.warn)
                }
            }
        }
    }
}
