# HapticBreak Homebrew Cask
#
# 用法（放入你自己的 tap，例如 github.com/tmpbin/homebrew-tap 的 Casks/ 目录）：
#
#   brew tap tmpbin/tap
#   brew install --cask hapticbreak
#   # 未公证（ad-hoc）版本装完后放行一次（新版 brew 已禁用 --no-quarantine 开关）：
#   xattr -dr com.apple.quarantine /Applications/HapticBreak.app
#
# 发版维护：每次 Release 后更新 version 与 sha256（可由 CI 自动 bump，见 docs）。
#   sha256:  shasum -a 256 HapticBreak-<版本>.dmg

cask "hapticbreak" do
  version "1.0.2"
  sha256 "7bfbb6d63cce0cf52c27d8497dfcfb90cb597d24b77551bbf03ce18f16bf40d1"

  url "https://github.com/tmpbin/HapticBreak/releases/download/v#{version}/HapticBreak-#{version}.dmg",
      verified: "github.com/tmpbin/HapticBreak/"
  name "HapticBreak"
  desc "Menu-bar break reminder that taps your palm via the trackpad Taptic Engine"
  homepage "https://github.com/tmpbin/HapticBreak"

  livecheck do
    url :url
    strategy :github_latest
  end

  # 应用自带应用内升级：声明后 brew 不再与其抢更新。
  auto_updates true

  depends_on macos: :ventura

  app "HapticBreak.app"

  zap trash: [
    "~/Library/Preferences/com.aremind.hapticbreak.plist",
    "~/Library/Application Support/HapticBreak",
    "~/Library/Caches/com.aremind.hapticbreak",
  ]
end
