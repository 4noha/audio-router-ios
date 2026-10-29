# CLAUDE.md — audio-router-ios

iOS アプリ。Mac の AudioRouter に LAN で接続してマイク音声を送信、Mac
からの戻し（任意ミックス・効果音）を受信して再生する Android 版の
対向 iOS 実装。

> **親ワークスペース**: `~/works/4noha-studio-family/`。プロトコル仕様の
> 権威は Mac 側の
> `audio-router/Sources/AudioRouterCore/NetAudioProtocol.swift` と
> `audio-router-android/.../NetAudio.kt`。本リポは byte 一致で 3 実装目。

## アーキテクチャ

```
App (SwiftUI)
  └─ ViewModel (@Observable)
      ├─ BonjourBrowser  NWBrowser で _4noha-audio._udp 解決 → 候補
      ├─ PingVerifier    候補に unicast PING、PONG 返ったものを Spinner へ
      ├─ AudioBridge     AVAudioEngine(mic+speaker) + AVAudioConverter(Opus)
      │                   + 1 つの UDP socket で送受信両方
      └─ NowPlayingControl  ロック画面の「再生中」表示 + 停止ボタン（Android の常駐通知に相当）
NetAudio                 22B header (4NHA…) の encode/decode (3 実装 byte 一致)
OpusCodec                AVAudioConverter (kAudioFormatOpus) ラッパ
```

- すべて Swift。最小要件 **iOS 17 以上** (kAudioFormatOpus の AudioConverter
  対応に必要)。
- Opus は **AudioToolbox 標準**で扱う。libopus 等の vendor 不要。
- AVAudioSession は `.playAndRecord` + `.defaultToSpeaker`、Background mode
  `audio` で バックグラウンド維持。

## ビルド / 配信

```bash
# 初回 / project.yml 編集後
./scripts/bootstrap.sh           # xcodegen で .xcodeproj 生成

# 実機テスト (有料 Apple Developer Program / 無料 Apple ID どちらでも)
open AudioRouterCompanion.xcodeproj
# Xcode で Team を選択 → 実機へ Run

# TestFlight アップロード (要 Apple Developer Program)
# 認証情報と TESTFLIGHT_TESTER_EMAIL は ~/.appstoreconnect/.env から自動で読む
./scripts/upload-testflight.sh
```

- **Team ID・配信先のメールアドレスは公開リポジトリに載せない。**
  - Team ID: git 管理外の `local.xcconfig` に `DEVELOPMENT_TEAM = …`（`Config.xcconfig` が `#include?` で読む）。
    `project.yml` の `settings` に書くと xcconfig より優先されるので書かない。
  - 配信先: `TESTFLIGHT_TESTER_EMAIL`（`~/.appstoreconnect/.env`）。未設定なら招待を省略する。

## 規約・前提

- 言語: Swift 5.9 / iOS 17.0+
- Bundle ID: `com.fournoha.audiorouter.ios`
- パケット仕様: **22B header + payload, magic "4NHA", BE**, Mac/Android と
  byte 一致 (`NetAudio.swift`)
- 端末名 = `UIDevice.current.name`。HELLO payload で Mac に送る → Mac 側は
  端末名で行管理 (slot は動的割当を hello-ack で受け取る)
- 1 packet 1 frame、MTU 内に収める (Opus 20ms = ~80B → 余裕)
- フレームサイズ 960 サンプル (20ms @48k) 固定

## 落とし穴

- **iOS 17 未満では `kAudioFormatOpus` の AVAudioConverter 対応が無い**。
  ビルド時の deployment target を 17.0 にしておく。
- **`NSBonjourServices` を Info.plist に書かないと NWBrowser が動かない**
  (iOS 14+ の Local Network 制限)。`_4noha-audio._udp` を必ず登録。
- **`NSLocalNetworkUsageDescription` 必須**（無いとローカル通信が動かない）。
- **AVAudioSession の category は `playAndRecord` + `defaultToSpeaker`**。
  `record` のみだと再生 (戻し) ができない。
- Background audio: `UIBackgroundModes` に `audio` を入れ、`AVAudioSession`
  を active に保つ。マイクキャプチャはバックグラウンドでも継続。
- xcodegen 生成の `.xcodeproj` と `Info.plist` は `.gitignore` 対象。
  毎回 `./scripts/bootstrap.sh` で再生成。

## 既知の TODO

- 多 NIC (Wi-Fi 切替) 時の socket 再構築。今は AVAudioSession 経由で
  自然回復することが多いが明示再接続なし
- 通話などによる AVAudioSession 割り込み (interruption notification) を
  まだハンドルしてない
- iOS 側 PCM-fallback (Mac が PCM のみで送ってきた場合の対応は実装済、
  受信は PCM16/Opus 両対応)

## 検証状況 (v0.3.1、2026-10-30)

- `xcodebuild` で iOS Simulator ビルド成功（`CODE_SIGNING_ALLOWED=NO`）。コードの警告ゼロ
- `local.xcconfig` があると `DEVELOPMENT_TEAM` が入り、無いと未設定になることを `-showBuildSettings` で確認
