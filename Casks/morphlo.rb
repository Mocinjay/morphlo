# Lives in the tap repo github.com/Mocinjay/homebrew-tap as Casks/morphlo.rb.
# Users install with:  brew tap mocinjay/tap && brew trust mocinjay/tap && brew install --cask morphlo
cask "morphlo" do
  version "0.1.4"
  sha256 "57d6c7d5772c5f176641a16881c470116a2ac8fe56e06384ef34decfa24cacb5"

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
