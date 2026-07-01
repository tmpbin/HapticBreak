<div align="center">

<img src="assets/icon.png" width="128" alt="HapticBreak" />

# HapticBreak

**一个能被你「摸到」的休息提醒——不弹窗、不出声、不遮屏。**

到点时，它用触摸板在你手心轻轻拍一下。没有弹窗，没有声音，旁人毫无察觉——而你的心流，一次都不会被打断。

<a href="README.md">English</a> · <b>简体中文</b>

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-000000?logo=apple)
![swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![haptics](https://img.shields.io/badge/Taptic%20Engine-powered-ff2d55)
![menubar](https://img.shields.io/badge/menubar-native-6e56cf)

</div>

---

## 为什么会喜欢它

你一坐就是三小时。眼睛发干、脖子发僵、手腕发麻——身体早就拉响了警报，只是你没听见。

市面上的休息提醒，无非三招：

- **全屏遮罩**——强行霸占屏幕，把你从状态里硬拽出来。
- **系统通知**——一眼就滑走，一开专注模式还被静音。
- **声音提醒**——直到你在开会、在图书馆、在开放工位……社死现场。

它们都在跟你的注意力抢工作。而 HapticBreak 走的是一条一直都在、却没人用的通道：**自 2015 年起，每块 MacBook 触摸板下都压着一颗 Taptic Engine**——一个能被软件精确控制的线性震动马达，就在你此刻搭着的手腕正下方。到点时，它给你一下恰到好处的轻拍：**你收到了，世界没被打扰。**

---

## 魔性，藏在节奏里

一下震动只是一下震动，**而节奏，是一种感觉。** HapticBreak 把你的触摸板当成一件小小的乐器。

- **35 种内置震动模式**，分三种气质——**基础 / 自然 / 节奏**——从一记轻拍，到滚滚雷声，再到带劲的鼓点。
- **靠手感就能认出来的旋律。** 有些节奏太经典，光凭手心里的拍子你就能哼出调：
  - **命运**——贝多芬第五：_哒-哒-哒-**当**_。
  - **跺脚拍手**——全场大合唱的 _咚-咚-**啪**_（We Will Rock You）。
  - **理发店七拍**——那段「哒哒·哒哒哒」，最后两下你会忍不住在心里补上。
  - **暗黑进行曲**——反派登场，三记沉重的脚步。
- **还能自己编。** 「震动模式编辑器」让你逐拍编排音色、强度与间隔，拖动即可试触，并以纯 JSON 导入导出（方便分享——或者让 AI 帮你写一段）。
- **凭手感调校。** 每个模式都跑在三轴引擎上（音色 × 强度 × 钝感），内置的「震动实验室」让你把它标定到**这台** Mac 最舒服的手感。

> 倒计时圆环也在合拍：它每秒释放一小簇能量；面板打开时，还可选一记极轻的震动「心跳」与之同步。

---

## 看一眼

| 控制面板 · 能量按秒释放的倒计时环 | 设置 · 系统设置级的清爽分区 |
|:--:|:--:|
| ![popover](assets/screenshots/popover-light.png) | ![settings](assets/screenshots/settings-light.png) |
| **统计 · 诚实的休息 + 连续天数** | **模式编辑器 · 编出你自己的节奏** |
| ![stats](assets/screenshots/statistics-light.png) | ![editor](assets/screenshots/editor-light.png) |

---

## 功能特性

- **定时震动提醒**——15 / 20 / 25 / 30 / 45 / 60 分钟可选，菜单栏实时倒计时。
- **35 种内置模式 + 自定义编辑器**——逐拍编排强度与间隔，可试触、可保存。
- **10 级强度**——基于双音源梯级标定，附「震动实验室」在真机上逐级校准到本机手感。
- **智能暂停（都无需额外权限）：**
  - 键鼠/触控板空闲自动暂停，长时间离开自动重置；
  - 全屏应用（演示 / 视频 / 游戏）自动暂停；
  - 专注 / 勿扰、会议（麦克风占用）自动暂停。
- **番茄钟模式**——工作 / 休息循环（默认 25 + 5），自动计数。
- **跳过 / 推迟**——随时跳过本次或推迟 N 分钟；反复跳过可选「升级助推」加强下次。
- **诚实的统计**——提醒响了不算数，**你真的离开了**才记一次休息。今日时长 / 休息 / 跳过 / 番茄，最近 7 天柱状图、连续天数 streak、CSV 导出。
- **全局快捷键**（无需辅助功能权限）：`⌃⌥Space` 暂停 · `⌃⌥S` 跳过 · `⌃⌥B` 立即震动。
- **三语界面**——简体中文 / English / 日本語，跟随系统或手动即时切换。
- **附加提醒（可选）**：屏幕轻闪、菜单栏图标高亮、系统提示音（14 种音色）。
- **开机自启**、菜单栏常驻（无 Dock 图标），纯原生 Swift，资源占用极低。

---

## 安装

> HapticBreak 通过触摸板震动工作，仅在**内置 Force Touch 触摸板**或 **Magic Trackpad 2+** 上有效。

### 推荐：Homebrew（连装带升级，一条命令）

```bash
brew tap OWNER/tap
brew install --cask --no-quarantine hapticbreak   # 未公证版本加 --no-quarantine 免「已损坏」提示
brew upgrade --cask hapticbreak                    # 以后升级一条命令
```

Cask 模板见 [`packaging/homebrew`](packaging/homebrew/Casks/hapticbreak.rb)。

### 或者下载 `.dmg` 手动放行一次

未公证的 ad-hoc 版本首次运行会被 macOS 拦截（Apple Silicon 上表现为「已损坏，应移到废纸篓」——这不是应用坏了，只是 Gatekeeper 对下载的未公证应用的默认态度）。任选其一放行：

```bash
# 方式 A：去掉隔离属性（最干净，一次即可）
xattr -dr com.apple.quarantine /Applications/HapticBreak.app

# 方式 B：右键 App →「打开」→ 弹窗再点「打开」（仅第一次）
```

---

## 从源码构建

依赖：Xcode 命令行工具（Swift 5.9+）。

```bash
./build.sh release        # → build/HapticBreak.app（ad-hoc 签名 + 自动图标）
./build.sh release dmg    # → 另出可分发的 build/HapticBreak-<版本>.dmg
```

版本号与签名身份可用环境变量注入（CI 即用此机制）：

```bash
HB_VERSION=1.2.0 \
HB_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./build.sh release dmg    # Developer ID 签名 + hardened runtime（可提交公证）
```

不装也能先感受一下震动：

```bash
swift run HapticBreak --rhythms     # 在触摸板上把每种节奏依次感受一遍
swift run HapticBreak --hapticlab   # 打开真机标定台
```

---

## 发布与升级

推送一个 `vX.Y.Z` 标签，[GitHub Actions 流水线](.github/workflows/release.yml) 会自动构建、跑测试、打包 `.dmg` + `.zip`，从 [`CHANGELOG.md`](CHANGELOG.md) 抽取对应版本段落作为发布说明，并创建 GitHub Release。

```bash
git tag v1.2.0
git push origin v1.2.0
# → Actions 自动出 Release
```

在仓库里配好签名 Secret（Developer ID 证书 + Apple ID），**同一条**流水线会自动升级为 **Developer ID 签名 + 公证 + staple**，产出「下载即开、零提示」的版本——无需改一行代码。再配上升级签名密钥，它还会发布一份签名的升级源，已安装的用户便可在后台静默升级。应用内升级的一次性设置见 [`packaging/autoupdate/README.md`](packaging/autoupdate/README.md)。

---

## 自动化测试

```bash
swift test                    # 计时状态机 / 诚实休息 / 圆环 / 统计 / 偏好 / 自定义模式
scripts/release-check.sh      # 发布前门禁：构建 → 单测 → CLI 冒烟 → 界面走查 → 打包
```

二进制另内置多个自检入口，便于真机手动验收（均使用隔离 / 只读状态，绝不污染真实数据）：

```bash
.build/release/HapticBreak --selftest    # 震动：逐级触发强度曲线
.build/release/HapticBreak --logictest   # 计时状态机：全部断言（含圆环扣减）
.build/release/HapticBreak --checkenv    # 空闲 / 全屏 / Focus / 麦克风检测 + 统计读取（只读）
.build/release/HapticBreak --demo        # UI 冒烟：实例化全部窗口并触发提醒
```

---

## 已知限制

- 未公证的独立分发版首次运行需手动放行（见上）；配置签名 Secret 后可彻底消除。
- 专注 / 勿扰检测为「最佳努力」（读取系统文件），系统改版可能失效，但不影响核心提醒。
- 精确震动走的是私有 API，理论上可能随 macOS 版本变化；已内置公开 API 自动回退。
