# resoloop 統合仕様 v0.1 — ClaudeEval / ResoniteRealtime / Resonite ボイスチャット

**resoloop は「Resonite の構造とロジックを変更する唯一の窓口」に固定し、WL・音声・ノートブックの各入口はすべて同じ薄い層 (ResoLoop.wl) を通す。リアルタイム経路 (L1/L2 の値の読み書き) は従来どおり ResoniteRealtime が持つ。**

- 日付: 2026-09-22
- ステータス: v0.1 ドラフト (未レビュー・未実装)
- 対象:
  - 新規 `ResoLoop.wl` (context `ResoLoop``)、`ResoLoop_mcp.wl`、`ResoLoop_builder.wl`
  - `ResoniteRealtime.wl` 系 (新規 `ResoniteRealtime_resoloop.wl`、`ResoniteRealtime_voice.wl`)
  - `VRCRealtime_info/resources/python/VRCRealtime_worker.py` (core / platform 分割)、新規 `platform_resonite.py`
  - `SourceVault_mcp.wl` (外部ツール登録フック)、`claudecode_directives.wl` (規則 1 本)
  - `ResoLoop_projects/` (resoloop プロジェクトの置き場。既存)
- 関連:
  - `ResoniteRealtime_info/docs/protoflux-llm-generation-proposal.md` (方式 C = ProtoGraph 経由。本仕様はその [D] デプロイ工程を resoloop で埋める)
  - `ResoniteRealtime_info/docs/api.md` (L1/L2/L3、Chat / Flux ガジェット)
  - `VRCRealtime_info/docs/api.md` (`VRCRealtimeStart` のオプション体系。音声ワーカーの WL 側契約)
  - `ResoniteIO_setup/README.md` (WSL2+Docker のボットクライアント)
  - `ResoLoop_projects/MyResoniteProject/CLAUDE.md` (resoloop / Flux-SDK 1.9 の実測された罠)
  - `ClaudeOrchestrator_info/design/claude_orchestrator_worker_dispatch_spec_v0_1.md` (ワーカー束縛。建築ジョブの backend 選択はこれに従う)

---

## 0. 目的とスコープ

### 0.1 目標

| ID | 目標 | 到達判定 |
| --- | --- | --- |
| G1 | ClaudeEval (ノートブックの ClaudeInput セル) から resoloop を使える | ClaudeInput に「Resonite に青い箱を作って」と書くと、モデルが MCP ツールで建築ジョブを起こし、完了報告と `capture` の画像がセルに出る |
| G2 | ResoniteRealtime から resoloop を使える | `ResoniteChatGadget[]` / `ResoniteFluxGenerate[]` の世界への書き込みが resoloop 経由になり、再実行が冪等 (2 回目 apply が書込 0) になる |
| G3 | ResoniteRealtime が VRCRealtime と同様のボイスチャットを Resonite で行える | ボットが Resonite のセッションに参加し、声で質問に答え、SourceVault KB を引き、スライド発表ができる |
| G4 | ボイスチャットで resoloop を使える | 「青い箱を作って」と声で言うと「作り始めます」→ (数十秒) →「できました」と答え、目の前に箱が出る |

### 0.2 前提

- **ResoniteLink は利用者 (オーナー) が Dashboard で常時オンにしておく** (2026-09-22 時点でオン)。本仕様はその前提で書き、オフの場合に備えた代替経路は設計しない。オフ・候補なし・ホスト不在は「前提違反」として検出して知らせるだけ (§3.2、§10.2)。
- オーナーのクライアントがセッションホストであり、ボット (G3) は同じセッションに参加者として入る。resoloop の接続先は常にオーナーのクライアント。
- ポートは Resonite の起動ごとに変わるので、値は固定せず `discover` / `--url auto` で毎回解決する。

### 0.3 非スコープ

- resoloop によるリアルタイム制御 (毎フレームの値駆動)。CLI 1 呼び出しは約 1 s (実測) で、その用途には向かない。従来の L1 (WebsocketClient 行プロトコル) と L2 の値書き込みを使う。
- resoloop の所有外 (ownership root の外) にある既存コンテンツの編集・削除。音声・ノートブックのどちらからも扱わない。
- Codex 経路の整備。`.agents/skills` は resoloop が保守するので触らない。
- ResoniteIO の GPU 描画性能の改善 (WSL2 では 3 fps。音声・移動には無関係と見込むが §10 で確認する)。

---

## 1. 現状 (実測に基づく事実)

設計はここからの差分として書く。

### 1.1 resoloop (0.1.0-preview.13、Flux-SDK 1.9.0)

| 項目 | 事実 |
| --- | --- |
| 形態 | dotnet グローバルツール。AI との接点は「シェルから `--json` で叩く」と「`AGENTS.md` + `.agents/skills/*/SKILL.md`」だけ。MCP/API は無い |
| 出力契約 | 成功 `{"ok":true,"data":…}` / 失敗 `{"ok":false,"error":{"code","message","context","suggestions"}}`。**失敗時の JSON は stderr** |
| 接続 | ResoniteLink (`ws://localhost:<port>`、ポートは起動毎に変わる)。`discover --json` (UDP 通知 12 s) / `--url auto`。有効化はセッションホストのクライアントの Dashboard から。**利用者が常時オンにしておく前提 (§0.2)** |
| 安定参照 | `$slot:key` / `$component:key` / `$member:key.Member` を `.resoloop/state/<ownership>.json` で現在 ID に再解決 |
| 安全装置 | 削除は `--yes` 必須、Root 拒否、既存 root の取り込みは `--adopt` 必須、`AI_GeneratedContent` 自動付与 |
| ProtoFlux | `.pg` → `flux check/build` → `flux deploy-manifest` (bindings で `in`/`out` を世界へ結線、ホットデプロイ)。Slot の transform は直接駆動できず `ValueField<T>`+`ValueCopy<T>` で中継 |
| 実績 | ムードランプ / キッチンタイマー / SpinBox を本手順で実機構築・検証済 (`ResoLoop_projects/MyResoniteProject`) |
| 罠 | `logs` は Resonite 起動中に共有違反、Slot 直接駆動不可、ジェネリック型は `[FrooxEngine]` 接頭辞必須、失敗 JSON は stderr、掴まれると `_lastParent` 外部参照が増える |

### 1.2 ClaudeEval の道具配線 (claudecode.wl)

| 経路 | 道具の供給 |
| --- | --- |
| Claude Code CLI (`--print`) | `ClaudeRegisterCLIMCPServer[id, <|"ConfigFn","AllowedTools","PromptDirective"|>]` に登録された HTTP MCP サーバーを `--mcp-config` + `--strict-mcp-config` + `--allowedTools mcp__<id>__<tool>` で渡す。対話承認は不可 |
| ローカル OpenAI 互換 (LM Studio / llama.cpp) | `$ClaudeLocalToolLoop` がクライアント側ツールループで **同じ SourceVault MCP のツール**を回す |
| クラウド API (GPT / GLM / Kimi) | ツールループ無し (意図的)。InlineContext のみ |

したがって **SourceVault MCP のツール表に載せれば CLI とローカルの両経路に同時に届く**。`sourcevault_submit_web_search` → `sourcevault_job_status` / `sourcevault_job_result` という非同期ジョブの型が既にある。

### 1.3 ResoniteRealtime (2026-09-06 時点)

| 層 | 実体 | 状態 |
| --- | --- | --- |
| L1 | WL が WebSocket サーバー、世界の `WebsocketClient` が接続 (TAB 行、RTT 32 ms) | 実機開通。リアルタイム用 |
| L2 | WL 自前の ResoniteLink クライアント (`ResoniteRealtimeLink*`、`AddSlot`/`AddComponent`/…) | 実機開通。Chat ガジェットの UIX をこれで組み立て |
| L3 | 同ポートで画像配信 (`ResoniteRealtimeShowImage` / `Board`) | 実機開通 |
| Flux | `ResoniteFluxGenerate` 既定 `"Format"->"Graph"` = LLM が JSON グラフ → `_fluxlink` が L2 でノードを直接配置。`"ProtoGraph"` は build まで。提案書の [D] (デプロイ) は「`Loader.replace` が動くか未確認」で止まっていた | resoloop の `deploy-manifest` がこの穴を埋める |

L2 の ID は「セッション中は解放されない・連番危険」(`resonitelink-notes.md`)。resoloop は state ファイルでこれを吸収している。

### 1.4 VRCRealtime (0.11.x)

| 部品 | 役割 | VRChat 依存 |
| --- | --- | --- |
| `VRCRealtime.wl` | `uv run python VRCRealtime_worker.py --model … --input-source … --output-device "CABLE-A Input" …` を起動。state/control の JSON ファイルで対話 | オプション名に VRChat 固有 (`--vrchat-pid`、visual gate、Sliden) が混在 |
| `VRCRealtime_worker.py` (320 KB) | Realtime/Live ブリッジ、VAD、道具 (`sourcevault_lookup` / `private_readout` / `web_search` / `start_presentation` / `presentation_control` / `show_slide` / `set_avatar_mode` / `turn_avatar` / `conversation_control` / `end_conversation` / `look_at_vrchat` / `set_question_mode`)、質問モード、発表状態機械 | 音声 I/O = sounddevice + VB-Cable、状態観測 = OSC 9001、画面 = スクリーンキャプチャ |
| `private_broker` (`PrivateTTSBrokerClient`) | 道具の実行を Wolfram サービスカーネル (`--sourcevault-service-dir` の commands/) へ運ぶ + 非公開文のローカル TTS | 無し |
| `_sliden.py` / `_worldjoin.py` / `_ownerjoin.py` / `_owner_follow.py` / `_owner_formation.py` / `_visual_gate.py` / `_person_detector.py` | VRChat の UI・OCR・マウス制御 | 全部 VRChat 専用 |
| `_voice_commands.py` (Vosk) / `_private_tts.py` / `_live.py` | ローカル音声認識・TTS・GPT-Live 変換層 | 無し |

### 1.5 ResoniteIO (v0.7.0 + 2026.9 パッチ、WSL2+Docker で稼働確認済)

| サービス | 使えること | 制約 |
| --- | --- | --- |
| `Microphone.StreamAudio` (client→bot) | ボットが喋る。**48 kHz / mono / float32 LE 固定** | — |
| `Speaker.StreamAudio` (bot→client) | ボットが聞く。**48 kHz / stereo / float32 LE interleaved 固定** | 自声が混ざるか未確認 (§10) |
| `World.ListSessions` / `Join(session_id)` / `Leave` / `GetCurrent` | オーナーのセッションへ参加 | — |
| `Locomotion.Drive` (stream) | 追従移動 | 目標位置は別途要る (§6.4) |
| `Camera.StreamFrames` | 視界画像 | WSL2 では 3 fps |
| `Auth.Login` / `Contact.*` / `Session.ListUsers` | ボット用アカウント・在席者一覧 | — |
| `Session.ApplySettings` の ResoniteLink 有効化 | **未実装 (proto に予約フィールドのみ)** | → resoloop の接続先はオーナーのクライアント |
| 接続 | UDS `~/.resonite-io/resonite-<pid>.sock` (WSL 内)。ホストからは `RESONITE_IO_SOCKET` 明示 | Windows から直接は繋げない (§6.6) |

---

## 2. 全体アーキテクチャ

```
 入口                          共通層                         Resonite 側
 ─────────────────────────     ──────────────────────────     ────────────────────────────────────
 G1 ClaudeInput セル ─▶ SourceVault MCP ─┐
     (CLI / ローカル LLM)  sourcevault_resonite_*  │
                                                 ├─▶ ResoLoop.wl ──(RunProcess, --json)──▶ resoloop CLI ──ResoniteLink──▶ オーナーの
 G2 ResoniteRealtime API ─▶ _resoloop.wl アダプタ ┤     │  ├ ResoLoop_builder.wl (建築ジョブ)                              Windows クライアント
     (Chat / Flux ガジェット)                       │     │  │   └─ claude --print (プロジェクト cwd, Skill 付き)                (セッションホスト)
                                                 │     │  └ ジョブ表 + 進捗 (LocalState)                                        ▲
 G4 音声ツール ─▶ broker ─▶ サービスカーネル ───────┘     │                                                                      │ 同じセッション
     resonite_build / query / adjust / remove            │                                                                      ▼
                                                        └── ResoniteRealtime L1/L2/L3 (値の読み書き・画像・行プロトコル) ──▶ 世界

 G3 音声ワーカー (realtime_core + platform_resonite) ──gRPC (ResoniteIO)──▶ ボットのクライアント (WSL2 Docker) ── 参加 ──▶ 同じセッション
```

### 2.1 役割分担 (固定する)

| やること | 通す層 | 理由 |
| --- | --- | --- |
| Slot / Component / ProtoFlux の作成・変更・削除 | **resoloop** (`ResoLoop.wl`) | 冪等・state・監査・タグ付け・型検証を持つのはここだけ |
| 値の高頻度読み書き (板の画像 URL、チャット欄の文字、表示切替) | ResoniteRealtime **L2** (`ResoniteRealtimeUpdateComponent`) | 1 回 100 ms 級。resoloop の 1 s は遅い |
| 世界からの事象 (ボタン、入力欄の送信、TAB 行) | ResoniteRealtime **L1** | 既存・最速 |
| 画像配信 | ResoniteRealtime **L3** | 既存 |
| ボットの声・耳・移動・参加 | **ResoniteIO** (`platform_resonite.py`) | 型付き API。OCR/マウス不要 |
| ユーザー位置 (追従の目標) | **resoloop** (`hierarchy` の `User …` Slot) | オーナーのクライアントは全員の User Slot を持つ。1 s 周期で足りる |

resoloop と ResoniteRealtime L2 は **同じ ResoniteLink ポートに別クライアントとして同時接続**する (多重接続の可否は §10 の F0 で確認。不可なら L2 の書き込みを resoloop の `component set` に寄せ、L2 は読み取り専用にする)。

### 2.2 プロジェクト規約

- resoloop プロジェクトは `MyPackages/ResoLoop_projects/<名前>/` (既存の規約)。用途ごとに分ける: `MyResoniteProject` (手作業・実験)、`ResoniteRealtime` (ガジェット群)、`VoiceBuilds` (音声からの建築物)。
- **ownership key = 1 ガジェット / 1 建築依頼**。`content/<key>.json` + 必要なら `flux/<key>.flux.json`。
- state の置き場は resoloop 既定 (プロジェクト内 `.resoloop/`) のままにし、代わりに **`.resoloop/` / `artifacts/` / `flux/build/` / `flux/.protograph/` に Dropbox の無視属性 (NTFS 代替ストリーム `com.dropbox.ignored=1`) を付ける** (`ResoLoopProjectSync` が Dropbox 配下なら自動で付与)。2026-09-22 の実機で、同期中の Dropbox が state を掴み `APPLY_STATE_WRITE_FAILED` になった (エージェントは再 apply で回復)。LocalState への移設 (`--state` 明示) は CLI 引数と manifest の `worldState` を全部揃える必要があり、エージェントの手順が長くなるので採らない。理由: プロジェクトは Dropbox 同期下にあり、`.lock` ファイルと機械固有の ID が競合コピーを生む (`sourcevault-file-handle-release` の再発防止)。
- 各プロジェクトに `CLAUDE.md` (`@AGENTS.md` 取り込み) と `.claude/skills/` (`.agents/skills/` の複製) を持つ。`ResoLoopProjectSync[]` が `skills sync --update` 後の再複製を行う。

---

## 3. G0: 共通層 `ResoLoop.wl`

全入口が使う薄い層。resoloop を知っているのはここだけ。

### 3.1 実行と応答

```mathematica
ResoLoopRun[{"find", "--name", "Box"}, "Project" -> "ResoniteRealtime", "URL" -> Automatic]
  → <|"ok" -> True, "data" -> …|>  |  Failure["ResoLoop", <|"Code" -> "FLUX_BINDING_TARGET_INVALID", "Message" -> …, "Context" -> …, "Suggestions" -> {…}|>]
```

- `RunProcess` で `resoloop … --json` を実行、**stdout と stderr を両方**読み、先に `{` で始まる方を JSON として解釈する (失敗 JSON は stderr)。
- 実行ファイルは `%USERPROFILE%\.dotnet\tools\resoloop.exe` を既定、`$ResoLoopExecutable` で上書き。
- `ProcessDirectory` = プロジェクト dir。`ProcessEnvironment` に `RESONITE_MANAGED_DATA_PATH` / `RESONITE_LOG_PATH` を継承 (ユーザー環境変数に永続化済)。
- タイムアウト: 既定 60 s、`apply` / `deploy-manifest` / `capture` は 600 s。超過は `Failure["ResoLoop", "Code" -> "COMMAND_TIMEOUT"]`。
- `"Async" -> True` で `StartProcess` + `ProcessStatus` ポーリング (`orchestrator-async-llm` の非ブロック規約。サービスカーネルからは必ずこちら)。

### 3.2 接続

- `ResoLoopConnect["Session" -> Automatic | "名前"]`: `discover --json` → 候補 1 つならその URL を `$ResoLoopURL` に保持 (プロセス内キャッシュ、`status` 失敗で無効化)。複数なら `Failure["AmbiguousSession", 候補一覧]` を返し**選ばせる** (Skill の規則どおり勝手に選ばない)。
- ResoniteRealtime が既に `ResoniteRealtimeLinkConnect[port]` していれば同じポートを流用する (`ResoniteRealtimeStatus[]["Link"]` を先に見る)。
- 候補 0 (ResoniteLink がオフ、または Resonite 未起動) は前提違反 (§0.2)。`--discovery-seconds 20` で 1 回だけ再試行し、それでも無ければ `Failure["ResoniteLinkOff"]` を返す。上位はこれを「Resonite リンクがオフのようです。Dashboard で有効にしてください」とそのまま利用者に伝える (ノートブックはメッセージ、音声は 1 文)。自動で待ち続けたり、L2 だけで代替したりしない。
- 接続の生存は `ResoLoopRun` が `CONNECTION_FAILED` を受けたときにキャッシュを捨てて `discover` をやり直すことで保つ (Resonite 再起動でポートが変わる場合の回復)。

### 3.3 公開関数 (資料は `ResoLoop_info/docs/api.md` に置く)

| 群 | 関数 | resoloop |
| --- | --- | --- |
| 環境 | `ResoLoopDoctor[]`, `ResoLoopVersion[]`, `ResoLoopProjectSync[project]`, `ResoLoopProject[name]` (無ければ `init` + CLAUDE.md + skills 複製) | `doctor` / `--version` / `init` / `skills sync` |
| 観測 (読み取り専用) | `ResoLoopStatus[]`, `ResoLoopHierarchy[under, depth]`, `ResoLoopFind[…]`, `ResoLoopInspect[sel]`, `ResoLoopComponentInspect[sel]`, `ResoLoopTypeSearch/Describe/Specialize` | 同名 |
| 宣言 | `ResoLoopValidate[file]`, `ResoLoopDiff[file]`, `ResoLoopApply[file]`, `ResoLoopTest[file]`, `ResoLoopCapture[file, camera]`, `ResoLoopItemAudit[root]` | 同名 |
| Flux | `ResoLoopFluxCheck/Build[pg]`, `ResoLoopFluxNodeSearch/Describe`, `ResoLoopFluxValidateManifest/DeployManifest[manifest]` | `flux …` |
| 原始操作 | `ResoLoopSlotCreate/Set`, `ResoLoopComponentAdd/Set`, `ResoLoopSlotDelete[id, "Confirm" -> True]`, `ResoLoopComponentRemove[id, "Confirm" -> True]` | `slot …` / `component …` |

戻り値はすべて `data` の Association (Dataset 化は View 側)。`core/View 分離` の原則に従い、この層は表示を持たない。

### 3.4 安全ゲート (この層で強制。上位は迂回できない)

1. **所有境界**: 変更系は `ResoLoop_*` で始まる root、または当該プロジェクトの state に載っている root の配下だけ。`Root` 直下の既存 Slot、`User …` Slot、他人の物への `slot set/delete` は `Failure["OutsideOwnership"]`。
2. **削除**: `"Confirm" -> True` が無ければ `--yes` を付けない (= resoloop 側が拒否)。`apply --prune` も同じ。音声・MCP からの削除は §7.4 の確認フローを経たときだけ `Confirm` が立つ。
3. **`--adopt` 禁止**: 自動経路では付けない。既存 root の取り込みはノートブックで人が明示したときのみ。
4. **同時実行**: プロジェクトごとに 1 つの mutation (WL 側 mutex)。ResoLoop の `APPLY_STATE_BUSY` は再試行せず上位へ返す。

### 3.5 機密度

- resoloop の観測結果には他ユーザーの名前 (User Slot) が含まれ得る。`ResoLoopHierarchy` 等の結果には `ResoniteAccessLevel[]` (Public 0.25 / Private 1.0、既存) を PrivacyLevel として付ける。
- ノートブック・音声から LLM へ渡すときは `ResoniteChat` と同じ規則: `PrivacyLevel = Max[依頼文, 観測結果]`、0.5 超はローカル LLM、依頼文の機密度 > 世界の公開度なら `WorldAccessDenied`。

### 3.6 建築ジョブ `ResoLoop_builder.wl`

「自然文の依頼 → 世界の変更」は多段の推論 (型調査 → 宣言 → 検証 → 適用 → 再観測) なので、**Skill を持つエージェント**に任せる。

```mathematica
ResoLoopBuildSubmit["青い箱を目の前に作って", "Project" -> "VoiceBuilds", "Placement" -> <|"User" -> "nconc", "Distance" -> 1.0|>,
  "Backend" -> Automatic, "PrivacyLevel" -> 0.25] → jobId
ResoLoopJobStatus[jobId] → <|"Phase" -> "applying", "Progress" -> "Slot 4/12", "Started", "Elapsed", "Ownership" -> "vb-20260922-0001"|>
ResoLoopJobResult[jobId] → <|"Ownership", "RootId", "RootName", "Summary", "Capture" -> pngPath, "Verification" -> "structural"|"runtime", "Log"|>
ResoLoopJobCancel[jobId]
```

- **Backend "ClaudeCLI" (既定)**: `claude --print --output-format stream-json` を **プロジェクト dir を cwd** にして起動 (claudecode の CLI ラッパを流用。`ProcessDirectory` 指定は既存)。プロジェクトの `CLAUDE.md` と `.claude/skills/resonite-*` が自動で効くので、ノートブック外でも今回の手作業と同じ手順を踏む。`--allowedTools` は `Bash(resoloop *)`、`PowerShell(resoloop *)` (Windows の Claude Code は PowerShell ツールも使う。F0-6 で実測)、`Read`、`Write`、`Edit`、`Glob`、`Grep` に限定し、`Bash(resoloop slot delete*)` / `Bash(resoloop component remove*)` / `Bash(*--prune*)` / `Bash(*--adopt*)` を **deny** (プロジェクトの `.claude/settings.json` に固定)。`--print` は対話承認できないので、この allow/deny がそのまま安全境界になる。
- **Backend "LocalToolLoop"**: PrivacyLevel > 0.5 のとき。`ClaudeQueryAsync` + `$ClaudeLocalToolLoop` で `sourcevault_resonite_*` (§4.1) を回す。Skill 本文はプロンプトに同梱 (`resonite-build` / `resonite-flux` の要約版)。品質は落ちるが機密は守る。
- backend の選択は worker dispatch 仕様の束縛規則 (能力 heavy、Criticality normal、PL ゲート) に委ねる。
- **プロンプト骨子**: 依頼文 + 配置指示 (ユーザー正面、§6.4 の座標取得を WL が先に済ませて数値で渡す) + 規約 (ownership key、`ResoLoop_<key>` 命名、`content/<key>.json` + `flux/<key>.flux.json`、必ず `validate --strict` → `diff` → `apply` → 同じ `apply` 再実行 → `capture` → `item audit --strict`、既定 3 ロール + `_lastParent` 許可) + 終了報告の書式 (JSON 1 行: ownership / rootName / summary / capture / verification)。
- **進捗**: stream-json のツール呼び出しから phase を推定 (`validate`→validating、`apply`→applying、`flux deploy-manifest`→deploying、`capture`/`test`→verifying) して `ResoLoopJobStatus` に反映。音声はこれを読み上げる (§7.3)。
- **上限**: 1 プロジェクト 1 ジョブ、既定 15 分、ツール呼び出し 80 回。超過は cancel し、途中まで作られた root は `ResoLoopJobResult` に残す (勝手に消さない)。
- ジョブ表は `%LOCALAPPDATA%\ResoLoop\jobs\<id>.json` (WXF/JSON)。サービスカーネル再起動後も `ResoLoopJobStatus` が読める。

---

## 4. G1: ClaudeEval から使う

### 4.1 MCP ツール (`ResoLoop_mcp.wl`)

SourceVault MCP に **外部登録フック** `SourceVaultMCPRegisterTools["resoloop", {tool…}, handler]` を 1 つ足し (現状はツール表がファイル内固定)、次を載せる。名前は既存の慣例に合わせて `sourcevault_` 接頭辞。

| ツール | 種別 | 中身 |
| --- | --- | --- |
| `sourcevault_resonite_status` | 読 | `doctor` 要約 + 接続セッション名 + 稼働ジョブ |
| `sourcevault_resonite_query` | 読 | `{kind: hierarchy\|find\|inspect\|type_search\|type_describe, …}` を `ResoLoop*` に写像。結果は 8 KB で切り、PL 付与 |
| `sourcevault_resonite_build` | 書 (非同期) | `{request, project?, placement?}` → `ResoLoopBuildSubmit` → `{jobId, ownership}` を即返す |
| `sourcevault_resonite_job_status` / `_job_result` | 読 | §3.6 のジョブ表。既存 `sourcevault_job_status` が web search 専用なら kind 付きに一般化し、両方から読めるようにする |
| `sourcevault_resonite_adjust` | 書 (同期) | `{target: ownership or $slot:key, changes: {position?, scale?, color?, text?}}` → 所有境界内の `slot set` / `component set` だけ。1 呼び出し 1 対象 |
| `sourcevault_resonite_remove` | 書 | `{ownership, confirm: true}` → その ownership の root を `slot delete --yes`。`confirm` が無ければ候補と影響 (子 Slot 数) を返すだけ |

`PromptDirective` (MCP-first 方針文) に 1 行足す: 「Resonite の世界に関する依頼 (作る・見る・直す・消す) は `sourcevault_resonite_*` で解決する。世界の中身を推測で答えない。」 `claudecode_directives.wl` には「建築は `_build` を 1 回呼んで jobId を受け取り、`_job_status` を待つ。完了前に『作りました』と言わない」の規則を 1 本追加。

### 4.2 ノートブック側

- 追加 UI は作らない。ClaudeInput セルにそのまま書く (式中心 UI の方針)。完了時は `ResoLoopJobResult` の `Capture` (PNG) をセル出力に貼り、`ResoLoopJobResult` の Association を Dataset で出す。
- 手動運用のために `ResoLoopBuildWatch[jobId]` (Dynamic でなく手動更新ボタン式。`ResoniteRealtimeMonitor` と同型) を用意する。
- `--print` 経路のツール許可は `AllowedTools` に `mcp__sourcevault__sourcevault_resonite_*` を追加。

### 4.3 機密度と世界の公開度

- `sourcevault_resonite_*` は release context `resonite-public` / `resonite-private` (Chat ガジェットと同じ) を尊重。Private な世界の観測結果を CLI 経路 (クラウド) に返す前に PL 判定で `LocalToolLoop` へ落ちる。
- 建築ジョブそのものは世界を「書く」だけで読まないが、`hierarchy` で他人の名前を読む。Private 世界では backend を LocalToolLoop に固定する。

---

## 5. G2: ResoniteRealtime から使う

### 5.1 方針

`$ResoniteRealtimeMutationBackend = "ResoLoop" | "Link"` (既定 `"ResoLoop"`、resoloop 不在なら `"Link"` に自動降格し `Failure` ではなく警告)。**既存の公開 API 名は変えない。** 変更系の中身だけ `ResoniteRealtime_resoloop.wl` のアダプタに差し替える。

### 5.2 写像

| 既存 API | 今 | 後 (ResoLoop backend) |
| --- | --- | --- |
| `ResoniteRealtimeAddSlot` / `AddComponent` / `UpdateComponent` / `RemoveSlot` | L2 で 1 メッセージずつ | 単発呼び出しは `ResoLoopSlotCreate` 等の原始操作へ。**まとまり (ガジェット) は宣言 JSON を生成して `ResoLoopApply`** |
| `ResoniteChatGadget[]` | L2 で UIX を組む (30 個超のメッセージ) | `content/chat-gadget.json` を生成 (Placement オプションから position を計算して埋める) → `ResoLoopApply`。`ResoniteChatRemoveGadget[]` = `ResoLoopSlotDelete[root, "Confirm"->True]`。再実行は state で冪等 |
| `ResoniteChatShow` / `ResoniteChatStart` の欄更新 | L2 `updateComponent` | **そのまま L2** (高頻度・値のみ)。対象 ID は `ResoLoopComponentInspect['$component:answer-text']` で state から解決し、キャッシュ |
| `ResoniteRealtimeBoard` / `ShowImage` | L2 + L3 | 板の作成は `ResoLoopApply` (宣言 `board-<n>.json`)、URL の差し替えは L2 のまま |
| `ResoniteFluxGenerate` 既定 `"Format"->"Graph"` | LLM が JSON グラフ → `_fluxlink` が直接配置 | **既定を `"ProtoGraph"` に変更**: LLM が `.pg` → `ResoLoopFluxCheck/Build` → `flux/<name>.flux.json` (bindings は I/O 規約から機械生成) → `ResoLoopFluxDeployManifest`。`"Graph"` は互換のため残す |
| `ResoniteFluxProbe` (動的変数の読み戻し) | L2 `~read` 相当 | そのまま L2 |
| `ResoniteFluxDrive` (世界フィールド駆動) | `DynamicValueVariableDriver` を L2 で | manifest の `mode: drive` binding に統合。Slot transform は `ValueField`+`ValueCopy` 中継を自動挿入 |

### 5.3 生成ループの変更点 (`ResoniteRealtime_flux.wl`)

- 検証器に `flux check` の `primaryDiagnostics` (行・列付き) をそのまま渡す。カタログ突合 (`ResoniteFluxUnknownNodes`) は残す (LLM の未知ノードを check より前に安く弾く)。
- プロンプトの ProtoGraph 知識に、今回実測した規則を追加: `IButton`/`IPlayable` は一度束縛、入れ子 `if` は括弧、駆動対象は `initialFields`、Slot 直接駆動不可。既にプロジェクト `CLAUDE.md` にある文をそのまま `$ResoniteFluxRules` として共有。
- 実行検証 [V2] は提案書どおり WL を正解器にし、`ResoLoopTest` (構造) + `ResoLoopComponentInspect` (駆動値のサンプリング) を使う。ボタン等のインパルスは押せないので「構造のみ検証」と明記して返す (キッチンタイマーで確立した手順)。

### 5.4 プロジェクトと state

- ResoniteRealtime 専用プロジェクト `ResoLoop_projects/ResoniteRealtime`。ガジェット JSON は生成物なので `content/` には**テンプレート** (`templates/chat-gadget.json` に `${position}` 等のパラメータ) を置き、実 apply 用は `%LOCALAPPDATA%\ResoLoop\generated\` に書く。
- `ResoniteRealtimeStatus[]` に `"MutationBackend"`, `"ResoLoopProject"`, `"ResoLoopSession"` を追加。

---

## 6. G3: Resonite でのボイスチャット

### 6.1 方針

VRCRealtime のワーカーを **core と platform に分割**し、Resonite 用 platform を ResoniteIO で実装する。WL 側は `ResoniteRealtime_voice.wl` が `VRCRealtimeStart` と同じオプション体系で起動する。VRChat 版の挙動は変えない (分割後に既存テスト green が条件)。

### 6.2 ワーカーの分割 (`VRCRealtime_info/resources/python/`)

| モジュール | 中身 | 出自 |
| --- | --- | --- |
| `realtime_core.py` | Realtime/Live ブリッジ、VAD、道具の登録と dispatch、質問モード、発表状態機械、broker、state/control ファイル、Vosk、private TTS | `VRCRealtime_worker.py` から抽出 |
| `platform_base.py` | 抽象: `AudioIn.read(chunk) -> pcm16@24k`, `AudioOut.play(pcm16@24k)`, `mic_live()`, `Presence.join(owner)`, `Presence.leave()`, `Locomotion.move_toward(target)`, `Vision.capture() -> png`, `Presentation.show(url\|image)`, `Chat.announce(text)`, `capabilities()` | 新規 |
| `platform_vrchat.py` | 今の実装 (sounddevice+VB-Cable、OSC 9001、Sliden、worldjoin/ownerjoin/formation、visual gate) | 既存コードの移動 |
| `platform_resonite.py` | §6.3〜6.5 | 新規 |
| `VRCRealtime_worker.py` | `--platform vrchat` 既定の薄い入口 (互換) | 残す |

道具表は core が持ち、platform の `capabilities()` に無い道具 (例: Resonite に `look_at_vrchat` の画面キャプチャは無い → `look` は Camera へ) は名前を保ったまま実装を差し替えるか、登録しない。

### 6.3 音声 (ResoniteIO)

| 方向 | ResoniteIO | core の形式 | 変換 |
| --- | --- | --- | --- |
| 聞く | `Speaker.StreamAudio` 48 kHz stereo float32 | 24 kHz mono PCM16 | L/R 平均 → 2:1 デシメーション (簡易 FIR) → int16 |
| 喋る | `Microphone.StreamAudio` 48 kHz mono float32 | 24 kHz mono PCM16 | 線形補間 ×2 → float32。無音時も 20 ms クロックで送る (GPT-Live 変換層と同じ規律) |

- VB-Cable も OSC も不要。**ミュート観測問題 (VRChat で最も苦労した点) が消える**: Microphone ストリームが繋がっていれば喋れている。`mic_live()` は gRPC の接続状態そのもの。
- 自声のエコー: Resonite はローカルの自分の声を再生しないはずだが、`Speaker` ストリームに自分の Microphone が混ざるかは **F0 で実測** (§10)。混ざるなら VRCRealtime にある出力中ゲート (`output_active` 中は入力を捨てる) を有効化。
- 非公開文の `private_readout` は VRChat と同じくローカル TTS → Microphone。

### 6.4 在席・追従・向き

- 参加: `World.ListSessions(search=<オーナーのセッション名>)` → `Join(session_id, focus=true)`。名前は `ResoniteRealtimeVoiceStart["Session" -> …]` か、`ResoLoopConnect` が発見したセッション名 (同じ世界なので一致するはず) を既定にする。
- オーナーの位置: **resoloop** で `hierarchy --depth 1` → `User <owner>` と `User <bot>` の root 位置・Head 回転 (1 s 周期、オーナーのクライアントから読む)。ボットは `Locomotion.Drive` で「オーナー正面 `FollowDistance` (既定 1.5 m) の点」へ向かう。VRChat 版の OCR・ランドマークによる距離推定は全部不要。`turn_avatar` は同じ経路でヨーだけ変える。
- 参加 / 離脱の音声語 (「会話に参加」「離脱」) は core の Vosk 経路をそのまま使う。

### 6.5 発表 (Sliden の代替)

- スライド画像は既存 L3 配信 + 板 (`ResoniteRealtimeBoard`、resoloop で作成) に出す。`start_presentation(url)` は Sliden の MP4 ではなく `SlideDeckImages` (SlideWorkflow) の PNG 列を受け、`show_slide(n)` は板の URL を L2 で差し替える。VRChat 版で最も壊れやすかった「パネル探索・URL 入力サーボ」が丸ごと無くなる。
- 質問モード 3 種・再開位置・割り込み語は core の実装がそのまま効く。

### 6.6 プロセス配置

ResoniteIO の UDS は WSL 内にあり Windows から直接は繋げない。二案を F0 で比べ、動いた方を採る。

| 案 | 構成 | 利点 | 懸念 |
| --- | --- | --- | --- |
| P-A (推奨) | ワーカーを **WSL 内**で動かす (`wsl.exe -e uv run … --platform resonite`)。state/control ファイルは `/mnt/c/Users/…/AppData/Local/Temp` | resoio をそのまま使える。音声ストリームが UDS 直結 | 9P 越しのファイル I/O (1 Hz の小 JSON なら可)。private TTS (AivisSpeech は Windows) へは TCP |
| P-B | WSL 側で `socat TCP-LISTEN:50051 UNIX-CONNECT:~/.resonite-io/…` を立て、Windows のワーカーから `localhost:50051` | 既存の起動経路 (Windows の uv) を維持 | resoio クライアントが TCP 宛先を受けるか未確認 |

WL 側 (`ResoniteRealtime_voice.wl`) は VRCRealtime.wl の起動・監視・停止 (state/control ファイル、`Status`/`Stop`/`Kill`/`Mute`/`SetInstructions`/`SetQuestionMode`/`StartPresentation`/`PresentationControl`) を **共通化して流用**する。VRChat 固有オプション (`VRChatPID`、visual gate、Sliden URL、`OwnerFollowEngine`) は受け付けず、代わりに `"Session"`, `"BotAccount"`, `"ResoniteIOSocket"`, `"FollowDistance"`, `"SlideDeck"` を持つ。

```mathematica
ResoniteRealtimeVoiceStart["Session" -> "nconc World", "Model" -> "gpt-live-1", "QuestionMode" -> "Keywords", "SourceVaultKB" -> "cn"]
ResoniteRealtimeVoiceStatus[] / Stop[] / Mute[b] / SetInstructions[t] / StartPresentation[deck] / PresentationControl[cmd]
```

---

## 7. G4: 音声から resoloop を使う

### 7.1 道具 (core の道具表に追加。GPT-Live では Responses 委譲 backend が実行する。既存機構)

| 道具 | 引数 | 動き |
| --- | --- | --- |
| `resonite_build` | `request` (日本語 1 文), `size_hint?` | broker → サービスカーネル → `ResoLoopBuildSubmit` (project `VoiceBuilds`、Placement = オーナー正面 1 m、PL = 世界の公開度)。**即座に** `{jobId, ack: "作り始めます。1 分ほどかかります"}` を返す |
| `resonite_query` | `question` | `find`/`inspect`/`hierarchy --summary` を組み合わせた読み取り。「目の前の物は何」「さっき作った物はどこ」。結果を 3 文以内に要約して返す (要約はモデル側) |
| `resonite_adjust` | `target` ("さっきの箱" → 直近ジョブの ownership), `change` (色 / 大きさ / 位置 / 文字) | `sourcevault_resonite_adjust` と同じ制約。同期、数秒 |
| `resonite_remove` | `target`, `confirmed` | `confirmed=false` なら「『ResoLoop_箱』を消します。子が 4 つあります。よろしいですか」を返し、モデルが利用者に確認 → 「はい」で `confirmed=true` 再呼び出し。曖昧 (候補複数) なら消さない |
| `resonite_job_status` | `jobId?` | 進捗の言い回し (§7.3)。省略時は直近 |

### 7.2 流れ

```
利用者「青い箱を作って」
 └ モデル → resonite_build(request) ─▶ 即 ack「作り始めます」 (モデルは待たずに会話に戻る)
     └ ジョブ (claude --print in VoiceBuilds) … 30〜120 s
         ├ phase 変化 → broker が control 経由で「短い注記」を core に渡す (Live では thinking に入れず、instructions で 1 文だけ:「『適用中です』と伝えて」)
         └ 完了 → 「できました。目の前に置きました」+ 失敗なら理由 1 文 (「型が見つかりませんでした」)
利用者「もう少し大きく」 → resonite_adjust(target=直近, change={scale: 1.5})
利用者「消して」 → resonite_remove(confirmed=false) →「消していいですか」→「はい」→ resonite_remove(confirmed=true)
```

### 7.3 進捗の読み上げ規則

- 発話は **phase の変化時だけ**、1 文、間隔 ≥ 10 s。発表中 (presentation phase) は割り込まず、区切りでまとめて 1 文。
- GPT-Live には「読んで」の命令形を文脈に書かない (実測で読み上げられる)。VRCRealtime で確立した `_front_instructions` / instructions 経路を使う。
- 完了報告は `ResoLoopJobResult` の `Summary` (実装エージェントが 1 行で書く) をそのまま使い、モデルに作文させない。

### 7.4 安全

- 音声からの削除は §7.1 の二段確認が必須。`confirmed=true` は同じ `target` に対して 60 s 以内にだけ有効。
- 建築は同時 1 件。実行中に次の依頼が来たら「今作っている物が終わってからにします」。
- 私有世界 (`ResoniteAccessLevel` 1.0) では build backend が LocalToolLoop に固定される。ローカルモデルが無ければ「この世界では作れません」と返す。
- 音声経路からは `--adopt` / `--prune` / 所有外編集は到達不能 (§3.4)。

---

## 8. ファイル構成 (新規 / 変更)

| 種別 | パス | 役割 |
| --- | --- | --- |
| 新規 | `ResoLoop.wl` | §3 共通層 (実行・接続・観測・宣言・Flux・原始操作・安全ゲート) |
| 新規 | `ResoLoop_builder.wl` | §3.6 建築ジョブ (CLI / LocalToolLoop backend、ジョブ表、進捗) |
| 新規 | `ResoLoop_mcp.wl` | §4.1 MCP ツール群と handler。`SourceVaultMCPRegisterTools` で登録 |
| 新規 | `ResoLoop_info/docs/api.md`、`ResoLoop_info/references/` | 資料。`test codes/ResoLoop_test.wls` (モック runner で CLI 無しでも通る) |
| 変更 | `SourceVault_mcp.wl` | 外部ツール登録フック 1 つ、ジョブ表の kind 一般化 |
| 変更 | `claudecode_directives.wl` | 規則 1 本 (建築は非同期・完了前に完了と言わない) |
| 新規 | `ResoniteRealtime_resoloop.wl` | §5 アダプタ (backend 切替、宣言テンプレート → apply、ID 解決キャッシュ) |
| 変更 | `ResoniteRealtime_chat.wl` / `_flux.wl` / `_fluxlink.wl` | 変更系をアダプタ経由に。Flux 既定 `"ProtoGraph"` + manifest 生成 |
| 新規 | `ResoniteRealtime_voice.wl` | §6.6 起動・監視 (VRCRealtime.wl から起動基盤を共通化して流用) |
| 変更 | `VRCRealtime_info/resources/python/*.py` | §6.2 core / platform 分割。`platform_resonite.py` 新規 |
| 新規 | `ResoLoop_projects/ResoniteRealtime/`、`ResoLoop_projects/VoiceBuilds/` | プロジェクト (CLAUDE.md、`.claude/skills`、`.claude/settings.json` の allow/deny) |
| 資料 | `ResoLoop_projects/MyResoniteProject/CLAUDE.md` の罠一覧 | `$ResoniteFluxRules` として共有 (単一情報源) |

---

## 9. 実装計画

| 段階 | 内容 | 目安 | 完了条件 |
| --- | --- | --- | --- |
| **F0** 計測 | §10 の未確認事項を実測で潰す (ResoniteLink 多重接続、ResoniteIO 音声往復、自声混入、P-A/P-B、Join) | 1 日 | 各項目に測定値が付く |
| **F1** ResoLoop.wl | §3.1〜3.5。モック runner のテスト + 実機で `Doctor`/`Hierarchy`/`Apply` (MyResoniteProject の SpinBox を再適用して書込 0) | 1 日 | `ResoLoop_test.wls` green、NB 実機 |
| **F2** 建築ジョブ + MCP (G1) | §3.6 + §4。ClaudeInput から箱を作る通し | 2 日 | G1 の到達判定 |
| **F3** ResoniteRealtime アダプタ (G2) | §5。Chat ガジェットの再実行冪等、Flux 既定 ProtoGraph でカウンタ例 (2026-09-06 の実機例) を deploy-manifest で再現 | 2 日 | G2 の到達判定、既存 NB 例が動く |
| **F4** ワーカー分割 | §6.2。VRChat 版の既存テスト (worker / talk / voice / live / sliden) を分割後も green | 2 日 | 回帰なし |
| **F5** Resonite platform (G3) | §6.3〜6.6。ボット参加 → 会話 → KB 質問 → 板で発表 | 3 日 | G3 の到達判定 |
| **F6** 音声道具 (G4) | §7。build / query / adjust / remove、確認フロー、進捗読み上げ | 1 日 | G4 の到達判定 |
| **F7** 仕上げ | docs (api.md / user_manual)、メモリ、GitHub 反映 (`test codes/` は非公開の規則) | 随時 | — |

F1〜F2 と F4 は独立に進められる。F3 は F1 の後、F5 は F0+F4 の後、F6 は F2+F5 の後。

### 9.1 検証の型 (各段階で共通)

- ワールド変更前に `validate --strict` → `diff --changes-only` (create 以外が 0 か) → `apply` → 同じ `apply` (書込 0) を自動化テストに含める。
- 「ボタンは外から押せない」ので、ProtoFlux のロジック検証は sync 変数ストアを `component set` して駆動値を読む方式 (キッチンタイマーで確立) を `ResoLoopTest` のプローブとして定型化する。
- 音声はワーカーの state (inputChunks / outputSamples / phase) と Resonite 側の `Session.ListUsers` で事後検証。VRCRealtime の「計器が正常でも届いていない」教訓から、**Microphone ストリームの接続状態**を state に必ず出す。

---

## 10. 未確認事項とリスク

### 10.1 F0 で実測するもの

| # | 問い | 影響 | 確認法 |
| --- | --- | --- | --- |
| 1 | ResoniteLink は同一ポートに resoloop と WL クライアントの**同時接続**を受けるか | §2.1 の役割分担 | **実測済 (2026-09-22): 受ける。** WS クライアントを開いたまま `resoloop status` ×3 が全部成功 (connectionId 1→2→3)、その後の WS 側 getSlot も成功 |
| 2 | ResoniteIO の `Speaker` ストリームに**ボット自身の声**が混ざるか | §6.3 のエコーゲート要否 | Microphone に正弦波を流し Speaker を録る |
| 3 | WSL2 (lavapipe 3 fps) で**音声ストリームが途切れないか** | G3 成立の前提 | 60 s の往復で欠落フレーム数 |
| 4 | P-A (WSL 内ワーカー) と P-B (socat) のどちらが動くか。resoio の宛先指定 | §6.6 | 両方試す |
| 5 | `World.Join` でオーナーのセッションに入れるか (フレンド限定・招待制のときの扱い) | §6.4 | 実機 |
| 6 | `claude --print` をプロジェクト cwd で動かしたとき Skill と `CLAUDE.md` が効くか、`--allowedTools Bash(resoloop *)` の書式 | §3.6 | **実測済 (2026-09-22): 効く。** CLAUDE.md=yes、Skill 6 つを列挙、正答。ただし `Bash(resoloop *)` だけでは **PowerShell ツールと `2>&1 \|` / `\|\|` 付きの複合コマンドが 4 回拒否**されてから成功 (7 ターン・44 s)。→ `PowerShell(resoloop *)` も許可し、CLAUDE.md に「素のコマンド 1 つで呼ぶ」を明記 (ResoLoop.wl の雛形に反映済) |
| 7 | ResoniteLink 越しの `hierarchy --depth 1` で他ユーザー (ボット) の位置が 1 s 周期で取れるか (latency 実測 ~0.7 s) | §6.4 | 実機 |

### 10.2 リスク

| リスク | 対処 |
| --- | --- |
| resoloop は preview。CLI の出力や引数が変わる | 版を `0.1.0-preview.13` に固定し、`ResoLoop.wl` だけが CLI を知る。更新時は `ResoLoop_test.wls` のモック契約を先に更新 |
| ResoniteLink がオフのまま使われる (前提 §0.2 の違反)、またはオーナーが他人のセッションにいてホストでない | 代替経路は作らない。`ResoLoopConnect` が `Failure["ResoniteLinkOff"]` / `Failure["NotHost"]` を返し、ノートブックにはメッセージ、音声は「Resonite リンクがオフのようです」の 1 文で知らせる。L1/L2 の値経路と ResoniteIO の会話は影響なし |
| `--print` は承認できない → allow/deny の書き漏れが安全境界の穴 | deny を `.claude/settings.json` に固定し、`ResoLoop.wl` 側の所有境界 (§3.4) と二重化。実装エージェントが `resoloop` 以外のシェルを使えないように `Bash(resoloop *)` 限定 |
| Dropbox 同期下の state / lock | state を LocalState へ (§2.2)。プロジェクト内には宣言とソースだけ |
| GPT-Live の文脈注入が読み上げられる | 進捗は instructions 1 文のみ (§7.3)。VRCRealtime の実測規則を踏襲 |
| Flux-SDK 1.9 の型解決の癖 | `$ResoniteFluxRules` に集約し、生成プロンプトと Skill の両方が同じ文を使う |
| ワーカー分割での回帰 | F4 は挙動を変えない純粋な移動。既存テスト全 green を merge 条件にする |
| 建築ジョブの暴走 (無限の再試行・大量 Slot) | ツール呼び出し 80 回 / 15 分 / 1 プロジェクト 1 ジョブ。上限到達は cancel + 途中成果を残して報告 |

---

## 11. 参照

- resoloop: https://github.com/orange3134/resoloop (README-DETAILS / docs/DECLARATIVE.md / docs/QUICKSTART.md)
- Flux-SDK / ProtoGraph: https://flux-sdk.samsmucny.com/ProtoGraph/ (Modules-and-Packages, Impulse-Control-Flow, Types-and-Variables, Dynamics, String-Formatting)
- ResoniteIO: https://github.com/MLShukai/ResoniteIO (`proto/resonite_io/v1/*.proto`: microphone / speaker / world / locomotion / session)
- ResoniteLink: https://github.com/Yellow-Dog-Man/ResoniteLink
- 本リポジトリ: `ResoniteRealtime_info/docs/*.md`、`VRCRealtime_info/docs/api.md`、`ResoLoop_projects/MyResoniteProject/CLAUDE.md`、`ResoniteIO_setup/README.md`

---

## 12. 実装記録

| 日付 | 段階 | 内容 |
| --- | --- | --- |
| 2026-09-22 | F0 | #1 ResoniteLink 多重接続 = 受ける (WS クライアント保持中に `resoloop status` ×3 成功)。#6 `claude --print` in project cwd = CLAUDE.md / Skill 有効。`Bash(resoloop *)` だけでは PowerShell ツールと複合コマンドが 4 回拒否 → `PowerShell(resoloop *)` 追加 + 「素のコマンドで呼ぶ」規則。#2〜#5, #7 は未測 (G3 着手前に行う) |
| 2026-09-22 | F1 | `ResoLoop.wl` v0.1.0 (§3.1〜3.5)。`test codes/ResoLoop_test.wls` 54/54 (モック実行器、ヘッドレス `wolfram.exe -noinit -noprompt -script`)。実機 (NCG Gallery, ws://localhost:2324/) で読み取り系スモーク OK: Connect / Status / Hierarchy / Find / TypeSearch / TypeSpecialize / Validate --strict / FluxCheck / FluxNodeSearch / Doctor、Root 削除は `OutsideOwnership` で拒否。資料 `ResoLoop_info/docs/api.md`。NB 未・未コミット || 2026-09-22 | F2 (G1) | `SourceVault_mcp.wl` に外部登録フック (`SourceVaultMCPRegisterTools` / `$SourceVaultMCPExternalTools`、組み込みに無い名前を外部 handler へ)、`SourceVault_servicemanager.wl` に `$SourceVaultServiceExtraPackages` (service 起動スクリプトが追加ロード) と CLI 登録の動的化 (AllowedTools を Function に、PromptDirective に外部方針文を合流)、`claudecode.wl` は AllowedTools の Function を受ける 1 箇所。新規 `ResoLoop_builder.wl` (`ResoLoopBuildSubmit` / `JobStatus` / `JobResult` / `UserPlacement`、`claude --print --output-format stream-json` をプロジェクト cwd で起動、進捗は JSONL を後読み) と `ResoLoop_mcp.wl` (`sourcevault_resonite_{status,query,build,job_status,job_result,adjust,remove}`、`remove` は CLI に pre-allow しない)。規則 `Claude Directives/rules/109-resonite-resoloop-mcp.md`。プロジェクト `ResoLoop_projects/VoiceBuilds` (builder 用 allow/deny 付き)。テスト `ResoLoop_builder_test.wls` 47/47、`ResoLoop_test.wls` 55/55。**実機 E2E 成功**: 「小さな青い球 (直径 15 cm、掴める)」→ 利用者の頭の向きから正面 1 m を算出 → CLI が type describe ×5 → 宣言 → validate/strict/diff → apply ×2 (収束) → capture → test → item audit を自走、30 ターン・200 s、`ResoLoop_小さな青い球` を作成し JSON 報告を返した。SourceVault はヘッドレスでロードできないので MCP 経由の通しは NB で確認する (service 再起動が要る) |

F1 で仕様から変えた点: 応答 JSON は 1 行前提にせず「全文 → 最初の `{` 以降 → 行」の順で抽出する (整形出力にも耐える)。`test --probe --yes` も Confirm 必須 (フラグ検査は全コマンド、所有境界と mutex は変更系のみ)。生の Component ID の変更は `"Owner" -> slotId` で所有を確認する (Component から Slot を安く引けないため)。

F2 で分かった罠: (a) `item audit --strict` は使われなかった `--allow-external-role` を `ITEM_ALLOW_ROLE_UNUSED` として**失敗**にする → `ResoLoopItemAudit` は「許可なしで監査 → 報告された候補のうち既定 4 ロールだけ許可して再監査」の二段に変更、プロンプトも同じ手順。(b) 配置の回転を 4 桁に丸めるとエンジン側で正規化され再 apply が収束しない → 正規化して 1e-8 で渡す。(c) `ImportString[s, "RawJSON"]` は非 ASCII を含む WL 文字列で失敗する → JSON 解釈は全部 `ImportByteArray[StringToByteArray[s, "UTF-8"], "RawJSON"]`。(d) JSONL は 1 行 1 オブジェクトを仮定せず、文字列内を無視した波括弧の深さで切る (WL の RawJSON 出力は整形される)。(e) `Failure` は Association ではないので `Lookup[f, "Context"]` は効かない → `f["Context"]`。(f) WL のコメント内に `_*)` を書くとコメントが閉じる。(g) `Bash(resoloop *)` だけでは PowerShell ツールと複合コマンドが拒否される → `PowerShell(resoloop *)` も許可し「素のコマンド 1 つで呼ぶ」を CLAUDE.md に明記 (実機 E2E では拒否 1 回まで減少)。
(h) NB からの 2 回目の実機建築 (赤い立方体、26 ターン) で「回転が 4 桁」が再発: 原因は配置の丸めではなくプロンプトの数値整形 `ibNum` (NumberForm 4 桁) だった → 8 桁 (float32 精度) に変更、回転は `N[Normalize[...]]` のまま渡す。エージェントは `Skill` ツールを最初に呼ぶので `--allowedTools` と `.claude/settings.json` に `Skill` を追加 (拒否 1 件の原因)。(i) NB カーネルで `SourceVaultMCPTools[]` に 0 件だったのは、SourceVault が本日の拡張点追加**前**にロードされていたため → `SourceVault_mcp.wl` / `SourceVault_servicemanager.wl` の再 Get (またはカーネル再起動) で解消するはず (要確認)。
(j) NB の ClaudeInput から使うと「承認待ち」が連発した (result.nb)。原因 2 つ: ① `ResoLoop*` が NBAccess の許可ヘッド未登録で、状態確認 (`ResoLoopJobStatus`) の提案ごとに `UnknownHeadRequiresApproval`。→ `ResoLoopRegisterHeads[]` で読み取り系・ジョブ系・`ResoLoopBuildSubmit` の 44 個を 2 層 (`NBRegisterAllowedHeads` + `NBRegisterTrustedPackageHeads`) 登録し、apply / delete / remove / deploy / 生 Run は `NBRegisterApprovalHeads`。`ResoLoopJobWait[]` (最長 300 s、1 呼び出しで完結) を追加し、規則 109 に「Pause ポーリングしない・グローバル変数に保存しない」を明記。② servicemanager が CLI の AllowedTools を Function で登録したため、Function 非対応の (ロード済み旧) claudecode が `{}` と解釈し **SourceVault の全 tool が CLI から不許可**になった → List で登録し、外部登録後は `SourceVaultRefreshCLIMCP[]` で再登録 (ResoLoop_mcp が自動で呼ぶ)。claudecode の Function 対応は残すが依存しない。テスト 57/57 + 49/49。
(k) NB 再検証 (result2.nb): 許可ヘッド登録後は `Permit` / `NeedsApproval` が期待どおりで、モデルは `ResoLoopBuildSubmit[...]; ResoLoopJobWait[...]` の 1 セルを提案 → 円錐は完成したが、承認が 1 回だけ残った: **`TimeoutExtension` (LLM が 600 s の同期実行を申告、既定 30 s)**。同期待ちは runtime の設計上この承認を必ず伴うので、非ブロックの `ResoLoopBuildWatch[]` (claudecode の共有 polling tick に相乗りし、完了時に `ClaudeWriteResponse` で要約+撮影画像をノートブックに書く) を追加し、規則 109 の正しい形を `Submit; Watch` に変更。`ResoLoopJobs[]` は running の記録を一覧時に更新する (別カーネルのジョブが running のまま見えていた)。Claude Code セッション側からも `mcp__sourcevault__sourcevault_resonite_status` / `job_status` が service kernel 経由で通ることを確認 (最初の円錐ジョブは done、19 呼び出し)。テスト 55/55 + 57/57。
(l) **G1 到達 (result3.nb)**: ClaudeInput「Resonite に緑の球を目の前に作って」→ モデルが `ResoLoopBuildSubmit[...]; ResoLoopBuildWatch[]` を 1 セルで提案 → 承認ゼロで即返り → 138 s 後に見張りが完了報告 (要約・root `ResoLoop_GreenSphere`・撮影) をノートブックに書いた。世界には青い球・赤い立方体・黄色い円錐 ×2・緑の球が並ぶ。緑の球の注記で Dropbox の state 掴み (`APPLY_STATE_WRITE_FAILED`) が判明 → §2.2 を Dropbox 無視属性方式に変更。
- (m) 2026-09-22 **タブレット (G1.5: ClaudeEval をワールド内で)**: `ResoniteRealtime_tablet.wl` 新規 (タブレット UIX / runtime 監視 / 承認・拒否 / スクロール出力 / ビューア / `ResoniteShowObject` / `ResoniteListGadget` / `ResoniteVideoBoard`)、chat の表示上限 4 段化 + `$ResoniteWorldOwner`、claudecode `ClaudeRuntimeDecide`、規則 110、`test codes/ResoniteRealtime_tablet_test.wls` 59/59。設計は `tablet_claudeeval_spec_v0_1.md`。ClaudeEval ターン通しは NB 未検証。
