#!/bin/bash
# 一次性生成应用内升级所需的 EdDSA 签名密钥。
#
# 产出：
#   1) packaging/autoupdate/eddsa_public.key   —— 公钥（可安全提交；build.sh 读它写入 Info.plist）
#   2) packaging/autoupdate/eddsa_private.key  —— 私钥（.gitignore 已忽略；用于配置 CI Secret）
#
# 私钥同时存入 macOS 登录钥匙串（generate_keys 默认行为），本地签名工具会自动读取；
# 导出文件仅用于把私钥交给 GitHub Actions。
#
# 用法：  bash packaging/autoupdate/setup-keys.sh
set -euo pipefail
cd "$(dirname "$0")/../.."   # → 仓库根目录

PUB_FILE="packaging/autoupdate/eddsa_public.key"
PRIV_FILE="packaging/autoupdate/eddsa_private.key"

echo "==> 定位升级签名工具（generate_keys）"
GK="$(ls .build/artifacts/*/Sparkle/bin/generate_keys 2>/dev/null | head -1 || true)"
if [ -z "$GK" ]; then
    echo "   未找到，先 swift build 拉取升级框架产物…"
    swift build -c release >/dev/null
    GK="$(ls .build/artifacts/*/Sparkle/bin/generate_keys 2>/dev/null | head -1 || true)"
fi
[ -n "$GK" ] || { echo "错误：仍未找到 generate_keys，请先成功执行 swift build。" >&2; exit 1; }

echo "==> 生成 / 读取密钥对（如钥匙串已有则复用，不会覆盖）"
# 首次运行会在钥匙串创建私钥，并可能弹出授权框——请点「允许」。
"$GK" >/dev/null 2>&1 || true

echo "==> 导出公钥 → $PUB_FILE"
"$GK" -p | tr -d '[:space:]' > "$PUB_FILE"
echo "   公钥：$(cat "$PUB_FILE")"

echo "==> 导出私钥 → ${PRIV_FILE}（已被 .gitignore 忽略，切勿提交）"
rm -f "$PRIV_FILE"
"$GK" -x "$PRIV_FILE" >/dev/null
chmod 600 "$PRIV_FILE"

cat <<EOF

============================ 完成 ============================
下一步（发布应用内升级需要）：

1) 提交公钥（安全）：
     git add $PUB_FILE
   之后 build.sh 会自动把它写入 .app 的 Info.plist（SUPublicEDKey）。

2) 配置 CI 私钥 Secret（用于自动签名升级包 + 生成 appcast）：
     在 GitHub 仓库 → Settings → Secrets and variables → Actions
     新建 Secret：  名称 UPDATE_PRIVATE_KEY
                    值   为 $PRIV_FILE 的完整内容（下面已打印）：

--------------------- UPDATE_PRIVATE_KEY ---------------------
$(cat "$PRIV_FILE")
---------------------------------------------------------------

3) 设置升级源地址：编辑 packaging/autoupdate/appcast-url.txt，
   改成  https://<你的GitHub用户名>.github.io/<仓库名>/appcast.xml
   并在仓库 Settings → Pages 里将来源设为 gh-pages 分支。

私钥已同时存入本机钥匙串；如需换机，用  $GK -f $PRIV_FILE  导入。
=============================================================
EOF
