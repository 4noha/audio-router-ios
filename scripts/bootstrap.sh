#!/usr/bin/env bash
# project.yml から AudioRouterCompanion.xcodeproj を生成する。
# 初回 / project.yml 編集後に実行。
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
echo "==> done: AudioRouterCompanion.xcodeproj"
echo "Xcode で開いて Team を設定 (Signing & Capabilities) してから実機に実行。"
