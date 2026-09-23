---
tier: procedure
paths:
  - "**/ResoLoop*.wl"
  - "**/ResoLoop_projects/**"
  - "**/ResoniteRealtime*.wl"
---

# 109 — Resonite の世界は resoloop (sourcevault_resonite_*) で扱う

## 背景

Resonite の世界の構造 (Slot / Component / ProtoFlux) を変える窓口は `ResoLoop.wl` (resoloop CLI の共通層) に一本化されている
(`ResoLoop_info/design/resoloop_integration_spec_v0_1.md`)。ClaudeEval からは SourceVault MCP の
`sourcevault_resonite_*` として見える。建築は別プロセスの Claude Code CLI (`claude --print`、プロジェクト cwd、Skill 付き) が
行うので**非同期**であり、削除は人が決める。

## 必須ルール

1. **推測で答えない**: 「今ワールドに何があるか」「あの物は何か」は `sourcevault_resonite_query`
   (kind = hierarchy / find / inspect) で観測してから答える。型やメンバー名は `type_search` / `type_describe` で確かめる。
2. **建築は 1 回の submit と polling**: 「作って」は `sourcevault_resonite_build` を **1 回だけ**呼び、返った `jobId` を保持する。
   `sourcevault_resonite_job_status` が `done` になるまで「作りました」と言わない (30 秒〜数分)。`failed` なら `summary` の理由を伝える。
   同じ依頼で build を連打しない (同一プロジェクトは同時 1 件で `Busy` になる)。
3. **完了報告は job_result から**: `summary` (何をどこに作ったか) と `capture` (撮影画像のパス) をそのまま使い、作文で補わない。
4. **削除は人の同意の後**: `sourcevault_resonite_remove` は `confirm` 無しで呼ぶと候補 (名前と子 Slot 数) を返すだけ。利用者が
   その候補に明示的に同意した後でだけ `confirm: true` で呼び直す。所有外 (`ResoLoop_*` で始まらない root) は消せない。
5. **小さな調整は adjust、機能の追加・変更は build**: 位置・回転・大きさ・名前・Component の 1 フィールドの変更は
   `sourcevault_resonite_adjust`。既にある物に部品や仕組みを足す変更 (「ResoLoop_MoodLamp を重力に従うように」など) は
   `sourcevault_resonite_build` の `request` に root 名 `ResoLoop_...` を書く (または `target`)。builder は宣言を編集する
   修正モードで走り、所有 state が無ければ宣言と実物が一致するときだけ束縛し直す。別の物として作り直すなら普通の build。
8. **依頼文には目的を書き、Resonite に無い部品名を書かない**: Resonite に RigidBody / Kinematic / NoGravity は無い。
   「重力で落ちる」「床に置ける」と目的を書けば、builder が CharacterController + HostUser 駆動の SimulatingUser で実装する。
6. **ノートブック側の直接 API** (`ResoLoop*`) を使うコードを生成するときも同じ制約に従う: `ResoLoopSlotDelete` /
   `ResoLoopApply["Prune" -> True]` には `"Confirm" -> True` が要り、`--adopt` は `"Adopt" -> True` を人が書いたときだけ。
7. **ノートブックのコードで建築するときは「投げて見張る」の 1 セルにする**: `ResoLoopBuildSubmit[依頼]; ResoLoopBuildWatch[]`。
   `ResoLoopBuildWatch[]` は即座に返り、共有 polling tick がジョブを見張って、完了時に要約と撮影画像をノートブックに書く。
   セルの実行は数秒で終わるので `expectedSeconds` は 30 以下にする (30 秒を超える同期実行は TimeoutExtension の承認が要る。
   `ResoLoopJobWait[]` で同期に待つのはその承認を受け入れられるときだけ)。`Pause` を挟んで `ResoLoopJobStatus` を何度も
   提案しない。jobId をグローバル変数 (`job = ...`) に保存しない: `ResoLoopBuildWatch[]` / `ResoLoopJobStatus[]` /
   `ResoLoopJobResult[]` は引数省略で直近のジョブを指す。読み取り系・ジョブ系の `ResoLoop*` は NBAccess の許可ヘッドに
   登録済み (承認不要)。承認が要るのは apply / delete / remove / deploy / 生の `ResoLoopRun` だけ。
   返事は「作り始めました。完了すると結果がこのノートブックに書かれます」で終え、完了を待たない。

## 禁止パターン

```text
❌ 「ワールドには箱とランプがあります」と観測せずに答える
❌ sourcevault_resonite_build を呼んだ直後に「作りました」
❌ job_status が running のまま、同じ依頼で build をもう一度呼ぶ
❌ 利用者に確認せず remove に confirm: true
❌ resoloop CLI を Bash で直接叩く (ResoLoop.wl / MCP を通す。安全ゲートが効かない)
❌ ノートブックで `job = ResoLoopBuildSubmit[...]` と保存し、次のセルで `Pause[25]; ResoLoopJobStatus[job["JobId"]]` を繰り返す
```

ノートブックのコードでの正しい形 (1 セル、数秒で返る):

```mathematica
ResoLoopBuildSubmit["黄色い円錐を目の前に作って"];
ResoLoopBuildWatch[]   (* 即座に返る。完了時に要約・root 名・撮影画像がノートブックに書かれる *)
```

## 正しい流れ

```text
利用者: 「青い箱を目の前に作って」
  → sourcevault_resonite_status (接続確認)
  → sourcevault_resonite_build {request: "青い箱を目の前に作って"}  → jobId, ownership
  → 「作り始めました (1 分ほど)」
  → sourcevault_resonite_job_status {jobId}  … running / applying …
  → done → sourcevault_resonite_job_result {jobId} → summary と capture を報告
```
