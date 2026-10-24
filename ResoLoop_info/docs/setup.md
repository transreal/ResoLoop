# ResoLoop セットアップ手順書

ResoLoop は、Resonite の世界 (Slot / Component / ProtoFlux) を ResoniteLink 経由で操作する CLI **resoloop** を Mathematica から扱うための共通層です。
resoloop 本体は別プロジェクト (AGPL-3.0-or-later) であり、**このリポジトリには含まれていません**。本書の手順で利用者自身が導入してください。

macOS/Linux ではパス区切りやシェルコマンドを適宜読み替えてください (本書は Windows 11 を前提とします)。

## 1. 前提環境

- **Wolfram Language / Mathematica**: 14.x 以降を推奨します (Association、`RawJSON`、`StartProcess` / `RunProcess`、`ScheduledTask` を多用します)。
- **OS**: Windows 11 (`%LOCALAPPDATA%` 配下のジョブ記録、bat 経由の非同期実行など Windows 前提の実装を含みます)。
- **Resonite**: デスクトップクライアント。操作したいセッションの **ホスト** であり、Dashboard → Session → Settings で **Enable ResoniteLink** を押しておく必要があります。ResoniteLink 0.13 系で動作確認しています。
- **.NET 10 SDK**: resoloop と Flux-SDK は dotnet グローバルツールとして配布されています。ランタイムだけでは `dotnet tool` が使えないので SDK が要ります。
- **resoloop** (`0.1.0` で動作確認): 下記 3 節。
- **Flux-SDK** (任意、`Papaltine.FluxSDK` 1.9.0): ProtoFlux (ProtoGraph) の check / build / deploy を使うときだけ。
- **Claude Code CLI** (任意): 自然文の依頼から世界を組み立てる建築ジョブ (`ResoLoopBuildSubmit`) が `claude --print` を別プロセスで起動します。

## 2. 依存パッケージ (すべて任意)

- **NBAccess.wl**: あると、読み取り系・ジョブ系の `ResoLoop*` を許可ヘッドに、`ResoLoopApply` / `ResoLoopSlotDelete` などを承認ヘッドに自動登録します (`ResoLoopRegisterHeads[]`)。
- **claudecode.wl**: `ResoLoopBuildWatch[]` (共有 polling tick でジョブを見張り、完了時にノートブックへ書く) と `$ClaudePackageKeywordMap` への登録に使います。
- **SourceVault.wl**: `ResoLoop_mcp.wl` が SourceVault MCP の外部登録簿に `sourcevault_resonite_*` tool 群を登録します。無ければ MCP 登録はスキップされます。
- **ResoniteRealtime.wl**: 上位パッケージ。3D 生成 (`ResoniteGraphics3D`) が本パッケージの `ResoLoopApply` を使います。→ [ResoniteRealtime](https://github.com/transreal/ResoniteRealtime)

## 3. resoloop の導入 (GitHub / NuGet から)

resoloop のソースは https://github.com/orange3134/resoloop 、配布物は nuget.org の dotnet グローバルツール `ResoLoop` です。

1. .NET 10 SDK を入れます (管理者権限の PowerShell)。

   ```powershell
   winget install Microsoft.DotNet.SDK.10
   dotnet --list-sdks
   ```

2. resoloop を入れます。動作確認した版を `--version` で明示します。

   ```powershell
   dotnet tool install --global ResoLoop --version 0.1.0
   resoloop --version
   ```

   実体は `%USERPROFILE%\.dotnet\tools\resoloop.exe` に置かれ、同フォルダがユーザー PATH に追加されます (`$ResoLoopExecutable` を明示しても構いません)。更新は `dotnet tool update --global ResoLoop --version <ver>`。dotnet tool は機械ごとに入るので、Dropbox などでパッケージを共有していても PC ごとに更新が要ります。更新後は各プロジェクトで `resoloop skills sync <プロジェクト> --check` を見て、更新があれば `--update` の後に `ResoLoopProjectSync[name]` で `.claude/skills` へ複製し直してください。

3. (任意) Flux-SDK を入れます。resoloop が要求する版は 1.9.0 です (`resoloop doctor` の指示に合わせてください)。

   ```powershell
   dotnet tool install --global Papaltine.FluxSDK --version 1.9.0
   flux-sdk --version
   ```

4. 環境変数をユーザースコープに永続化します (resoloop が Resonite の DLL とログを見つけるため)。

   | 変数 | 値 |
   | --- | --- |
   | `RESONITE_MANAGED_DATA_PATH` | Resonite のインストール先 (例 `C:\Program Files (x86)\Steam\steamapps\common\Resonite`。FrooxEngine.dll が直下にあるフォルダ) |
   | `RESONITE_LOG_PATH` | 同フォルダの `Logs` |

   `RESONITE_LINK_URL` は **永続化しないでください**。ResoniteLink のポートは Resonite の起動毎に変わるので、`ResoLoopConnect[]` が `resoloop discover` で毎回拾います。

## 4. Resonite 側の準備

1. 操作したいワールドのセッションを自分がホストします。
2. Dashboard → Session → Settings → **Enable ResoniteLink**。「ポート NNNNN で動作中」と表示されれば準備完了です。
3. ResoniteLink はそのセッションが続く間だけ有効です。Resonite を起動し直したら再度有効化してください (ポートは変わります)。

## 5. パッケージの配置と読込

1. 本リポジトリをクローンし、`.wl` ファイル 3 本 (`ResoLoop.wl` / `ResoLoop_builder.wl` / `ResoLoop_mcp.wl`) を `$packageDirectory` 直下に、`ResoLoop_info/` フォルダをその隣に置きます (サブディレクトリに分けないこと。`ResoLoop.wl` が同じディレクトリの補助モジュールを自動ロードします)。

   ```bash
   git clone https://github.com/transreal/ResoLoop.git
   ```

2. 読み込みます。

   ```wolfram
   Block[{$CharacterEncoding = "UTF-8"}, Get["ResoLoop.wl"]];
   ```

   NBAccess / claudecode / SourceVault を使う場合は、それらを **先に** ロードしておくと登録が自動で行われます (後からロードしたときは `ResoLoopRegisterHeads[]` と `ResoLoopMCPRegister[]` を手で呼びます)。

## 6. プロジェクトの作成

resoloop は「プロジェクト」(`resoloop init` が作るフォルダ。`.resoloop.json`、宣言ファイル `content/`、ProtoFlux `flux/`、状態 `.resoloop/state/`) の中で動きます。置き場は `$ResoLoopProjectsDirectory` (既定 `<$packageDirectory>/ResoLoop_projects`) です。

```wolfram
ResoLoopProject["MyResoniteProject", "Create" -> True]   (* 既定プロジェクト ($ResoLoopDefaultProject) *)
ResoLoopProject["VoiceBuilds", "Create" -> True]         (* 建築ジョブの既定プロジェクト ($ResoLoopBuilderProject) *)
```

`"Create" -> True` は `resoloop init` を走らせ、続けて `ResoLoopProjectSync` が `.agents/skills` を `.claude/skills` に複製し、`CLAUDE.md` を作ります。`resoloop init` が生成する Skill / AGENTS.md は resoloop の成果物なので、リポジトリには含めていません (各自のプロジェクトで生成されます)。

置き場が Dropbox などの同期フォルダにある場合、`ResoLoopProjectSync` は `.resoloop` / `artifacts` / `flux/build` に Dropbox の無視属性を付けます。それでも新規ファイルが同期に掴まれて `APPLY_STATE_WRITE_FAILED` になることがあるため、大量に apply する用途では `$ResoLoopProjectsDirectory` を同期フォルダの外 (例 `%LOCALAPPDATA%\ResoLoop\projects`) に置くことを推奨します。

## 7. 動作確認

```wolfram
ResoLoopExecutable[]        (* resoloop.exe のパス。Failure["NotInstalled"] なら 3 節 *)
ResoLoopVersion[]           (* "0.1.0" *)
ResoLoopDoctor[]            (* 接続 / Flux-SDK / managed data / log の各項目 *)
ResoLoopConnect[]           (* "ws://localhost:<port>/"。候補が無ければ Failure["ResoniteLinkOff"] *)
ResoLoopStatus[]["resoniteVersion"]
ResoLoopHierarchy["Root", 1]
```

`ResoLoopDoctor[]` の全項目 (0.1.0 では resonite-link-url / flux-sdk / resonite-managed-data / resonite-log の 4 項目) がすべて pass なら準備完了です。resonite-link-url は Resonite でホストして Enable ResoniteLink するまで fail のままで正常です。

## 8. 任意機能の設定

### 8.1 建築ジョブ (ResoLoop_builder.wl)

- Claude Code CLI (`claude.cmd` / `claude.exe`) が `%APPDATA%\npm` か `~/.local/bin` にあれば自動で見つかります。別の場所なら `$ResoLoopBuilderExecutable` に設定してください。
- ジョブはプロジェクトを cwd にして `claude --print --output-format stream-json` を別プロセスで起動します。`ResoLoopProjectSync[name, "BuilderPolicy" -> True]` を一度実行すると、プロジェクトの `.claude/settings.json` に allow (`Bash(resoloop *)` など) と deny (`slot delete` / `component remove` / `--prune` / `--adopt`) が書かれ、これが安全境界になります。
- ジョブ記録は `$ResoLoopBuilderJobsDirectory` (既定 `%LOCALAPPDATA%\ResoLoop\jobs`)。

### 8.2 MCP tool (ResoLoop_mcp.wl)

SourceVault がロード済みなら、ロード時に `sourcevault_resonite_*` が SourceVault MCP の外部登録簿に登録され、`$SourceVaultServiceExtraPackages` に `ResoLoop.wl` が加わります。**service kernel に反映するには SourceVault service の再起動が要ります。**

### 8.3 Claude Directives の規則

ClaudeEval (claudecode.wl) から resoloop を使わせる場合の方針文 `109-resonite-resoloop-mcp.md` を `ResoLoop_info/directives/` に同梱しています。`Claude Directives/rules/` にコピーしてください (観測してから答える、建築は 1 回の submit と polling、削除は人の同意の後、など)。

## 9. トラブルシューティング

| 症状 | 原因と対処 |
| --- | --- |
| `Failure["NotInstalled"]` | resoloop が見つからない。3 節の手順で導入し、新しいシェル/カーネルで PATH を読み直す。または `$ResoLoopExecutable = "C:\\...\\resoloop.exe"` |
| `Failure["ResoniteLinkOff"]` | ResoniteLink が有効化されていない、またはホストでない。4 節。`ResoLoopDiscover[]` で候補を確認 |
| `Failure["AmbiguousSession"]` | 複数セッションが見つかった。`ResoLoopConnect["Session" -> 名前]` か `"URL" -> "ws://localhost:<port>/"` |
| `Failure["OutsideOwnership"]` | root 名が `ResoLoop_` で始まらない Slot を変更しようとした。所有境界は迂回できない (仕様) |
| `Failure["Busy"]` | 同じプロジェクトで mutation が実行中 (1 プロジェクト 1 mutation)。`ResoLoopLocks[]` で確認 |
| `APPLY_STATE_WRITE_FAILED` | プロジェクトの `.resoloop/state` を同期ソフトが掴んだ。同じ apply を再実行する (checkpoint から収束)。恒常的なら 6 節の置き場変更 |
| `resoloop logs` が共有違反で失敗 | Resonite 起動中は最新ログが書込共有なしで開かれている (resoloop 側の仕様)。最新 .log をコピーしてから `--path` で読む |
| `dotnet tool` が `No .NET SDKs were found` | ランタイムだけで SDK が無い。3 節 1. |
| Flux-SDK 1.10.0 で doctor の flux-sdk / resonite-managed-data が warning | resoloop 0.1.0 のテスト済みは 1.9.x のため。managed-data の確認処理は 1 行の `module X where { }` を check するが、1.10.0 は `module X` の後に改行が無いと PG1036 で拒否する。通常の ProtoGraph (`module X` 改行 `where {...}`) は 1.10.0 でも check が通る (2026-10-24 確認)。1.9.0 に戻すには `dotnet tool update --global Papaltine.FluxSDK --version 1.9.0 --allow-downgrade` |
| 建築ジョブが `Failure["BackendUnavailable"]` | PrivacyLevel > 0.5 (私有ワールド相当) はローカル LLM backend 担当で v0.1 未実装。黙ってクラウドへ送らない設計 |
