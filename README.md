# audio-router-ios

macOS の [AudioRouter](https://github.com/4noha/audio-router) のコンパニオン iOS アプリ。
[Android 版](https://github.com/4noha/audio-router-android) と同じプロトコルで、
iPhone のマイク音を LAN 越しに Mac へ送り（AudioRouter の「ワイヤレスマイク」）、
Mac からの戻しを受けて再生する。

## 必要環境

- iPhone、iOS 17 以上（kAudioFormatOpus / AVAudioConverter 対応のため）
- Wi-Fi で Mac と同じネットワーク
- Mac 側 `audio-router` が起動中
- Apple Developer Program (TestFlight 配信用) もしくは無料 Apple ID
  (Xcode から実機 sideload, 7 日期限)

## ビルド

```bash
# 初回・project.yml 変更後
brew install xcodegen          # 未インストールなら
./scripts/bootstrap.sh         # .xcodeproj 生成

# 実機テスト
open AudioRouterCompanion.xcodeproj
# Xcode → Signing & Capabilities で Team を選択
# iPhone を接続 → Run
```

Team を毎回選ばずに済ませるには、git 管理外の `local.xcconfig` に書いておく
（`Config.xcconfig` が読む）:

```
DEVELOPMENT_TEAM = ABCDE12345
```

## TestFlight アップロード

```bash
export APP_STORE_CONNECT_KEY_ID=ABC1234567
export APP_STORE_CONNECT_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export APP_STORE_CONNECT_KEY_PATH=/path/to/AuthKey_ABC1234567.p8
export TESTFLIGHT_TESTER_EMAIL=you@example.com   # 省略可。内部テスターとして招待する
./scripts/upload-testflight.sh
```

これらは `~/.appstoreconnect/.env`（chmod 600）に書いておけば自動で読まれる。
スクリプトは、App Store Connect のアプリ確認 → Archive → Export → upload →
輸出規制コンプライアンスのマーク → 内部テスター招待までを行う。
アプリが App Store Connect に未登録なら、先に Web UI で登録する
（Bundle ID = `com.fournoha.audiorouter.ios`。自分で配るときは変える）。

## 使い方

1. Mac で AudioRouter を起動する（起動すると Bonjour `_4noha-audio._udp` を公開する）
2. iOS アプリ起動 → マイク権限・ローカルネットワーク権限を許可
3. 「Mac (発見済み・到達性確認済)」セクションに Mac が出てきたらタップ
4. ペアリング後 (status「ペアリング済」) で送信開始
5. Mac 側 UI に「(端末名)」の「ワイヤレスマイク」行が自動追加される
6. 戻し（Mac → iPhone）は、Mac 側で「ネットスピーカー」を送り先にした行を有効にすると再生される

送信中はロック画面・コントロールセンターの「再生中」に表示され、そこから停止できる。

## プロトコル

Mac 側の [`NetAudioProtocol.swift`](https://github.com/4noha/audio-router/blob/main/Sources/AudioRouterCore/NetAudioProtocol.swift) が正。
22B header + Opus/PCM payload、UDP、Bonjour `_4noha-audio._udp` で発見。

## ディレクトリ

```
audio-router-ios/
├── project.yml                   xcodegen spec
├── Config.xcconfig               local.xcconfig（git 管理外）を読む
├── scripts/
│   ├── bootstrap.sh              .xcodeproj 生成
│   ├── upload-testflight.sh      Archive → ExportArchive → upload → テスター招待
│   ├── asc-api.py                App Store Connect API（アプリ登録・コンプライアンス・テスター）
│   └── generate-icon.swift       アプリアイコン（1024px）の生成
├── AudioRouterCompanion/
│   ├── App.swift                 SwiftUI @main
│   ├── ContentView.swift         UI
│   ├── ViewModel.swift           Bonjour + PingVerifier + AudioBridge 配線
│   ├── Net/
│   │   ├── NetAudio.swift        プロトコル (Mac/Android と byte 一致)
│   │   ├── BonjourBrowser.swift  NWBrowser
│   │   └── PingVerifier.swift    unicast PING/PONG 検証
│   ├── Audio/
│   │   ├── OpusCodec.swift       AVAudioConverter (Opus) wrapper
│   │   ├── AudioBridge.swift     mic + speaker + UDP send/recv
│   │   └── NowPlayingControl.swift  ロック画面の「再生中」表示と停止ボタン
│   └── Resources/
│       ├── Assets.xcassets/
│       └── Info.plist            (xcodegen が生成)
└── CLAUDE.md
```

## ライセンス

MIT License（`LICENSE`）。
