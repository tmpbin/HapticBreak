#!/bin/bash
# 构建 HapticBreak 并打包为 .app 应用包（菜单栏常驻、无 Dock 图标）。
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
MAKE_DMG="${2:-}"      # 传入 "dmg" 则在打包后生成可分发的 .dmg
ARCH="${3:-}"           # 传入 "universal" 则构建 arm64+x86_64 通用二进制
APP_NAME="HapticBreak"
BUNDLE_ID="com.aremind.hapticbreak"

# 版本号可由环境变量注入（CI 用 git tag 注入）；本地默认与当前发布版一致。
VERSION="${HB_VERSION:-1.2.0}"
# 构建号（CFBundleVersion）：应用内升级按它比较新旧，必须随版本单调递增。
# 未显式提供时由版本号导出（1.0.1 → 10001；预发布后缀忽略）。
if [ -n "${HB_BUILD:-}" ]; then
    BUILD_NUMBER="$HB_BUILD"
else
    BASE_VERSION="${VERSION%%-*}"
    IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "$BASE_VERSION"
    BUILD_NUMBER=$(( ${V_MAJOR:-0} * 10000 + ${V_MINOR:-0} * 100 + ${V_PATCH:-0} ))
fi

# 代码签名身份：默认 "-" = ad-hoc（本地零门槛）。
# 传入 Developer ID 身份（如 "Developer ID Application: Name (TEAMID)"）即启用
# hardened runtime + 安全时间戳——这是提交 Apple 公证（notarization）的前置条件。
SIGN_IDENTITY="${HB_SIGN_IDENTITY:--}"

# ---- 应用内升级配置 ---------------------------------------------------------
# 公钥（EdDSA）：可安全提交，来自 packaging/autoupdate/eddsa_public.key；缺失则不写入
# SUPublicEDKey → 应用运行时自动禁用更新器（见 UpdaterController）。
# 升级源（appcast）URL：优先 env HB_FEED_URL，其次 packaging/autoupdate/appcast-url.txt。
SU_PUBKEY="${HB_SU_PUBKEY:-}"
if [ -z "$SU_PUBKEY" ] && [ -f "packaging/autoupdate/eddsa_public.key" ]; then
    SU_PUBKEY="$(tr -d '[:space:]' < packaging/autoupdate/eddsa_public.key)"
fi
SU_FEED_URL="${HB_FEED_URL:-}"
if [ -z "$SU_FEED_URL" ] && [ -f "packaging/autoupdate/appcast-url.txt" ]; then
    SU_FEED_URL="$(tr -d '[:space:]' < packaging/autoupdate/appcast-url.txt)"
fi
[ -z "$SU_FEED_URL" ] && SU_FEED_URL="https://tmpbin.github.io/HapticBreak/appcast.xml"

ARCH_FLAGS=""
if [ "$ARCH" = "universal" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
    echo "==> swift build -c $CONFIG (Universal: arm64 + x86_64)"
else
    echo "==> swift build -c $CONFIG ($(uname -m))"
fi
swift build -c "$CONFIG" $ARCH_FLAGS

# Universal 构建 (--arch) 使用 Xcode build system，产物路径不同于 SPM 原生路径。
if [ "$ARCH" = "universal" ]; then
    BIN=".build/apple/Products/Release/$APP_NAME"
else
    BIN=".build/$CONFIG/$APP_NAME"
fi
APP="build/$APP_NAME.app"
CONTENTS="$APP/Contents"

mkdir -p build

# 生成应用图标（程序化绘制 → iconset → .icns）
if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
    echo "==> 生成应用图标"
    ICON_PNG="build/icon-1024.png"
    "$BIN" --makeicon "$ICON_PNG" >/dev/null 2>&1 || true
    if [ -f "$ICON_PNG" ]; then
        ICONSET="build/AppIcon.iconset"
        rm -rf "$ICONSET"; mkdir -p "$ICONSET"
        for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
                    "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
                    "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
            px="${spec%%:*}"; name="${spec##*:}"
            sips -z "$px" "$px" "$ICON_PNG" --out "$ICONSET/$name.png" >/dev/null 2>&1
        done
        iconutil -c icns "$ICONSET" -o "build/AppIcon.icns" >/dev/null 2>&1 || echo "（iconutil 失败，跳过图标）"
    fi
fi

# 兜底：无窗口服务器（如 CI）时程序化绘制可能失败，回退到仓库内预生成的图标。
if [ ! -f "build/AppIcon.icns" ] && [ -f "assets/AppIcon.icns" ]; then
    echo "==> 使用仓库预置图标 assets/AppIcon.icns"
    cp "assets/AppIcon.icns" "build/AppIcon.icns"
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"

# 瘦身：移除可执行文件里的本地符号（调试信息已在独立 .dSYM 中，不影响崩溃符号化）。
strip -x "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true

# 让主二进制能在 .app 内找到 Sparkle：SPM 产物的 install name 是
# @rpath/Sparkle.framework/…，而框架将放到 Contents/Frameworks，故补一条 rpath。
# 必须在签名之前执行（install_name_tool 会使既有签名失效）。
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>HapticBreak</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
        <string>ja</string>
    </array>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrefersDisplaySafeAreaCompatibilityMode</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>HapticBreak · 触摸板震动休息提醒</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

if [ -f "build/AppIcon.icns" ]; then
    cp "build/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

printf 'APPL????' > "$CONTENTS/PkgInfo"

# ---- 应用内升级：写入 SU* 键 + 嵌入升级框架 --------------------------------
PB=/usr/libexec/PlistBuddy
if [ "$ARCH" = "universal" ]; then
    FRAMEWORK_SRC=".build/apple/Products/Release/Sparkle.framework"
else
    FRAMEWORK_SRC=".build/$CONFIG/Sparkle.framework"
fi
if [ -d "$FRAMEWORK_SRC" ]; then
    echo "==> 写入应用内升级 Info.plist 键（feed=${SU_FEED_URL}）"
    "$PB" -c "Add :SUFeedURL string $SU_FEED_URL" "$CONTENTS/Info.plist"
    "$PB" -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS/Info.plist"
    if [ -n "$SU_PUBKEY" ]; then
        "$PB" -c "Add :SUPublicEDKey string $SU_PUBKEY" "$CONTENTS/Info.plist"
    else
        echo "   （未提供 EdDSA 公钥：应用内升级将保持禁用，见 packaging/autoupdate/README.md）"
    fi

    echo "==> 嵌入 Sparkle.framework → Contents/Frameworks"
    mkdir -p "$CONTENTS/Frameworks"
    # -R 保留符号链接与 Versions 结构；框架内自带 XPC 服务、Autoupdate、Updater.app。
    cp -R "$FRAMEWORK_SRC" "$CONTENTS/Frameworks/"
else
    echo "==> 警告：未找到 ${FRAMEWORK_SRC}，跳过 Sparkle 嵌入（应用内升级将不可用）"
fi

# ---- 瘦身：让 Sparkle 与主程序架构一致 -------------------------------------
# 预编译 Sparkle 是通用二进制(x86_64+arm64)；主程序若是单架构（本 App 仅 arm64），
# 其余 slice 永远用不到，thin 掉可省近一半框架体积，且不损失任何功能。
# 必须在签名之前执行（lipo 会使既有签名失效，随后统一重签）。
FW="$CONTENTS/Frameworks/Sparkle.framework"
APP_ARCHS="$(lipo -archs "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true)"
APP_ARCH_COUNT="$(printf '%s' "$APP_ARCHS" | wc -w | tr -d ' ')"
if [ -d "$FW" ] && [ "$APP_ARCH_COUNT" = "1" ]; then
    KEEP="$APP_ARCHS"
    echo "==> 瘦身 Sparkle 到 ${KEEP}（主程序单架构，移除多余 slice）"
    thin_macho() {  # 仅对「含多架构且包含目标架构」的 Mach-O 执行 lipo -thin
        local f="$1"
        [ -f "$f" ] || return 0
        lipo "$f" -verify_arch "$KEEP" >/dev/null 2>&1 || return 0
        if lipo -archs "$f" 2>/dev/null | grep -q ' '; then
            lipo "$f" -thin "$KEEP" -output "$f.__thin" 2>/dev/null && mv -f "$f.__thin" "$f"
        fi
    }
    V="$FW/Versions/Current"
    thin_macho "$V/Sparkle"
    thin_macho "$V/Autoupdate"
    thin_macho "$V/Updater.app/Contents/MacOS/Updater"
    for xpc in "$V"/XPCServices/*.xpc; do
        [ -e "$xpc" ] || continue
        thin_macho "$xpc/Contents/MacOS/$(basename "$xpc" .xpc)"
    done
fi

# ---- 代码签名（由内向外，逐层签名嵌套代码）--------------------------------
# 通用签名参数：Developer ID 时附加 hardened runtime + 安全时间戳（公证前置）。
sign_one() {  # $1=路径  $2=额外参数（如 --preserve-metadata=entitlements）
    local path="$1"; shift
    local flags=(--force --sign "$SIGN_IDENTITY" "$@")
    if [ "$SIGN_IDENTITY" != "-" ]; then
        flags+=(--options runtime --timestamp)
    fi
    codesign "${flags[@]}" "$path"
}

FW="$CONTENTS/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    echo "==> 逐层签名 Sparkle 嵌套代码"
    # 1) XPC 服务：保留其自带 entitlements（沙箱下载/安装权限），否则功能失效。
    for xpc in "$FW"/Versions/*/XPCServices/*.xpc; do
        [ -e "$xpc" ] && sign_one "$xpc" --preserve-metadata=entitlements
    done
    # 2) Updater.app（升级进度 UI）与 Autoupdate（安装助手可执行文件）。
    for app in "$FW"/Versions/*/Updater.app; do
        [ -e "$app" ] && sign_one "$app"
    done
    for exe in "$FW"/Versions/*/Autoupdate; do
        [ -e "$exe" ] && sign_one "$exe"
    done
    # 3) 框架本身（须在其内部组件签完之后）。
    sign_one "$FW"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> ad-hoc 代码签名主程序（本地/无证书）"
    sign_one "$APP" || echo "（签名失败，本地仍可运行）"
else
    echo "==> Developer ID 代码签名主程序（hardened runtime + 时间戳，可提交公证）"
    sign_one "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "==> 完成：$APP"

# 可分发 DMG：拖拽安装布局（.app + 指向 /Applications 的软链接）
if [ "$MAKE_DMG" = "dmg" ]; then
    echo "==> 制作 DMG"
    DMG_STAGE="build/dmg-stage"
    DMG_PATH="build/$APP_NAME-$VERSION.dmg"
    rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
    cp -R "$APP" "$DMG_STAGE/"
    ln -s /Applications "$DMG_STAGE/Applications"
    rm -f "$DMG_PATH"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" \
        -fs HFS+ -format UDZO -ov "$DMG_PATH" >/dev/null
    rm -rf "$DMG_STAGE"
    echo "==> 完成：$DMG_PATH"
fi
