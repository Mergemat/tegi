#!/bin/sh
# Packages a release into .build/dist: the zip and the cask for Mergemat/homebrew-tap.
# CI runs this on a version tag and publishes the result; locally it only builds.
#
#   ./scripts/release.sh 0.1.0
#
#   SIGN_IDENTITY="Developer ID Application: …"   sign for Gatekeeper (default: ad-hoc)
#   NOTARY_PROFILE=tegi                            notarize with a profile saved by
#                                                  `xcrun notarytool store-credentials tegi`
set -e
cd "$(dirname "$0")/.."

version=$1
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "usage: $0 <version>, like 0.1.0" >&2; exit 1 ;;
esac
[ -z "$(git status --porcelain)" ] || { echo "commit or stash changes first" >&2; exit 1; }
swift test

VERSION=$version ./scripts/app.sh

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

sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha/g" packaging/homebrew/tegi.rb > "$dist/tegi.rb"

cat <<DONE

Built $zip
  sha256 $sha
Wrote $dist/tegi.rb

Nothing is published. Pushing the tag does the rest in CI:
  git tag v$version && git push origin v$version
DONE
