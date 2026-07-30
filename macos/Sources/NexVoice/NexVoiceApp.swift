import AppKit
import SwiftUI

@main
struct NexVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    private let instanceGuard: SingleInstanceGuard?

    init() {
        if CommandLine.arguments.contains("--prepare-for-update") {
            AppDelegate.requestGracefulShutdown()
            usleep(250_000)
            self.instanceGuard = nil
            self._model = StateObject(wrappedValue: AppModel())
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        let instanceGuard = SingleInstanceGuard.acquire()
        if instanceGuard == nil {
            AppDelegate.pingRunningInstance()
            usleep(150_000)
            self.instanceGuard = nil
            self._model = StateObject(wrappedValue: AppModel())
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        self.instanceGuard = instanceGuard
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        AppDelegate.shutdownHandler = { [weak model] in
            await model?.prepareForTermination() ?? true
        }
        DispatchQueue.main.async {
            model.startMonitoring()
        }
        if CommandLine.arguments.contains("--hud-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak model] in
                model?.previewRecorderHUD(thinking: false, duration: 15)
            }
        }
    }

    var body: some Scene {
        // Single main window (not WindowGroup).
        Window("NexVoice", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .task { model.startMonitoring() }
                .background(WindowActivator().environmentObject(model))
                .background(OnboardingPresenter().environmentObject(model))
        }
        .defaultSize(width: 920, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("設定引導…") {
                    model.reopenOnboarding()
                }
            }
        }

        MenuBarExtra {
            MenuPanelView()
                .environmentObject(model)
                .task { model.startMonitoring() }
        } label: {
            MenuBarLabel(isEnabled: model.isEnabled)
        }
        .menuBarExtraStyle(.window)

        Window("NexVoice 設定引導", id: "onboarding") {
            OnboardingView()
                .environmentObject(model)
                .task { model.startMonitoring() }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 520)
    }
}

struct OnboardingPresenter: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.showOnboarding) { _, show in
                guard show else { return }
                if AppDelegate.onboardingWindows().isEmpty {
                    openWindow(id: "onboarding")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
