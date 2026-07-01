# 应用内升级（方案 A：appcast 托管于同仓库 GitHub Pages）

HapticBreak 内置应用内一键升级：新版本经 **EdDSA 签名**校验后在后台静默下载安装，用户不必去 GitHub 手动下载。

```
应用内检查更新
      │  读 Info.plist: SUFeedURL
      ▼
https://<owner>.github.io/<repo>/appcast.xml   ← gh-pages（CI 自动更新）
      │  找到更高版本 + EdDSA 签名
      ▼
https://github.com/<owner>/<repo>/releases/download/<tag>/HapticBreak-x.y.z.zip
      │  校验签名 → 解包 .app → 替换 → 重启
      ▼
     完成
```

## 一次性设置（发布者做一次）

### 1. 生成签名密钥

```bash
bash packaging/autoupdate/setup-keys.sh
```

它会产出：

| 文件 | 用途 | 是否提交 |
| --- | --- | --- |
| `eddsa_public.key` | 公钥，`build.sh` 写入 `Info.plist` 的 `SUPublicEDKey` | **提交** |
| `eddsa_private.key` | 私钥，配置到 CI Secret | **切勿提交**（已 `.gitignore`） |

### 2. 配置仓库

- **Secret**：`Settings → Secrets and variables → Actions` 新建 `UPDATE_PRIVATE_KEY`，值为 `eddsa_private.key` 全文（脚本已打印）。
- **Pages**：`Settings → Pages`，Source 选 `gh-pages` 分支（首次发布后该分支才会由 CI 自动创建，创建后再来打开）。
- **升级源**：编辑 [`appcast-url.txt`](appcast-url.txt)，把 `OWNER`/`HapticBreak` 换成你的 `用户名`/`仓库名`。

### 3. 提交公钥与配置

```bash
git add packaging/autoupdate/eddsa_public.key packaging/autoupdate/appcast-url.txt
```

## 之后每次发布

打个 tag 即可，CI 全自动：

```bash
git tag v1.1.0 && git push --tags
```

`release.yml` 会：构建 → 打包 → 建 Release → 用私钥 `generate_appcast` 生成/追加 `appcast.xml` → 推送到 `gh-pages`。已安装用户下次检查更新即可获得。

## 无密钥时的行为（安全降级）

- `build.sh` 未读到 `eddsa_public.key` → 不写 `SUPublicEDKey` → 应用启动时**自动禁用**更新器（`UpdaterController`），菜单不显示「检查更新」。
- `release.yml` 未配置 `UPDATE_PRIVATE_KEY` → 跳过 appcast 步骤，仍正常出 Release。

即：不配升级也能照常发布，配了才启用应用内升级——两条路径互不阻塞。

## 本地手动生成 appcast（可选调试）

```bash
mkdir -p /tmp/arch && cp build/HapticBreak-*.dmg /tmp/arch/
.build/artifacts/*/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/OWNER/HapticBreak/releases/download/vX.Y.Z/" \
  /tmp/arch
cat /tmp/arch/appcast.xml
```

私钥从钥匙串自动读取（`setup-keys.sh` 已存入）。
