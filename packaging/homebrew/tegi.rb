# Rendered into Mergemat/homebrew-tap as Casks/tegi.rb by
# .github/workflows/release.yml.
cask "tegi" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Mergemat/tegi/releases/download/v#{version}/tegi-#{version}.zip"
  name "tegi"
  desc "Scrollable tiling window manager"
  homepage "https://github.com/Mergemat/tegi"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "tegi.app"
  binary "#{appdir}/tegi.app/Contents/MacOS/tegi"

  postflight_steps do
    # The app is signed ad hoc, not notarized; Homebrew already checked the
    # download against the sha256 above.
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/tegi.app"]
    # Start right away, and again after an upgrade quit the old version.
    run "/usr/bin/open", args: ["{{appdir}}/tegi.app"], must_succeed: false
  end

  # Direct motion's passwordless Dock helper, if it was ever turned on.
  uninstall quit:   "io.github.mergemat.tegi",
            delete: ["/Library/PrivilegedHelperTools/tegi-dock-loader", "/etc/sudoers.d/tegi"]

  zap trash: "~/.config/tegi"

  caveats <<~EOS
    tegi asks for Accessibility (to move windows) and Screen Recording (for
    workspace slides and the overview) on first launch, and starts at login.
  EOS
end
