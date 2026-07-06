# HapticBreak Homebrew Cask
#
# 用法（放入你自己的 tap，例如 github.com/tmpbin/homebrew-tap 的 Casks/ 目录）：
#
#   brew tap tmpbin/tap
#   # 已公证版本：
#   brew install --cask hapticbreak
#   # 未公证（ad-hoc）版本——跳过隔离即可免「已损坏」提示：
#   brew install --cask --no-quarantine hapticbreak
#
# 发版维护：每次 Release 后更新 version 与 sha256（可由 CI 自动 bump，见 docs）。
#   sha256:  shasum -a 256 HapticBreak-<版本>.dmg

cask "hapticbreak" do
  version "1.0.1"
  sha256 "3c29456b72df975e59fcebd1c0a0236d6ce41dc659bb6b37b5b5b836b433851a"

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

  depends_on macos: ">= :ventura"

  app "HapticBreak.app"

  zap trash: [
    "~/Library/Preferences/com.aremind.hapticbreak.plist",
    "~/Library/Application Support/HapticBreak",
    "~/Library/Caches/com.aremind.hapticbreak",
  ]
end
