#!/bin/bash
# 发布前门禁：一条命令跑完「构建 → 单元测试 → CLI 冒烟 → 界面走查 → 打包」。
# 任一环节失败即非零退出，杜绝"带病发布"。
#
#   scripts/release-check.sh            # 完整门禁（含打包 .app）
#   scripts/release-check.sh --dmg      # 额外产出可分发 .dmg
#   scripts/release-check.sh --no-package  # 只跑校验，不打包（更快）
set -euo pipefail
cd "$(dirname "$0")/.."          # 切到仓库根

DO_PACKAGE=1
DMG_ARG=""
ARCH_ARG=""
for arg in "$@"; do
    case "$arg" in
        --no-package) DO_PACKAGE=0 ;;
        --dmg) DMG_ARG="dmg" ;;
        --universal) ARCH_ARG="universal" ;;
        *) echo "未知参数：$arg"; exit 2 ;;
    esac
done

# Universal 构建 (--arch) 使用 Xcode build system，产物路径不同于 SPM 原生路径。
# 该布局下裸二进制的 @rpath 指向 ../lib，找不到同目录的 Sparkle.framework（dyld 直接崩溃），
# 冒烟步骤需通过 DYLD_FRAMEWORK_PATH 指回产物目录；原生路径框架与二进制同目录，无需处理。
if [ "$ARCH_ARG" = "universal" ]; then
    BIN=".build/apple/Products/Release/HapticBreak"
    export DYLD_FRAMEWORK_PATH="$PWD/.build/apple/Products/Release"
else
    BIN=".build/release/HapticBreak"
fi
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$1"; }

step "1/6 构建（release${ARCH_ARG:+ · universal}）"
BUILD_ARCH_FLAGS=""
if [ "$ARCH_ARG" = "universal" ]; then
    BUILD_ARCH_FLAGS="--arch arm64 --arch x86_64"
fi
swift build -c release $BUILD_ARCH_FLAGS
ok "swift build 完成"

step "2/6 单元测试（swift test）"
swift test
ok "全部单测通过"

step "3/6 CLI 冒烟：计时状态机逻辑自测（--logictest）"
"$BIN" --logictest
ok "逻辑自测通过"

step "4/6 CLI 冒烟：环境只读体检（--checkenv）"
"$BIN" --checkenv
ok "环境体检通过"

step "5/6 界面离屏走查（--rendershots）"
SHOTS_DIR="$(mktemp -d)"
trap 'rm -rf "$SHOTS_DIR"' EXIT
"$BIN" --rendershots "$SHOTS_DIR"
SHOT_COUNT="$(ls -1 "$SHOTS_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')"
[ "$SHOT_COUNT" -ge 1 ] || { echo "  ✗ 未生成任何界面快照"; exit 1; }
ok "生成 $SHOT_COUNT 张界面快照"

if [ "$DO_PACKAGE" -eq 1 ]; then
    step "6/6 打包 .app${DMG_ARG:+（含 .dmg）}${ARCH_ARG:+（universal）}"
    ./build.sh release ${DMG_ARG} ${ARCH_ARG}
    ok "打包完成：build/HapticBreak.app"
else
    step "6/6 打包（已跳过 --no-package）"
fi

printf '\n\033[1;32m✅ 发布门禁全部通过。\033[0m\n'
