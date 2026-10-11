# ResoLoop API

resoloop CLI (Resonite を ResoniteLink 経由で操作する CLI) の共通層。ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["ResoLoop.wl"]]`。
設計は `ResoLoop_info/design/resoloop_integration_spec_v0_1.md` §3。この層だけが CLI を知り、上位 (ノートブック / MCP / ResoniteRealtime / 音声) はすべてここを通る。
前提: ResoniteLink は利用者が常時オン。オフは `Failure["ResoLoop", "Code" -> "ResoniteLinkOff"]` で知らせるだけ。
resoloop CLI 本体 (https://github.com/orange3134/resoloop、AGPL-3.0-or-later、dotnet グローバルツール) はこのパッケージに含まれない。導入は `setup.md`。

## 戻り値の約束

- 成功: resoloop の `data` (Association / List)。表示は持たない (core/View 分離)。生の応答は `$ResoLoopLastResult`。
- 失敗: `Failure["ResoLoop", <|"Code", "MessageTemplate", "Context", "Suggestions", "Arguments"|>]`。`Code` は resoloop のエラーコード (`COMPONENT_TYPE_NOT_FOUND` など) か、この層のもの: `NotInstalled` / `ProjectNotFound` / `ResoniteLinkOff` / `AmbiguousSession` / `ConfirmRequired` / `AdoptNotAllowed` / `OutsideOwnership` / `OwnerRequired` / `StateRequired` / `Busy` / `COMMAND_TIMEOUT` / `NO_JSON` / `Running`。
- すべての関数が `"Project" -> 名前` (既定 `$ResoLoopDefaultProject` = "MyResoniteProject") を受け、そのプロジェクト dir で実行する。ファイル引数は絶対パスか、プロジェクト dir からの相対。

## 安全ゲート (この層で強制。上位は迂回できない)

| 制約 | 内容 |
| --- | --- |
| 所有境界 | `slot set/delete`、`component add/set/remove` は root 名が `$ResoLoopOwnershipPrefixes` (既定 `{"ResoLoop_"}`) で始まる Slot の配下だけ (`inspect` の `path` で判定)。`Root` と `User ...` は不可。`$slot:key` 等の安定セレクタは state で解決されるので可 |
| Confirm | `--yes` を含む操作 (`slot delete` / `component remove` / `apply --prune` / `test --probe`) は `"Confirm" -> True` が無ければ実行しない |
| Adopt | `--adopt` は `"Adopt" -> True` (ノートブックで人が明示) のときだけ |
| Owner | 生の Component ID (`Reso_...`) を変更するときは `"Owner" -> slotId` でその Slot の所有を確認する |
| 排他 | 1 プロジェクト 1 mutation。実行中は `Failure["Busy"]` |
| 新規 Slot | `slot create` の親が所有外なら `--name` は接頭辞 `ResoLoop_` が要る |

## 変数

| 変数 | 意味 |
| --- | --- |
| `$ResoLoopExecutable` | resoloop 実行ファイル。Automatic = `%USERPROFILE%\.dotnet\tools\resoloop.exe` → PATH |
| `$ResoLoopProjectsDirectory` | プロジェクト置き場 (既定 `<MyPackages>/ResoLoop_projects`) |
| `$ResoLoopDefaultProject` | "Project" 省略時の名前 |
| `$ResoLoopURL` / `$ResoLoopSession` | 接続中の URL とセッション名 (`ResoLoopConnect` が設定) |
| `$ResoLoopDefaultTimeout` / `$ResoLoopLongTimeout` | 60 / 600 秒。apply / capture / test / item / flux / init は Long |
| `$ResoLoopOwnershipPrefixes` | 所有境界の接頭辞 |
| `$ResoLoopDefaultExternalRoles` | item audit で既定許可する外部参照ロール (PBS_Metallic:_shader / TextRenderer:Font / TextRenderer:Materials[0] / Grabbable:_lastParent) |
| `$ResoLoopDefaultPrivacyLevel` | 観測結果の機密度の既定 (0.25) |
| `$ResoLoopRunner` | テスト用フック。関数を入れると RunProcess の代わりに `<|"Executable","Arguments","Directory","Timeout"|>` で呼ばれる |
| `$ResoLoopLastResult` | 直近の生応答 |

## 実行

### ResoLoopRun[args] → data | Failure
Options: `"Project" -> Automatic, "URL" -> Automatic, "Timeout" -> Automatic, "Raw" -> False, "Confirm" -> False, "Adopt" -> False, "Owner" -> None, "Directory" -> Automatic`
生の CLI 呼び出し。`--json` と `--command-timeout` を自動で付け、接続が要るコマンドには `--url` を補う (未接続なら `ResoLoopConnect[]` を先に呼ぶ)。`CONNECTION_FAILED` / `REQUEST_TIMEOUT` は 1 回だけ再探索して再実行する。変更系には安全ゲートがかかる。
### ResoLoopRunAsync[args] → job / ResoLoopAsyncStatus[job] / ResoLoopAsyncResult[job] / ResoLoopAsyncWait[job, timeout] / ResoLoopAsyncKill[job]
同じ内容を bat + `StartProcess` で非ブロック実行する (サービスカーネル向け。rule 100)。Status は "Running" | "Finished" | "Killed"。

## 環境・接続

### ResoLoopExecutable[] → path | Failure["NotInstalled"]
### ResoLoopVersion[] → "0.1.0-preview.17"
### ResoLoopDoctor[] → doctor の項目 (未接続なら `--url auto`、Timeout 120)
### ResoLoopDiscover[] → {<|"sessionId","sessionName","url"|>...}   Options: `"DiscoverySeconds" -> 12`
### ResoLoopConnect[] → url | Failure
Options: `"Session" -> Automatic | 名前, "URL" -> Automatic | "ws://localhost:<port>/", "DiscoverySeconds" -> 12`
候補 1 つ → `status` で確認して接続。複数 → `Failure["AmbiguousSession"]` (候補は `"Sessions"`)。0 → 20 秒で 1 回再探索し、それでも無ければ `Failure["ResoniteLinkOff"]`。
### ResoLoopDisconnect[] / ResoLoopSessionInfo[] / ResoLoopStatus[]
### ResoLoopPrivacyLevel[] → `ResoniteRealtime`ResoniteAccessLevel[]` があればそれ、無ければ `$ResoLoopDefaultPrivacyLevel`
### ResoLoopLog[n] → 直近 n 件の呼び出し (Time / Arguments / Elapsed / OK / Code) / ResoLoopLocks[]

## プロジェクト

### ResoLoopProjects[] → 名前のリスト
### ResoLoopProject[name] → dir | Failure["ProjectNotFound"]   Options: `"Create" -> False` (True で `resoloop init` + Sync)
### ResoLoopProjectSync[name] → <|"Directory","SkillsCopied","ClaudeMd","Settings"|>
`.agents/skills` → `.claude/skills` 複製、`CLAUDE.md` が無ければ生成。`"BuilderPolicy" -> True` で `.claude/settings.json` に builder 用 allow/deny (無いときだけ):
allow = `Bash(resoloop *)`, `PowerShell(resoloop *)`, Read/Write/Edit/Glob/Grep、deny = `slot delete` / `component remove` / `--prune` / `--adopt`。

## 観測 (読み取り専用)

### ResoLoopHierarchy[under, depth] (既定 "Root", 1)   Options: `"IncludeComponents", "Summary", "State"`
### ResoLoopFind["Name" -> text | "Component" -> type]   Options: `"Exact", "Under", "DirectChildren", "Depth"`
### ResoLoopInspect[slotOrSelector]   Options: `"State", "Depth", "Members", "Component", "Member", "ComponentsOnly"`
`$slot:key` には `"State" -> ownership key` (→ `<project>/.resoloop/state/<key>.json`) かファイルが要る。
### ResoLoopComponentInspect[idOrSelector]   Options: `"State"`
### ResoLoopTypeSearch[query] / ResoLoopTypeDescribe[type, "Member" -> name] / ResoLoopTypeSpecialize[open, {args}] → 閉じた型名

## 宣言

### ResoLoopValidate[file]   Options: `"Strict" -> False` (True は接続が要る)
### ResoLoopDiff[file]   Options: `"Mode" -> "Changes" | "Creates" | "Deletes" | "Summary" | All, "State", "Adopt"`
### ResoLoopApply[file]   Options: `"State", "Prune" -> False (要 Confirm), "Confirm", "Adopt", "Profile", "Quiet" -> True, "Timeout"`
同じ apply をもう一度呼んで updated が 0 なら収束。
### ResoLoopTest[file]   Options: `"State", "Probe" -> False (要 Confirm)`
### ResoLoopCapture[file, camera, output]   Options: `"Width", "Height", "Import" -> False`  (output 既定 `artifacts/<file>.jpg`)
### ResoLoopSceneSummary[file, output]
### ResoLoopItemAudit[root]   Options: `"Strict" -> True, "AllowExternalRoles" -> Automatic | None | {...}, "State", "Report" -> False`
`"Report" -> True` なら不合格 (`ITEM_NOT_PORTABLE`) でも report Association を返す。

## Flux

### ResoLoopFluxStatus[] / ResoLoopFluxCheck[pg] / ResoLoopFluxBuild[pg]   Options: `"FluxProject" -> Automatic` (`<project>/flux`)
### ResoLoopFluxNodeSearch[query, "Limit" -> 50] → nodes / ResoLoopFluxNodeDescribe[name] → nodes
### ResoLoopFluxValidateManifest[manifest] / ResoLoopFluxDeployManifest[manifest] (mutation)

## 原始操作 (所有境界内のみ)

### ResoLoopSlotCreate["Name" -> ..., "Parent" -> "Root", "Position" -> {x,y,z}, "Rotation" -> {x,y,z,w}, "Scale" -> {x,y,z}]
### ResoLoopSlotSet[id, "Name" | "Position" | "Rotation" | "Scale" -> ...]
### ResoLoopSlotDelete[id, "Confirm" -> True]
### ResoLoopComponentAdd[slotId, type, <|member -> value ...|>]
### ResoLoopComponentSet[idOrSelector, member, value]   Options: `"Owner", "State"`
### ResoLoopComponentRemove[idOrSelector, "Confirm" -> True]   Options: `"Owner", "State"`
### ResoLoopOwnedQ[slotId] → True | False | Failure

## 建築ジョブ (ResoLoop_builder.wl、自動ロード)

自然文の依頼を Resonite の世界に実装する。既定 backend "ClaudeCLI" は `claude --print --output-format stream-json` を **プロジェクトを cwd にして**起動する
(CLAUDE.md と `.claude/skills/resonite-*` が効く)。別 OS プロセスなので非ブロック。進捗は stream-json を後から読んで判定する (polling tick 不要)。
PrivacyLevel > 0.5 は `Failure["BackendUnavailable"]` (ローカル LLM backend は未実装。黙ってクラウドへ送らない)。

### ResoLoopBuildSubmit[request] → <|"JobId","Ownership","Project","Status","Phase","Placement","Mode","Target"|> | Failure
Options: `"Project" -> $ResoLoopBuilderProject ("VoiceBuilds"), "Placement" -> Automatic | <|"User","Distance"|> | <|"Position","Rotation"|>, "Backend" -> Automatic, "PrivacyLevel" -> Automatic, "Model", "MaxTurns" -> 80, "Timeout" -> 900, "Origin" -> "Notebook", "Ownership" -> Automatic, "Target" -> Automatic | None | "ResoLoop_X", "Adopt" -> Automatic | False`
同一プロジェクトで同時 1 件 (`Failure["Busy"]`)。新規 (Mode `create`) の ownership key は `vb-YYYYMMDD-HHMMSS-xxxx`、宣言は `content/<key>.json`。
**既存物の変更 (Mode `modify`)**: 依頼文に既にワールドにある `ResoLoop_...` の名前があり (大文字小文字は問わない)、「作って」系の語が無ければ、その物を作ったプロジェクトで走り、既存の宣言 `content/<key>.json` を編集する (新しい宣言は作らない。`"Target" -> "ResoLoop_X"` で明示、`None` で常に新規)。root の transform は実測値を宣言に写して跳ばせない。所有 state `.resoloop/state/<key>.json` が無い (別 PC で作った・セッションが変わった) ときは、`diff --adopt` に delete / rename / Slot の create が無いことを確かめてから `apply --adopt` で束縛し直す (`"Adopt" -> False` なら `Failure["OwnershipUnbound"]`。危ない差分は `Failure["AdoptUnsafe"]` で人に返す)。プロジェクトには builder の安全設定 (`ResoLoopProjectSync["BuilderPolicy" -> True]`) を揃える。
### ResoLoopBuildTarget[requestOrRootName] → <|"RootName","Project","Directory","File","Ownership","LiveId","Path","Transform","StateFile","StateBound","FluxManifests"|> | None | Failure
文中の `ResoLoop_...` をプロジェクト群の宣言 (`content/*.json` の `slot.name`) とワールドの実物 (`find`, Root 直下) の両方で照合する。無ければ `None` (新規)。実物だけなら `Failure["TargetDeclarationMissing"]` (adjust を使う)、宣言だけなら `Failure["TargetNotFound"]`。
### $ResoLoopBuilderFacts
プロンプトに入れる Resonite の事実 (文字列のリスト)。既定: Resonite に RigidBody は無く、重力落下は root の Collider (`Type: CharacterController`) + `FrooxEngine.CharacterController` + ProtoFlux `HostUser` → `$member:cc.SimulatingUser` (mode drive) で実装し、Grabbable が付く物は `not IsGrabbableGrabbed(...)` を `$member:cc.Enabled` に drive して掴み中は止める (止めないと持ち上がらない。SimulatingUser が空だと動かない。ResoniteLink は User 参照を書けない。実機 2026-09-23 検証)、Unity 系の部品名 (RigidBody / Kinematic / NoGravity) は目的の言い換えとして読む、など。
### ResoLoopJobStatus[jobId] → <|"JobId","Status" (running|done|failed|cancelled),"Phase","Ownership","Elapsed","ToolCalls","LastCommand","Summary","RootName"|>
phase は最後のツール呼び出しから推定: inspecting / authoring / validating / applying / compiling / deploying / verifying / done。jobId 省略で直近。
### ResoLoopJobResult[jobId] → Report (ownership / rootName / summary / capture / verification / notes)、Capture (絶対パス)、Turns、Cost、Denials、Events | Failure["Running"]
### ResoLoopBuildWatch[jobId] → <|"JobId","Watching","Key","Message"|> | Failure["WatchUnavailable"]   Options: `"Notebook" -> Automatic, "Timeout" -> 900, "Interval" -> 5`
即座に返り、claudecode の共有 polling tick (`ClaudeRegisterPollingTick`) がジョブを見張る。完了時に `$ResoLoopBuildWatchWriter` (既定: `ClaudeWriteResponse` で要約の markdown + 撮影画像の Output セル) がノートブックに書く。
ClaudeEval のコードは `ResoLoopBuildSubmit[...]; ResoLoopBuildWatch[]` の 1 セルにする (数秒で返るので TimeoutExtension の承認が出ない)。`ResoLoopBuildWatchTick[jobId]` は tick 1 回分 (テスト用に公開)。
### ResoLoopJobWait[jobId] → ResoLoopJobResult と同じ | Failure["Running"]   Options: `"Timeout" -> 300, "Poll" -> 5`
終わるまで同期に待って結果を返す (スクリプト向け。ClaudeEval では 30 秒超の同期実行として承認が要る)。
### ResoLoopJobCancel[jobId] / ResoLoopJobs[] / ResoLoopJobEvents[jobId]

### ResoLoopRegisterHeads[] → <|"Registered","Approval"|> | Missing["NoNBAccess"]
NBAccess の許可ヘッド (読み取り系・ジョブ系・`ResoLoopBuildSubmit` など 44 個。`ResoLoopBuildWatch` を含む) と承認ヘッド (`ResoLoopApply` / `ResoLoopSlotDelete` / `ResoLoopRun` など) を 2 層 (`NBRegisterAllowedHeads` + `NBRegisterTrustedPackageHeads`) で登録する。ロード時に自動実行。
`ClaudeCode`$ClaudePackageKeywordMap["ResoLoop"]` にも語 (Resonite / resoloop / ProtoFlux …) を登録する。
### ResoLoopBuildPrompt[request, opts] → プロンプト文字列 (起動しない)。手順 (type describe → 宣言 → validate → strict → diff → apply ×2 → capture → item audit → 挙動の実測) と 1 行 JSON 報告の書式、`$ResoLoopBuilderFacts` を含む。`"Target" -> ResoLoopBuildTarget の結果` で修正モードの文面 (既存宣言の編集、root 配下の update 許可、delete 禁止、配置なし)。
### ResoLoopUserPlacement[] → <|"Position","Rotation","User","UserId","HeadPosition","Forward"|>
利用者の User Slot と Head の向き (ヨー) から正面 `"Distance"` (1.0 m)、高さ = 頭 − 0.35 m の点。`Rotation` は正規化済みで、局所 −Z (TextRenderer の読める面) が利用者を向く。`"User" -> 名前` で複数人から選ぶ。
### 変数
`$ResoLoopBuilderExecutable` (claude.cmd / claude.exe、Automatic で探索) / `$ResoLoopBuilderModel` / `$ResoLoopBuilderMaxTurns` / `$ResoLoopBuilderTimeout` / `$ResoLoopBuilderProject` / `$ResoLoopBuilderJobsDirectory` (`%LOCALAPPDATA%\ResoLoop\jobs`) / `$ResoLoopBuilderAllowedTools`
(`Bash(resoloop *)`, `PowerShell(resoloop *)`, Read, Write, Edit, Glob, Grep。deny はプロジェクトの `.claude/settings.json`)。

## MCP tool (ResoLoop_mcp.wl、自動ロード)

SourceVault MCP の外部登録簿 (`SourceVault`$SourceVaultMCPExternalTools`、`SourceVaultMCPRegisterTools`) に `sourcevault_resonite_*` を登録する。
ClaudeEval からは Claude Code CLI (`--mcp-config`) とローカル LLM (`$ClaudeLocalToolLoop`) の両経路で見える。service kernel には
`$SourceVaultServiceExtraPackages` 経由でロードされる (**反映には SourceVault service の再起動が要る**)。

| tool | 種別 | 内容 |
| --- | --- | --- |
| `sourcevault_resonite_status` | 読 | 接続・セッション・機密度・実行中ジョブ |
| `sourcevault_resonite_query` | 読 | `kind`: hierarchy (under, depth≤3) / find / inspect / component_inspect / type_search / type_describe / flux_node_search / flux_node_describe |
| `sourcevault_resonite_build` | 書 (非同期) | `{request, project?, user?, distance?}` → jobId。完了は job_status が done |
| `sourcevault_resonite_job_status` / `_job_result` | 読 | ジョブの進捗 / 結果 (summary, rootName, capture) |
| `sourcevault_resonite_adjust` | 書 | `{target (ownership key か Slot ID), position/rotation/scale/name}` または `{target, componentKey, member, value}` |
| `sourcevault_resonite_remove` | 書 | `confirm` 無しは候補 (名前・子 Slot 数) の提示だけ。headless CLI では pre-allow しない |

`ResoLoopMCPTools[]` / `ResoLoopMCPCallTool[name, args]` / `ResoLoopMCPRegister[]` / `ResoLoopMCPPromptDirective[]` / `$ResoLoopMCPAllowedTools` / `$ResoLoopMCPMaxChars` (8000)。
方針は `Claude Directives/rules/109-resonite-resoloop-mcp.md`。

## 使用例

```mathematica
Block[{$CharacterEncoding = "UTF-8"}, Get["ResoLoop.wl"]];
ResoLoopConnect[]                                   (* ws://localhost:<port>/ *)
ResoLoopStatus[]["resoniteVersion"]
ResoLoopFind["Name" -> "ResoLoop_", "Depth" -> 1]  (* 自分が作った root 一覧 *)
ResoLoopValidate["content/spinbox.json", "Strict" -> True]
ResoLoopDiff["content/spinbox.json"]               (* create 以外が無いことを見る *)
ResoLoopApply["content/spinbox.json"]
ResoLoopFluxDeployManifest["flux/spinbox.flux.json"]
ResoLoopInspect["$slot:box", "State" -> "spinbox"]["rotation"]
ResoLoopItemAudit["$slot:root", "State" -> "spinbox"]
```

テスト: `test codes/ResoLoop_test.wls` (モック実行器、`wolfram.exe -noinit -noprompt -script`)。
