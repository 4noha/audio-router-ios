#!/usr/bin/env bash
# A〜D 一気通貫 TestFlight 配信スクリプト。
#
#  A: App Store Connect 上のアプリ登録 (未存在なら API で試す、不可なら Web UI 誘導)
#  C: Archive → ExportArchive → upload (xcodebuild + altool)
#  D: 輸出規制コンプライアンス即時マーク + 内部テスター招待
#
# 必要環境変数 (Bを Web UI で済ませた後):
#   APP_STORE_CONNECT_KEY_ID         例 ABC1234567
#   APP_STORE_CONNECT_ISSUER_ID      UUID
#   APP_STORE_CONNECT_KEY_PATH       .p8 ファイル絶対パス
#   TESTFLIGHT_TESTER_EMAIL          (省略可) 内部テスターとして招待するアドレス。省略時は招待しない
#   TESTFLIGHT_TESTER_FIRST_NAME     (省略可)
#
# 上記は ~/.appstoreconnect/.env (chmod 600) に書いておけば自動 source される
# (sister iOS リポ arkit-relay と共有可)。 別 sidecar を指定したい場合は
# ASC_ENV を export してから呼ぶ。
#
# 使い方:
#   ./scripts/upload-testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# 認証情報の sidecar (sister iOS リポと共有)。 env で上書きされてれば
# そちらが優先 (source 前なら sidecar が default)。
ASC_ENV="${ASC_ENV:-$HOME/.appstoreconnect/.env}"
if [ -f "$ASC_ENV" ]; then
    set +u
    # shellcheck disable=SC1090
    . "$ASC_ENV"
    set -u
fi

: "${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID required (set in ~/.appstoreconnect/.env)}"
: "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID required (set in ~/.appstoreconnect/.env)}"
: "${APP_STORE_CONNECT_KEY_PATH:?APP_STORE_CONNECT_KEY_PATH required (set in ~/.appstoreconnect/.env)}"

BUNDLE_ID=${BUNDLE_ID:-com.fournoha.audiorouter.ios}
APP_NAME=${APP_NAME:-"AudioRouter Companion"}
APP_SKU=${APP_SKU:-audiorouter-ios}
TESTER_EMAIL=${TESTFLIGHT_TESTER_EMAIL:-}
TESTER_FIRST=${TESTFLIGHT_TESTER_FIRST_NAME:-}

PROJECT=AudioRouterCompanion.xcodeproj
SCHEME=AudioRouterCompanion
BUILD_DIR=build
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
IPA_DIR="$BUILD_DIR/ipa"
EXPORT_OPTS="$BUILD_DIR/ExportOptions.plist"

if [ ! -d "$PROJECT" ]; then
    ./scripts/bootstrap.sh
fi
mkdir -p "$BUILD_DIR"

# ==== A: アプリ登録 (未存在なら API で試行、不可なら Web UI 案内) ====
echo "==> A: App Store Connect アプリ確認/登録"
./scripts/asc-api.py create-app \
    --bundle-id "$BUNDLE_ID" \
    --name "$APP_NAME" \
    --sku "$APP_SKU" || {
    echo "A 失敗: Web UI で先にアプリ登録してから再実行してください。"
    echo "  https://appstoreconnect.apple.com/apps"
    exit 1
}

# ==== C: Archive → Export → Upload ====
cat > "$EXPORT_OPTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

echo "==> C-1: archive"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
    -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID" \
    -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH" \
    archive

echo "==> C-2: exportArchive"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTS" \
    -exportPath "$IPA_DIR" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
    -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID" \
    -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH"

IPA=$(find "$IPA_DIR" -name "*.ipa" | head -1)
echo "==> IPA: $IPA"

echo "==> C-3: upload to App Store Connect"
xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$APP_STORE_CONNECT_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"

echo "==> upload OK. App Store Connect で処理待ち (5〜30 分)..."

# ==== D: compliance + テスター招待 ====
# 処理完了を待つ簡易リトライ。
echo "==> D-1: ビルド処理完了を待ち中..."
for i in $(seq 1 30); do
    sleep 30
    if ./scripts/asc-api.py mark-build-compliance --bundle-id "$BUNDLE_ID" 2>/dev/null; then
        echo "compliance マーク完了"
        break
    fi
    echo "  ($i/30) まだ処理中..."
done

if [ -n "$TESTER_EMAIL" ]; then
    echo "==> D-2: 内部テスター招待 ($TESTER_EMAIL)"
    ./scripts/asc-api.py add-internal-tester \
        --bundle-id "$BUNDLE_ID" \
        --email "$TESTER_EMAIL" \
        --first-name "$TESTER_FIRST" || true
    echo ""
    echo "==> 完了。$TESTER_EMAIL に TestFlight 招待メールが届きます。"
else
    echo "==> D-2: TESTFLIGHT_TESTER_EMAIL が未設定なのでテスター招待は省略"
    echo ""
    echo "==> 完了。"
fi
echo "    https://appstoreconnect.apple.com/apps を開いて TestFlight タブから確認可。"
