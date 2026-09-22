(* ::Package:: *)

(* ResoLoop_builder.wl -- 自然文の依頼を Resonite の世界に実装する建築ジョブ (G1/G4 の背骨)

   This file is encoded in UTF-8. ResoLoop.wl が自動でロードする (同じ ResoLoop` コンテキスト)。
   設計: ResoLoop_info/design/resoloop_integration_spec_v0_1.md §3.6。

   「青い箱を目の前に作って」のような依頼は、型調査 → 宣言 → 検証 → 適用 → 再観測の多段推論なので、
   **Skill を持つエージェント**に任せる。既定 backend "ClaudeCLI" は `claude --print` を
   **resoloop プロジェクトを cwd にして**起動する: プロジェクトの CLAUDE.md と .claude/skills/resonite-*
   が効き、手作業と同じ手順を踏む。--print は対話承認できないので、--allowedTools と
   プロジェクトの .claude/settings.json (deny: delete / remove / --prune / --adopt) が安全境界になる。

   ジョブは別 OS プロセス (bat + StartProcess)。進捗は stream-json (JSONL) を後から読んで判定するので
   polling tick は要らない (サービスカーネルでも NB でも同じ)。記録は %LOCALAPPDATA%\ResoLoop\jobs\<id>.json。

   PrivacyLevel > 0.5 (私有ワールド) は LocalToolLoop backend の担当だが v0.1 では未実装 →
   Failure["BackendUnavailable"] を返す (黙ってクラウドに送らない)。
*)

BeginPackage["ResoLoop`"];

ResoLoop`$ResoLoopBuilderExecutable::usage =
  "$ResoLoopBuilderExecutable は Claude Code CLI (claude.cmd / claude.exe) のパス。Automatic なら %APPDATA%\\npm\\claude.cmd と ~/.local/bin/claude.exe を探す。";
ResoLoop`$ResoLoopBuilderModel::usage = "$ResoLoopBuilderModel は建築ジョブの --model。Automatic なら CLI の既定。";
ResoLoop`$ResoLoopBuilderMaxTurns::usage = "$ResoLoopBuilderMaxTurns は 1 ジョブのツール往復上限 (既定 80)。";
ResoLoop`$ResoLoopBuilderTimeout::usage = "$ResoLoopBuilderTimeout は 1 ジョブの壁時計上限秒 (既定 900)。";
ResoLoop`$ResoLoopBuilderProject::usage = "$ResoLoopBuilderProject は建築ジョブの既定プロジェクト (既定 \"VoiceBuilds\")。";
ResoLoop`$ResoLoopBuilderJobsDirectory::usage = "$ResoLoopBuilderJobsDirectory はジョブ記録の置き場 (既定 %LOCALAPPDATA%\\ResoLoop\\jobs)。";
ResoLoop`$ResoLoopBuilderAllowedTools::usage = "$ResoLoopBuilderAllowedTools は --allowedTools に渡すリスト。";

ResoLoop`ResoLoopBuildSubmit::usage =
  "ResoLoopBuildSubmit[request] は自然文の依頼を建築ジョブとして起動し、直ちにジョブ (Association: JobId / Ownership / Project / Status) を返す。\n" <>
  "オプション: \"Project\" -> $ResoLoopBuilderProject, \"Placement\" -> Automatic (利用者の正面) | <|\"User\" -> 名前, \"Distance\" -> 1.0|> | <|\"Position\" -> {x,y,z}, \"Rotation\" -> {x,y,z,w}|>,\n" <>
  "  \"Backend\" -> Automatic (\"ClaudeCLI\"), \"PrivacyLevel\" -> Automatic (ResoLoopPrivacyLevel[])、\"Model\", \"MaxTurns\", \"Timeout\", \"Origin\" -> \"Notebook\"。\n" <>
  "進捗は ResoLoopJobStatus[jobId]、結果は ResoLoopJobResult[jobId]。";
ResoLoop`ResoLoopJobStatus::usage =
  "ResoLoopJobStatus[jobId] は <|\"JobId\",\"Status\" (queued|running|done|failed|cancelled),\"Phase\",\"Ownership\",\"Elapsed\",\"ToolCalls\",\"LastCommand\",\"Summary\"|>。jobId 省略で直近のジョブ。";
ResoLoop`ResoLoopJobResult::usage =
  "ResoLoopJobResult[jobId] は完了したジョブの結果 (Report: ownership / rootName / summary / capture / verification / notes、ResultText、Turns、Cost、Denials、Events)。走っていれば Failure[\"Running\"]。";
ResoLoop`ResoLoopJobCancel::usage = "ResoLoopJobCancel[jobId] はジョブのプロセスを止め、status を cancelled にする。";
ResoLoop`ResoLoopBuildWatch::usage =
  "ResoLoopBuildWatch[jobId] は建築ジョブを claudecode の共有 polling tick で見張り、終わったら結果 (要約・root 名・撮影画像) をノートブックに書く。呼び出しは即座に返る (ブロックしない)。\n" <>
  "ClaudeEval のコードはこれを使う: ResoLoopBuildSubmit[...]; ResoLoopBuildWatch[] (同期待ちの ResoLoopJobWait は 30 秒超の実行として承認が要る)。\n" <>
  "jobId 省略で直近。\"Notebook\" -> Automatic (EvaluationNotebook[])、\"Timeout\" -> 900。claudecode が無ければ Failure[\"WatchUnavailable\"]。";
ResoLoop`ResoLoopBuildWatchTick::usage = "ResoLoopBuildWatchTick[jobId] は見張りの 1 回分 (tick から呼ばれる)。\"Waiting\" | \"Running\" | \"Done\" | \"Failed\" | \"Timeout\" | \"NotWatched\" を返す。";
ResoLoop`$ResoLoopBuildWatchWriter::usage =
  "$ResoLoopBuildWatchWriter は完了時にノートブックへ書く関数 (nb, markdown, capturePath) |-> Null。Automatic なら ClaudeWriteResponse + 画像セル、無ければ Print。";
ResoLoop`ResoLoopJobWait::usage =
  "ResoLoopJobWait[jobId] は建築ジョブが終わるまで待って ResoLoopJobResult を返す (1 回の呼び出しで完結。ノートブックの LLM コードはこれを使い、Pause で自前ポーリングしない)。\n" <>
  "jobId 省略で直近。\"Timeout\" -> 300 秒 (runtime の同期実行上限 600 秒より短く)、\"Poll\" -> 5 秒。時間内に終わらなければ Failure[\"Running\"] (ジョブは走り続ける)。";
ResoLoop`ResoLoopJobs::usage = "ResoLoopJobs[] は記録にあるジョブの要約リスト (新しい順)。";
ResoLoop`ResoLoopJobEvents::usage = "ResoLoopJobEvents[jobId] は stream-json から取り出したツール呼び出し列 ({Tool, Command, Phase} ...)。";
ResoLoop`ResoLoopBuildPrompt::usage = "ResoLoopBuildPrompt[request, opts] は ResoLoopBuildSubmit が使うプロンプト文字列を (起動せずに) 返す。";
ResoLoop`ResoLoopUserPlacement::usage =
  "ResoLoopUserPlacement[] は利用者の頭の向きから正面 \"Distance\" (1.0 m) の点と、正面 (-Z) が利用者を向く rotation を返す。\n" <>
  "<|\"Position\",\"Rotation\",\"User\",\"UserId\",\"HeadPosition\",\"Forward\"|>。\"User\" -> 名前の一部 で複数ユーザーから選ぶ。";
ResoLoop`ResoLoopBuilderParseStream::usage = "ResoLoopBuilderParseStream[jsonlText] は stream-json を解釈して <|\"Events\",\"Result\",\"Phase\",\"ToolCalls\"|> を返す (テスト用に公開)。";

Begin["`Private`"];

If[!ValueQ[ResoLoop`$ResoLoopBuilderExecutable], ResoLoop`$ResoLoopBuilderExecutable = Automatic];
If[!ValueQ[ResoLoop`$ResoLoopBuilderModel], ResoLoop`$ResoLoopBuilderModel = Automatic];
If[!IntegerQ[ResoLoop`$ResoLoopBuilderMaxTurns], ResoLoop`$ResoLoopBuilderMaxTurns = 80];
If[!NumericQ[ResoLoop`$ResoLoopBuilderTimeout], ResoLoop`$ResoLoopBuilderTimeout = 900];
If[!StringQ[ResoLoop`$ResoLoopBuilderProject], ResoLoop`$ResoLoopBuilderProject = "VoiceBuilds"];
If[!StringQ[ResoLoop`$ResoLoopBuilderJobsDirectory],
  ResoLoop`$ResoLoopBuilderJobsDirectory = FileNameJoin[{
    With[{la = Environment["LOCALAPPDATA"]}, If[StringQ[la] && la =!= "", la, $UserBaseDirectory]],
    "ResoLoop", "jobs"}]];
If[!ListQ[ResoLoop`$ResoLoopBuilderAllowedTools],
  ResoLoop`$ResoLoopBuilderAllowedTools = {"Bash(resoloop *)", "PowerShell(resoloop *)", "Read", "Write", "Edit", "Glob", "Grep", "Skill"}];

$ibProcs = <||>;   (* jobId -> ProcessObject (このカーネルが起動したものだけ) *)

(* ============================================================
   小道具
   ============================================================ *)

ibFailure[code_String, msg_String, extra_Association : <||>] :=
  Failure["ResoLoop", Join[<|"Code" -> code, "MessageTemplate" -> msg, "MessageParameters" -> {}|>, extra]];

(* 小数 8 桁 (float32 の精度) で書く。4 桁で丸めると回転がエンジン側で正規化されて宣言と食い違い、
   再 apply が収束しない (2026-09-22 実機で 2 回踏んだ) *)
ibNum[x_Integer] := ToString[x];
ibNum[x_?NumericQ] := Module[{s = StringTrim[ToString[NumberForm[N[x], {16, 8}, ExponentFunction -> (Null &)]]]},
  s = StringReplace[s, RegularExpression["(\\.\\d*?)0+$"] -> "$1"]; StringReplace[s, RegularExpression["\\.$"] -> ""]];
ibVec[v_List] := "[" <> StringRiffle[ibNum /@ v, ", "] <> "]";

ibJobsDir[] := With[{d = ResoLoop`$ResoLoopBuilderJobsDirectory},
  If[!DirectoryQ[d], Quiet @ CreateDirectory[d, CreateIntermediateDirectories -> True]]; d];

ibWorkDir[] :=
  Module[{dir},
    dir = If[ValueQ[ClaudeCode`$ClaudeWorkingDirectory] && StringQ[ClaudeCode`$ClaudeWorkingDirectory],
      ClaudeCode`$ClaudeWorkingDirectory, FileNameJoin[{$HomeDirectory, "Claude Working"}]];
    If[!DirectoryQ[dir], Quiet @ CreateDirectory[dir]];
    dir];

ibWriteUTF8[file_String, text_String] :=
  Module[{strm = OpenWrite[file, BinaryFormat -> True]},
    BinaryWrite[strm, StringToByteArray[text, "UTF-8"]]; Close[strm]; file];

ibReadUTF8[file_String] :=
  If[FileExistsQ[file], Quiet @ Check[ByteArrayToString[ReadByteArray[file], "UTF-8"], ""], ""];

(* JSON 文字列の解釈は必ずバイト経由 (rule 30): ImportString[s, "RawJSON"] は非 ASCII 文字を含む
   WL 文字列で "Out of range Unicode code point" になる。stream-json には日本語が普通に入る。 *)
ibJSONParse[s_String] :=
  Quiet @ Check[ImportByteArray[StringToByteArray[s, "UTF-8"], "RawJSON"], $Failed];

(* JSON に落とせる形へ (DateObject / Failure / Missing / ProcessObject を潰す) *)
ibJSONSafe[a_Association] := Map[ibJSONSafe, KeyMap[ToString, a]];
ibJSONSafe[l_List] := ibJSONSafe /@ l;
ibJSONSafe[d_DateObject] := DateString[d, "ISODateTime"];
ibJSONSafe[f_Failure] := <|"failure" -> ToString[f[[1]]], "message" -> ToString[Lookup[f[[2]], "MessageTemplate", ""]]|>;
ibJSONSafe[_Missing] := Null;
ibJSONSafe[_ProcessObject] := Null;
ibJSONSafe[x_String] := x;
ibJSONSafe[x_?NumericQ] := If[IntegerQ[x], x, N[x]];
ibJSONSafe[True] := True;
ibJSONSafe[False] := False;
ibJSONSafe[Null] := Null;
ibJSONSafe[x_] := ToString[x, InputForm];

ibJSONString[expr_] := ByteArrayToString[ExportByteArray[ibJSONSafe[expr], "RawJSON"], "UTF-8"];

ibSaveJob[job_Association] :=
  Module[{file = FileNameJoin[{ibJobsDir[], job["JobId"] <> ".json"}], strm},
    strm = OpenWrite[file, BinaryFormat -> True];
    BinaryWrite[strm, ExportByteArray[ibJSONSafe[KeyDrop[job, {"Process"}]], "RawJSON"]];
    Close[strm];
    job];

ibLoadJob[id_String] :=
  Module[{file = FileNameJoin[{ibJobsDir[], id <> ".json"}], r},
    If[!FileExistsQ[file], Return[None]];
    r = Quiet @ Check[ImportByteArray[ReadByteArray[file], "RawJSON"], $Failed];
    (* 過去のジョブ記録は RawJSON の実数/整数がそのまま戻る。Started 等は数値のまま扱う *)
    If[AssociationQ[r], r, None]];

ibLatestJobId[] :=
  With[{files = FileNames["*.json", ibJobsDir[]]},
    If[files === {}, None, FileBaseName[Last[SortBy[files, FileDate[#, "Modification"] &]]]]];

(* ============================================================
   実行ファイル
   ============================================================ *)

ibExecutable[] :=
  Module[{exe = ResoLoop`$ResoLoopBuilderExecutable, cands},
    If[StringQ[exe] && FileExistsQ[exe], Return[exe]];
    cands = {
      FileNameJoin[{With[{a = Environment["APPDATA"]}, If[StringQ[a], a, FileNameJoin[{$HomeDirectory, "AppData", "Roaming"}]]], "npm", "claude.cmd"}],
      FileNameJoin[{$HomeDirectory, ".local", "bin", "claude.exe"}]};
    With[{f = SelectFirst[cands, FileExistsQ, None]},
      If[StringQ[f], f, ibFailure["BuilderNotInstalled", "Claude Code CLI (claude.cmd / claude.exe) が見つかりません。"]]]];

(* ============================================================
   配置: 利用者の頭の向きから正面の点
   ============================================================ *)

ibQuatRotate[{qx_, qy_, qz_, qw_}, v_List] :=
  Module[{u = {qx, qy, qz}, s = qw},
    2 (u . v) u + (s^2 - u . u) v + 2 s Cross[u, v]];

ibQuat[assoc_Association] := N[{Lookup[assoc, "x", 0], Lookup[assoc, "y", 0], Lookup[assoc, "z", 0], Lookup[assoc, "w", 1]}];
ibVecOf[assoc_Association] := N[{Lookup[assoc, "x", 0], Lookup[assoc, "y", 0], Lookup[assoc, "z", 0]}];
ibQuatMul[{ax_, ay_, az_, aw_}, {bx_, by_, bz_, bw_}] :=
  {aw bx + ax bw + ay bz - az by, aw by - ax bz + ay bw + az bx, aw bz + ax by - ay bx + az bw, aw bw - ax bx - ay by - az bz};

Options[ResoLoop`ResoLoopUserPlacement] = {"User" -> Automatic, "Distance" -> 1.0, "Height" -> Automatic, "Project" -> Automatic};
ResoLoop`ResoLoopUserPlacement[OptionsPattern[]] :=
  Module[{h, users, user, uh, head, rootPos, rootRot, headPos, headRot, fwd, pos, height, yaw, rot, name},
    h = ResoLoop`ResoLoopHierarchy["Root", 1, "Project" -> OptionValue["Project"]];
    If[FailureQ[h], Return[h]];
    users = Select[Lookup[h, "children", {}], StringStartsQ[Lookup[#, "name", ""], "User "] &];
    If[StringQ[OptionValue["User"]],
      users = Select[users, StringContainsQ[Lookup[#, "name", ""], OptionValue["User"], IgnoreCase -> True] &]];
    Which[
      users === {}, Return[ibFailure["UserNotFound", "ワールドに利用者の User Slot が見つかりません。"]],
      Length[users] > 1, Return[ibFailure["AmbiguousUser",
        "利用者が複数います。\"User\" -> 名前 で選んでください: " <> StringRiffle[Lookup[#, "name", "?"] & /@ users, ", "],
        <|"Users" -> (Lookup[#, "name", "?"] & /@ users)|>]]];
    user = First[users];
    uh = ResoLoop`ResoLoopHierarchy[user["id"], 1, "Project" -> OptionValue["Project"]];
    If[FailureQ[uh], Return[uh]];
    head = SelectFirst[Lookup[uh, "children", {}], Lookup[#, "name", ""] === "Head" &, None];
    rootPos = ibVecOf[Lookup[user, "position", <||>]];
    rootRot = ibQuat[Lookup[user, "rotation", <||>]];
    headPos = If[AssociationQ[head], ibVecOf[Lookup[head, "position", <||>]], {0, 1.6, 0}];
    headRot = If[AssociationQ[head], ibQuat[Lookup[head, "rotation", <||>]], {0, 0, 0, 1}];
    (* 頭のワールド前方 (ヨーだけ) *)
    fwd = ibQuatRotate[ibQuatMul[rootRot, headRot], {0, 0, 1}];
    fwd = {fwd[[1]], 0, fwd[[3]]};
    fwd = If[Norm[fwd] < 10^-6, {0, 0, 1}, Normalize[fwd]];
    height = Replace[OptionValue["Height"], Automatic :> (rootPos[[2]] + headPos[[2]] - 0.35)];
    pos = rootPos + ibQuatRotate[rootRot, headPos] + OptionValue["Distance"] fwd;
    pos = {pos[[1]], height, pos[[3]]};
    (* 物体の局所 +Z が利用者の前方と同じ向き = 局所 -Z (TextRenderer の読める面) が利用者を向く *)
    yaw = ArcTan[fwd[[3]], fwd[[1]]];
    (* 正規化済みの値を十分な桁で渡す。粗く丸めるとエンジン側で正規化され、宣言との差分が
       残って再 apply が収束しない (2026-09-22 実機で判明) *)
    rot = N[Normalize[{0, Sin[yaw/2], 0, Cos[yaw/2]}]];
    name = StringTrim[StringReplace[Lookup[user, "name", ""], {RegularExpression["^User\\s*"] -> "", RegularExpression["<[^>]*>"] -> "", RegularExpression["\\(ID[^)]*\\)"] -> ""}]];
    <|"Position" -> Round[pos, 0.001], "Rotation" -> rot, "User" -> name, "UserId" -> user["id"],
      "HeadPosition" -> Round[rootPos + ibQuatRotate[rootRot, headPos], 0.001], "Forward" -> Round[fwd, 0.001]|>];

(* ============================================================
   プロンプト
   ============================================================ *)

ibSlug[request_String] :=
  Module[{s = StringReplace[ToLowerCase[request], Except[LetterCharacter | DigitCharacter] -> ""]},
    If[StringLength[s] > 12, StringTake[s, 12], s]];

ibOwnershipKey[] :=
  "vb-" <> DateString[{"Year", "Month", "Day", "-", "Hour", "Minute", "Second"}] <> "-" <> StringTake[CreateUUID[], 4];

ibPlacementText[p_Association] :=
  Module[{pos = Lookup[p, "Position", None], rot = Lookup[p, "Rotation", None], user = Lookup[p, "User", None], dist = Lookup[p, "Distance", None]},
    StringJoin[
      If[ListQ[pos], "- root Slot の position: " <> ibVec[pos] <> "\n", ""],
      If[ListQ[rot], "- root Slot の rotation: " <> ibVec[rot] <> " (正規化済み。この値をそのまま書く。局所 -Z 側 = TextRenderer が読める面が利用者を向く)\n", ""],
      If[StringQ[user], "- 利用者「" <> user <> "」の正面" <> If[NumericQ[dist], " " <> ibNum[dist] <> " m", ""] <> "。物の大きさは手に取れる程度 (0.1〜0.4 m) を既定とし、依頼に大きさがあればそれに従う\n", ""],
      If[!ListQ[pos], "- 位置の指定なし: Root 直下、position [0, 1.3, -0.8] に置く\n", ""]]];

Options[ResoLoop`ResoLoopBuildPrompt] = {"Project" -> Automatic, "Ownership" -> Automatic, "Placement" -> <||>, "URL" -> Automatic};
ResoLoop`ResoLoopBuildPrompt[request_String, OptionsPattern[]] :=
  Module[{key, url, placement, roles},
    key = Replace[OptionValue["Ownership"], Automatic :> ibOwnershipKey[]];
    url = Replace[OptionValue["URL"], Automatic :> If[StringQ[ResoLoop`$ResoLoopURL], ResoLoop`$ResoLoopURL, "auto"]];
    placement = Replace[OptionValue["Placement"], Except[_Association] -> <||>];
    roles = StringRiffle[("`" <> # <> "`") & /@ ResoLoop`$ResoLoopDefaultExternalRoles, ", "];
    StringJoin[
      "あなたはこの resoloop プロジェクト (カレントディレクトリ) の中で作業しています。プロジェクトの CLAUDE.md と skill (resonite-build / resonite-flux / resonite-inspect) に従い、次の依頼を Resonite の世界に実装してください。\n\n",
      "## 依頼\n", request, "\n\n",
      "## 接続\n",
      "- すべての resoloop コマンドに `--url ", url, " --json` を付ける (discover は不要)。\n",
      "- resoloop は素のコマンド 1 つで呼ぶ。パイプ・`2>&1`・`||`・PowerShell の補助ロジックで包まない (許可リスト外で拒否される)。\n\n",
      "## 命名と配置\n",
      "- ownership key: `", key, "`。宣言は `content/", key, ".json` (ProtoFlux を使うときは `flux/", key, ".pg` と `flux/", key, ".flux.json`)。\n",
      "- root Slot の key は `root`、名前は `ResoLoop_` + 物の英語名 (例 `ResoLoop_YellowCone`。依頼文をそのまま使わない)。parent は Root、`runtimeRelocatable: true`、Grabbable を付ける。\n",
      ibPlacementText[placement],
      "- このプロジェクトにある他の宣言・state には触らない。\n\n",
      "## 手順 (省略しない)\n",
      "1. 使う Component の型とメンバーは `resoloop type search` / `type describe` で確認する (名前を推測しない)。ProtoFlux のノードは `flux node search` / `flux node describe`。\n",
      "2. 宣言を書く。cameras に `main` (root を正面から写す) と tests (root と主要 Component の exists) を含める。\n",
      "3. `resoloop validate <file> --json` → `--strict --json` → `resoloop diff <file> --changes-only --json`。create 以外の操作 (update/delete) が出たら適用せず、理由を報告して止める。\n",
      "4. `resoloop apply <file> --quiet --json`。続けて同じ apply をもう一度実行し、slotsUpdated と componentsUpdated が 0 であることを確認する (収束)。\n",
      "5. ProtoFlux を使うなら `flux check` → `flux validate-manifest` → `flux deploy-manifest`。Slot の transform を駆動するときは ValueField<T> + ValueCopy<T> で中継する (manifest は Slot のフィールドを直接駆動できない)。\n",
      "6. `resoloop capture <file> --camera main --output artifacts/", key, ".jpg --json` で撮影する。\n",
      "7. `resoloop item audit '$slot:root' --state .resoloop/state/", key, ".json --strict --json` を実行する。ITEM_NOT_PORTABLE なら報告の externalRoleCandidates を見て、次の 4 つ (エンジン既定) に含まれるものだけを `--allow-external-role` で許可して再実行する: ", roles, "。使わないロールを渡すと strict では ITEM_ALLOW_ROLE_UNUSED で落ちる。監査を通すためだけに部品を足さない。\n",
      "8. 最後の出力は次の JSON を 1 行だけにする (前後に他の文を書かない):\n",
      "{\"ownership\":\"", key, "\",\"rootName\":\"ResoLoop_...\",\"summary\":\"<日本語 1 文。何をどこに作ったか>\",\"capture\":\"artifacts/", key, ".jpg\",\"verification\":\"structural\"|\"runtime\",\"notes\":\"<未確認事項や失敗理由。無ければ空>\"}\n\n",
      "## 禁止\n",
      "- `slot delete` / `component remove` / `--prune` / `--adopt`。Root や `ResoLoop_` で始まらない既存物の変更。\n",
      "- resoloop 以外の手段でワールドに触ること。\n",
      "- 完了していないのに完了と書くこと。途中で失敗したら、その時点までの状態と理由を summary と notes に書く。\n"]];

(* ============================================================
   起動
   ============================================================ *)

$ibEnvResets = {"CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
  "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"};

ibBatQuote[s_String] := "\"" <> StringReplace[s, "\"" -> "\\\""] <> "\"";

Options[ResoLoop`ResoLoopBuildSubmit] = {"Project" -> Automatic, "Placement" -> Automatic, "Backend" -> Automatic,
  "PrivacyLevel" -> Automatic, "Model" -> Automatic, "MaxTurns" -> Automatic, "Timeout" -> Automatic, "Origin" -> "Notebook",
  "Ownership" -> Automatic};
ResoLoop`ResoLoopBuildSubmit[request_String, OptionsPattern[]] :=
  Module[{project, dir, exe, pl, backend, placement, key, prompt, id, wd, promptFile, bat, out, err, code, proc, job,
    maxTurns, timeout, model, url, running},
    project = Replace[OptionValue["Project"], Automatic -> ResoLoop`$ResoLoopBuilderProject];
    dir = ResoLoop`ResoLoopProject[project];
    If[FailureQ[dir], Return[dir]];
    (* 機密度: 私有ワールドはローカル backend の担当 (未実装) *)
    pl = Replace[OptionValue["PrivacyLevel"], Automatic :> ResoLoop`ResoLoopPrivacyLevel[]];
    backend = Replace[OptionValue["Backend"], Automatic -> If[NumericQ[pl] && pl > 0.5, "LocalToolLoop", "ClaudeCLI"]];
    If[backend =!= "ClaudeCLI",
      Return[ibFailure["BackendUnavailable",
        "backend " <> ToString[backend] <> " は未実装です (PrivacyLevel " <> ToString[pl] <> ")。私有ワールドでの建築はローカル LLM 経路 (F2b) を待ってください。",
        <|"Backend" -> backend, "PrivacyLevel" -> pl|>]]];
    exe = ibExecutable[];
    If[FailureQ[exe], Return[exe]];
    (* 1 プロジェクト 1 ジョブ *)
    running = Select[ResoLoop`ResoLoopJobs[], #["Project"] === project && MemberQ[{"queued", "running"}, #["Status"]] &];
    If[running =!= {},
      Return[ibFailure["Busy", "このプロジェクトでは別の建築ジョブが実行中です: " <> running[[1]]["JobId"], <|"JobId" -> running[[1]]["JobId"]|>]]];
    (* 接続 (URL をプロンプトに焼き込む) *)
    If[!StringQ[ResoLoop`$ResoLoopURL], With[{c = ResoLoop`ResoLoopConnect[]}, If[FailureQ[c], Return[c]]]];
    url = ResoLoop`$ResoLoopURL;
    (* 配置 *)
    placement = Switch[OptionValue["Placement"],
      Automatic, With[{p = ResoLoop`ResoLoopUserPlacement["Project" -> project]},
        If[FailureQ[p], <|"PlacementFailure" -> p["Code"]|>, Append[p, "Distance" -> 1.0]]],
      _Association, With[{o = OptionValue["Placement"]},
        If[KeyExistsQ[o, "Position"], o,
          With[{p = ResoLoop`ResoLoopUserPlacement["User" -> Lookup[o, "User", Automatic], "Distance" -> Lookup[o, "Distance", 1.0], "Project" -> project]},
            If[FailureQ[p], <|"PlacementFailure" -> p["Code"]|>, Append[p, "Distance" -> Lookup[o, "Distance", 1.0]]]]]],
      _, <||>];
    key = Replace[OptionValue["Ownership"], Automatic :> ibOwnershipKey[]];
    prompt = ResoLoop`ResoLoopBuildPrompt[request, "Project" -> project, "Ownership" -> key, "Placement" -> placement, "URL" -> url];
    maxTurns = Replace[OptionValue["MaxTurns"], Automatic -> ResoLoop`$ResoLoopBuilderMaxTurns];
    timeout = Replace[OptionValue["Timeout"], Automatic -> ResoLoop`$ResoLoopBuilderTimeout];
    model = Replace[OptionValue["Model"], Automatic -> ResoLoop`$ResoLoopBuilderModel];
    id = "rlb-" <> DateString[{"Year", "Month", "Day", "-", "Hour", "Minute", "Second"}] <> "-" <> StringTake[CreateUUID[], 6];
    wd = ibWorkDir[];
    promptFile = FileNameJoin[{wd, id <> ".prompt.txt"}];
    bat = FileNameJoin[{wd, id <> ".bat"}];
    out = FileNameJoin[{wd, id <> ".jsonl"}];
    err = FileNameJoin[{wd, id <> ".err"}];
    code = FileNameJoin[{wd, id <> ".code"}];
    ibWriteUTF8[promptFile, prompt];
    ibWriteUTF8[bat, StringJoin[
      "@echo off\r\n", "chcp 65001 >nul\r\n",
      StringJoin[("set \"" <> # <> "=\"\r\n") & /@ $ibEnvResets],
      "cd /d ", ibBatQuote[dir], "\r\n",
      If[StringEndsQ[exe, ".cmd", IgnoreCase -> True], "call ", ""], ibBatQuote[exe],
      " --print --output-format stream-json --verbose",
      " --max-turns ", ToString[maxTurns],
      " --allowedTools ", ibBatQuote[StringRiffle[ResoLoop`$ResoLoopBuilderAllowedTools, ","]],
      If[StringQ[model] && model =!= "", " --model " <> ibBatQuote[model], ""],
      " < ", ibBatQuote[promptFile], " > ", ibBatQuote[out], " 2> ", ibBatQuote[err], "\r\n",
      "echo %ERRORLEVEL% > ", ibBatQuote[code], "\r\n"]];
    proc = Quiet @ Check[StartProcess[{"cmd", "/c", bat}], $Failed];
    If[Head[proc] =!= ProcessObject,
      Return[ibFailure["SpawnFailed", "Claude Code CLI を起動できませんでした。", <|"Bat" -> bat|>]]];
    $ibProcs[id] = proc;
    job = <|"JobId" -> id, "Status" -> "running", "Phase" -> "starting", "Request" -> request, "Ownership" -> key,
      "Project" -> project, "Directory" -> dir, "Backend" -> backend, "PrivacyLevel" -> pl, "Origin" -> OptionValue["Origin"],
      "Placement" -> KeyDrop[placement, {}], "Started" -> AbsoluteTime[], "Timeout" -> timeout, "MaxTurns" -> maxTurns,
      "Files" -> <|"Prompt" -> promptFile, "Bat" -> bat, "Out" -> out, "Err" -> err, "Code" -> code|>,
      "ToolCalls" -> 0, "LastCommand" -> None, "Summary" -> None, "Report" -> None|>;
    ibSaveJob[job];
    KeyTake[job, {"JobId", "Ownership", "Project", "Status", "Phase", "Placement"}]];

(* ============================================================
   stream-json の解釈
   ============================================================ *)

ibPhaseOf[tool_String, cmd_String] :=
  Module[{c = ToLowerCase[cmd]},
    Which[
      MemberQ[{"Write", "Edit"}, tool], "authoring",
      MemberQ[{"Read", "Glob", "Grep"}, tool], "reading",
      StringContainsQ[c, "flux deploy"], "deploying",
      StringContainsQ[c, "flux check"] || StringContainsQ[c, "flux build"] || StringContainsQ[c, "validate-manifest"], "compiling",
      StringContainsQ[c, " apply "] || StringEndsQ[c, " apply"], "applying",
      StringContainsQ[c, " capture "] || StringContainsQ[c, " test "] || StringContainsQ[c, "item audit"] || StringContainsQ[c, "tool audit"], "verifying",
      StringContainsQ[c, " validate "] || StringContainsQ[c, " diff "] || StringContainsQ[c, " plan "], "validating",
      StringContainsQ[c, " type "] || StringContainsQ[c, "hierarchy"] || StringContainsQ[c, " find "] || StringContainsQ[c, " inspect "] || StringContainsQ[c, "node search"] || StringContainsQ[c, "node describe"], "inspecting",
      True, "working"]];

ibToolUses[event_Association] :=
  Module[{msg = Lookup[event, "message", <||>], content},
    content = If[AssociationQ[msg], Lookup[msg, "content", {}], {}];
    If[!ListQ[content], Return[{}]];
    Map[Function[item,
      With[{input = Lookup[item, "input", <||>]},
        <|"Tool" -> Lookup[item, "name", "?"],
          "Command" -> Which[
            AssociationQ[input] && StringQ[Lookup[input, "command", None]], input["command"],
            AssociationQ[input] && StringQ[Lookup[input, "file_path", None]], input["file_path"],
            True, ""]|>]],
      Select[content, AssociationQ[#] && Lookup[#, "type", ""] === "tool_use" &]]];

(* 最終応答の文字列から報告 JSON (1 行) を取り出す *)
ibExtractReport[text_String] :=
  Module[{cands, parsed},
    cands = Join[
      StringCases[text, "```json" ~~ Shortest[body__] ~~ "```" :> body],
      StringCases[text, "```" ~~ Shortest[body__] ~~ "```" :> body],
      Select[StringTrim /@ StringSplit[text, "\n"], StringStartsQ[#, "{"] &],
      With[{p = StringPosition[text, "{\"ownership\"", 1]}, If[p === {}, {}, {StringDrop[text, First[First[p]] - 1]}]]];
    parsed = Select[ibJSONParse[StringTrim[#]] & /@ cands, AssociationQ[#] && KeyExistsQ[#, "ownership"] &];
    If[parsed === {}, None, First[parsed]]];

(* JSONL を「トップレベルの { ... } の連なり」として切り出す。CLI は 1 行 1 オブジェクトだが、
   整形出力 (複数行) にも耐えるよう、文字列内を無視した波括弧の深さで区切る。 *)
ibJSONObjects[text_String] :=
  Module[{chars = Characters[text], depth = 0, inStr = False, esc = False, start = 0, out = {}, c},
    Do[
      c = chars[[i]];
      Which[
        inStr, Which[esc, esc = False, c === "\\", esc = True, c === "\"", inStr = False],
        c === "\"", inStr = True,
        c === "{", If[depth == 0, start = i]; depth++,
        c === "}", depth--; If[depth == 0 && start > 0, AppendTo[out, StringJoin[chars[[start ;; i]]]]; start = 0]],
      {i, Length[chars]}];
    out];

ResoLoop`ResoLoopBuilderParseStream[text_String] :=
  Module[{events, uses, result, phase, resultText},
    events = Select[ibJSONParse /@ ibJSONObjects[text], AssociationQ];
    uses = Flatten[ibToolUses /@ Select[events, Lookup[#, "type", ""] === "assistant" &]];
    uses = Map[Append[#, "Phase" -> ibPhaseOf[#["Tool"], #["Command"]]] &, uses];
    result = SelectFirst[Reverse[events], Lookup[#, "type", ""] === "result" &, None];
    resultText = If[AssociationQ[result], Lookup[result, "result", ""], ""];
    phase = Which[
      AssociationQ[result], If[Lookup[result, "subtype", ""] === "success", "done", "failed"],
      uses === {}, "starting",
      True, Last[uses]["Phase"]];
    <|"Events" -> uses, "Result" -> result, "Phase" -> phase, "ToolCalls" -> Length[uses],
      "LastCommand" -> If[uses === {}, None, Last[uses]["Command"]],
      "ResultText" -> If[StringQ[resultText], resultText, ""],
      "Report" -> If[StringQ[resultText], ibExtractReport[resultText], None],
      "Denials" -> If[AssociationQ[result], Length[Replace[Lookup[result, "permission_denials", {}], Except[_List] -> {}]], 0],
      "Turns" -> If[AssociationQ[result], Lookup[result, "num_turns", None], None],
      "Cost" -> If[AssociationQ[result], Lookup[result, "total_cost_usd", None], None]|>];

(* ============================================================
   状態
   ============================================================ *)

ibProcessRunningQ[id_String, job_Association] :=
  Module[{proc = Lookup[$ibProcs, id, None], code = job["Files"]["Code"]},
    Which[
      Head[proc] === ProcessObject, Quiet @ Check[ProcessStatus[proc] === "Running", False],
      FileExistsQ[code], False,
      True, True (* 別カーネルが起動したジョブ: exit code ファイルが出るまで走っているとみなす *)]];

ibFinalize[job_Association, parsed_Association, forced_ : None] :=
  Module[{j = job, report = parsed["Report"], status, summary},
    status = Which[
      StringQ[forced], forced,
      AssociationQ[report] && parsed["Phase"] === "done", "done",
      True, "failed"];
    summary = Which[
      AssociationQ[report] && StringQ[Lookup[report, "summary", None]], report["summary"],
      StringQ[parsed["ResultText"]] && parsed["ResultText"] =!= "", StringTake[parsed["ResultText"], UpTo[300]],
      StringQ[forced], forced,
      True, "結果が読めませんでした (" <> ibReadUTF8[job["Files"]["Err"]] <> ")"];
    j = Join[j, <|"Status" -> status, "Phase" -> If[status === "done", "done", "failed"],
      (* 別カーネルで終わったジョブを後から確定するときも、終了時刻は exit code ファイルの更新時刻にする *)
      "Finished" -> With[{cf = job["Files"]["Code"]},
        If[StringQ[cf] && FileExistsQ[cf], Quiet @ Check[AbsoluteTime[FileDate[cf, "Modification"]], AbsoluteTime[]], AbsoluteTime[]]],
      "ToolCalls" -> parsed["ToolCalls"], "LastCommand" -> parsed["LastCommand"],
      "Summary" -> StringTake[summary, UpTo[300]], "Report" -> report, "ResultText" -> StringTake[parsed["ResultText"], UpTo[4000]],
      "Turns" -> parsed["Turns"], "Cost" -> parsed["Cost"], "Denials" -> parsed["Denials"], "Events" -> parsed["Events"],
      "Capture" -> With[{c = If[AssociationQ[report], Lookup[report, "capture", None], None]},
        If[StringQ[c] && FileExistsQ[FileNameJoin[{job["Directory"], c}]], FileNameJoin[{job["Directory"], c}], None]]|>];
    KeyDropFrom[$ibProcs, job["JobId"]];
    ibSaveJob[j];
    j];

ibRefresh[id_String] :=
  Module[{job = ibLoadJob[id], parsed, elapsed},
    If[job === None, Return[ibFailure["JobNotFound", "ジョブ " <> id <> " がありません。"]]];
    If[MemberQ[{"done", "failed", "cancelled"}, job["Status"]], Return[job]];
    parsed = ResoLoop`ResoLoopBuilderParseStream[ibReadUTF8[job["Files"]["Out"]]];
    elapsed = AbsoluteTime[] - job["Started"];
    Which[
      ibProcessRunningQ[id, job] && elapsed > job["Timeout"] + 30,
        Quiet @ KillProcess[Lookup[$ibProcs, id, None]];
        ibFinalize[job, parsed, "時間切れ (" <> ToString[Round[elapsed]] <> " 秒)"],
      ibProcessRunningQ[id, job],
        job = Join[job, <|"Phase" -> parsed["Phase"], "ToolCalls" -> parsed["ToolCalls"], "LastCommand" -> parsed["LastCommand"]|>];
        ibSaveJob[job],
      True, ibFinalize[job, parsed]]];

ResoLoop`ResoLoopJobStatus[id : (_String | Automatic) : Automatic] :=
  Module[{jid = Replace[id, Automatic :> ibLatestJobId[]], job},
    If[!StringQ[jid], Return[ibFailure["JobNotFound", "ジョブがありません。"]]];
    job = ibRefresh[jid];
    If[FailureQ[job], Return[job]];
    <|"JobId" -> job["JobId"], "Status" -> job["Status"], "Phase" -> job["Phase"], "Ownership" -> job["Ownership"],
      "Project" -> job["Project"], "Request" -> job["Request"],
      "Elapsed" -> Round[If[NumericQ[Lookup[job, "Finished", None]], job["Finished"], AbsoluteTime[]] - job["Started"]],
      "ToolCalls" -> job["ToolCalls"], "LastCommand" -> job["LastCommand"], "Summary" -> job["Summary"],
      "RootName" -> If[AssociationQ[job["Report"]], Lookup[job["Report"], "rootName", None], None]|>];

ResoLoop`ResoLoopJobResult[id : (_String | Automatic) : Automatic] :=
  Module[{jid = Replace[id, Automatic :> ibLatestJobId[]], job},
    If[!StringQ[jid], Return[ibFailure["JobNotFound", "ジョブがありません。"]]];
    job = ibRefresh[jid];
    If[FailureQ[job], Return[job]];
    If[MemberQ[{"queued", "running"}, job["Status"]],
      Return[ibFailure["Running", "まだ実行中です (" <> ToString[job["Phase"]] <> ")", <|"JobId" -> jid, "Phase" -> job["Phase"]|>]]];
    KeyTake[job, {"JobId", "Status", "Ownership", "Project", "Request", "Summary", "Report", "RootName", "Capture", "Turns", "Cost",
      "Denials", "Events", "ResultText", "Started", "Finished", "Placement"}]];

Options[ResoLoop`ResoLoopJobWait] = {"Timeout" -> 300, "Poll" -> 5};
ResoLoop`ResoLoopJobWait[id : (_String | Automatic) : Automatic, OptionsPattern[]] :=
  Module[{jid = Replace[id, Automatic :> ibLatestJobId[]], t0 = AbsoluteTime[], st},
    If[!StringQ[jid], Return[ibFailure["JobNotFound", "ジョブがありません。"]]];
    While[True,
      st = ResoLoop`ResoLoopJobStatus[jid];
      If[FailureQ[st], Return[st]];
      If[!MemberQ[{"queued", "running"}, st["Status"]], Break[]];
      If[AbsoluteTime[] - t0 > OptionValue["Timeout"],
        Return[ibFailure["Running", "まだ実行中です (" <> ToString[st["Phase"]] <> ", " <> ToString[st["ToolCalls"]] <> " 回のツール呼び出し)。ジョブは走り続けます。もう一度 ResoLoopJobWait[] を呼んでください。",
          <|"JobId" -> jid, "Phase" -> st["Phase"], "Elapsed" -> st["Elapsed"]|>]]];
      Pause[OptionValue["Poll"]]];
    ResoLoop`ResoLoopJobResult[jid]];

(* ============================================================
   見張り (非ブロック): claudecode の共有 polling tick に相乗りし、完了時に結果をノートブックへ書く。
   ClaudeEval の runtime は 30 秒を超える同期実行に承認 (TimeoutExtension) を求めるので、
   建築のように数分かかるものは submit だけして戻り、結果は後から書く。
   ============================================================ *)

If[!ValueQ[ResoLoop`$ResoLoopBuildWatchWriter], ResoLoop`$ResoLoopBuildWatchWriter = Automatic];
$ibWatches = <||>;

ibWatchKey[id_String] := "resoloop-build-" <> id;

ibDefaultWriter[nb_, md_String, capture_] :=
  Module[{written = False},
    If[Head[nb] === NotebookObject && Length[DownValues[ClaudeCode`ClaudeWriteResponse]] > 0,
      written = TrueQ[Quiet @ Check[ClaudeCode`ClaudeWriteResponse[nb, md]; True, False]];
      If[written && StringQ[capture] && FileExistsQ[capture],
        Quiet @ Check[NotebookWrite[nb, Cell[BoxData[ToBoxes[Import[capture]]], "Output"]], Null]]];
    If[!written, Print[md]; If[StringQ[capture] && FileExistsQ[capture], Print[Import[capture]]]];
    Null];

ibWatchMarkdown[res_Association] :=
  Module[{rep = Lookup[res, "Report", None], status = Lookup[res, "Status", "?"]},
    StringJoin[
      "## Resonite 建築ジョブ ", If[status === "done", "完了", "終了 (" <> ToString[status] <> ")"], "\n\n",
      "- **依頼**: ", ToString[Lookup[res, "Request", ""]], "\n",
      "- **結果**: ", ToString[Lookup[res, "Summary", ""]], "\n",
      If[AssociationQ[rep],
        StringJoin[
          "- **root**: ", ToString[Lookup[rep, "rootName", "?"]], " (ownership `", ToString[Lookup[res, "Ownership", ""]], "`)\n",
          "- **検証**: ", ToString[Lookup[rep, "verification", "?"]],
          With[{n = Lookup[rep, "notes", ""]}, If[StringQ[n] && StringTrim[n] =!= "", "\n- **未確認・注記**: " <> n, ""]], "\n"],
        ""],
      "- ジョブ ", ToString[Lookup[res, "JobId", ""]], ": ", ToString[Lookup[res, "Turns", "?"]], " ターン",
      With[{c = Lookup[res, "Capture", None]}, If[StringQ[c], "、撮影 `" <> c <> "`", ""]], "\n"]];

Options[ResoLoop`ResoLoopBuildWatch] = {"Notebook" -> Automatic, "Timeout" -> 900, "Interval" -> 5, "Register" -> True};
ResoLoop`ResoLoopBuildWatch[id : (_String | Automatic) : Automatic, OptionsPattern[]] :=
  Module[{jid = Replace[id, Automatic :> ibLatestJobId[]], nb, key},
    If[!StringQ[jid], Return[ibFailure["JobNotFound", "ジョブがありません。"]]];
    If[ibLoadJob[jid] === None, Return[ibFailure["JobNotFound", "ジョブ " <> jid <> " がありません。"]]];
    If[TrueQ[OptionValue["Register"]] && Length[DownValues[ClaudeCode`ClaudeRegisterPollingTick]] == 0,
      Return[ibFailure["WatchUnavailable", "claudecode の polling tick が無いので見張れません。ResoLoopJobWait[] で同期に待ってください。"]]];
    nb = Replace[OptionValue["Notebook"], Automatic :> If[TrueQ[$Notebooks], Quiet @ Check[EvaluationNotebook[], None], None]];
    key = ibWatchKey[jid];
    $ibWatches[jid] = <|"Notebook" -> nb, "Started" -> AbsoluteTime[], "LastCheck" -> 0,
      "Timeout" -> OptionValue["Timeout"], "Interval" -> OptionValue["Interval"], "Key" -> key, "Registered" -> TrueQ[OptionValue["Register"]]|>;
    If[TrueQ[OptionValue["Register"]],
      With[{j = jid},
        Quiet @ Check[ClaudeCode`ClaudeRegisterPollingTick[key, Function[ResoLoop`ResoLoopBuildWatchTick[j]],
          "Phase" -> "external", "Caller" -> "ResoLoop"], Null]]];
    <|"JobId" -> jid, "Watching" -> True, "Key" -> key,
      "Message" -> "建築ジョブを見張っています。終わると結果がこのノートブックに書かれます (数十秒〜数分)。"|>];

ibWatchFinish[jid_String, w_Association, md_String, capture_] :=
  Module[{writer = ResoLoop`$ResoLoopBuildWatchWriter},
    Quiet @ Check[If[writer === Automatic, ibDefaultWriter[w["Notebook"], md, capture], writer[w["Notebook"], md, capture]], Null];
    If[TrueQ[w["Registered"]] && Length[DownValues[ClaudeCode`ClaudeUnregisterPollingTick]] > 0,
      Quiet @ Check[ClaudeCode`ClaudeUnregisterPollingTick[w["Key"]], Null]];
    KeyDropFrom[$ibWatches, jid]];

ResoLoop`ResoLoopBuildWatchTick[jid_String] :=
  Module[{w = Lookup[$ibWatches, jid, None], st, res},
    If[!AssociationQ[w],
      If[Length[DownValues[ClaudeCode`ClaudeUnregisterPollingTick]] > 0,
        Quiet @ Check[ClaudeCode`ClaudeUnregisterPollingTick[ibWatchKey[jid]], Null]];
      Return["NotWatched"]];
    If[AbsoluteTime[] - w["LastCheck"] < w["Interval"], Return["Waiting"]];
    $ibWatches[jid] = Append[w, "LastCheck" -> AbsoluteTime[]];
    st = ResoLoop`ResoLoopJobStatus[jid];
    Which[
      FailureQ[st],
        ibWatchFinish[jid, w, "## Resonite 建築ジョブ\n\n状態を読めませんでした: " <> ToString[st["MessageTemplate"]] <> "\n", None]; "Failed",
      MemberQ[{"queued", "running"}, st["Status"]],
        If[AbsoluteTime[] - w["Started"] > w["Timeout"],
          ibWatchFinish[jid, w, "## Resonite 建築ジョブ\n\n" <> ToString[Round[w["Timeout"]]] <> " 秒たっても終わりません (段階 " <> ToString[st["Phase"]] <> ")。ジョブは走り続けます。ResoLoopJobStatus[\"" <> jid <> "\"] で確認してください。\n", None]; "Timeout",
          "Running"],
      True,
        res = ResoLoop`ResoLoopJobResult[jid];
        If[FailureQ[res],
          ibWatchFinish[jid, w, "## Resonite 建築ジョブ\n\n結果を読めませんでした: " <> ToString[res["MessageTemplate"]] <> "\n", None]; "Failed",
          ibWatchFinish[jid, w, ibWatchMarkdown[res], Lookup[res, "Capture", None]];
          If[res["Status"] === "done", "Done", "Failed"]]]];

ResoLoop`ResoLoopJobCancel[id_String] :=
  Module[{job = ibLoadJob[id], proc},
    If[job === None, Return[ibFailure["JobNotFound", "ジョブ " <> id <> " がありません。"]]];
    proc = Lookup[$ibProcs, id, None];
    If[Head[proc] === ProcessObject, Quiet @ KillProcess[proc]];
    ibFinalize[job, ResoLoop`ResoLoopBuilderParseStream[ibReadUTF8[job["Files"]["Out"]]], "cancelled"]["Status"]];

(* 記録上 running のジョブは、別カーネルが起動したものでも exit code ファイルで終了を判定できるので、
   一覧を出すときに更新する (更新しないと ResoLoopJobStatus を呼ぶまで running のまま見える) *)
ResoLoop`ResoLoopJobs[] :=
  Module[{files = FileNames["*.json", ibJobsDir[]], jobs},
    jobs = Select[Quiet @ Check[ImportByteArray[ReadByteArray[#], "RawJSON"], $Failed] & /@ files, AssociationQ];
    jobs = Map[If[MemberQ[{"queued", "running"}, Lookup[#, "Status", ""]] && StringQ[Lookup[#, "JobId", None]],
        With[{r = Quiet @ Check[ibRefresh[#["JobId"]], #]}, If[AssociationQ[r], r, #]], #] &, jobs];
    jobs = Reverse @ SortBy[jobs, Lookup[#, "Started", 0] &];
    KeyTake[#, {"JobId", "Status", "Phase", "Ownership", "Project", "Request", "Summary"}] & /@ jobs];

ResoLoop`ResoLoopJobEvents[id : (_String | Automatic) : Automatic] :=
  Module[{jid = Replace[id, Automatic :> ibLatestJobId[]], job},
    If[!StringQ[jid], Return[{}]];
    job = ibLoadJob[jid];
    If[job === None, Return[{}]];
    ResoLoop`ResoLoopBuilderParseStream[ibReadUTF8[job["Files"]["Out"]]]["Events"]];

End[];
EndPackage[];
