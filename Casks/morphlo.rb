# Lives in the tap repo github.com/Mocinjay/homebrew-tap as Casks/morphlo.rb.
# Users install with:  brew tap mocinjay/tap && brew trust mocinjay/tap && brew install --cask morphlo
cask "morphlo" do
  version "0.1.0"
  sha256 "d91557ae889338b0775651c6bc3efb99db84a85ce7060074e0c9c21adb74f2e5"

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
