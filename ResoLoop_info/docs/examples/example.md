# ResoLoop 使用例集

resoloop CLI を Mathematica から扱う共通層の、よく使う操作パターンをまとめます。各例は `Block[{$CharacterEncoding = "UTF-8"}, Get["ResoLoop.wl"]]` の後にそのまま評価できます。Resonite 側で ResoniteLink を有効化しておいてください (導入は [setup.md](setup.md))。

## 1. 導入確認と接続

```mathematica
ResoLoopDoctor[]
ResoLoopConnect[]
ResoLoopStatus[]["resoniteVersion"]
```
`ResoLoopConnect[]` は `"ws://localhost:<port>/"` を返します。候補が無ければ `Failure["ResoLoop", ...]` (Code `ResoniteLinkOff`)。

## 2. 自分が作った物だけを一覧する

```mathematica
ResoLoopFind["Name" -> "ResoLoop_", "Depth" -> 1]
```
所有境界 (`ResoLoop_` で始まる root) の配下だけが変更対象です。

## 3. 宣言ファイルから物を作る (validate → diff → apply → 収束確認)

```mathematica
ResoLoopValidate["content/spinbox.json", "Strict" -> True]
ResoLoopDiff["content/spinbox.json"]         (* create 以外が無いことを見る *)
ResoLoopApply["content/spinbox.json"]
ResoLoopApply["content/spinbox.json"]        (* updated が 0 なら収束 *)
```

## 4. 安定セレクタで読み戻す・1 フィールドだけ変える

```mathematica
ResoLoopInspect["$slot:box", "State" -> "spinbox"]["rotation"]
ResoLoopComponentSet["$slot:box", "AlbedoColor", {0.2, 0.4, 0.9, 1}, "State" -> "spinbox"]
```

## 5. 撮影して結果を確かめる

```mathematica
img = ResoLoopCapture["content/spinbox.json", "$slot:camera", "artifacts/spinbox.jpg", "Import" -> True]
ResoLoopItemAudit["$slot:root", "State" -> "spinbox"]
```

## 6. 削除は Confirm を明示する

```mathematica
ResoLoopSlotDelete["$slot:root", "Confirm" -> True]       (* 無ければ実行されない *)
ResoLoopApply["content/spinbox.json", "Prune" -> True, "Confirm" -> True]
```

## 7. 型を調べてから宣言を書く

```mathematica
ResoLoopTypeSearch["PBS_Metallic"]
ResoLoopTypeDescribe["[FrooxEngine]FrooxEngine.PBS_Metallic", "Member" -> "AlbedoColor"]
ResoLoopTypeSpecialize["ValueField<T>", {"float"}]
```

## 8. ProtoFlux を check → build → deploy

```mathematica
ResoLoopFluxCheck["flux/Main.pg"]
ResoLoopFluxBuild["flux/Main.pg"]
ResoLoopFluxDeployManifest["flux/spinbox.flux.json"]
```
Flux-SDK 1.9.0 が必要です (`ResoLoopDoctor[]` で確認)。

## 9. 自然文で建築を頼み、完了をノートブックで受け取る

```mathematica
ResoLoopBuildSubmit["黄色い円錐を目の前に作って"];
ResoLoopBuildWatch[]
```
セルは数秒で返ります。完了すると要約・root 名・撮影画像がノートブックに書かれます (claudecode.wl の共有 polling tick)。同期に待つなら `ResoLoopJobWait[]`。

## 10. 建築ジョブの進捗と結果

```mathematica
ResoLoopJobStatus[]
ResoLoopJobResult[]["Report"]
ResoLoopJobs[]
```

## 11. サービスカーネルで長いコマンドを非ブロック実行

```mathematica
job = ResoLoopRunAsync[{"apply", "content/spinbox.json"}];
ResoLoopAsyncWait[job, 300]
```

## 12. 新しいプロジェクトを作る

```mathematica
ResoLoopProject["Garden", "Create" -> True]
ResoLoopProjects[]
```
`resoloop init` → `.agents/skills` の `.claude/skills` への複製 → `CLAUDE.md` 生成まで行います。

## 13. MCP tool として ClaudeEval から使う

```mathematica
ResoLoopMCPRegister[]      (* SourceVault MCP の外部登録簿に sourcevault_resonite_* を登録 *)
ResoLoopMCPTools[][[All, "name"]]
ResoLoopMCPCallTool["sourcevault_resonite_status", <||>]
```
service kernel への反映には SourceVault service の再起動が要ります。

## 14. 直近の呼び出しを調べる

```mathematica
ResoLoopLog[10]
$ResoLoopLastResult
ResoLoopLocks[]
```
