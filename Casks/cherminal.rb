cask "cherminal" do
  version "0.2.1"
  sha256 "534b65c644f5da0a2f2c29705508e7c109c09aaa500b997ab535120b54412851"

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
