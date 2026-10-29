#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
archive_sha=eb777d3e7baedeb02871c691b2090daa1bc51baf9215a81bc55bf54edb76df2b
if [[ -f app/src/main/jniLibs/.source-sha256 ]] && [[ "$(cat app/src/main/jniLibs/.source-sha256)" = "$archive_sha" ]]; then
  complete=true
  for abi in arm64-v8a armeabi-v7a x86_64; do
    [[ -s "app/src/main/jniLibs/$abi/libtdjson.so" ]] || complete=false
  done
  if "$complete"; then exit 0; fi
fi
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 \
  https://github.com/up9cloud/android-libtdjson/releases/download/v1.8.65/jniLibs.tar.gz -o "$staging/tdlib.tar.gz"
printf '%s  %s\n' "$archive_sha" "$staging/tdlib.tar.gz" | sha256sum --check --status
tar xzf "$staging/tdlib.tar.gz" -C "$staging"
rm -rf app/src/main/jniLibs
mv "$staging/jniLibs" app/src/main/jniLibs
printf '%s\n' "$archive_sha" > app/src/main/jniLibs/.source-sha256
