import Foundation

extension Notification.Name {
    /// Broadcast after a language switch: SwiftUI views refresh automatically via @ObservedObject,
    /// while the AppKit side (window titles / context menus) listens for this notification and rebuilds.
    static let hbLanguageChanged = Notification.Name("com.aremind.hapticbreak.languageChanged")
}

/// App language. `system` follows the system language; the rest are manual selections.
/// Three supported localizations: Simplified Chinese / English / Japanese; falls back to English when the
/// system language isn't supported.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case en
    case ja

    var id: String { rawValue }

    /// Name shown in the picker: supported languages always use their native name (not changing with the
    /// current language, matching platform convention); "Follow system" is localized to the current language.
    var displayName: String {
        switch self {
        case .system: return L.t("lang.system")
        case .zhHans: return "简体中文"
        case .en:     return "English"
        case .ja:     return "日本語"
        }
    }
}

/// Built-in localization hub in code: singleton + observable. SwiftUI views hold `@ObservedObject var
/// l10n = L10n.shared` and refresh instantly on language change; non-SwiftUI code uses `L.t(...)` to fetch
/// strings and listens to `.hbLanguageChanged` to rebuild.
final class L10n: ObservableObject {

    static let shared = L10n()

    private static let storageKey = "hb.appLanguage"

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            if suppressPersist { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
            NotificationCenter.default.post(name: .hbLanguageChanged, object: nil)
        }
    }

    /// Switch language for offscreen rendering/preview only, without persisting, to avoid polluting the real .app domain.
    private var suppressPersist = false
    func previewOnlySet(_ lang: AppLanguage) {
        suppressPersist = true
        language = lang
        suppressPersist = false
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
    }

    // MARK: - Resolution

    /// Column index of the currently effective language in the dictionary arrays: 0=zhHans, 1=en, 2=ja.
    private var index: Int {
        switch language {
        case .zhHans: return 0
        case .en:     return 1
        case .ja:     return 2
        case .system: return Self.systemIndex()
        }
    }

    /// Follow system: Simplified Chinese → Chinese, Japanese → Japanese, everything else (incl. Traditional) → English.
    private static func systemIndex() -> Int {
        for code in Locale.preferredLanguages {
            let c = code.lowercased()
            if c.hasPrefix("zh") {
                if c.contains("hant") || c.contains("-tw") || c.contains("-hk") || c.contains("-mo") {
                    return 1   // Traditional not yet supported → fall back to English
                }
                return 0
            }
            if c.hasPrefix("ja") { return 2 }
            if c.hasPrefix("en") { return 1 }
        }
        return 1
    }

    // MARK: - String lookup

    /// Look up a localized string: missing current language → fall back to English → fall back to key name (to surface gaps).
    func t(_ key: String) -> String {
        guard let row = Self.strings[key] else { return key }
        let i = index
        if i < row.count, !row[i].isEmpty { return row[i] }
        if row.count > 1, !row[1].isEmpty { return row[1] }
        return key
    }
}

/// Convenience entry point for string lookup (namespaced to avoid polluting the global scope).
enum L {
    static func t(_ key: String) -> String { L10n.shared.t(key) }
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: L10n.shared.t(key), arguments: args)
    }
}

// MARK: - Dictionary table ([zhHans, en, ja])

extension L10n {
    /// All user-visible copy. Each value array is fixed as [Simplified Chinese, English, Japanese].
    /// Entries containing `%@ / %d` are format strings; callers use `L.t(key, args...)`.
    static let strings: [String: [String]] = [

        // Common / units
        "unit.minutes":            ["%d 分钟", "%d min", "%d 分"],
        "lang.system":             ["跟随系统", "System", "システムに従う"],
        "settings.language":       ["语言", "Language", "言語"],
        "settings.section.general":["通用", "General", "一般"],

        // Status (AppViewModel)
        "status.waitingTyping":    ["等待打字停顿…", "Waiting for a typing pause…", "入力の区切りを待っています…"],
        "status.paused":           ["已暂停", "Paused", "一時停止中"],
        "status.idlePaused":       ["空闲暂停", "Paused (idle)", "アイドルで一時停止"],
        "status.focusPaused":      ["专注模式暂停", "Paused (Focus)", "集中モードで一時停止"],
        "status.fullscreenPaused": ["全屏应用暂停", "Paused (full screen)", "フルスクリーンで一時停止"],
        "status.meetingPaused":    ["通话/会议暂停", "Paused (call/meeting)", "通話/会議で一時停止"],
        "status.resting":          ["休息中", "Resting", "休憩中"],
        "status.working":          ["工作中", "Working", "作業中"],
        "status.available":        ["可用", "Available", "利用可能"],
        "status.unavailable":      ["不可用", "Unavailable", "利用不可"],

        // Control panel (Popover)
        "popover.nextReminder":    ["下次提醒 %@", "Next at %@", "次は %@"],
        "popover.streakDays":      ["连续 %d 天", "%d-day streak", "%d 日連続"],
        "popover.noActuator":      ["未检测到可用触摸板致动器，提醒将无震动",
                                    "No trackpad actuator detected; reminders won't vibrate",
                                    "トラックパッドのアクチュエータが見つかりません。リマインドは振動しません"],
        "popover.pomodoroMode":    ["番茄钟模式：%d + %d 分钟", "Pomodoro: %d + %d min", "ポモドーロ：%d + %d 分"],

        "action.resume":           ["恢复", "Resume", "再開"],
        "action.pause":            ["暂停", "Pause", "一時停止"],
        "action.skip":             ["跳过", "Skip", "スキップ"],
        "action.postpone":         ["+%d分", "+%dm", "+%d分"],
        "action.testHaptic":       ["试震", "Test", "テスト"],

        "label.interval":          ["提醒间隔", "Interval", "間隔"],
        "label.pattern":           ["震动模式", "Pattern", "パターン"],
        "label.intensity":         ["强度", "Strength", "強さ"],

        // Event patterns (different events use different timbres / patterns)
        "settings.section.events": ["事件模式", "Per-event patterns", "イベント別パターン"],
        "label.reminderPattern":   ["休息提醒", "Break reminder", "休憩リマインド"],
        "label.headsUpPattern":    ["休息前预告", "Heads-up", "予告"],
        "label.finishPattern":     ["休息结束", "Break finished", "休憩終了"],
        "settings.eventsFooter":   ["为不同事件挑选不同的震动模式：休息提醒、休息前的轻预告、休息结束时的提示，可各有专属手感。全部仍受上方「震动强度」统一缩放。",
                                    "Pick a different pattern for each moment — the break reminder, the gentle heads-up before it, and the cue when a break ends. All are still scaled by the Haptic strength above.",
                                    "イベントごとに別々の振動パターンを選べます：休憩リマインド、その前のそっとした予告、休憩終了の合図。いずれも上の「振動の強さ」で一律に倍率調整されます。"],

        // Timbre families (one of the three axes: timbre)
        "timbre.soft":             ["轻点", "Soft", "ソフト"],
        "timbre.crisp":            ["清脆", "Crisp", "クリア"],
        "timbre.buzz":             ["低频嗡", "Low buzz", "低周波"],

        "footer.settings":         ["设置", "Settings", "設定"],
        "footer.stats":            ["统计", "Stats", "統計"],
        "footer.patterns":         ["模式", "Patterns", "パターン"],
        "footer.quit":             ["退出", "Quit", "終了"],

        "help.resume":             ["恢复计时（⌃⌥Space）", "Resume timer (⌃⌥Space)", "タイマーを再開（⌃⌥Space）"],
        "help.pause":              ["暂停计时（⌃⌥Space）", "Pause timer (⌃⌥Space)", "タイマーを一時停止（⌃⌥Space）"],
        "help.skip":               ["跳过本次，重新开始计时（⌃⌥S）",
                                    "Skip this one and restart the timer (⌃⌥S)",
                                    "今回をスキップしてタイマーを再開（⌃⌥S）"],
        "help.postpone":           ["推迟 %d 分钟", "Postpone %d min", "%d 分延期"],
        "help.testHaptic":         ["立即试触当前震动模式（⌃⌥B 为立即提醒）",
                                    "Feel the current pattern now (⌃⌥B for an instant reminder)",
                                    "現在のパターンを今すぐ体感（⌃⌥B で即リマインド）"],
        "help.openSettings":       ["打开设置", "Open Settings", "設定を開く"],
        "help.openStats":          ["查看休息统计", "View break stats", "休憩の統計を見る"],
        "help.openEditor":         ["自定义震动模式", "Custom haptic patterns", "カスタム振動パターン"],
        "help.quit":               ["退出 HapticBreak", "Quit HapticBreak", "HapticBreak を終了"],

        // Settings
        "settings.section.reminder": ["提醒", "Reminders", "リマインド"],
        "settings.reminderPomoFooter": ["番茄钟开启时，提醒间隔由番茄钟的工作时长接管。",
                                    "While Pomodoro is on, the interval is managed by the Pomodoro work length.",
                                    "ポモドーロが有効な間、間隔はポモドーロの作業時間で管理されます。"],
        "settings.alertsFooter":   ["震动之外的辅助提醒通道，可按需开启；开启提示音后可挑选音色并试听。",
                                    "Extra alert channels beyond haptics — enable as you like; once Sound is on, pick a tone and preview it.",
                                    "触覚以外の補助的な通知。必要に応じて有効化でき、サウンドをオンにすると音色を選んで試聴できます。"],
        "settings.backendFooter":  ["「自动」会优先使用完整震动，不可用时回退到兼容震动。一般保持自动即可。",
                                    "“Automatic” prefers full haptics and falls back to compatible haptics when unavailable. Leave it on Automatic in most cases.",
                                    "「自動」はフル振動を優先し、利用できない場合は互換振動に切り替えます。通常は自動のままで構いません。"],
        "settings.intensityFull":  ["震动强度", "Haptic strength", "振動の強さ"],
        "btn.test":                ["试触", "Test", "テスト"],
        "settings.repeatOnce":     ["提醒震 1 遍", "Buzz once per reminder", "1 回振動"],
        "settings.repeatN":        ["提醒连震 %d 遍", "Buzz %d times per reminder", "%d 回連続で振動"],
        "settings.section.rhythm": ["节奏", "Rhythm", "リズム"],
        "settings.typingDefer":    ["打字时等停顿再提醒", "Wait for a typing pause", "入力の区切りを待つ"],
        "settings.headsUp":        ["休息前 30 秒轻点预告", "Gentle heads-up 30s before", "休憩 30 秒前にそっと予告"],
        "settings.escalation":     ["反复跳过则下次略增强", "Strengthen after repeated skips", "繰り返しスキップで次回を強める"],
        "settings.panelHeartbeat": ["打开面板时倒计时心跳震动",
                                    "Countdown heartbeat while panel is open",
                                    "表示中はカウントダウンの心拍振動"],
        "settings.rhythmFooter":   ["让提醒落在打字的空隙、提前温柔预告——配合你，而不是打断你。打开控制面板时，触摸板会随倒计时像心跳般轻跳：每秒最轻一下、每跨一分钟更明显地撞一下。",
                                    "Land reminders in the gaps between keystrokes and warn you gently in advance — working with you, not interrupting you. While the panel is open, the trackpad beats like a countdown heartbeat: the lightest tap each second, and a firmer one as every minute ticks off.",
                                    "リマインドを入力の合間にそっと差し込み、事前にやさしく予告します——あなたを遮るのではなく、寄り添うために。パネルを開いている間は、カウントダウンの心拍のようにトラックパッドが脈打ちます：毎秒もっとも軽く、1 分経過ごとに少し強く。"],
        "settings.section.autopause": ["智能暂停", "Smart pause", "スマート一時停止"],
        "settings.idle":           ["空闲时自动暂停", "Auto-pause when idle", "アイドル時に自動一時停止"],
        "settings.idleSeconds":    ["空闲判定 %d 秒", "Idle after %d s", "アイドル判定 %d 秒"],
        "settings.idleResetOff":   ["长时间离开后重置：关闭", "Reset after long away: Off", "長時間離席後にリセット：オフ"],
        "settings.idleResetN":     ["长时间离开 %d 分钟后重置", "Reset after %d min away", "%d 分離席でリセット"],
        "settings.fullscreen":     ["全屏时自动暂停", "Auto-pause in full screen", "フルスクリーン時に自動一時停止"],
        "settings.mic":            ["通话 / 会议时暂停", "Pause during calls / meetings", "通話 / 会議中は一時停止"],
        "settings.focus":          ["专注 / 勿扰时暂停", "Pause in Focus / Do Not Disturb", "集中 / おやすみ中は一時停止"],
        "settings.autopauseFooter":["离开、全屏、开会或勿扰时自动暂停，避免在不合适的时刻打扰你。",
                                    "Auto-pause when you're away, in full screen, in a meeting, or in Do Not Disturb — so it never nudges you at the wrong moment.",
                                    "離席中・フルスクリーン・会議中・おやすみモード中は自動で一時停止し、不適切なタイミングで邪魔をしません。"],
        "settings.adv.pomodoro":   ["番茄钟", "Pomodoro", "ポモドーロ"],
        "settings.pomodoroToggle": ["番茄钟模式（工作 / 休息循环）", "Pomodoro mode (work / break cycle)", "ポモドーロ（作業 / 休憩サイクル）"],
        "settings.pomoWork":       ["工作 %d 分钟", "Work %d min", "作業 %d 分"],
        "settings.pomoBreak":      ["休息 %d 分钟", "Break %d min", "休憩 %d 分"],
        "settings.adv.menubar":    ["菜单栏与提示", "Menu bar & alerts", "メニューバーと通知"],
        "settings.menuBarStyle":   ["菜单栏样式", "Menu bar style", "メニューバーの表示"],
        "settings.flash":          ["震动时屏幕轻闪", "Flash screen on buzz", "振動時に画面を点滅"],
        "settings.menubarHi":      ["临近提醒时图标高亮", "Highlight icon near reminder", "リマインド間近にアイコンを強調"],
        "settings.sound":          ["同时播放提示音", "Also play a sound", "サウンドも再生"],
        "settings.soundName":      ["提示音", "Sound", "サウンド"],
        "settings.soundPreview":   ["试听", "Preview", "試聴"],
        "settings.soundPreviewHelp":["试听当前提示音", "Preview the selected sound", "選択中のサウンドを試聴"],
        "settings.adv.backend":    ["震动后端", "Haptic backend", "振動バックエンド"],
        "settings.backendPicker":  ["震动方式", "Haptic method", "振動方式"],
        "settings.currentBackend": ["当前后端", "Current backend", "現在のバックエンド"],
        "settings.actuatorStatus": ["致动器状态", "Actuator status", "アクチュエータの状態"],
        "settings.adv.system":     ["系统", "System", "システム"],
        "settings.launchAtLogin":  ["开机自动启动", "Launch at login", "ログイン時に起動"],
        "settings.shortcuts":      ["启用全局快捷键", "Enable global shortcuts", "グローバルショートカットを有効化"],
        "settings.scPause":        ["⌃⌥Space  暂停 / 恢复", "⌃⌥Space  Pause / Resume", "⌃⌥Space  一時停止 / 再開"],
        "settings.scSkip":         ["⌃⌥S  跳过本次", "⌃⌥S  Skip this one", "⌃⌥S  今回をスキップ"],
        "settings.scBreak":        ["⌃⌥B  立即震动", "⌃⌥B  Buzz now", "⌃⌥B  今すぐ振動"],
        "settings.openEditor":     ["自定义震动模式编辑器…", "Custom pattern editor…", "カスタムパターンエディタ…"],
        "settings.autoUpdate":     ["自动检查更新", "Automatically check for updates", "自動的にアップデートを確認"],
        "settings.checkUpdate":    ["立即检查更新", "Check for updates now", "今すぐアップデートを確認"],
        "settings.updateFooter":   ["安全升级：新版本经数字签名校验后在后台静默更新。",
                                    "Secure updates: new versions are cryptographically verified and installed silently in the background.",
                                    "安全なアップデート：新バージョンは署名検証のうえ、バックグラウンドで静かに適用されます。"],
        "settings.resetDefaults":  ["恢复默认设置", "Restore defaults", "デフォルトに戻す"],
        "settings.resetFooter":    ["将全部偏好恢复为出厂默认；自定义模式与统计数据不受影响。",
                                    "Restore all preferences to factory defaults; your custom patterns and statistics are kept.",
                                    "すべての設定を初期値に戻します。カスタムパターンと統計は保持されます。"],
        "settings.resetConfirmTitle": ["恢复默认设置？", "Restore default settings?", "デフォルト設定に戻しますか？"],
        "settings.resetConfirmMsg": ["将把全部偏好恢复为出厂默认（不影响自定义模式与统计），且无法撤销。",
                                    "This restores all preferences to factory defaults (custom patterns and stats are kept) and can't be undone.",
                                    "すべての設定を初期値に戻します（カスタムパターンと統計は保持）。元に戻せません。"],
        "settings.about":          ["用触摸板震动提醒你起身休息的 macOS 应用——无声、无弹窗、不打断心流。",
                                    "A macOS app that taps your break reminder into your palm through trackpad haptics — silent, no pop-ups, never breaking your flow.",
                                    "トラックパッドの振動で休憩を知らせる macOS アプリ——無音・ポップアップなし・フローを妨げません。"],

        // Statistics
        "stats.title":             ["统计", "Statistics", "統計"],
        "stats.refresh":           ["刷新", "Refresh", "更新"],
        "stats.refreshHelp":       ["刷新统计数据", "Refresh statistics", "統計を更新"],
        "stats.exportCSV":         ["导出 CSV", "Export CSV", "CSV を書き出す"],
        "stats.exportHelp":        ["导出全部统计为 CSV", "Export all statistics as CSV", "すべての統計を CSV で書き出す"],
        "stats.reset":             ["重置", "Reset", "リセット"],
        "stats.resetHelp":         ["清空全部统计数据", "Clear all statistics", "すべての統計を消去"],
        "stats.streakTitle":       ["连续 %d 天坚持休息", "%d days of resting in a row", "%d 日連続で休憩を継続"],
        "stats.streakStart":       ["今天开始你的第一天", "Start your first day today", "今日から 1 日目を始めよう"],
        "stats.streakKeep":        ["保持下去，别让火苗熄灭。", "Keep it up — don't let the flame go out.", "この調子で——火を絶やさないで。"],
        "stats.streakHint":        ["完成一次休息，即可点亮连续天数。", "Finish one break to light up your streak.", "1 回休憩すると連続日数が点灯します。"],
        "stats.todayOverview":     ["今日概览", "Today", "今日の概要"],
        "stats.workTime":          ["工作时长", "Work time", "作業時間"],
        "stats.breaks":            ["休息次数", "Breaks", "休憩回数"],
        "stats.skips":             ["跳过", "Skips", "スキップ"],
        "stats.pomodoros":         ["番茄", "Pomodoros", "ポモドーロ"],
        "stats.minShort":          ["%dm", "%dm", "%d分"],
        "stats.weekTotals":        ["最近 7 天合计：工作 %d 分钟 · 休息 %d 次 · 跳过 %d 次",
                                    "Last 7 days: %d min worked · %d breaks · %d skips",
                                    "直近 7 日：作業 %d 分 · 休憩 %d 回 · スキップ %d 回"],
        "stats.chartWork":         ["工作时长（分钟 / 天）", "Work time (min / day)", "作業時間（分 / 日）"],
        "stats.chartBreaks":       ["休息次数（次 / 天）", "Breaks (per day)", "休憩回数（回 / 日）"],
        "stats.resetConfirmTitle": ["重置统计数据？", "Reset statistics?", "統計をリセットしますか？"],
        "stats.resetConfirmMsg":   ["将清空全部历史统计，且无法恢复。",
                                    "This clears all historical statistics and can't be undone.",
                                    "すべての履歴統計を消去します。元に戻せません。"],
        "stats.csvFilename":       ["HapticBreak-统计.csv", "HapticBreak-Stats.csv", "HapticBreak-統計.csv"],
        "btn.cancel":              ["取消", "Cancel", "キャンセル"],
        "chart.date":              ["日期", "Date", "日付"],
        "chart.workMin":           ["工作分钟", "Work min", "作業分"],
        "chart.breakCount":        ["休息次数", "Breaks", "休憩回数"],

        // Pattern editor
        "editor.title":            ["自定义震动模式", "Custom haptic patterns", "カスタム振動パターン"],
        "editor.copyBuiltin":      ["从内置复制", "Copy from built-in", "プリセットから複製"],
        "editor.new":              ["新建", "New", "新規"],
        "editor.myPatterns":       ["我的模式", "My patterns", "マイパターン"],
        "editor.currentSelected":  ["当前选用：%@", "In use: %@", "使用中：%@"],
        "editor.empty":            ["还没有自定义模式。可点击右上角「新建」或「从内置复制」开始。",
                                    "No custom patterns yet. Tap “New” or “Copy from built-in” in the top right to start.",
                                    "まだカスタムパターンがありません。右上の「新規」または「プリセットから複製」から始めましょう。"],
        "editor.current":          ["当前", "In use", "使用中"],
        "editor.steps":            ["· %d 拍", "· %d taps", "· %d タップ"],
        "editor.setCurrent":       ["设为当前模式", "Set as current", "現在のパターンに設定"],
        "editor.testShort":        ["试触", "Test", "テスト"],
        "editor.testThis":         ["试触此模式", "Test this pattern", "このパターンをテスト"],
        "editor.edit":             ["编辑", "Edit", "編集"],
        "editor.editThis":         ["编辑此模式", "Edit this pattern", "このパターンを編集"],
        "editor.delete":           ["删除", "Delete", "削除"],
        "editor.deleteThis":       ["删除此模式", "Delete this pattern", "このパターンを削除"],
        "editor.name":             ["名称", "Name", "名前"],
        "editor.namePlaceholder":  ["模式名称", "Pattern name", "パターン名"],
        "editor.addStep":          ["添加一拍", "Add a tap", "タップを追加"],
        "editor.hint":             ["提示：每一拍可独立设「音色 / 强度(1–10) / 沉闷(清脆↔沉闷) / 间隔」；间隔是本拍后到下一拍的等待，末拍的间隔无效。整段力度还会乘上设置里的全局强度。",
                                    "Tip: each tap has its own timbre / strength (1–10) / dullness (crisp↔dull) / gap; the gap is the wait before the next tap and is ignored on the last one. The whole pattern is also scaled by the global strength in Settings.",
                                    "ヒント：各タップは音色 / 強さ(1–10) / 鈍さ(クリア↔鈍) / 間隔を個別に設定できます。間隔は次のタップまでの待ちで、最後のタップでは無効。全体は設定のグローバル強度で倍率調整されます。"],
        "editor.testAll":          ["试触整段", "Test all", "全体をテスト"],
        "editor.save":             ["保存", "Save", "保存"],
        "editor.stepN":            ["第 %d 拍", "Tap %d", "タップ %d"],
        "editor.strength":         ["强度", "Strength", "強さ"],
        "editor.dullness":         ["沉闷", "Dullness", "鈍さ"],
        "editor.fireOnDrag":       ["滑动即震", "Fire while dragging", "ドラッグで発火"],
        "editor.unify":            ["整条统一", "Unify all", "全体を統一"],
        "editor.unifyTimbre":      ["全部用此音色", "Use this timbre for all", "全タップをこの音色に"],
        "editor.unifyDullness":    ["沉闷统一为第 1 拍", "Match dullness to tap 1", "鈍さをタップ 1 に合わせる"],
        "editor.stepDelay":        ["间隔 %dms", "Gap %dms", "間隔 %dms"],
        "editor.testStep":         ["试触该拍", "Test this tap", "このタップをテスト"],
        "editor.testStepN":        ["试触第 %d 拍", "Test tap %d", "タップ %d をテスト"],
        "editor.deleteStep":       ["删除该拍", "Delete this tap", "このタップを削除"],
        "editor.deleteStepN":      ["删除第 %d 拍", "Delete tap %d", "タップ %d を削除"],
        "editor.newPatternName":   ["新模式", "New pattern", "新しいパターン"],
        "editor.copySuffix":       ["%@ 副本", "%@ Copy", "%@ のコピー"],
        "editor.duration":         ["约 %.1f 秒", "≈ %.1f s", "約 %.1f 秒"],

        // Editor · single-tap operations
        "editor.moveUp":           ["上移", "Move up", "上へ"],
        "editor.moveDown":         ["下移", "Move down", "下へ"],
        "editor.duplicateStep":    ["复制此拍", "Duplicate tap", "このタップを複製"],
        "editor.stepMore":         ["更多", "More", "その他"],

        // Editor · import / export
        "editor.import":           ["导入…", "Import…", "読み込み…"],
        "editor.export":           ["导出…", "Export…", "書き出し…"],
        "editor.copyJSON":         ["复制当前", "Copy current", "現在をコピー"],
        "editor.pasteJSON":        ["粘贴导入", "Paste import", "貼り付けて読み込み"],
        "editor.format":           ["格式说明", "Format help", "形式の説明"],
        "editor.copied":           ["已复制到剪贴板", "Copied to clipboard", "クリップボードにコピー"],
        "editor.imported":         ["已导入 %d 个模式", "Imported %d pattern(s)", "%d 件を読み込み"],
        "editor.pasteFailed":      ["剪贴板内容不是有效模式 JSON", "Clipboard isn't valid pattern JSON", "クリップボードは有効なパターン JSON ではありません"],
        "editor.copyExample":      ["复制范例", "Copy example", "例をコピー"],
        "editor.format.title":     ["模式 JSON 格式", "Pattern JSON format", "パターン JSON 形式"],
        "editor.format.body":      ["导出 / 导入使用下面这种精简 JSON（一个数组，可含多个模式），方便你用任意文本编辑器修改、或交给 AI 创作后再「导入」/「粘贴导入」回来。\n字段：\n· name 模式名称（字符串）\n· steps 单拍数组，每拍包含：\n   - timbre 音色：soft（轻点）/ crisp（清脆）/ buzz（低频嗡）\n   - strength 设计强度 1–10（运行时再乘全局强度）\n   - dullness 沉闷 0–1（0 清脆 → 1 沉闷）\n   - gapMs 本拍后到下一拍的间隔毫秒（末拍可为 0）",
                                    "Export / import uses the compact JSON below (an array that may hold several patterns), so you can edit it in any text editor or have an AI compose it, then “Import” / “Paste import” it back.\nFields:\n· name — pattern name (string)\n· steps — array of taps, each with:\n   - timbre: soft / crisp / buzz\n   - strength: design strength 1–10 (scaled by global strength at runtime)\n   - dullness: 0–1 (0 crisp → 1 dull)\n   - gapMs: gap in ms before the next tap (0 on the last one)",
                                    "書き出し / 読み込みは下記の簡潔な JSON（複数パターンを含められる配列）を使います。任意のテキストエディタで編集したり、AI に作らせてから「読み込み」/「貼り付けて読み込み」で戻せます。\nフィールド：\n· name パターン名（文字列）\n· steps タップ配列、各タップ：\n   - timbre 音色：soft / crisp / buzz\n   - strength 設計強度 1–10（実行時にグローバル強度を乗算）\n   - dullness 鈍さ 0–1（0 クリア → 1 鈍）\n   - gapMs 次のタップまでの間隔ミリ秒（最後は 0 可）"],

        // Pattern categories
        "patcat.basic":            ["基础", "Basic", "基本"],
        "patcat.nature":           ["自然", "Nature", "自然"],
        "patcat.rhythm":           ["节奏", "Rhythm", "リズム"],
        "patcat.custom":           ["自定义", "Custom", "カスタム"],

        // Context menu
        "menu.resume":             ["恢复计时", "Resume timer", "タイマーを再開"],
        "menu.pause":              ["暂停计时", "Pause timer", "タイマーを一時停止"],
        "menu.skip":               ["跳过本次", "Skip this one", "今回をスキップ"],
        "menu.breakNow":           ["立即震动一次", "Buzz now", "今すぐ振動"],
        "menu.settings":           ["设置…", "Settings…", "設定…"],
        "menu.stats":              ["统计…", "Statistics…", "統計…"],
        "menu.editor":             ["自定义震动模式…", "Custom patterns…", "カスタムパターン…"],
        "menu.checkUpdate":        ["检查更新…", "Check for Updates…", "アップデートを確認…"],
        "menu.about":              ["关于 HapticBreak…", "About HapticBreak…", "HapticBreak について…"],

        // Window titles
        "window.settings":         ["HapticBreak 设置", "HapticBreak Settings", "HapticBreak 設定"],
        "window.stats":            ["HapticBreak 统计", "HapticBreak Statistics", "HapticBreak 統計"],
        "window.hapticLab":        ["HapticBreak 震动实验室", "HapticBreak Haptic Lab", "HapticBreak 振動ラボ"],

        // Haptic backend
        "backend.auto":            ["自动（推荐）", "Automatic (recommended)", "自動（推奨）"],
        "backend.private":         ["完整震动（私有 API）", "Full haptics (private API)", "フル振動（プライベート API）"],
        "backend.public":          ["兼容震动（公开 API）", "Compatible haptics (public API)", "互換振動（公開 API）"],
        "backend.name.private":    ["MultitouchSupport · 私有 API", "MultitouchSupport · private API", "MultitouchSupport · プライベート API"],
        "backend.name.public":     ["NSHapticFeedback · 公开 API", "NSHapticFeedback · public API", "NSHapticFeedback · 公開 API"],

        // Menu-bar style
        "menustyle.iconCountdown": ["图标 + 倒计时", "Icon + countdown", "アイコン + カウントダウン"],
        "menustyle.iconOnly":      ["仅图标（紧凑）", "Icon only (compact)", "アイコンのみ（コンパクト）"],
        "menustyle.progressRing":  ["进度环", "Progress ring", "進捗リング"],

        // Built-in haptic pattern names
        "pattern.gentle":          ["轻拍", "Tap", "タップ"],
        "pattern.double":          ["双击", "Double", "ダブル"],
        "pattern.triple":          ["三连击", "Triple", "トリプル"],
        "pattern.heartbeat":       ["心跳", "Heartbeat", "ハートビート"],
        "pattern.ramp":            ["渐强", "Ramp up", "クレッシェンド"],
        "pattern.fade":            ["渐弱", "Fade out", "デクレッシェンド"],
        "pattern.breathe":         ["呼吸", "Breathe", "呼吸"],
        "pattern.ripple":          ["涟漪", "Ripple", "さざ波"],
        "pattern.heavy":           ["重锤", "Heavy", "ヘビー"],
        "pattern.urgent":          ["持续提醒", "Insistent", "しつこく"],
        "pattern.sos":             ["SOS", "SOS", "SOS"],
        // Natural
        "pattern.raindrops":       ["雨滴", "Raindrops", "雨だれ"],
        "pattern.waves":           ["海浪", "Waves", "波"],
        "pattern.thunder":         ["雷声", "Thunder", "雷"],
        "pattern.dripping":        ["滴水", "Dripping", "水滴"],
        "pattern.crackle":         ["篝火", "Campfire", "たき火"],
        "pattern.flutter":         ["振翅", "Flutter", "羽ばたき"],
        "pattern.tremor":          ["震颤", "Tremor", "震え"],
        "pattern.woodpecker":      ["啄木鸟", "Woodpecker", "キツツキ"],
        // Rhythm
        "pattern.waltz":           ["华尔兹", "Waltz", "ワルツ"],
        "pattern.march":           ["进行曲", "March", "行進曲"],
        "pattern.boomclap":        ["鼓点", "Boom-clap", "ブンチャ"],
        "pattern.clave":           ["克拉维", "Clave", "クラーベ"],
        "pattern.accelerando":     ["渐快", "Accelerando", "アッチェレランド"],
        "pattern.ritardando":      ["渐慢", "Ritardando", "リタルダンド"],
        "pattern.triplet":         ["三连音", "Triplet", "三連符"],
        "pattern.echo":            ["回声", "Echo", "エコー"],
        "pattern.pulse":           ["脉冲", "Pulse", "パルス"],
        "pattern.countdown":       ["倒计时", "Countdown", "カウントダウン"],
        "pattern.swing":           ["摇摆", "Swing", "スウィング"],
        "pattern.gallop":          ["疾驰", "Gallop", "ギャロップ"],
        "pattern.fate":            ["命运", "Fate", "運命"],
        "pattern.stomp":           ["跺脚拍手", "Stomp-Clap", "ストンプ"],
        "pattern.haircut":         ["理发调", "Shave & Haircut", "散髪リズム"],
        "pattern.darkmarch":       ["黑暗进行曲", "Dark March", "ダークマーチ"],

        // Haptic Lab — three-axis model (timbre × strength float0 × dullness float1) on-device calibration bench
        "lab.title":               ["震动实验室", "Haptic Lab", "振動ラボ"],
        "lab.subtitle":            ["把一根手指放在触摸板上。震动采用三轴：音色族 × 强度(1–10→float0) × 沉闷(float1)，弃用档位、固定 flags=0。从上到下：① 为三音色族指派代表 ID；② 试听 1→10 强度曲线；③ 浏览全部音色 × 三档（挑 ID 用）；④ 原始探针做底层验证。",
                                    "Rest a finger on the trackpad. Haptics use three axes: timbre × strength (1–10→float0) × dullness (float1), with presets dropped and flags fixed at 0. Top to bottom: ① assign a representative ID to each of the 3 timbres; ② audition the 1→10 strength curve; ③ browse all timbres × 3 presets (to pick IDs); ④ verify at the low level with the raw probe.",
                                    "指をトラックパッドに置いてください。振動は 3 軸を使います：音色 × 強さ(1–10→float0) × 鈍さ(float1)、プリセットは廃止し flags=0 固定。上から：① 3 音色に代表 ID を割り当て、② 1→10 強度カーブを試聴、③ 全音色 × 3 プリセットを一覧（ID 選び用）、④ 原始プローブで低レベル検証。"],
        "lab.fireOnDrag":          ["滑动即震（拖滑条/改参数立即触发）", "Fire while dragging", "ドラッグで発火"],
        "lab.diag.ready":          ["私有 API 可用", "Private API ready", "プライベート API 利用可"],
        "lab.diag.unavailable":    ["私有 API 不可用", "Private API unavailable", "プライベート API 利用不可"],
        "lab.unavailable.note":    ["未找到可用的触摸板致动器（私有 API）。震动实验室需要内置 Force Touch 触摸板。",
                                    "No trackpad actuator (private API) found. Haptic Lab needs a built-in Force Touch trackpad.",
                                    "利用可能なトラックパッドアクチュエータ（プライベート API）が見つかりません。振動ラボには内蔵 Force Touch トラックパッドが必要です。"],

        // Timbre-family assignment (production)
        "lab.timbre.title":        ["音色族指派（生产 · 即时生效 · 跨启动保留）", "Timbre assignment · production (live · persisted)", "音色の割り当て · 本番（即時 · 永続）"],
        "lab.timbre.hint":        ["为「轻点 / 清脆 / 低频嗡」三族各指定一个代表 actuationID。同族多个 ID 体感等价（实测 1≈3≈5、2≈4≈6、15≈16），从下面「致动浏览器」挑一个写到这里即可。",
                                    "Assign a representative actuationID to each of Soft / Crisp / Low-buzz. IDs within a family feel the same (measured 1≈3≈5, 2≈4≈6, 15≈16) — pick one from the Actuation browser below and set it here.",
                                    "Soft / Crisp / Low-buzz の各族に代表 actuationID を割り当て。同族の ID は体感が同じ（実測 1≈3≈5、2≈4≈6、15≈16）。下の一覧から 1 つ選んで設定してください。"],

        // Strength curve 1→10 (production)
        "lab.curve.title":         ["强度曲线 1→10（生产手感）", "Strength curve 1→10 (in-app feel)", "強度カーブ 1→10（本番の手触り）"],
        "lab.curve.hint":         ["选音色 + 沉闷，逐级试 1→10 强度（float0 线性主控）——与 App 实际播放完全一致。点「试 1→10」端到端确认单调可分。",
                                    "Pick a timbre + dullness and sweep strength 1→10 (float0 master) — identical to what the app plays. Tap “Test 1→10” to confirm it's monotonic and distinct end-to-end.",
                                    "音色 + 鈍さを選び、強さ 1→10（float0 主制御）を試す——アプリの再生と完全一致。「1→10 を試す」で通し確認。"],
        "lab.curve.strength":      ["强度 1–10", "Strength 1–10", "強さ 1–10"],
        "lab.curve.dullness":      ["沉闷 float1", "Dullness float1", "鈍さ float1"],
        "lab.curve.preview":       ["试 1→10", "Test 1→10", "1→10 を試す"],
        "lab.curve.now":           ["强度 %d · ID %d", "Strength %d · ID %d", "強さ %d · ID %d"],

        // Actuation browser (all timbres × three levels)
        "lab.browser.title":       ["致动浏览器 · 全部音色 × 三档", "Actuation browser · all timbres × 3 presets", "アクチュエーション一覧 · 全音色 × 3 プリセット"],
        "lab.browser.hint":        ["逐一感受 8 个致动（音色）在 Light / Medium / Firm 三档下的真实手感（主缩放=1.0），用它为上面三族挑代表 ID。",
                                    "Feel each of the 8 actuations (timbres) at Light / Medium / Firm (master scale = 1.0); use it to pick the representative IDs for the 3 timbres above.",
                                    "8 つのアクチュエーション（音色）を Light / Medium / Firm（主スケール=1.0）で体感し、上の 3 音色の代表 ID を選びます。"],

        "lab.wf.1":                ["弱点击", "Weak click", "弱クリック"],
        "lab.wf.2":                ["强点击", "Strong click", "強クリック"],
        "lab.wf.3":                ["蜂鸣", "Buzz", "ブザー"],
        "lab.wf.4":                ["轻拍", "Light tap", "軽いタップ"],
        "lab.wf.5":                ["中拍", "Medium tap", "中タップ"],
        "lab.wf.6":                ["重拍", "Strong tap", "強いタップ"],
        "lab.wf.15":               ["软撞击", "Soft thud", "ソフトな衝撃"],
        "lab.wf.16":               ["强撞击", "Strong thud", "強い衝撃"],

        "lab.stop":                ["停止", "Stop", "停止"],
        "lab.footer":              ["提示：致动器为一次性，每次触发都会重建并 close；ret 0x0 表示调用成功。音色族指派改完即时写入并跨启动保留。设计与底层语义详见 docs/HAPTIC_V2_DESIGN.md 与 docs/HAPTIC_API_REVERSE_ENGINEERING.md。",
                                    "Note: the actuator is single-shot — each fire recreates and closes it; ret 0x0 means success. Timbre assignments apply instantly and persist across launches. Design & low-level semantics: docs/HAPTIC_V2_DESIGN.md and docs/HAPTIC_API_REVERSE_ENGINEERING.md.",
                                    "メモ：アクチュエータは単発で、毎回再生成して close します。ret 0x0 は成功。音色の割り当ては即時反映・永続。設計と低レベル仕様は docs/HAPTIC_V2_DESIGN.md と docs/HAPTIC_API_REVERSE_ENGINEERING.md を参照。"],

        // Haptic Lab · raw actuation probe (Light/Medium/Firm empirical)
        "lab.raw.title":           ["原始致动探针 · Light/Medium/Firm 实证", "Raw actuation probe · Light/Medium/Firm", "原始アクチュエーション · Light/Medium/Firm 実証"],
        "lab.raw.hint":            ["直驱 MTActuatorActuate 全参数、实证强度模型：选「强度档」并保持 float0=1.0，即用 Apple 按机型（ActuatorRevision）调好的 Light/Medium/Firm 曲线（含音色、跨机一致）。float0 才是真正的主缩放；float1 只改基础脉冲宽度（夹 4–8ms）。点「试 Light→Medium→Firm」确认三档单调可分。",
                                    "Drive every MTActuatorActuate parameter to ground-truth the strength model: pick a preset and keep float0=1.0 to use Apple's per-model (ActuatorRevision) Light/Medium/Firm curves (with timbre, consistent across machines). float0 is the real master scale; float1 only changes base pulse width (clamped 4–8 ms). Tap “Test Light→Medium→Firm” to confirm the three are monotonic and distinct.",
                                    "MTActuatorActuate の全引数を直接駆動して強度モデルを実証：プリセットを選び float0=1.0 のままにすると、Apple が機種（ActuatorRevision）ごとに調整した Light/Medium/Firm 曲線（音色付き・機種間で一貫）を使用します。float0 が本当の主スケール、float1 は基本パルス幅のみ（4–8ms に固定）。「Light→Medium→Firm を試す」で 3 段が単調かつ識別可能かを確認。"],
        "lab.raw.id":              ["Actuation ID", "Actuation ID", "Actuation ID"],
        "lab.raw.strength":        ["强度档（flags）", "Preset (flags)", "プリセット（flags）"],
        "lab.raw.none":            ["不选档", "None", "なし"],
        "lab.raw.scale":           ["主缩放 float0", "Master float0", "主スケール float0"],
        "lab.raw.time":            ["沉闷 float1", "Dullness float1", "鈍さ float1"],
        "lab.raw.fire":            ["试触", "Fire", "発火"],
        "lab.raw.sweep":           ["试 Light→Medium→Firm", "Test Light→Medium→Firm", "Light→Medium→Firm を試す"],
        "lab.raw.now":             ["ID %d · %@", "ID %d · %@", "ID %d · %@"],

        "settings.openLab":        ["震动实验室（真机标定）…", "Haptic Lab (device calibration)…", "振動ラボ（実機キャリブレーション）…"],
        "help.openLab":            ["打开震动实验室，真机感受波形与振幅", "Open Haptic Lab to feel waveforms and amplitude on-device", "振動ラボを開いて波形と振幅を実機で体感"],
    ]
}
