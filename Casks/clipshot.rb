# Homebrew cask for ClipShot.
#
# Install:
#   brew install --cask m-moravcik/clipshot/clipshot
#
# This copy is the cask, kept next to the source so a change to the install,
# the uninstall or the zap list is reviewed with the code that writes those
# files. The cask Homebrew installs lives in the m-moravcik/homebrew-clipshot
# tap; on every release scripts/release.sh copies this file there and writes
# the release's version and sha256 into it, so the two lines below are
# placeholders here.
#
# `binary` links the command line tool that ships inside the app,
# ClipShot.app/Contents/Helpers/clipshot, into Homebrew's bin as `clipshot`.
#
# The release ZIP is Developer ID signed, notarized and stapled. A copy installed
# by this cask never updates itself: Homebrew owns its updates
# (`brew upgrade --cask clipshot`), and the app says so in Settings > About.
cask "clipshot" do
  version "0.9.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/m-moravcik/ClipShot/releases/download/v#{version}/ClipShot-#{version}.zip"
  name "ClipShot"
  desc "Copies every screenshot to the clipboard and keeps the file"
  homepage "https://github.com/m-moravcik/ClipShot"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "ClipShot.app"
  binary "#{appdir}/ClipShot.app/Contents/Helpers/clipshot"

  uninstall quit: "sk.moravcik.ClipShot"

  # ClipShot's own files only. The macOS screenshot settings it changed stay as
  # they are: use Settings > Capture > Restore previous settings before
  # uninstalling to put them back.
  zap trash: [
    "~/Library/Application Support/ClipShot",
    "~/Library/Caches/sk.moravcik.ClipShot",
    "~/Library/HTTPStorages/sk.moravcik.ClipShot",
    "~/Library/Logs/clipshot.log",
    "~/Library/Logs/clipshot.log.1",
    "~/Library/Preferences/sk.moravcik.ClipShot.plist",
  ]
end
