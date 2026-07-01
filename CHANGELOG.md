# 更新日志

本文件记录 HapticBreak 的全部值得关注的变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> 发布约定：`.github/workflows/release.yml` 会在推送 `vX.Y.Z` 标签时，
> **自动抽取本文件中对应版本段落作为 GitHub Release 的发布说明**。
> 因此每次发版前，请把改动写在下方对应的版本标题（`## [X.Y.Z]`）之下。

## [Unreleased]

## [1.1.0] - 2026-07-02

### Added
- **音乐节奏预设**：新增可凭手感辨识的经典节奏动机——命运（贝多芬第五）、跺脚拍手
  （We Will Rock You）、理发店七拍、暗黑进行曲；并将节奏类模式延长到至少两个完整小节，更「像一首曲子」。
- **内置模式扩充至 35 种**，分为基础 / 自然 / 节奏三类；配合可逐拍编排的自定义模式编辑器与 JSON 导入导出。
- **菜单栏「关于 HapticBreak」入口**。
- **倒计时圆环流光扩展到灰色轨道**：整环随能量流动而「活」起来，而不仅是已点亮部分。
- **调试入口 `--rhythms`**：在触摸板上依次感受全部节奏动机，便于按手感调校。
- **应用内自动升级**：新版本经 EdDSA 签名校验后后台静默更新；菜单栏与
  「设置 → 系统」均提供「立即检查更新」，可开关自动检查。未配置签名密钥时自动禁用、不影响构建与发布。
- **发布流水线扩展**：配置 `UPDATE_PRIVATE_KEY` 后，`release.yml` 自动 `generate_appcast`
  签名升级源并发布到 `gh-pages`（方案 A：appcast 托管于同仓库 GitHub Pages）。
- `packaging/autoupdate/`：一键密钥生成脚本 `setup-keys.sh`、appcast 源地址配置与接入说明。
- **标准单元测试** `Tests/HapticBreakTests`（43 条）：覆盖计时状态机、诚实休息、圆环真相层、
  统计存储、偏好持久化/迁移、自定义模式导入导出。`swift test` 现已可用。
- **发布前门禁** `scripts/release-check.sh`：一条命令串联「构建 → 单测 → CLI 冒烟
  （`--logictest` / `--checkenv`）→ 界面走查（`--rendershots`）→ 打包」。

### Changed
- **全局强度分级从 1–5 扩展到 1–10**，标定曲线更细腻；原有偏好按 ×2 自动迁移。
- **全部源码注释统一为英文**（保留三语 UI 文案与可追溯 issue 标记）。
- `build.sh`：自动写入升级所需的 `SU*` Info.plist 键、嵌入升级框架到
  `Contents/Frameworks` 并由内向外逐层重签名（XPC 服务 / Updater.app / Autoupdate / 框架）。
- `build.sh`：按主程序架构自动**瘦身升级框架**（arm64 单架构 App 会移除多余的 x86_64 slice），
  `.app` 约 4.3 MB → 3.1 MB、DMG 约 1.7 MB → 1.3 MB，功能无损。
- 「关于」版本号改为读取打包写入的 `CFBundleShortVersionString`，与发布 tag 一致、不再硬编码。
- `Package.resolved` 纳入版本库，锁定依赖版本以保证可复现的发布构建。
- 应用内升级相关的用户可见文案不出现第三方框架名，仅表述为「安全升级 / 检查更新」。
- **测试隔离**：新增 `KeyValueStore` 抽象，`Settings` 改为 `init(defaults:)` 注入；
  `StatisticsStore` 改为 `init(fileURL:)` 注入。`--logictest` 与单测改用纯内存偏好、
  `--demo` 落到易失存储——均不再污染真实偏好与统计，且不残留任何隔离域 plist。

### Performance
- **后台 CPU 占用下降**：将较昂贵、变化缓慢的环境探测（全屏 / 麦克风 / 专注）改为按节流周期
  评估并缓存结果，不再每秒执行；连续天数（streak）改为缓存，面板不再每帧重算。
- **实验室即时震动更跟手**：滑块拖动的即时预览改为「最新覆盖」合并，避免快速拖动时串行队列
  堆积导致的滞后（此前易被误认为内存泄漏）。

### Fixed
- `StatisticsStore.flush()` 改为同步落盘，修复退出瞬间异步写盘可能被进程终止吞掉的隐患。

## [1.0.0] - 2026-07-01

初始公开版本：一款用**触摸板震动**提醒你起身休息的 macOS 应用——无声、无弹窗、不打断心流。

### Added
- **定时震动提醒**：15 / 20 / 25 / 30 / 45 / 60 分钟可选，菜单栏实时倒计时。
- **6 种内置震动模式** + **自定义震动模式编辑器**（逐步编排强度与间隔、可试触、持久化）。
- **全局强度分级（1–5）**，基于双音源梯级标定，附「震动实验室」真机逐级校准。
- **智能暂停**：空闲自动暂停、全屏应用（演示/视频/游戏）暂停、专注/勿扰暂停、会议（麦克风占用）暂停。
- **番茄钟模式**（默认 25 + 5）、跳过 / 推迟、跳过升级助推。
- **统计面板**：今日工作时长 / 休息 / 跳过 / 番茄，最近 7 天柱状图、连续天数 streak、CSV 导出。
- **全局快捷键**（无需辅助功能权限）：`⌃⌥Space` 暂停、`⌃⌥S` 跳过、`⌃⌥B` 立即震动。
- **倒计时圆环**「能量按秒释放」动画：秒针顺时针扫动，归零发射流光子弹沿环命中、扣减一格。
- **附加提醒**（可选）：屏幕轻闪、菜单栏图标高亮、系统提示音（14 种音色）。
- **国际化**：简体中文 / English / 日本語，跟随系统或手动切换、即时生效。
- **开机自启**、菜单栏常驻（无 Dock 图标），纯原生 Swift，资源占用极低。

### 分发
- 独立分发（非 App Store）：`build.sh` 支持版本注入与可选 Developer ID 签名 / 公证。
- GitHub Actions：推送 tag 自动构建、按本更新日志生成 Release（`.dmg` + `.zip`）。

[Unreleased]: https://github.com/OWNER/HapticBreak/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/OWNER/HapticBreak/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/OWNER/HapticBreak/releases/tag/v1.0.0
