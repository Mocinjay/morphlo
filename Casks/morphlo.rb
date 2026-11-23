# Lives in the tap repo github.com/Mocinjay/homebrew-tap as Casks/morphlo.rb.
# Users install with:  brew tap mocinjay/tap && brew trust mocinjay/tap && brew install --cask morphlo
cask "morphlo" do
  version "0.1.5"
  sha256 "6b3081edf3e76adcb43ebbc43bacdd44233b09c32b76354dd89b312a1b16b8f6"

  url "https://github.com/Mocinjay/morphlo/releases/download/v#{version}/Morphlo-#{version}.zip"
  name "Morphlo"
  desc "Never worry about converting again: fixes Photos drags and converts any file"
  homepage "https://github.com/Mocinjay/morphlo"

  depends_on macos: :sonoma

  app "Morphlo.app"

  uninstall quit: "io.github.mocinjay.morphlo"

  zap trash: [
    "~/Library/Caches/io.github.mocinjay.morphlo",
    "~/Library/Logs/Morphlo",
    "~/Library/Preferences/io.github.mocinjay.morphlo.plist",
  ]
end
