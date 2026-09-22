# ResoLoop ユーザーマニュアル

ResoLoop は resoloop CLI (Resonite を ResoniteLink 経由で操作する CLI) の Mathematica 側の共通層です。
「この層だけが CLI を知る」設計で、ノートブック・MCP・ResoniteRealtime・音声など上位はすべてここを通り、安全ゲートを迂回できません。
オプション付きの API 一覧は [api.md](api.md)、導入は [setup.md](setup.md) を参照してください。

## 目次

- 用語と約束
- 接続と環境
- 観測 (読み取り専用)
- 宣言ファイルの検証・適用
- 原始操作
- ProtoFlux (Flux-SDK)
- 非同期実行
- 建築ジョブ (自然文から世界を組み立てる)
- MCP tool
- 安全ゲート
- 変数とログ

## 用語と約束

- **プロジェクト**: `resoloop init` が作るフォルダ (`.resoloop.json` / `content/` / `flux/` / `.resoloop/state/`)。すべての関数が `"Project" -> 名前` を受け、そのフォルダを cwd にして CLI を実行します。省略時は `$ResoLoopDefaultProject` (既定 `"MyResoniteProject"`)。
- **宣言ファイル**: 世界に作る Slot / Component を書いた JSON (`content/<name>.json`)。`validate` → `diff` → `apply` の順で世界に反映します。
- **State と安定セレクタ**: apply は `.resoloop/state/<key>.json` に生成物の ID を記録します。以後 `$slot:key` のようなセレクタで同じ物を指せます (`"State" -> key` を渡す)。
- **所有境界**: 変更できるのは root 名が `$ResoLoopOwnershipPrefixes` (既定 `{"ResoLoop_"}`) で始まる Slot の配下だけ。`Root` や `User ...`、他人の物は `Failure["OutsideOwnership"]`。
- **戻り値**: 成功は resoloop の `data` (Association / List) をそのまま返します。表示は持ちません (core/View 分離)。失敗は `Failure["ResoLoop", <|"Code", "MessageTemplate", "Context", "Suggestions"|>]`。生の応答は `$ResoLoopLastResult`。

## 接続と環境

```wolfram
Block[{$CharacterEncoding = "UTF-8"}, Get["ResoLoop.wl"]];
ResoLoopDoctor[]        (* 接続 / Flux-SDK / managed data / log *)
ResoLoopDiscover[]      (* {<|"sessionId", "sessionName", "url"|> ...} *)
ResoLoopConnect[]       (* 候補が 1 つならそれに接続し "ws://localhost:<port>/" を返す *)
ResoLoopStatus[]        (* Resonite の版・セッション名など *)
ResoLoopDisconnect[]
```

- `ResoLoopConnect[]` は候補が複数なら `Failure["AmbiguousSession"]` (候補は `"Sessions"`)、0 なら 20 秒後に 1 回だけ再探索し、それでも無ければ `Failure["ResoniteLinkOff"]` を返します。待ち続けたり代替経路に落ちたりはしません。
- 接続が要るコマンドは `--url` を自動で補い、`CONNECTION_FAILED` / `REQUEST_TIMEOUT` のときは 1 回だけ再探索します。
- `ResoLoopPrivacyLevel[]` は観測結果の機密度。`ResoniteRealtime`ResoniteAccessLevel[]` があればそれ、無ければ `$ResoLoopDefaultPrivacyLevel` (0.25 = 公開ワールド相当)。

## 観測 (読み取り専用)

```wolfram
ResoLoopHierarchy["Root", 1]                         (* 階層 *)
ResoLoopFind["Name" -> "ResoLoop_", "Depth" -> 1]    (* 自分が作った root 一覧 *)
ResoLoopFind["Component" -> "MeshRenderer"]
ResoLoopInspect["$slot:box", "State" -> "spinbox"]   (* 安定セレクタで指す *)
ResoLoopComponentInspect[componentId]
ResoLoopTypeSearch["PBS_Metallic"]
ResoLoopTypeDescribe["[FrooxEngine]FrooxEngine.PBS_Metallic", "Member" -> "AlbedoColor"]
ResoLoopTypeSpecialize["ValueField<T>", {"float"}]   (* 閉じた型名 *)
ResoLoopSceneSummary[file, output]
```

観測系は承認不要です (NBAccess がある環境では許可ヘッドに登録されます)。

## 宣言ファイルの検証・適用

```wolfram
ResoLoopValidate["content/spinbox.json"]                    (* 構文と型 *)
ResoLoopValidate["content/spinbox.json", "Strict" -> True]  (* 接続して実在の型・メンバと突合 *)
ResoLoopDiff["content/spinbox.json"]                        (* create 以外が無いことを確かめる *)
ResoLoopApply["content/spinbox.json"]                       (* 反映 *)
ResoLoopApply["content/spinbox.json"]                       (* もう一度。updated が 0 なら収束 *)
ResoLoopTest["content/spinbox.json"]
ResoLoopCapture["content/spinbox.json", camera, "artifacts/spinbox.jpg", "Import" -> True]
ResoLoopItemAudit["$slot:root", "State" -> "spinbox"]      (* 持ち出せる item か (外部参照の監査) *)
```

- `ResoLoopApply` の `"Prune" -> True` (宣言に無い物を消す) は `"Confirm" -> True` が無ければ実行されません。
- `--adopt` (既存の物を取り込む) は `"Adopt" -> True` を人がノートブックで書いたときだけです。
- apply の checkpoint 書き込みが同期ソフトに阻まれた (`APPLY_STATE_WRITE_FAILED`) ときは、同じ apply をもう一度呼ぶと checkpoint から収束します。

## 原始操作

宣言ファイルを使わない 1 手の操作です。所有境界の中でだけ動きます。

```wolfram
root = ResoLoopSlotCreate["Name" -> "ResoLoop_Demo", "Parent" -> "Root", "Position" -> {0, 1.2, 1.5}];
ResoLoopComponentAdd[root["id"], "[FrooxEngine]FrooxEngine.Grabbable", <|"Scalable" -> True|>];
ResoLoopSlotSet[root["id"], "Scale" -> {0.5, 0.5, 0.5}];
ResoLoopComponentSet["$slot:box", "AlbedoColor", {0.2, 0.4, 0.9, 1}, "State" -> "spinbox"];
ResoLoopOwnedQ[root["id"]]
ResoLoopSlotDelete[root["id"], "Confirm" -> True]
```

`slot create` の親が所有外 (Root など) のときは、`"Name"` に接頭辞 `ResoLoop_` が要ります。

## ProtoFlux (Flux-SDK)

```wolfram
ResoLoopFluxStatus[]
ResoLoopFluxCheck["flux/Main.pg"]
ResoLoopFluxBuild["flux/Main.pg"]
ResoLoopFluxNodeSearch["ValueAdd"]
ResoLoopFluxNodeDescribe["ValueAdd<float>"]
ResoLoopFluxValidateManifest["flux/spinbox.flux.json"]
ResoLoopFluxDeployManifest["flux/spinbox.flux.json"]   (* mutation。所有境界の中 *)
```

Flux-SDK が無い環境では `ResoLoopDoctor[]` の該当項目が fail になり、Flux 系は resoloop のエラーをそのまま返します。

## 非同期実行

サービスカーネルなど、長い CLI 呼び出しでブロックできない場所では `ResoLoopRunAsync` を使います (bat + `StartProcess`)。

```wolfram
job = ResoLoopRunAsync[{"apply", "content/spinbox.json"}];
ResoLoopAsyncStatus[job]         (* "Running" | "Finished" | "Killed" *)
ResoLoopAsyncWait[job, 300]
ResoLoopAsyncResult[job]
ResoLoopAsyncKill[job]
```

## 建築ジョブ (自然文から世界を組み立てる)

`ResoLoop_builder.wl` (自動ロード)。「青い箱を目の前に作って」のような依頼を、Skill を持つエージェント (既定 backend は Claude Code CLI) に任せます。CLI はプロジェクトを cwd にして別 OS プロセスで走るので、ノートブックはブロックされません。

```wolfram
ResoLoopBuildSubmit["黄色い円錐を目の前に作って"];
ResoLoopBuildWatch[]          (* 即座に返る。完了時に要約・root 名・撮影画像がノートブックに書かれる *)
```

- 進捗は `ResoLoopJobStatus[]` (queued / running / done / failed / cancelled と phase)、結果は `ResoLoopJobResult[]` (summary / rootName / capture / verification / notes、コスト、拒否された操作)。引数省略で直近のジョブを指します。
- `ResoLoopJobWait[]` は終わるまで同期に待ちます (スクリプト向け)。`ResoLoopJobCancel[]` / `ResoLoopJobs[]` / `ResoLoopJobEvents[]`。
- 置き場所は既定でアバターの正面 1 m (`ResoLoopUserPlacement[]`: User Slot と Head の向きから計算。`"User" -> 名前` で複数人から選ぶ)。`"Placement" -> <|"Position" -> {x,y,z}, "Rotation" -> {x,y,z,w}|>` で明示もできます。
- 同一プロジェクトは同時 1 件 (`Failure["Busy"]`)。ownership key は `vb-YYYYMMDD-HHMMSS-xxxx`、宣言は `content/<key>.json` に残ります。
- PrivacyLevel > 0.5 (私有ワールド相当) は `Failure["BackendUnavailable"]` です。ローカル LLM backend は未実装で、黙ってクラウドへ送らない設計です。
- `ResoLoopBuildPrompt[request]` はプロンプトだけを組み立てて返します (起動しない)。

## MCP tool

`ResoLoop_mcp.wl` (自動ロード) は SourceVault MCP に `sourcevault_resonite_*` を登録します。ClaudeEval からは Claude Code CLI (`--mcp-config`) とローカル LLM の両経路で見えます。

| tool | 種別 | 内容 |
| --- | --- | --- |
| `sourcevault_resonite_status` | 読 | 接続・セッション・機密度・実行中ジョブ |
| `sourcevault_resonite_query` | 読 | hierarchy / find / inspect / component_inspect / type_search / type_describe / flux_node_search / flux_node_describe |
| `sourcevault_resonite_build` | 書 (非同期) | 建築ジョブの投入 → jobId |
| `sourcevault_resonite_job_status` / `_job_result` | 読 | 進捗 / 結果 |
| `sourcevault_resonite_adjust` | 書 | 位置・回転・大きさ・名前・Component の 1 フィールド |
| `sourcevault_resonite_remove` | 書 | `confirm` 無しは候補の提示だけ |

登録は `ResoLoopMCPRegister[]`、定義は `ResoLoopMCPTools[]`、直接呼ぶなら `ResoLoopMCPCallTool[name, args]`。service kernel への反映には SourceVault service の再起動が要ります。LLM 側の方針は `ResoLoop_info/directives/109-resonite-resoloop-mcp.md`。

## 安全ゲート

| 制約 | 内容 |
| --- | --- |
| 所有境界 | `ResoLoop_` で始まる root の配下だけ変更できる |
| Confirm | `--yes` を含む操作 (`slot delete` / `component remove` / `apply --prune` / `test --probe`) は `"Confirm" -> True` が必須 |
| Adopt | `--adopt` は `"Adopt" -> True` のときだけ |
| Owner | 生の Component ID を変更するときは `"Owner" -> slotId` で所有を確認 |
| 排他 | 1 プロジェクト 1 mutation。実行中は `Failure["Busy"]` |
| 承認ヘッド | NBAccess がある環境では `ResoLoopApply` / `ResoLoopSlotDelete` / `ResoLoopComponentRemove` / `ResoLoopFluxDeployManifest` / 生の `ResoLoopRun` が承認対象 |

生の CLI を直接呼ぶ `ResoLoopRun[{"find", "--name", "Box"}]` も同じゲートを通ります。Bash で resoloop を直接叩くとゲートが効かないので、必ずこの層を通してください。

## 変数とログ

| 変数 | 意味 |
| --- | --- |
| `$ResoLoopExecutable` | resoloop 実行ファイル (Automatic = `%USERPROFILE%\.dotnet\tools\resoloop.exe` → PATH) |
| `$ResoLoopProjectsDirectory` / `$ResoLoopDefaultProject` | プロジェクト置き場と既定名 |
| `$ResoLoopURL` / `$ResoLoopSession` | 接続中の URL とセッション名 |
| `$ResoLoopDefaultTimeout` / `$ResoLoopLongTimeout` | 60 / 600 秒 (apply / capture / test / item / flux / init は Long) |
| `$ResoLoopOwnershipPrefixes` | 所有境界の接頭辞 |
| `$ResoLoopDefaultExternalRoles` | item audit で既定許可する外部参照ロール |
| `$ResoLoopDefaultPrivacyLevel` | 観測結果の機密度の既定 (0.25) |
| `$ResoLoopBuilderExecutable` / `$ResoLoopBuilderModel` / `$ResoLoopBuilderMaxTurns` / `$ResoLoopBuilderTimeout` / `$ResoLoopBuilderProject` / `$ResoLoopBuilderJobsDirectory` / `$ResoLoopBuilderAllowedTools` | 建築ジョブの設定 |
| `$ResoLoopMCPAllowedTools` / `$ResoLoopMCPMaxChars` | MCP の pre-allow と結果本文の上限 |
| `$ResoLoopRunner` | テスト用フック (RunProcess の代わりに呼ばれる関数) |

`ResoLoopLog[n]` で直近 n 件の呼び出し (Time / Arguments / Elapsed / OK / Code)、`ResoLoopLocks[]` で実行中の mutation ロックが見えます。
