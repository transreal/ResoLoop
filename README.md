# ResoLoop

## 設計思想と実装の概要

**ResoLoop** は、VR プラットフォーム Resonite の世界 (Slot / Component / ProtoFlux) を ResoniteLink 経由で操作する CLI **resoloop** を、Mathematica (Wolfram Language) から安全に扱うための共通層パッケージです。

resoloop は orange3134 氏による別プロジェクト (AGPL-3.0-or-later、dotnet グローバルツール) であり、ライセンスが異なるため **本リポジトリには同梱していません**。利用者が GitHub / NuGet から導入したうえで、本パッケージがそれを `RunProcess` で呼び出します。導入手順は [setup.md](ResoLoop_info/docs/setup.md) にまとめてあります。

最も重要な設計判断は、**「この層だけが CLI を知る」** ことです。ノートブックからの直接呼び出し、SourceVault MCP 経由の LLM ツール、上位の ResoniteRealtime (ワールド内タブレットや 3D 生成)、音声インタフェースなど、すべての経路が `ResoLoop.wl` を通ります。そのため次の制約をこの一箇所で強制でき、上位が迂回することはできません。

- **応答契約**: resoloop の `--json` 応答 (`{"ok":true,"data":...}` / `{"ok":false,"error":{...}}`) を `data` または `Failure["ResoLoop", ...]` に正規化します。失敗 JSON は stderr に出るので両方を読みます。
- **所有境界**: 変更できるのは root 名が `ResoLoop_` で始まる Slot の配下、または状態ファイルで解決される安定セレクタ (`$slot:key`) だけ。`Root` や他人の物は `Failure["OutsideOwnership"]`。
- **Confirm / Adopt**: 削除・prune・probe は `"Confirm" -> True` が無ければ `--yes` を付けず (resoloop 側が拒否)、`--adopt` は人がノートブックで `"Adopt" -> True` と書いたときだけ。
- **排他**: 1 プロジェクト 1 mutation (カーネル内 mutex)。
- **機密度**: 観測結果には機密度 (PrivacyLevel) が付き、私有ワールド相当 (> 0.5) の建築はローカル LLM backend の担当です。未実装の間は `Failure["BackendUnavailable"]` を返し、黙ってクラウドへ送りません。

もう一つの柱は **非同期** です。自然文の依頼から世界を組み立てる建築ジョブ (`ResoLoop_builder.wl`) は、resoloop プロジェクトを cwd にして Claude Code CLI (`claude --print`) を別 OS プロセスで起動します。プロジェクトの `CLAUDE.md` と Skill が効くので手作業と同じ手順 (型調査 → 宣言 → validate → diff → apply → 撮影 → item audit) を踏み、進捗は stream-json を後から読んで判定するため polling tick を要しません。ノートブックでは `ResoLoopBuildSubmit[依頼]; ResoLoopBuildWatch[]` の 1 セルが数秒で返り、完了時に要約と撮影画像が書かれます。

`ResoLoop_mcp.wl` は同じ機能を SourceVault MCP の tool 群 `sourcevault_resonite_*` として登録し、ClaudeEval (Claude Code CLI とローカル LLM の両経路) から使えるようにします。ResoniteLink は「利用者が常時オンにしている」前提で、オフのときは `ResoniteLinkOff` で知らせるだけで、待ち続けたり代替経路に落ちたりしません。

## 詳細説明

### 動作環境

- **Wolfram Language / Mathematica**: 14.x 以降を推奨します。
- **OS**: Windows 11 を前提としています (`%LOCALAPPDATA%` のジョブ記録、bat 経由の非同期実行など)。
- **Resonite**: 操作するセッションの **ホスト** であり、Dashboard → Session → Settings で **Enable ResoniteLink** を押しておく必要があります (ResoniteLink 0.13 系で確認)。
- **.NET 10 SDK** と **resoloop** (`0.1.0-preview.13` で確認): [setup.md](ResoLoop_info/docs/setup.md) の手順で導入します。
- **Flux-SDK** (任意、1.9.0): ProtoFlux (ProtoGraph) の check / build / deploy を使う場合。
- **Claude Code CLI** (任意): 建築ジョブの既定 backend。
- **依存パッケージ (すべて任意)**: NBAccess.wl (許可ヘッド / 承認ヘッドの登録)、claudecode.wl (`ResoLoopBuildWatch` の polling tick)、SourceVault.wl (MCP 登録)、ResoniteRealtime.wl (上位。3D 生成が本パッケージを使う)。

### インストール

1. resoloop を導入します (本リポジトリには含まれません)。

   ```powershell
   winget install Microsoft.DotNet.SDK.10
   dotnet tool install --global ResoLoop --version 0.1.0-preview.13
   dotnet tool install --global Papaltine.FluxSDK --version 1.9.0    # 任意
   ```

   環境変数 `RESONITE_MANAGED_DATA_PATH` (Resonite のインストール先) と `RESONITE_LOG_PATH` (同 `Logs`) をユーザースコープに設定します。`RESONITE_LINK_URL` は永続化しません (ポートは起動毎に変わり、`ResoLoopConnect[]` が探索します)。

2. 本リポジトリをクローンし、`ResoLoop.wl` / `ResoLoop_builder.wl` / `ResoLoop_mcp.wl` を `$packageDirectory` 直下に、`ResoLoop_info/` をその隣に置きます。

   ```bash
   git clone https://github.com/transreal/ResoLoop.git
   ```

3. Resonite で ResoniteLink を有効化し、Mathematica で読み込みます。

   ```wolfram
   Block[{$CharacterEncoding = "UTF-8"}, Get["ResoLoop.wl"]];
   ResoLoopProject["MyResoniteProject", "Create" -> True];   (* resoloop init *)
   ResoLoopDoctor[]
   ```

4. ClaudeEval から使う場合は、`ResoLoop_info/directives/109-resonite-resoloop-mcp.md` を `Claude Directives/rules/` にコピーします。

詳細は [setup.md](ResoLoop_info/docs/setup.md) を参照してください。

### クイックスタート

```wolfram
ResoLoopConnect[]                                   (* ws://localhost:<port>/ *)
ResoLoopFind["Name" -> "ResoLoop_", "Depth" -> 1]  (* 自分が作った root 一覧 *)
ResoLoopValidate["content/spinbox.json", "Strict" -> True]
ResoLoopDiff["content/spinbox.json"]               (* create 以外が無いことを見る *)
ResoLoopApply["content/spinbox.json"]
ResoLoopInspect["$slot:box", "State" -> "spinbox"]["rotation"]
ResoLoopSlotDelete["$slot:root", "State" -> "spinbox", "Confirm" -> True]
```

自然文で頼むなら:

```wolfram
ResoLoopBuildSubmit["青い箱を目の前に作って"];
ResoLoopBuildWatch[]
```

### 主な機能

- **接続と環境**: `ResoLoopDoctor` / `ResoLoopDiscover` / `ResoLoopConnect` / `ResoLoopStatus`。ポートは毎回探索します。
- **観測 (読み取り専用)**: `ResoLoopHierarchy` / `ResoLoopFind` / `ResoLoopInspect` / `ResoLoopComponentInspect` / `ResoLoopTypeSearch` / `ResoLoopTypeDescribe` / `ResoLoopSceneSummary`。
- **宣言ファイル**: `ResoLoopValidate` (Strict は接続して実在の型と突合) / `ResoLoopDiff` / `ResoLoopApply` (同じ apply の再実行で収束) / `ResoLoopTest` / `ResoLoopCapture` / `ResoLoopItemAudit`。
- **原始操作**: `ResoLoopSlotCreate` / `ResoLoopSlotSet` / `ResoLoopSlotDelete` / `ResoLoopComponentAdd` / `ResoLoopComponentSet` / `ResoLoopComponentRemove` (所有境界内のみ)。
- **ProtoFlux**: `ResoLoopFluxCheck` / `ResoLoopFluxBuild` / `ResoLoopFluxNodeSearch` / `ResoLoopFluxDeployManifest` (Flux-SDK)。
- **非同期**: `ResoLoopRunAsync` とジョブ回収 (サービスカーネル向け)。
- **建築ジョブ**: `ResoLoopBuildSubmit` / `ResoLoopBuildWatch` / `ResoLoopJobStatus` / `ResoLoopJobResult` / `ResoLoopUserPlacement` (アバター正面の置き場所)。
- **MCP tool**: `sourcevault_resonite_status` / `query` / `build` / `job_status` / `job_result` / `adjust` / `remove`。

### ドキュメント一覧

- [api.md](ResoLoop_info/docs/api.md) — オプションを含む API リファレンス
- [setup.md](ResoLoop_info/docs/setup.md) — セットアップ手順書 (resoloop の導入を含む)
- [user_manual.md](ResoLoop_info/docs/user_manual.md) — ユーザーマニュアル
- [example.md](ResoLoop_info/docs/examples/example.md) — 使用例集
- [resoloop_integration_spec_v0_1.md](ResoLoop_info/design/resoloop_integration_spec_v0_1.md) — 統合仕様 (設計と実装記録)
- [109-resonite-resoloop-mcp.md](ResoLoop_info/directives/109-resonite-resoloop-mcp.md) — ClaudeEval 向けの規則 (Claude Directives 用の写し)

## 使用例・デモ

```wolfram
Block[{$CharacterEncoding = "UTF-8"}, Get["ResoLoop.wl"]];
ResoLoopConnect[];
ResoLoopBuildSubmit["黄色い円錐を目の前に作って"];
ResoLoopBuildWatch[]
```

完了すると、作った root 名 (`ResoLoop_...`)、要約、撮影画像がノートブックに書かれます。上位パッケージ ResoniteRealtime では、Mathematica の `Plot3D` の出力を本パッケージの `ResoLoopApply` を通してワールド内の掴めるメッシュにする「3D 生成」を実装しています。

## 謝辞

- resoloop (orange3134 氏、AGPL-3.0-or-later) と Flux SDK (Papaltine、AGPL-3.0) を外部ツールとして利用しています。どちらも本リポジトリには含まれません。
- Resonite / ResoniteLink は Yellow Dog Man Studios の製品です。

---

## 免責事項

本ソフトウェアは "as is"（現状有姿）で提供されており、明示・黙示を問わずいかなる保証もありません。
本ソフトウェアの使用または使用不能から生じるいかなる損害についても責任を負いません。
今後の動作保証のための更新が行われるとは限りません。
本ソフトウェアとドキュメントはほぼすべてが生成AIによって生成されたものです。
Windows 11上での実行を想定しており、MacOS, LinuxのMathematicaでの動作検証は一切していません(生成AIの処理で対応可能と想定されます)。

---

## ライセンス

```
MIT License

Copyright (c) 2026 Katsunobu Imai

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

上記ライセンスは本リポジトリのコードとドキュメントに適用されます。外部ツールとして呼び出す resoloop と Flux SDK はそれぞれ AGPL-3.0 で配布されており、本リポジトリには含まれていません。
