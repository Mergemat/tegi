#!/bin/sh
# Packages a release locally; publishing stays a manual step it prints at the end.
#
#   ./scripts/release.sh 0.1.0
#
#   SIGN_IDENTITY="Developer ID Application: …"   sign for Gatekeeper (default: ad-hoc)
#   NOTARY_PROFILE=tegi                            notarize with a profile saved by
#                                                  `xcrun notarytool store-credentials tegi`
set -e
cd "$(dirname "$0")/.."

version=$1
repo=mergemat/tegi
bundle_id=io.github.mergemat.tegi
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "usage: $0 <version>, like 0.1.0" >&2; exit 1 ;;
esac
[ -z "$(git status --porcelain)" ] || { echo "commit or stash changes first" >&2; exit 1; }
swift test

VERSION=$version UNIVERSAL=1 ./scripts/app.sh

dist=.build/dist
zip=$dist/tegi-$version.zip
rm -rf "$dist"
mkdir -p "$dist"

if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    ditto -c -k --keepParent .build/tegi.app "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple .build/tegi.app
    rm "$zip"
fi
ditto -c -k --keepParent .build/tegi.app "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

# Until releases are notarized, Gatekeeper would refuse the download; the tap clears the flag.
quarantine=""
if [ -z "$NOTARY_PROFILE" ]; then
    quarantine='    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/tegi.app"]
'
fi

cat > "$dist/tegi.rb" <<CASK
cask "tegi" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/tegi-#{version}.zip"
  name "tegi"
  desc "Scrollable tiling window manager"
  homepage "https://github.com/$repo"

  depends_on macos: ">= :sonoma"

  app "tegi.app"
  binary "#{appdir}/tegi.app/Contents/MacOS/tegi"

  postflight do
${quarantine}    system_command "/usr/bin/open", args: ["#{appdir}/tegi.app"]
  end

  uninstall quit: "$bundle_id"

  zap trash: "~/.config/tegi"

  caveats <<~EOS
    tegi asks for Accessibility (to move windows) and Screen Recording (for
    workspace slides and the overview) on first launch, and starts at login.
  EOS
end
CASK

cat <<DONE

Built $zip
  sha256 $sha
Wrote $dist/tegi.rb

Nothing is published. To release:
  git tag v$version && git push origin v$version
  gh release create v$version $zip --repo $repo --title v$version --generate-notes
  cp $dist/tegi.rb <homebrew-tap>/Casks/tegi.rb, commit and push
DONE
