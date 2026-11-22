# Lives in the tap repo github.com/Mocinjay/homebrew-tap as Casks/morphlo.rb.
# Users install with:  brew install --cask mocinjay/tap/morphlo
cask "morphlo" do
  version "0.1.0"
  sha256 "4ed1f2bfcefc823e8e32b160f04e0e7ff1aa725d9d09088e419881f41251a19c"

  url "https://github.com/Mocinjay/morphlo/releases/download/v#{version}/Morphlo-#{version}.zip"
  name "Morphlo"
  desc "Never worry about converting again: fixes Photos drags and converts any file"
  homepage "https://github.com/Mocinjay/morphlo"

  depends_on macos: ">= :sonoma"

  app "Morphlo.app"

  uninstall quit: "io.github.mocinjay.morphlo"

  zap trash: [
    "~/Library/Caches/io.github.mocinjay.morphlo",
    "~/Library/Logs/Morphlo",
    "~/Library/Preferences/io.github.mocinjay.morphlo.plist",
  ]
end
