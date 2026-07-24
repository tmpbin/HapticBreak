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
    /// Shared preference store (in-memory in ephemeral runs — never bypass to UserDefaults directly).
    private let store: KeyValueStore = RuntimeMode.settingsDefaults()

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            if suppressPersist { return }
            store.set(language.rawValue, forKey: Self.storageKey)
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
        let raw = (store.object(forKey: Self.storageKey) as? String) ?? AppLanguage.system.rawValue
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
        "status.reminding":        ["该休息了", "Time for a break", "休憩の時間"],
        "status.breakShort":       ["休息", "Break", "休憩"],
        "status.paused":           ["已暂停", "Paused", "一時停止中"],
        "status.idlePaused":       ["空闲暂停", "Paused (idle)", "アイドルで一時停止"],
        "status.focusPaused":      ["专注模式暂停", "Paused (Focus)", "集中モードで一時停止"],
        "status.fullscreenPaused": ["全屏应用暂停", "Paused (full screen)", "フルスクリーンで一時停止"],
        "status.meetingPaused":    ["通话/会议暂停", "Paused (call/meeting)", "通話/会議で一時停止"],
        "status.scenePaused":      ["今天已收工", "Done for today", "今日は終了"],
        "status.resting":          ["休息中", "Resting", "休憩中"],
        "status.working":          ["工作中", "Working", "作業中"],
        "status.available":        ["可用", "Available", "利用可能"],
        "status.unavailable":      ["不可用", "Unavailable", "利用不可"],

        // Control panel (Popover)
        "popover.nextReminder":    ["下次提醒 %@", "Next at %@", "次は %@"],
        "popover.todayBreaks":     ["今日已休息 %d 次", "%d breaks today", "今日 %d 回休憩"],
        "popover.noActuator":      ["未检测到可用触摸板致动器，提醒将无震动",
                                    "No trackpad actuator detected; reminders won't vibrate",
                                    "トラックパッドのアクチュエータが見つかりません。リマインドは振動しません"],
        "popover.cycleMode":       ["工作 %d + 休息 %d 分钟", "Work %d + rest %d min", "作業 %d + 休憩 %d 分"],
        "popover.firstIntro":      ["到点后会重复提醒，直到你确认或离开电脑。",
                                    "When it's time, I'll keep reminding until you acknowledge — or step away.",
                                    "時間になったら、確認するか席を立つまで繰り返し知らせます。"],
        "popover.bandHelp":        ["今天的节奏：色块深浅 = 工作密度，圆点 = 真实休息",
                                    "Today's rhythm: shading = activity, dots = real breaks",
                                    "今日のリズム：濃淡 = 活動量、点 = 実際の休憩"],
        "popover.remindingHint":   ["确认，或离开 30 秒，休息即开始",
                                    "Acknowledge — or step away 30 s — and the break begins",
                                    "確認するか 30 秒席を離れると休憩が始まります"],
        "popover.nudgeHint.title": ["还没确认？试试这样：",
                                    "Haven't acknowledged? Try this:",
                                    "まだ確認していませんか？こうしてみて："],
        "popover.nudgeHint.body":  ["三指在触摸板上轻敲三次即可确认——或者直接离开电脑 30 秒也算确认。也可以点击上方「开始休息」按钮。",
                                    "Triple-tap the trackpad with three fingers to acknowledge — or simply step away for 30 seconds. You can also click \"Start break\" above.",
                                    "トラックパッドを3本指でトリプルタップすると確認できます。30秒席を離れても確認になります。上の「休憩を開始」ボタンでもOKです。"],

        // Auto-pause transparency: say (once) why we're quiet and that it self-resumes
        "popover.resume.idle":       ["回来后自动继续", "Resumes when you're back", "戻ると自動で再開"],
        "popover.resume.fullscreen": ["退出全屏后自动继续", "Resumes after full screen", "フルスクリーン終了後に再開"],
        "popover.resume.meeting":    ["通话结束后自动继续", "Resumes after your call", "通話終了後に再開"],
        "popover.resume.focus":      ["勿扰结束后自动继续", "Resumes after Focus", "集中モード終了後に再開"],

        // Rest-phase companion tips (rotated in the ring's status line)
        "tip.rest.1":              ["站起来，伸个懒腰", "Stand up and stretch", "立ち上がって伸びを"],
        "tip.rest.2":              ["看看 6 米外的东西", "Look at something far away", "遠くのものを見て"],
        "tip.rest.3":              ["倒杯水，喝一口", "Get some water", "水を一杯どうぞ"],
        "tip.rest.4":              ["深呼吸，放松肩膀", "Breathe. Drop your shoulders", "深呼吸して肩の力を抜いて"],

        // Quiet scenes: bounded, self-restoring "not now" decisions
        "scene.menu":              ["场景", "Scenes", "シーン"],
        "scene.focus90":           ["专注 90 分钟", "Focus for 90 min", "90 分集中"],
        "scene.meeting60":         ["静音 1 小时", "Quiet for 1 hour", "1 時間静かに"],
        "scene.doneToday":         ["今天到此为止", "Done for today", "今日はここまで"],
        "scene.until":             ["静音至 %@，之后自动继续", "Quiet until %@, then resumes", "%@ まで静かに、以後再開"],
        "scene.untilTomorrow":     ["今天到此为止，明早自动回来", "Done for today — back tomorrow morning", "今日はここまで。明朝に再開"],
        "scene.cancel":            ["取消", "Cancel", "キャンセル"],

        // Ring click hints (hover preview of the primary action)
        "ring.tapPause":           ["点按暂停", "Click to pause", "クリックで一時停止"],
        "ring.tapResume":          ["点按继续", "Click to resume", "クリックで再開"],
        "ring.tapAck":             ["点按开始休息", "Click to start break", "クリックで休憩開始"],

        "help.dice":               ["随机试一个模式", "Try a random pattern", "ランダムに試す"],

        "action.resume":           ["恢复", "Resume", "再開"],
        "action.pause":            ["暂停", "Pause", "一時停止"],
        "action.skip":             ["跳过", "Skip", "スキップ"],
        "action.postpone":         ["+%d分", "+%dm", "+%d分"],
        "action.acknowledge":      ["开始休息", "Start break", "休憩する"],

        "label.interval":          ["提醒间隔", "Interval", "間隔"],
        "label.pattern":           ["震动模式", "Pattern", "パターン"],
        "label.intensity":         ["强度", "Strength", "強さ"],
        "action.testHaptic":       ["试震", "Test", "テスト"],
        "help.testHaptic":         ["立即试触当前震动模式", "Feel the current pattern now", "現在のパターンを今すぐ体感"],

        // Event patterns (different events use different timbres / patterns)
        "label.reminderPattern":   ["休息提醒", "Break reminder", "休憩リマインド"],
        "label.headsUpPattern":    ["休息前预告", "Heads-up", "予告"],
        "label.finishPattern":     ["休息结束", "Break finished", "休憩終了"],
        "label.screenFlash":       ["屏幕", "Screen", "画面"],

        // Timbre families (one of the three axes: timbre)
        "timbre.soft":             ["轻点", "Soft", "ソフト"],
        "timbre.crisp":            ["清脆", "Crisp", "クリア"],
        "timbre.buzz":             ["低频嗡", "Low buzz", "低周波"],

        "footer.settings":         ["设置", "Settings", "設定"],
        "footer.stats":            ["统计", "Stats", "統計"],
        "footer.quit":             ["退出", "Quit", "終了"],

        "help.resume":             ["恢复计时（⌃⌥Space）", "Resume timer (⌃⌥Space)", "タイマーを再開（⌃⌥Space）"],
        "help.pause":              ["暂停计时（⌃⌥Space）", "Pause timer (⌃⌥Space)", "タイマーを一時停止（⌃⌥Space）"],
        "help.skip":               ["跳过本次，重新开始计时（⌃⌥S）",
                                    "Skip this one and restart the timer (⌃⌥S)",
                                    "今回をスキップしてタイマーを再開（⌃⌥S）"],
        "help.postpone":           ["推迟 %d 分钟", "Postpone %d min", "%d 分延期"],
        "help.acknowledge":        ["确认提醒并开始休息（%@）",
                                    "Acknowledge and start the break (%@)",
                                    "リマインドを確認して休憩を開始（%@）"],
        "help.openSettings":       ["打开设置", "Open Settings", "設定を開く"],
        "help.openStats":          ["查看休息统计", "View break stats", "休憩の統計を見る"],
        "help.quit":               ["退出 HapticBreak", "Quit HapticBreak", "HapticBreak を終了"],

        // Settings
        "settings.tab.basic":      ["基本", "Basic", "基本"],
        "settings.tab.advanced":   ["高级", "Advanced", "詳細"],
        "settings.section.cycle":  ["节奏", "Cycle", "リズム"],
        "settings.cycleFooter":    ["到点后每 %1$d 秒重复完整提醒（%2$@），直到你确认或真的离开；多次未确认会弹出教学提示，之后自动推迟。",
                                    "When time's up, the full reminder (%2$@) repeats every %1$d s until you acknowledge or step away. After several unanswered nudges a teaching hint pops up, then it auto-postpones.",
                                    "時間になると、完全なリマインド（%2$@）が %1$d 秒ごとに繰り返されます。確認するか離席すると停止します。数回応答がなければヒントが表示され、その後自動延期されます。"],
        "settings.restOff":        ["不休息（仅提醒）", "No rest segment (reminder only)", "休憩なし（リマインドのみ）"],
        "settings.restN":          ["每次休息 %d 分钟", "Rest %d min per break", "毎回 %d 分休憩"],
        "settings.section.haptic": ["震动", "Haptics", "振動"],
        "settings.section.acknowledge": ["确认", "Acknowledge", "確認"],
        "settings.ackGesture":     ["三指三击触摸板确认", "Three-finger triple-tap to acknowledge", "3本指トリプルタップで確認"],
        "settings.ackFooter":      ["确认即停止提醒。真的离开电脑也算确认——什么都不用按。",
                                    "Acknowledging stops the reminder. Actually stepping away counts too — no buttons needed.",
                                    "確認するとリマインドが止まります。実際に席を離れても確認になります——何も押す必要はありません。"],
        "settings.section.reminderBehavior": ["提醒行为", "Reminder behavior", "リマインドの挙動"],
        "settings.pulseInterval":  ["未确认时每 %d 秒再提醒", "Re-remind every %d s until acknowledged", "確認まで %d 秒ごとに再リマインド"],
        "settings.pulseMax":       ["最多提醒 %d 次后自动推迟", "Auto-postpone after %d nudges", "%d 回通知後に自動延期"],
        "settings.alertsFooter":   ["震动之外的辅助提醒通道，可按需开启；开启提示音后可挑选音色并试听。",
                                    "Extra alert channels beyond haptics — enable as you like; once Sound is on, pick a tone and preview it.",
                                    "触覚以外の補助的な通知。必要に応じて有効化でき、サウンドをオンにすると音色を選んで試聴できます。"],
        "settings.backendFooter":  ["「自动」会优先使用完整震动，不可用时回退到兼容震动。一般保持自动即可。",
                                    "“Automatic” prefers full haptics and falls back to compatible haptics when unavailable. Leave it on Automatic in most cases.",
                                    "「自動」はフル振動を優先し、利用できない場合は互換振動に切り替えます。通常は自動のままで構いません。"],
        "settings.intensityFull":  ["震动强度", "Haptic strength", "振動の強さ"],
        "btn.test":                ["试触", "Test", "テスト"],
        "settings.typingDefer":    ["打字时等停顿再提醒", "Wait for a typing pause", "入力の区切りを待つ"],
        "settings.headsUp":        ["休息前 30 秒轻点预告", "Gentle heads-up 30s before", "休憩 30 秒前にそっと予告"],
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
        "settings.section.hotkeys":["全局快捷键", "Global shortcuts", "グローバルショートカット"],
        "settings.hotkeysFooter":  ["点按组合键即可录制新快捷键（⎋ 取消）；需包含 ⌃ / ⌥ / ⌘，无需辅助功能权限。",
                                    "Click a combo to record a new shortcut (⎋ cancels); it must include ⌃ / ⌥ / ⌘. No Accessibility permission needed.",
                                    "コンビネーションをクリックすると新しいショートカットを記録できます（⎋ でキャンセル）。⌃ / ⌥ / ⌘ を含む必要があります。アクセシビリティ権限は不要です。"],
        "hotkey.pause":            ["暂停 / 恢复", "Pause / Resume", "一時停止 / 再開"],
        "hotkey.skip":             ["跳过本次", "Skip this one", "今回をスキップ"],
        "hotkey.buzz":             ["立即震动", "Buzz now", "今すぐ振動"],
        "hotkey.ack":              ["开始休息（确认提醒）", "Start break (acknowledge)", "休憩を開始（確認）"],
        "hotkey.recording":        ["按下新组合键…", "Press new combo…", "新しいキーを押す…"],
        "hotkey.taken":            ["已被其他动作占用", "Already used by another action", "他のアクションで使用中"],
        "hotkey.needModifier":     ["需包含 ⌃ / ⌥ / ⌘", "Include ⌃ / ⌥ / ⌘", "⌃ / ⌥ / ⌘ が必要"],
        "hotkey.reset":            ["恢复默认快捷键", "Restore default shortcuts", "ショートカットをデフォルトに戻す"],
        "hotkey.conflictWarning":  ["以下组合键被其他应用占用，未能注册：%@",
                                    "Taken by another app, could not register: %@",
                                    "他のアプリが使用中のため登録できません：%@"],
        "hotkey.ackHint":          ["%@  开始休息 / 确认提醒", "%@  Start break / acknowledge", "%@  休憩を開始 / 確認"],
        "settings.openEditorBtn":  ["打开编辑器…", "Open editor…", "エディタを開く…"],
        "settings.autoUpdate":     ["自动检查更新", "Automatically check for updates", "自動的にアップデートを確認"],
        "settings.checkUpdate":    ["检查更新", "Check for updates", "アップデートを確認"],
        "settings.checkNow":       ["立即检查", "Check now", "今すぐ確認"],
        "settings.resetBtn":       ["恢复…", "Restore…", "リセット…"],
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
        "settings.about":          ["用触摸板震动提醒你起身休息的 macOS 应用——无声、无弹窗、不打断心流。目前为 Beta 公测版，欢迎反馈。",
                                    "A macOS app that taps your break reminder into your palm through trackpad haptics — silent, no pop-ups, never breaking your flow. Currently in beta; feedback welcome.",
                                    "トラックパッドの振動で休憩を知らせる macOS アプリ——無音・ポップアップなし・フローを妨げません。現在ベータ版です。フィードバック歓迎。"],

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
        "stats.cycles":            ["完整循环", "Cycles", "サイクル"],
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
        "editor.canvasHint":       ["点按一拍：选中并试听 · 在拍子上下拖动：直接改强度 · 拍子间距即间隔",
                                    "Tap a beat to select & preview · drag a beat vertically for strength · spacing = the gap",
                                    "タップで選択・試聴 · 縦ドラッグで強さを調整 · 間隔はバーの間隔"],
        "editor.testAll":          ["试触整段", "Test all", "全体をテスト"],
        "editor.save":             ["保存", "Save", "保存"],
        "editor.saved":            ["已保存并设为当前模式", "Saved and set as current", "保存して現在のパターンに設定"],
        "editor.stepN":            ["第 %d 拍", "Tap %d", "タップ %d"],
        "editor.strength":         ["强度", "Strength", "強さ"],
        "editor.dullness":         ["沉闷", "Dullness", "鈍さ"],
        "editor.fireOnDrag":       ["滑动即震", "Fire while dragging", "ドラッグで発火"],
        "editor.unify":            ["整条统一", "Unify all", "全体を統一"],
        "editor.unifyTimbre":      ["全部用此音色", "Use this timbre for all", "全タップをこの音色に"],
        "editor.unifyDullness":    ["沉闷统一为第 1 拍", "Match dullness to tap 1", "鈍さをタップ 1 に合わせる"],
        "editor.gapToNext":        ["与下一拍间隔", "Gap to next", "次との間隔"],
        "editor.deleteStep":       ["删除该拍", "Delete this tap", "このタップを削除"],
        "editor.newPatternName":   ["新模式", "New pattern", "新しいパターン"],
        "editor.copySuffix":       ["%@ 副本", "%@ Copy", "%@ のコピー"],
        "editor.duration":         ["约 %.1f 秒", "≈ %.1f s", "約 %.1f 秒"],

        // Editor · single-tap operations
        "editor.moveLeft":         ["左移一拍", "Move left", "左へ"],
        "editor.moveRight":        ["右移一拍", "Move right", "右へ"],
        "editor.duplicateStep":    ["复制此拍", "Duplicate tap", "このタップを複製"],
        "editor.advanced":         ["高级：沉闷度 · 整条统一 · JSON 导入导出",
                                    "Advanced: dullness · unify · JSON import/export",
                                    "詳細：鈍さ · 一括統一 · JSON 読み書き"],

        // Editor · tap-a-rhythm recording
        "editor.record":           ["敲一段节奏", "Tap a rhythm", "リズムをタップ"],
        "editor.recordHint":       ["心里想着一段节奏，照它敲下面的三只鼓（或按键盘 J / K / L）——每次敲击就是一拍，敲击之间的时间就是拍与拍的间隔。",
                                    "Think of a rhythm and play it on the three drums below (or press J / K / L) — every hit becomes a beat, and the time between hits becomes the gap.",
                                    "頭の中のリズムに合わせて下の 3 つのドラムを叩く（またはキーボードの J / K / L）——1 打が 1 拍になり、打つ間隔がそのまま拍の間隔になります。"],
        "editor.recordUse":        ["用这段节奏（%d 拍）", "Use this rhythm (%d taps)", "このリズムを使う（%d 拍）"],

        // Editor · recording transport & status
        "editor.rec.recording":    ["录制中", "Recording", "録音中"],
        "editor.rec.paused":       ["已暂停", "Paused", "一時停止"],
        "editor.rec.empty":        ["敲击下方鼓垫或按 J/K/L 开始录制节奏…",
                                    "Hit the drum pads below or press J / K / L to start…",
                                    "下のパッドを叩くか J / K / L を押してリズムを録音…"],
        "editor.rec.clear":        ["清空", "Clear", "クリア"],
        "editor.rec.pause":        ["暂停", "Pause", "一時停止"],
        "editor.rec.resume":       ["继续", "Resume", "再開"],
        "editor.rec.play":         ["试听", "Play", "再生"],
        "editor.rec.rerecord":     ["重录", "Re-record", "録り直す"],

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
        "menu.acknowledge":        ["开始休息", "Start break", "休憩を開始"],
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
        "window.about":            ["关于 HapticBreak", "About HapticBreak", "HapticBreak について"],

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
        "pattern.ripple":          ["涟漪", "Ripple", "さざ波"],
        "pattern.urgent":          ["急促", "Insistent", "しつこく"],
        "pattern.sos":             ["SOS", "SOS", "SOS"],
        // Natural
        "pattern.dripping":        ["滴水", "Dripping", "水滴"],
        "pattern.flutter":         ["振翅", "Flutter", "羽ばたき"],
        "pattern.woodpecker":      ["啄木鸟", "Woodpecker", "キツツキ"],
        // Rhythm
        "pattern.boomclap":        ["鼓点", "Boom-clap", "ブンチャ"],
        "pattern.accelerando":     ["渐快（坠落）", "Accelerando", "アッチェレランド"],
        "pattern.ritardando":      ["渐慢（回弹）", "Ritardando", "リタルダンド"],
        "pattern.triplet":         ["三连音", "Triplet", "三連符"],
        "pattern.echo":            ["回声", "Echo", "エコー"],
        "pattern.pulse":           ["脉冲", "Pulse", "パルス"],
        "pattern.countdown":       ["倒计时", "Countdown", "カウントダウン"],
        "pattern.gallop":          ["疾驰", "Gallop", "ギャロップ"],
        "pattern.fate":            ["命运", "Fate", "運命"],
        "pattern.stomp":           ["跺脚拍手", "Stomp-Clap", "ストンプ"],
        "pattern.haircut":         ["理发调", "Shave & Haircut", "散髪リズム"],
        "pattern.darkmarch":       ["黑暗进行曲", "Dark March", "ダークマーチ"],
        "pattern.jingle":          ["铃儿响叮当", "Jingle Bells", "ジングルベル"],
        "pattern.birthday":        ["生日快乐", "Happy Birthday", "ハッピーバースデー"],
        "pattern.frere":           ["两只老虎", "Frère Jacques", "グーチョキパー"],
        "pattern.chime":           ["上课铃", "Westminster", "学校のチャイム"],
        "pattern.mission":         ["秘密任务", "Secret Mission", "スパイのテーマ"],

        // Haptic Lab — per-machine feel calibration (timbre feel check + strength curve audition)
        "lab.title":               ["震动实验室", "Haptic Lab", "振動ラボ"],
        "lab.subtitle":            ["把一根手指轻放在触摸板上，校准这台电脑的震动手感：先确认三种音色都能清楚感到，再从 1 到 10 试一遍强度。",
                                    "Rest a finger on the trackpad and calibrate how haptics feel on this machine: first make sure all three timbres come through clearly, then audition the strength scale from 1 to 10.",
                                    "指をトラックパッドに軽く置いて、このマシンの振動の手触りを調整します。まず 3 つの音色がはっきり感じられるか確認し、次に強さ 1→10 を通して試します。"],
        "lab.fireOnDrag":          ["滑动即震", "Fire while dragging", "ドラッグで発火"],
        "lab.try":                 ["试触", "Try it", "試す"],
        "lab.diag.ready":          ["震动引擎正常", "Haptic engine ready", "振動エンジン正常"],
        "lab.diag.unavailable":    ["震动引擎不可用", "Haptic engine unavailable", "振動エンジン利用不可"],
        "lab.unavailable.note":    ["未找到可用的触摸板致动器。震动实验室需要内置 Force Touch 触摸板。",
                                    "No trackpad actuator found. Haptic Lab needs a built-in Force Touch trackpad.",
                                    "利用可能なトラックパッドアクチュエータが見つかりません。振動ラボには内蔵 Force Touch トラックパッドが必要です。"],

        // Timbre feel check
        "lab.timbre.title":        ["三种音色", "The three timbres", "3 つの音色"],
        "lab.timbre.hint":         ["所有震动模式都由这三种音色组成。逐个试触；若某种在这台机器上感觉不对，换一个备选手感（立即生效、跨启动保留）。",
                                    "Every pattern is built from these three timbres. Try each one; if a timbre feels wrong on this machine, switch it to an alternative feel (applies instantly, persists across launches).",
                                    "すべてのパターンはこの 3 音色からできています。順に試して、このマシンで感触が合わない音色があれば別の感触に切り替えてください（即時反映・永続）。"],
        "lab.timbre.desc.soft":    ["最轻的一下，用于弱拍与预告", "The lightest tap — weak beats & heads-ups", "最も軽い一打——弱拍と予告に"],
        "lab.timbre.desc.crisp":   ["干净利落的敲击，节奏的主角", "A clean click — the backbone of rhythms", "切れのよいクリック——リズムの主役"],
        "lab.timbre.desc.buzz":    ["低沉的嗡震，用于重拍与钟声", "A deep buzz — downbeats & bells", "低いうなり——強拍とベルに"],
        "lab.reset":               ["恢复默认手感", "Restore default feels", "デフォルトの感触に戻す"],

        // Strength curve 1→10
        "lab.curve.title":         ["强度 1→10", "Strength 1→10", "強さ 1→10"],
        "lab.curve.hint":          ["与 App 实际播放完全一致的强度标尺。拖动逐级感受，或点「从 1 试到 10」听整条曲线——每一级都应比上一级更明显。",
                                    "The exact strength scale the app plays. Drag to feel each level, or tap “Play 1 to 10” for the whole curve — every level should feel clearly stronger than the last.",
                                    "アプリの再生と完全に一致する強さの目盛りです。ドラッグして 1 段ずつ感じるか、「1→10 を再生」で通して確認——各段が前の段よりはっきり強く感じられるはずです。"],
        "lab.curve.strength":      ["强度 1–10", "Strength 1–10", "強さ 1–10"],
        "lab.curve.preview":       ["从 1 试到 10", "Play 1 to 10", "1→10 を再生"],
        "lab.curve.now":           ["强度 %d", "Strength %d", "強さ %d"],

        // Alternative actuation feels (per-machine)
        "lab.wf.1":                ["弱点击", "Weak click", "弱クリック"],
        "lab.wf.2":                ["强点击", "Strong click", "強クリック"],
        "lab.wf.3":                ["蜂鸣", "Buzz", "ブザー"],
        "lab.wf.4":                ["轻拍", "Light tap", "軽いタップ"],
        "lab.wf.5":                ["中拍", "Medium tap", "中タップ"],
        "lab.wf.6":                ["重拍", "Strong tap", "強いタップ"],
        "lab.wf.15":               ["软撞击", "Soft thud", "ソフトな衝撃"],
        "lab.wf.16":               ["强撞击", "Strong thud", "強い衝撃"],

        "lab.stop":                ["停止", "Stop", "停止"],
        "lab.footer":              ["这里的调整只改变震动在这台机器上的手感，不影响任何模式的节奏设计。",
                                    "Adjustments here only change how haptics feel on this machine; they never alter a pattern's rhythm.",
                                    "ここでの調整はこのマシンでの感触だけを変えます。パターンのリズム設計には影響しません。"],
    ]
}
