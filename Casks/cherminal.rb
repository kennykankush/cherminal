cask "cherminal" do
  version "0.2.0"
  sha256 "176108d9bdb72eef771a5e37b348560ffd0cdd7ee6f1c70d6f804b4da2ab33e8"

  url "https://github.com/kennykankush/cherminal/releases/download/v#{version}/Cherminal-#{version}.dmg"
  name "Cherminal"
  desc "Terminal for living with CLI AI agents - conversations, panes, persistent sessions"
  homepage "https://cherminal.com/"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Cherminal.app"

  zap trash: [
    "~/Library/Application Support/dev.hamulia.Cherminal",
    "~/.cherminal",
  ]
end
