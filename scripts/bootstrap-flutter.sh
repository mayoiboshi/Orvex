#!/usr/bin/env bash
set -euo pipefail
ORVEX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${ORVEX_PROXY:-}" ]]; then
  export HTTPS_PROXY="$ORVEX_PROXY" HTTP_PROXY="$ORVEX_PROXY" ALL_PROXY="$ORVEX_PROXY"
fi
ORVEX_SDK="$ORVEX_ROOT/.tooling/flutter"
ORVEX_REVISION=c197ca5199e9ee5661e865596c9c07294dfab51c
if [[ ! -x "$ORVEX_SDK/bin/flutter" ]]; then
  mkdir -p "$ORVEX_SDK"
  git -C "$ORVEX_SDK" init
  git -C "$ORVEX_SDK" remote add origin https://github.com/flutter/flutter.git
  git -C "$ORVEX_SDK" fetch --depth 1 origin "$ORVEX_REVISION"
  git -C "$ORVEX_SDK" checkout --detach FETCH_HEAD
fi
if [[ "$(git -C "$ORVEX_SDK" rev-parse HEAD)" != "$ORVEX_REVISION" ]]; then
  echo "Flutter revision differs from Orvex's verified SDK; inspect it before upgrading." >&2
  exit 1
fi
"$ORVEX_ROOT/scripts/flutterw" --version
"$ORVEX_ROOT/scripts/flutterw" pub get
