import SwiftUI

/// 配置的唯一可写入口：App 侧改完立刻落 App Group，键盘下次分析就能读到。
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: JevConfig {
        didSet { JevStore.saveConfig(config) }
    }
    @Published var language: JevLanguage {
        didSet { JevStore.saveLanguage(language) }
    }

    init() {
        config = JevStore.loadConfig()
        language = JevStore.loadLanguage()
    }

    /// 键盘那边也能改共享配置（话术槽位就能直接在键盘上选），回到前台时把外部改动收进来——
    /// 否则 App 里这份旧值会在下次编辑时把键盘的选择覆盖掉。
    func reloadIfChanged() {
        let fresh = JevStore.loadConfig()
        if fresh != config { config = fresh }
        let freshLanguage = JevStore.loadLanguage()
        if freshLanguage != language { language = freshLanguage }
    }

    var toneCatalog: [String: String] { allTones(custom: config.customTones) }
}

@main
struct JevJarvisApp: App {
    @StateObject private var store = ConfigStore()
    @Environment(\.scenePhase) private var scenePhase
    /// 当前选中的 tab。判断层未配置时，「开始」页要能一键跳到「模型」——
    /// 用 tab 切换而不是 NavigationLink，因为 ProvidersView 自带 NavigationStack，
    /// 拿它当导航目标会套出双层导航栏。
    @State private var selectedTab: AppTab = .setup

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                SetupView(selectedTab: $selectedTab)
                    .tabItem { Label(jevLocalized(store.language, zh: "开始", en: "Home"), systemImage: "keyboard") }
                    .tag(AppTab.setup)
                ProvidersView()
                    .tabItem { Label(jevLocalized(store.language, zh: "模型", en: "Models"), systemImage: "brain.head.profile") }
                    .tag(AppTab.models)
                TonesView()
                    .tabItem { Label(jevLocalized(store.language, zh: "话术", en: "Tones"), systemImage: "theatermasks") }
                    .tag(AppTab.tones)
                PlaygroundView()
                    .tabItem { Label(jevLocalized(store.language, zh: "试一试", en: "Try it"), systemImage: "flask") }
                    .tag(AppTab.playground)
            }
            .environmentObject(store)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { store.reloadIfChanged() }
        }
    }
}

/// App 的四个 tab。判断层入口要跳到「模型」。
enum AppTab: Hashable {
    case setup, models, tones, playground
}
