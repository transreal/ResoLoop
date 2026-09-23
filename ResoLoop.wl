(* ::Package:: *)

(* ResoLoop.wl -- resoloop CLI (Resonite を ResoniteLink 経由で操作する CLI) の共通層

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["ResoLoop.wl"]]

   設計: ResoLoop_info/design/resoloop_integration_spec_v0_1.md §3 (G0)。
   この層だけが resoloop の CLI を知る。上位 (ノートブック / MCP / ResoniteRealtime / 音声) は
   すべてここを通り、次をこの層で強制する:

     - 応答契約: 成功 {"ok":true,"data":...} / 失敗 {"ok":false,"error":{code,...}}。
       失敗 JSON は stderr に出るので stdout と stderr を両方読む。
     - 所有境界: 変更系は ResoLoop_* で始まる root の配下、または state ファイルで解決される
       安定セレクタ ($slot:key 等) だけ。Root / User ... / 他人の物は Failure["OutsideOwnership"]。
     - 削除・prune・probe は "Confirm" -> True が無ければ --yes を付けない (= resoloop 側が拒否する)。
       --adopt は "Adopt" -> True (ノートブックで人が明示) のときだけ。
     - 1 プロジェクト 1 mutation (カーネル内 mutex)。

   前提: ResoniteLink は利用者が常時オン (§0.2)。候補 0 は Failure["ResoniteLinkOff"] で知らせるだけで、
   待ち続けたり代替経路に落ちたりしない。

   ---- 導入 (resoloop 本体はこのパッケージに含まれない) ----

   resoloop は orange3134 氏の別プロジェクト (https://github.com/orange3134/resoloop、AGPL-3.0-or-later、
   nuget.org の dotnet グローバルツール "ResoLoop") で、ライセンスが異なるためここには同梱しない。
   利用者が自分で入れる (手順は ResoLoop_info/docs/setup.md):
     1. .NET 10 SDK            winget install Microsoft.DotNet.SDK.10
     2. resoloop               dotnet tool install --global ResoLoop --version 0.1.0-preview.13
                               (preview 版なので --version 必須。実体 %USERPROFILE%\.dotnet\tools\resoloop.exe)
     3. Flux-SDK (ProtoFlux)   dotnet tool install --global Papaltine.FluxSDK --version 1.9.0   (任意)
     4. Resonite 側            Dashboard > Session > Settings > Enable ResoniteLink (ホストであること)
     5. 環境変数 (User)        RESONITE_MANAGED_DATA_PATH = Resonite のインストール先、RESONITE_LOG_PATH = 同 \Logs
                               (RESONITE_LINK_URL は起動毎にポートが変わるので永続化しない。discover で拾う)
   プロジェクト (resoloop init の出力) は $ResoLoopProjectsDirectory に置き、ResoLoopProject[name, "Create" -> True] で作る。
   プロジェクト配下の Skill / AGENTS.md は resoloop が生成するものなので、これもリポジトリには含めない。

   ---- 使い方 ----

     ResoLoopConnect[]                                  (* discover → 候補 1 つなら接続 *)
     ResoLoopStatus[]
     ResoLoopHierarchy["Root", 1]
     ResoLoopFind["Name" -> "ResoLoop_MoodLamp", "Exact" -> True]
     ResoLoopValidate["content/moodlamp.json", "Strict" -> True]
     ResoLoopDiff["content/moodlamp.json"]              (* create 以外が無いか見る *)
     ResoLoopApply["content/moodlamp.json"]
     ResoLoopFluxDeployManifest["flux/moodlamp.flux.json"]
     ResoLoopSlotDelete[id, "Confirm" -> True]

   すべて "Project" -> 名前 (既定 $ResoLoopDefaultProject) を受け、その dir で実行する。
   戻り値は resoloop の data (Association / List)。表示は持たない (core/View 分離)。

   ---- テスト用フック ----

   $ResoLoopRunner に関数を入れると RunProcess の代わりに呼ばれる
   (引数 <|"Executable","Arguments","Directory","Timeout"|>、戻り値 <|"ExitCode","StandardOutput","StandardError"|>)。
   test codes/ResoLoop_test.wls が使う。Private 変数を外から触らない (rule 86)。
*)

Quiet[Remove["Global`ResoLoop*"], {Remove::rmnsm}];
Quiet[Remove["Global`$ResoLoop*"], {Remove::rmnsm}];

BeginPackage["ResoLoop`"];

$ResoLoopVersion::usage = "$ResoLoopVersion はこのパッケージの版。";
$ResoLoopExecutable::usage =
  "$ResoLoopExecutable は resoloop 実行ファイルのパス。Automatic なら %USERPROFILE%\\.dotnet\\tools\\resoloop.exe と PATH を探す。";
$ResoLoopProjectsDirectory::usage =
  "$ResoLoopProjectsDirectory は resoloop プロジェクトの置き場 (既定 <MyPackages>/ResoLoop_projects)。";
$ResoLoopDefaultProject::usage = "$ResoLoopDefaultProject は \"Project\" 省略時のプロジェクト名 (既定 \"MyResoniteProject\")。";
$ResoLoopURL::usage = "$ResoLoopURL は接続中の ResoniteLink URL (ws://localhost:<port>/)。未接続なら None。ResoLoopConnect が設定する。";
$ResoLoopSession::usage = "$ResoLoopSession は接続中のセッション名。";
$ResoLoopRunner::usage =
  "$ResoLoopRunner はテスト用フック。関数を入れると RunProcess の代わりに <|\"Executable\",\"Arguments\",\"Directory\",\"Timeout\"|> で呼ばれ、\n" <>
  "<|\"ExitCode\",\"StandardOutput\",\"StandardError\"|> を返すことが期待される。Automatic で実プロセス。";
$ResoLoopLastResult::usage = "$ResoLoopLastResult は直近の ResoLoopRun の生の応答 (ok / data / error を含む Association)。";
$ResoLoopDefaultTimeout::usage = "$ResoLoopDefaultTimeout は 1 コマンドの既定タイムアウト秒 (60)。apply / deploy / capture は $ResoLoopLongTimeout (600)。";
$ResoLoopLongTimeout::usage = "$ResoLoopLongTimeout は長いコマンド (apply / flux deploy-manifest / capture / test) のタイムアウト秒 (600)。";
$ResoLoopOwnershipPrefixes::usage = "$ResoLoopOwnershipPrefixes は変更を許す root 名の接頭辞のリスト (既定 {\"ResoLoop_\"})。";
$ResoLoopDefaultExternalRoles::usage =
  "$ResoLoopDefaultExternalRoles は item audit で既定で許可する外部参照ロール (エンジン既定のシェーダー / フォント / テキスト材質と、掴んだ後に付く Grabbable:_lastParent)。";
$ResoLoopDefaultPrivacyLevel::usage = "$ResoLoopDefaultPrivacyLevel は ResoniteRealtime`ResoniteAccessLevel が無いときの観測結果の機密度 (0.25 = 公開ワールド相当)。";
$ResoLoopPackageDirectory::usage = "$ResoLoopPackageDirectory は ResoLoop.wl のあるディレクトリ (補助モジュールの探索に使う)。";
ResoLoopRegisterHeads::usage =
  "ResoLoopRegisterHeads[] は NBAccess の許可ヘッド (読み取り系・建築ジョブ) と承認ヘッド (apply / delete / deploy など) を登録する。\n" <>
  "ロード時に NBAccess があれば自動で呼ばれる。NBAccess を後からロードしたときは手で呼ぶ。";

ResoLoopRun::usage =
  "ResoLoopRun[{\"find\", \"--name\", \"Box\"}] は resoloop を --json 付きで実行し、成功なら data を、失敗なら Failure[\"ResoLoop\", <|\"Code\", \"Message\", \"Context\", \"Suggestions\"|>] を返す。\n" <>
  "オプション: \"Project\" -> Automatic, \"URL\" -> Automatic (接続中なら --url を付ける), \"Timeout\" -> Automatic, \"Raw\" -> False (ok/data/error をそのまま返す),\n" <>
  "  \"Confirm\" -> False (--yes を含む操作に必須), \"Adopt\" -> False (--adopt に必須), \"Owner\" -> None (生の component ID を変更するとき、その属する Slot)。\n" <>
  "変更系 (slot / component / apply / flux deploy) には所有境界と 1 プロジェクト 1 mutation の制約がかかる。";
ResoLoopRunAsync::usage =
  "ResoLoopRunAsync[args] は同じコマンドを別プロセスで非ブロック実行し、ジョブ (Association) を返す。ResoLoopAsyncStatus / ResoLoopAsyncResult / ResoLoopAsyncWait で回収する。";
ResoLoopAsyncStatus::usage = "ResoLoopAsyncStatus[job] は \"Running\" | \"Finished\" | \"Killed\" を返す。";
ResoLoopAsyncResult::usage = "ResoLoopAsyncResult[job] は終了したジョブの結果 (ResoLoopRun と同じ形)。走っていれば Failure[\"Running\"]。";
ResoLoopAsyncWait::usage = "ResoLoopAsyncWait[job, timeout] は終了まで待って結果を返す (ノートブック用。サービスからは Status を poll する)。";
ResoLoopAsyncKill::usage = "ResoLoopAsyncKill[job] はジョブのプロセスを止める。";

ResoLoopExecutable::usage = "ResoLoopExecutable[] は解決した resoloop 実行ファイルのパス。見つからなければ Failure[\"NotInstalled\"]。";
ResoLoopVersion::usage = "ResoLoopVersion[] は resoloop の版文字列 (例 \"0.1.0-preview.13\")。";
ResoLoopDoctor::usage = "ResoLoopDoctor[] は resoloop doctor の各項目 (接続 / Flux-SDK / managed data / log) を返す。";
ResoLoopDiscover::usage = "ResoLoopDiscover[] は ResoniteLink の UDP 通知を集めてセッション候補 {<|\"sessionId\",\"sessionName\",\"url\"|>...} を返す。\"DiscoverySeconds\" -> 12。";
ResoLoopConnect::usage =
  "ResoLoopConnect[] は discover の候補が 1 つならその URL に接続し (status で確認)、$ResoLoopURL を設定する。\n" <>
  "複数なら Failure[\"AmbiguousSession\"] (候補は \"Sessions\")、\"Session\" -> 名前 で選ぶ。候補 0 は 20 秒で 1 回だけ再探索し、それでも無ければ Failure[\"ResoniteLinkOff\"] (前提違反。Dashboard で有効にする)。\n" <>
  "\"URL\" -> \"ws://localhost:<port>/\" で探索せず直接接続する。";
ResoLoopDisconnect::usage = "ResoLoopDisconnect[] は接続キャッシュを捨てる (次の呼び出しで再探索する)。";
ResoLoopSessionInfo::usage = "ResoLoopSessionInfo[] は <|\"URL\",\"Session\",\"SessionId\",\"ConnectedAt\"|>。";
ResoLoopStatus::usage = "ResoLoopStatus[] は接続状態 (resoniteVersion / resoniteLinkVersion / latencyMs)。";
ResoLoopPrivacyLevel::usage = "ResoLoopPrivacyLevel[] は観測結果に付ける機密度。ResoniteRealtime`ResoniteAccessLevel[] があればそれ、無ければ $ResoLoopDefaultPrivacyLevel。";
ResoLoopLog::usage = "ResoLoopLog[n] は直近 n 件の呼び出し記録 (Time / Arguments / Elapsed / OK / Code)。";
ResoLoopLocks::usage = "ResoLoopLocks[] は mutation 中のプロジェクト名のリスト。";

ResoLoopProjects::usage = "ResoLoopProjects[] は $ResoLoopProjectsDirectory にあるプロジェクト名 (.resoloop.json を持つ dir) のリスト。";
ResoLoopProject::usage =
  "ResoLoopProject[name] はプロジェクト dir を返す。無ければ Failure[\"ProjectNotFound\"]。\"Create\" -> True なら resoloop init で作り、ResoLoopProjectSync を行う。";
ResoLoopProjectSync::usage =
  "ResoLoopProjectSync[name] は .agents/skills を .claude/skills へ複製し、CLAUDE.md が無ければ作る。\n" <>
  "\"BuilderPolicy\" -> True なら .claude/settings.json に builder 用の allow/deny (削除 / --prune / --adopt の拒否) を書く (無いときだけ)。";

ResoLoopHierarchy::usage = "ResoLoopHierarchy[under, depth] は階層 (既定 \"Root\", 1)。\"IncludeComponents\" -> False, \"Summary\" -> False, \"State\" -> None。";
ResoLoopFind::usage = "ResoLoopFind[\"Name\" -> text | \"Component\" -> type, \"Exact\" -> False, \"Under\" -> None, \"DirectChildren\" -> False, \"Depth\" -> 8]。";
ResoLoopInspect::usage = "ResoLoopInspect[slotOrSelector] は Slot を調べる。\"State\", \"Depth\", \"Members\" -> False, \"Component\", \"Member\", \"ComponentsOnly\"。$slot:key には \"State\" が要る。";
ResoLoopComponentInspect::usage = "ResoLoopComponentInspect[idOrSelector] は Component のメンバー値を返す。\"State\" -> ownership key またはファイル。";
ResoLoopTypeSearch::usage = "ResoLoopTypeSearch[query] は実行中の Resonite の型名を検索する。\"Limit\" -> 50。";
ResoLoopTypeDescribe::usage = "ResoLoopTypeDescribe[type] はメンバー一覧、\"Member\" -> name で enum 値などの定義。";
ResoLoopTypeSpecialize::usage = "ResoLoopTypeSpecialize[\"[FrooxEngine]FrooxEngine.ValueField<>\", {\"floatQ\"}] は閉じたジェネリック型名を返す。";

ResoLoopValidate::usage = "ResoLoopValidate[file] は宣言のオフライン検証。\"Strict\" -> True で実行時 Reflection と突合 (接続が要る)。";
ResoLoopDiff::usage = "ResoLoopDiff[file] は変更前の差分 (world は変えない)。\"Mode\" -> \"Changes\" (既定) | \"Creates\" | \"Deletes\" | \"Summary\" | All。\"State\"。";
ResoLoopApply::usage =
  "ResoLoopApply[file] は宣言を適用する。\"State\", \"Prune\" -> False (要 \"Confirm\" -> True), \"Adopt\" -> False, \"Profile\" -> False, \"Timeout\" -> $ResoLoopLongTimeout。\n" <>
  "同じ apply をもう一度呼んで slotsUpdated / componentsUpdated が 0 なら収束している。";
ResoLoopTest::usage = "ResoLoopTest[file] は宣言の tests を実行する。\"Probe\" -> True (要 \"Confirm\" -> True) で method / set-member probe も呼ぶ。";
ResoLoopCapture::usage = "ResoLoopCapture[file, camera, output] はゲーム内カメラで撮影する (.jpg/.png は実描画、.svg はオフライン投影)。\"Import\" -> True で画像を返す。";
ResoLoopSceneSummary::usage = "ResoLoopSceneSummary[file, output] は宣言のシーン要約 JSON を書く。";
ResoLoopItemAudit::usage =
  "ResoLoopItemAudit[root] は保存・配布できるかの参照監査。\"Strict\" -> True, \"AllowExternalRoles\" -> Automatic ($ResoLoopDefaultExternalRoles), \"State\", \"Report\" -> False (True なら不合格でも report を返す)。";

ResoLoopFluxStatus::usage = "ResoLoopFluxStatus[] は Flux-SDK の可用性と版。";
ResoLoopFluxCheck::usage = "ResoLoopFluxCheck[pgFile] は ProtoGraph の意味検査。失敗なら Failure の Context に diagnostics (行・列付き)。\"FluxProject\" -> Automatic (<project>/flux)。";
ResoLoopFluxBuild::usage = "ResoLoopFluxBuild[pgFile] は .brson まで作る。";
ResoLoopFluxNodeSearch::usage = "ResoLoopFluxNodeSearch[query] は ProtoFlux ノードのカタログ検索。\"Limit\" -> 50。";
ResoLoopFluxNodeDescribe::usage = "ResoLoopFluxNodeDescribe[name] はノードの入出力・globals。";
ResoLoopFluxValidateManifest::usage = "ResoLoopFluxValidateManifest[manifest] は接続なしで manifest / source / binding を検証する。";
ResoLoopFluxDeployManifest::usage = "ResoLoopFluxDeployManifest[manifest] はモジュールをビルドして親 Slot 配下へホットデプロイする (mutation)。";

ResoLoopSlotCreate::usage = "ResoLoopSlotCreate[\"Name\" -> \"ResoLoop_X\", \"Parent\" -> \"Root\", \"Position\" -> {x,y,z}, \"Rotation\" -> {x,y,z,w}, \"Scale\" -> {x,y,z}]。Parent が所有外なら Name は接頭辞 ResoLoop_ が要る。";
ResoLoopSlotSet::usage = "ResoLoopSlotSet[id, \"Name\" | \"Position\" | \"Rotation\" | \"Scale\" -> value]。所有境界内だけ。";
ResoLoopSlotDelete::usage = "ResoLoopSlotDelete[id, \"Confirm\" -> True]。Confirm 無しは Failure[\"ConfirmRequired\"]。Root と所有外は拒否。";
ResoLoopComponentAdd::usage = "ResoLoopComponentAdd[slotId, type, <|member -> value ...|>]。所有境界内だけ。";
ResoLoopComponentSet::usage = "ResoLoopComponentSet[idOrSelector, member, value]。生の ID には \"Owner\" -> slotId (所有確認に使う) が要る。$component:key は \"State\" で解決。";
ResoLoopComponentRemove::usage = "ResoLoopComponentRemove[idOrSelector, \"Confirm\" -> True]。生の ID には \"Owner\" が要る。";
ResoLoopOwnedQ::usage = "ResoLoopOwnedQ[slotId] は Slot が所有境界内 (root 名が $ResoLoopOwnershipPrefixes のどれかで始まる) か。安定セレクタは True、Root は False。";

Begin["`Private`"];

$iPackageDirectory = DirectoryName[$InputFileName];

ResoLoop`$ResoLoopVersion = "0.1.0";
If[!ValueQ[ResoLoop`$ResoLoopExecutable], ResoLoop`$ResoLoopExecutable = Automatic];
If[!StringQ[ResoLoop`$ResoLoopProjectsDirectory],
  ResoLoop`$ResoLoopProjectsDirectory = FileNameJoin[{$iPackageDirectory, "ResoLoop_projects"}]];
If[!StringQ[ResoLoop`$ResoLoopDefaultProject], ResoLoop`$ResoLoopDefaultProject = "MyResoniteProject"];
If[!ValueQ[ResoLoop`$ResoLoopURL], ResoLoop`$ResoLoopURL = None];
If[!ValueQ[ResoLoop`$ResoLoopSession], ResoLoop`$ResoLoopSession = None];
If[!ValueQ[ResoLoop`$ResoLoopRunner], ResoLoop`$ResoLoopRunner = Automatic];
If[!ValueQ[ResoLoop`$ResoLoopLastResult], ResoLoop`$ResoLoopLastResult = None];
If[!NumericQ[ResoLoop`$ResoLoopDefaultTimeout], ResoLoop`$ResoLoopDefaultTimeout = 60];
If[!NumericQ[ResoLoop`$ResoLoopLongTimeout], ResoLoop`$ResoLoopLongTimeout = 600];
If[!ListQ[ResoLoop`$ResoLoopOwnershipPrefixes], ResoLoop`$ResoLoopOwnershipPrefixes = {"ResoLoop_"}];
If[!ListQ[ResoLoop`$ResoLoopDefaultExternalRoles],
  ResoLoop`$ResoLoopDefaultExternalRoles = {
    "[FrooxEngine]FrooxEngine.PBS_Metallic:_shader",
    "[FrooxEngine]FrooxEngine.TextRenderer:Font",
    "[FrooxEngine]FrooxEngine.TextRenderer:Materials[0]",
    "[FrooxEngine]FrooxEngine.Grabbable:_lastParent"}];
If[!NumericQ[ResoLoop`$ResoLoopDefaultPrivacyLevel], ResoLoop`$ResoLoopDefaultPrivacyLevel = 0.25];

(* セッション情報・ログ・mutex はカーネル内。$ResoLoopURL (公開) は再ロードで残るので、
   対になる private 側も残す (残さないと SessionInfo の SessionId が None になる)。 *)
If[!ValueQ[$iSessionId], $iSessionId = None];
If[!ValueQ[$iConnectedAt], $iConnectedAt = None];
If[!ListQ[$iLog], $iLog = {}];
If[!AssociationQ[$iLocks], $iLocks = <||>];
If[!AssociationQ[$iJobs], $iJobs = <||>];

(* ============================================================
   小道具
   ============================================================ *)

iFailure[code_String, msg_String, extra_Association : <||>] :=
  Failure["ResoLoop", Join[<|"Code" -> code, "MessageTemplate" -> msg, "MessageParameters" -> {}|>, extra]];

iStr[x_String] := x;
iStr[x_?NumericQ] := iNumberString[x];
iStr[True] := "true";
iStr[False] := "false";
iStr[x_] := ToString[x];

(* 1.5 → "1.5", 2 → "2", 0.10000000000000001 → "0.1" *)
iNumberString[x_Integer] := ToString[x];
iNumberString[x_?NumericQ] :=
  Module[{s = StringTrim[ToString[NumberForm[N[x], {16, 15}, ExponentFunction -> (Null &)]]]},
    s = StringReplace[s, RegularExpression["(\\.\\d*?)0+$"] -> "$1"];
    StringReplace[s, RegularExpression["\\.$"] -> ""]];

(* {x,y,z} → "[x,y,z]" (resoloop は JSON 配列を正準入力とする) *)
iVector[v_List] := "[" <> StringRiffle[iNumberString /@ v, ","] <> "]";
iVector[s_String] := s;

iWorkingDirectory[] :=
  Module[{dir},
    dir = If[ValueQ[ClaudeCode`$ClaudeWorkingDirectory] && StringQ[ClaudeCode`$ClaudeWorkingDirectory],
      ClaudeCode`$ClaudeWorkingDirectory,
      FileNameJoin[{$HomeDirectory, "Claude Working"}]];
    If[!DirectoryQ[dir], Quiet @ CreateDirectory[dir]];
    dir];

iAppendLog[entry_Association] :=
  ($iLog = With[{l = Append[$iLog, entry]}, If[Length[l] > 200, Drop[l, Length[l] - 200], l]]);

ResoLoop`ResoLoopLog[n_Integer : 20] := Take[Reverse[$iLog], UpTo[n]];
ResoLoop`ResoLoopLocks[] := Keys[Select[$iLocks, TrueQ]];

(* ============================================================
   実行ファイルとプロジェクト
   ============================================================ *)

iExecutableCandidates[] := {
  FileNameJoin[{$HomeDirectory, ".dotnet", "tools", "resoloop.exe"}],
  FileNameJoin[{$HomeDirectory, ".dotnet", "tools", "resoloop"}]};

ResoLoop`ResoLoopExecutable[] :=
  Module[{exe = ResoLoop`$ResoLoopExecutable, found},
    If[StringQ[exe] && FileExistsQ[exe], Return[exe]];
    found = SelectFirst[iExecutableCandidates[], FileExistsQ, None];
    If[StringQ[found], Return[found]];
    (* PATH 上の resoloop: RunProcess が解決するので名前だけ返す *)
    If[StringQ[Environment["PATH"]] &&
       AnyTrue[StringSplit[Environment["PATH"], ";"],
         FileExistsQ[FileNameJoin[{#, "resoloop.exe"}]] &],
      Return["resoloop"]];
    iFailure["NotInstalled",
      "resoloop が見つかりません。dotnet tool install --global ResoLoop --version 0.1.0-preview.13 で入れてください。"]];

ResoLoop`ResoLoopProjects[] :=
  If[!DirectoryQ[ResoLoop`$ResoLoopProjectsDirectory], {},
    FileNameTake /@ Select[
      FileNames["*", ResoLoop`$ResoLoopProjectsDirectory],
      DirectoryQ[#] && FileExistsQ[FileNameJoin[{#, ".resoloop.json"}]] &]];

Options[ResoLoop`ResoLoopProject] = {"Create" -> False};
ResoLoop`ResoLoopProject[Automatic, opts : OptionsPattern[]] :=
  ResoLoop`ResoLoopProject[ResoLoop`$ResoLoopDefaultProject, opts];
ResoLoop`ResoLoopProject[name_String, OptionsPattern[]] :=
  Module[{dir, exe, r},
    dir = If[DirectoryQ[name] && FileExistsQ[FileNameJoin[{name, ".resoloop.json"}]],
      ExpandFileName[name],
      FileNameJoin[{ResoLoop`$ResoLoopProjectsDirectory, name}]];
    If[FileExistsQ[FileNameJoin[{dir, ".resoloop.json"}]], Return[dir]];
    If[!TrueQ[OptionValue["Create"]],
      Return[iFailure["ProjectNotFound",
        "プロジェクト " <> name <> " がありません (" <> dir <> ")。\"Create\" -> True で作れます。",
        <|"Directory" -> dir|>]]];
    exe = ResoLoop`ResoLoopExecutable[];
    If[FailureQ[exe], Return[exe]];
    If[!DirectoryQ[ResoLoop`$ResoLoopProjectsDirectory], CreateDirectory[ResoLoop`$ResoLoopProjectsDirectory]];
    r = iRunCore[{"init", dir}, ResoLoop`$ResoLoopProjectsDirectory, ResoLoop`$ResoLoopDefaultTimeout, "Raw" -> False];
    If[FailureQ[r], Return[r]];
    ResoLoop`ResoLoopProjectSync[dir];
    dir];

$iClaudeMdTemplate = StringJoin[
  "# ResoLoop project (Claude Code)\n\n@AGENTS.md\n\n## Claude Code notes\n\n",
  "- `resoloop init` installs the project skills under `.agents/skills/` (Codex layout). `.claude/skills/` is a plain copy of them so Claude Code can discover the same skills. Wherever `AGENTS.md` or a skill says `.agents/skills/`, the Claude Code equivalent is `.claude/skills/`.\n",
  "- `resoloop skills sync --update` only updates `.agents/skills/`. After running it, re-copy the skill folders into `.claude/skills/` (`ResoLoopProjectSync[]` does this).\n",
  "- Call `resoloop` as one plain command per tool call (`resoloop status --url auto --json`). Do not wrap it in pipes, `2>&1`, `||` fallbacks or PowerShell helpers: only the plain form is on the allow list, everything else is refused and wastes a turn. When a command fails, its JSON error report is on stderr.\n",
  "- `RESONITE_MANAGED_DATA_PATH` and `RESONITE_LOG_PATH` are user environment variables on this machine. Do not persist `RESONITE_LINK_URL`; use `--url auto`.\n",
  "- Never delete or mutate `Root`, an unverified ID, or existing content outside roots named `ResoLoop_*`. Deletion, `--prune` and `--adopt` are decided by the person, not by you.\n"];

$iBuilderSettings = <|
  "permissions" -> <|
    "allow" -> {"Bash(resoloop *)", "PowerShell(resoloop *)", "Read", "Write", "Edit", "Glob", "Grep", "Skill"},
    "deny" -> {"Bash(resoloop slot delete*)", "Bash(resoloop component remove*)",
      "Bash(* --prune*)", "Bash(* --adopt*)",
      "PowerShell(resoloop slot delete*)", "PowerShell(resoloop component remove*)",
      "PowerShell(* --prune*)", "PowerShell(* --adopt*)"}|>|>;

iWriteUTF8[file_String, text_String] :=
  Module[{strm},
    strm = OpenWrite[file, BinaryFormat -> True];
    BinaryWrite[strm, StringToByteArray[text, "UTF-8"]];
    Close[strm];
    file];

(* Dropbox 配下のプロジェクトでは、resoloop の state / lock / 撮影画像 / build 生成物を同期対象から外す。
   同期中の掴みで apply が APPLY_STATE_WRITE_FAILED になる (2026-09-22 実機、緑の球のジョブ)。
   Dropbox の「無視」は NTFS 代替ストリーム com.dropbox.ignored=1 (フォルダ単位、ローカルのみに残る)。 *)
$iDropboxIgnoreDirs = {".resoloop", "artifacts", FileNameJoin[{"flux", "build"}], FileNameJoin[{"flux", ".protograph"}]};

iDropboxIgnore[dir_String] :=
  If[$OperatingSystem =!= "Windows" || !DirectoryQ[dir], False,
    TrueQ[Quiet @ Check[
      RunProcess[{"powershell", "-NoProfile", "-Command",
        "Set-Content -LiteralPath '" <> StringReplace[dir, "'" -> "''"] <> "' -Stream com.dropbox.ignored -Value 1"}]["ExitCode"] === 0,
      False]]];

iDropboxIgnoredQ[dir_String] :=
  If[$OperatingSystem =!= "Windows" || !DirectoryQ[dir], False,
    TrueQ[Quiet @ Check[
      StringContainsQ[RunProcess[{"powershell", "-NoProfile", "-Command",
        "(Get-Content -LiteralPath '" <> StringReplace[dir, "'" -> "''"] <> "' -Stream com.dropbox.ignored -ErrorAction SilentlyContinue)"}]["StandardOutput"], "1"],
      False]]];

Options[ResoLoop`ResoLoopProjectSync] = {"BuilderPolicy" -> False, "DropboxIgnore" -> Automatic};
ResoLoop`ResoLoopProjectSync[name : (_String | Automatic) : Automatic, OptionsPattern[]] :=
  Module[{dir, src, dst, copied = {}, claudeMd, settings, settingsFile, ignored = {}},
    dir = ResoLoop`ResoLoopProject[name];
    If[FailureQ[dir], Return[dir]];
    (* Dropbox 配下 (パスに Dropbox を含む) なら既定で無視属性を付ける *)
    If[Replace[OptionValue["DropboxIgnore"], Automatic :> StringContainsQ[dir, "Dropbox", IgnoreCase -> True]],
      Do[
        With[{d = FileNameJoin[{dir, sub}]},
          If[!DirectoryQ[d], Quiet @ CreateDirectory[d, CreateIntermediateDirectories -> True]];
          If[iDropboxIgnoredQ[d] || iDropboxIgnore[d], AppendTo[ignored, sub]]],
        {sub, $iDropboxIgnoreDirs}]];
    src = FileNameJoin[{dir, ".agents", "skills"}];
    dst = FileNameJoin[{dir, ".claude", "skills"}];
    If[DirectoryQ[src],
      If[!DirectoryQ[dst], CreateDirectory[dst, CreateIntermediateDirectories -> True]];
      Do[
        With[{target = FileNameJoin[{dst, FileNameTake[d]}]},
          If[DirectoryQ[target], DeleteDirectory[target, DeleteContents -> True]];
          CopyDirectory[d, target];
          AppendTo[copied, FileNameTake[d]]],
        {d, Select[FileNames["*", src], DirectoryQ]}]];
    claudeMd = FileNameJoin[{dir, "CLAUDE.md"}];
    If[!FileExistsQ[claudeMd], iWriteUTF8[claudeMd, $iClaudeMdTemplate]];
    settingsFile = FileNameJoin[{dir, ".claude", "settings.json"}];
    settings = If[TrueQ[OptionValue["BuilderPolicy"]] && !FileExistsQ[settingsFile],
      If[!DirectoryQ[DirectoryName[settingsFile]], CreateDirectory[DirectoryName[settingsFile]]];
      Module[{strm = OpenWrite[settingsFile, BinaryFormat -> True]},
        BinaryWrite[strm, ExportByteArray[$iBuilderSettings, "RawJSON"]];
        Close[strm]];
      "written",
      If[FileExistsQ[settingsFile], "kept", "none"]];
    <|"Directory" -> dir, "SkillsCopied" -> copied, "ClaudeMd" -> FileExistsQ[claudeMd], "Settings" -> settings,
      "DropboxIgnored" -> ignored|>];

(* ============================================================
   コマンド実行と応答の解釈
   ============================================================ *)

(* stdout / stderr のどちらかにある {"ok":...} を応答として取り出す。
   候補は (a) 全文、(b) 最初の "{" から末尾まで (apply の進捗行など、JSON の前に非 JSON があるとき)、
   (c) "{" で始まる各行 (1 行 JSON)。resoloop は 1 行 JSON を出すが、整形出力にも耐える。
   stdout を stderr より優先する。 *)
iJSONCandidates[s_String] :=
  Module[{t = StringTrim[s], p},
    p = StringPosition[t, "{", 1];
    DeleteDuplicates @ DeleteCases[Join[{t},
      If[p === {}, {}, {StringDrop[t, First[First[p]] - 1]}],
      Select[StringTrim /@ StringSplit[t, "\n"], StringStartsQ[#, "{"] &]], ""]];
iJSONCandidates[_] := {};

(* JSON の解釈はバイト経由 (rule 30): ImportString[s, "RawJSON"] は非 ASCII 文字を含む文字列で失敗する。
   resoloop は非 ASCII を \uXXXX に逃がすが、将来の変更や他経路 (bat 経由の出力) にも耐える。 *)
iJSONParse[s_String] :=
  Quiet @ Check[ImportByteArray[StringToByteArray[s, "UTF-8"], "RawJSON"], $Failed];

iParseResponse[out_, err_] :=
  Module[{cands, parsed},
    cands = Join[iJSONCandidates[out], iJSONCandidates[err]];
    parsed = Select[iJSONParse /@ cands, AssociationQ];
    SelectFirst[parsed, KeyExistsQ[#, "ok"] &, None]];

iRawRunner[exe_String, args_List, dir_String, timeout_] :=
  Module[{r},
    r = TimeConstrained[
      Quiet @ Check[RunProcess[Prepend[args, exe], ProcessDirectory -> dir], $Failed],
      timeout + 10, $TimedOut];
    Which[
      r === $TimedOut, <|"ExitCode" -> -1, "StandardOutput" -> "", "StandardError" -> "", "TimedOut" -> True|>,
      !AssociationQ[r], <|"ExitCode" -> -1, "StandardOutput" -> "", "StandardError" -> "RunProcess failed", "Spawn" -> False|>,
      True, r]];

(* 生の実行 (ガード無し・接続補完無し)。内部専用。 *)
Options[iRunCore] = {"Raw" -> False};
iRunCore[args_List, dir_String, timeout_, OptionsPattern[]] :=
  Module[{exe, argv, t0, r, resp, entry},
    exe = If[StringQ[ResoLoop`$ResoLoopExecutable] && FileExistsQ[ResoLoop`$ResoLoopExecutable],
      ResoLoop`$ResoLoopExecutable, ResoLoop`ResoLoopExecutable[]];
    If[FailureQ[exe], Return[exe]];
    argv = iStr /@ args;
    If[!MemberQ[argv, "--json"], AppendTo[argv, "--json"]];
    If[!MemberQ[argv, "--command-timeout"] && First[argv, ""] =!= "--version",
      argv = Join[argv, {"--command-timeout", iNumberString[timeout]}]];
    t0 = AbsoluteTime[];
    r = If[ResoLoop`$ResoLoopRunner === Automatic,
      iRawRunner[exe, argv, dir, timeout],
      ResoLoop`$ResoLoopRunner[<|"Executable" -> exe, "Arguments" -> argv, "Directory" -> dir, "Timeout" -> timeout|>]];
    If[!AssociationQ[r], r = <|"ExitCode" -> -1, "StandardOutput" -> "", "StandardError" -> ToString[r]|>];
    resp = iParseResponse[Lookup[r, "StandardOutput", ""], Lookup[r, "StandardError", ""]];
    entry = <|"Time" -> DateObject[], "Arguments" -> argv, "Directory" -> dir,
      "Elapsed" -> Round[AbsoluteTime[] - t0, 0.01], "ExitCode" -> Lookup[r, "ExitCode", -1]|>;
    Which[
      TrueQ[Lookup[r, "TimedOut", False]],
        iAppendLog[Join[entry, <|"OK" -> False, "Code" -> "COMMAND_TIMEOUT"|>]];
        iFailure["COMMAND_TIMEOUT", "resoloop が " <> iNumberString[timeout] <> " 秒で終わりませんでした: " <> StringRiffle[argv, " "],
          <|"Arguments" -> argv|>],
      !AssociationQ[resp],
        iAppendLog[Join[entry, <|"OK" -> False, "Code" -> "NO_JSON"|>]];
        iFailure["NO_JSON", "resoloop の応答に JSON がありません (exit " <> ToString[Lookup[r, "ExitCode", -1]] <> "): " <> StringRiffle[argv, " "],
          <|"Arguments" -> argv, "ExitCode" -> Lookup[r, "ExitCode", -1],
            "StandardOutput" -> StringTake[Lookup[r, "StandardOutput", ""], UpTo[2000]],
            "StandardError" -> StringTake[Lookup[r, "StandardError", ""], UpTo[2000]]|>],
      True,
        ResoLoop`$ResoLoopLastResult = Join[resp, <|"Arguments" -> argv, "Elapsed" -> entry["Elapsed"]|>];
        If[TrueQ[resp["ok"]],
          iAppendLog[Join[entry, <|"OK" -> True, "Code" -> None|>]];
          If[TrueQ[OptionValue["Raw"]], resp, Lookup[resp, "data", <||>]],
          With[{e = Lookup[resp, "error", <||>]},
            iAppendLog[Join[entry, <|"OK" -> False, "Code" -> Lookup[e, "code", "UNKNOWN"]|>]];
            iFailure[Lookup[e, "code", "UNKNOWN"], Lookup[e, "message", "resoloop error"],
              <|"Context" -> Lookup[e, "context", <||>], "Suggestions" -> Lookup[e, "suggestions", {}],
                "Arguments" -> argv|>]]]]];

(* ---- 接続が要るコマンドか / 変更系か ---- *)

$iConnectedHeads = {"status", "ping", "hierarchy", "find", "inspect", "slot", "component", "type",
  "plan", "diff", "apply", "test", "uix", "item", "tool", "scene"};

iNeedsConnectionQ[argv_List] :=
  With[{h = First[argv, ""], s = If[Length[argv] >= 2, argv[[2]], ""]},
    Or[MemberQ[$iConnectedHeads, h],
       h === "validate" && MemberQ[argv, "--strict"],
       h === "capture" && !StringEndsQ[iCaptureOutput[argv], ".svg", IgnoreCase -> True],
       h === "flux" && MemberQ[{"deploy", "deploy-manifest", "watch"}, s]]];

iCaptureOutput[argv_List] :=
  With[{p = Position[argv, "--output"]},
    If[p === {} || First[First[p]] >= Length[argv], "", argv[[First[First[p]] + 1]]]];

iMutationQ[argv_List] :=
  With[{h = First[argv, ""], s = If[Length[argv] >= 2, argv[[2]], ""]},
    Or[h === "apply",
       h === "slot" && MemberQ[{"create", "set", "delete"}, s],
       h === "component" && MemberQ[{"add", "set", "remove"}, s],
       h === "flux" && MemberQ[{"deploy", "deploy-manifest", "watch"}, s]]];

iAddURL[argv_List] :=
  If[MemberQ[argv, "--url"] || !StringQ[ResoLoop`$ResoLoopURL], argv, Join[argv, {"--url", ResoLoop`$ResoLoopURL}]];

(* ============================================================
   所有境界
   ============================================================ *)

iOwnedPathQ[path_String] :=
  Module[{segs = Select[StringSplit[path, "/"], # =!= "" &], first},
    If[segs =!= {} && First[segs] === "Root", segs = Rest[segs]];
    If[segs === {}, Return[False]];
    first = First[segs];
    AnyTrue[ResoLoop`$ResoLoopOwnershipPrefixes, StringStartsQ[first, #] &]];

iOwnedQ[id_String, dir_String] :=
  Module[{r},
    Which[
      id === "Root", False,
      StringStartsQ[id, "$"], True,
      StringStartsQ[id, "path:"], iOwnedPathQ[StringDrop[id, 5]],
      StringContainsQ[id, "/"] && !StringStartsQ[id, "Reso_"], iOwnedPathQ[id],
      True,
        r = iRunCore[iAddURL[{"inspect", id, "--depth", "0"}], dir, ResoLoop`$ResoLoopDefaultTimeout];
        If[FailureQ[r], r, iOwnedPathQ[Lookup[r, "path", ""]]]]];

ResoLoop`ResoLoopOwnedQ[id_String, opts : OptionsPattern[{"Project" -> Automatic}]] :=
  Module[{dir = ResoLoop`ResoLoopProject[OptionValue["Project"]]},
    If[FailureQ[dir], Return[dir]];
    If[!StringQ[ResoLoop`$ResoLoopURL] && !StringStartsQ[id, "$"] && id =!= "Root",
      With[{c = ResoLoop`ResoLoopConnect[]}, If[FailureQ[c], Return[c]]]];
    iOwnedQ[id, dir]];

iOutside[id_] :=
  iFailure["OutsideOwnership",
    "所有境界の外です: " <> ToString[id] <> " (root 名が " <> StringRiffle[ResoLoop`$ResoLoopOwnershipPrefixes, " / "] <> " で始まるものだけ変更できます)。",
    <|"Target" -> id|>];

iConfirmRequired[what_String] :=
  iFailure["ConfirmRequired", what <> " には \"Confirm\" -> True が要ります (音声・MCP からは確認フローを経たときだけ)。"];

(* 変更系の引数を見て、実行してよいか判定する。None なら可、Failure なら不可。 *)
iGuard[argv_List, dir_String, confirm_, adopt_, owner_] :=
  Module[{h = First[argv, ""], s = If[Length[argv] >= 2, argv[[2]], ""], target, parent, name, owned},
    Which[
      MemberQ[argv, "--adopt"] && !TrueQ[adopt],
        iFailure["AdoptNotAllowed", "--adopt は \"Adopt\" -> True (ノートブックで人が明示) のときだけ使えます。"],
      MemberQ[argv, "--prune"] && !TrueQ[confirm], iConfirmRequired["--prune"],
      MemberQ[argv, "--yes"] && !TrueQ[confirm], iConfirmRequired["--yes"],
      h === "slot" && s === "delete",
        If[!TrueQ[confirm], Return[iConfirmRequired["slot delete"]]];
        target = If[Length[argv] >= 3, argv[[3]], ""];
        owned = iOwnedQ[target, dir];
        Which[FailureQ[owned], owned, !TrueQ[owned], iOutside[target], True, None],
      h === "slot" && s === "set",
        target = If[Length[argv] >= 3, argv[[3]], ""];
        owned = iOwnedQ[target, dir];
        Which[FailureQ[owned], owned, !TrueQ[owned], iOutside[target], True, None],
      h === "slot" && s === "create",
        parent = iFlagValue[argv, "--parent", "Root"];
        name = iFlagValue[argv, "--name", ""];
        owned = iOwnedQ[parent, dir];
        Which[
          FailureQ[owned], owned,
          TrueQ[owned], None,
          AnyTrue[ResoLoop`$ResoLoopOwnershipPrefixes, StringStartsQ[name, #] &], None,
          True, iFailure["OutsideOwnership",
            "所有外の親 (" <> parent <> ") に作る Slot の名前は " <> StringRiffle[ResoLoop`$ResoLoopOwnershipPrefixes, " / "] <> " で始めてください。",
            <|"Parent" -> parent, "Name" -> name|>]],
      h === "component" && s === "add",
        target = If[Length[argv] >= 3, argv[[3]], ""];
        owned = iOwnedQ[target, dir];
        Which[FailureQ[owned], owned, !TrueQ[owned], iOutside[target], True, None],
      h === "component" && MemberQ[{"set", "remove"}, s],
        If[s === "remove" && !TrueQ[confirm], Return[iConfirmRequired["component remove"]]];
        target = If[Length[argv] >= 3, argv[[3]], ""];
        Which[
          StringStartsQ[target, "$"], None,
          !StringQ[owner],
            iFailure["OwnerRequired",
              "生の Component ID を変更するときは \"Owner\" -> slotId (その Component が属する Slot) を指定してください。安定セレクタ $component:key なら不要です。",
              <|"Target" -> target|>],
          True,
            owned = iOwnedQ[owner, dir];
            Which[FailureQ[owned], owned, !TrueQ[owned], iOutside[owner], True, None]],
      True, None]];

iFlagValue[argv_List, flag_String, default_] :=
  With[{p = Position[argv, flag]},
    If[p === {} || First[First[p]] >= Length[argv], default, argv[[First[First[p]] + 1]]]];

(* ============================================================
   公開: ResoLoopRun
   ============================================================ *)

Options[ResoLoop`ResoLoopRun] = {
  "Project" -> Automatic, "URL" -> Automatic, "Timeout" -> Automatic, "Raw" -> False,
  "Confirm" -> False, "Adopt" -> False, "Owner" -> None, "Directory" -> Automatic};

ResoLoop`ResoLoopRun[args_List, OptionsPattern[]] :=
  Module[{dir, argv, timeout, guard, project, r},
    project = OptionValue["Project"];
    argv = iStr /@ args;
    dir = If[StringQ[OptionValue["Directory"]], OptionValue["Directory"], ResoLoop`ResoLoopProject[project]];
    (* プロジェクトが要らないコマンド (--version / discover / doctor / init) はどこで走らせてもよい *)
    If[FailureQ[dir] && MemberQ[{"--version", "discover", "doctor", "init"}, First[argv, ""]],
      dir = If[DirectoryQ[ResoLoop`$ResoLoopProjectsDirectory], ResoLoop`$ResoLoopProjectsDirectory, $HomeDirectory]];
    If[FailureQ[dir], Return[dir]];
    timeout = Replace[OptionValue["Timeout"], Automatic :>
      If[MemberQ[{"apply", "capture", "test", "item", "flux", "init"}, First[argv, ""]],
        ResoLoop`$ResoLoopLongTimeout, ResoLoop`$ResoLoopDefaultTimeout]];
    (* 接続 *)
    If[StringQ[OptionValue["URL"]] && !MemberQ[argv, "--url"], argv = Join[argv, {"--url", OptionValue["URL"]}]];
    If[iNeedsConnectionQ[argv] && !MemberQ[argv, "--url"],
      If[!StringQ[ResoLoop`$ResoLoopURL],
        With[{c = ResoLoop`ResoLoopConnect[]}, If[FailureQ[c], Return[c]]]];
      argv = iAddURL[argv]];
    (* ガード: --yes / --prune / --adopt の検査は全コマンド (test --probe --yes も含む)、
       所有境界と mutex は変更系だけ *)
    guard = iGuard[argv, dir, OptionValue["Confirm"], OptionValue["Adopt"], OptionValue["Owner"]];
    If[FailureQ[guard], Return[guard]];
    If[iMutationQ[argv],
      If[TrueQ[$iLocks[dir]],
        Return[iFailure["Busy", "このプロジェクトでは別の変更が実行中です: " <> dir, <|"Directory" -> dir|>]]];
      $iLocks[dir] = True;
      r = Quiet @ Check[iRunCore[argv, dir, timeout, "Raw" -> OptionValue["Raw"]], $Failed];
      $iLocks[dir] = False;
      If[r === $Failed, Return[iFailure["Aborted", "実行中に例外が起きました: " <> StringRiffle[argv, " "]]]],
      r = iRunCore[argv, dir, timeout, "Raw" -> OptionValue["Raw"]]];
    (* 接続切れ (Resonite 再起動でポートが変わった等) は 1 回だけ再探索して再実行 *)
    If[FailureQ[r] && MemberQ[{"CONNECTION_FAILED", "REQUEST_TIMEOUT"}, r["Code"]] && iNeedsConnectionQ[argv] &&
       StringQ[ResoLoop`$ResoLoopURL] && !StringQ[OptionValue["URL"]],
      ResoLoop`ResoLoopDisconnect[];
      With[{c = ResoLoop`ResoLoopConnect[]},
        If[FailureQ[c], Return[c]];
        argv = iAddURL[DeleteCases[argv, "--url" | _?(StringStartsQ[#, "ws://"] &)]];
        r = iRunCore[argv, dir, timeout, "Raw" -> OptionValue["Raw"]]]];
    r];

(* ============================================================
   非同期実行 (bat でリダイレクトし、StartProcess で監視)
   ============================================================ *)

iBatQuote[s_String] := "\"" <> StringReplace[s, "\"" -> "\\\""] <> "\"";

Options[ResoLoop`ResoLoopRunAsync] = Options[ResoLoop`ResoLoopRun];
ResoLoop`ResoLoopRunAsync[args_List, opts : OptionsPattern[]] :=
  Module[{dir, argv, timeout, guard, exe, id, wd, bat, out, err, code, proc, job},
    dir = If[StringQ[OptionValue["Directory"]], OptionValue["Directory"], ResoLoop`ResoLoopProject[OptionValue["Project"]]];
    If[FailureQ[dir], Return[dir]];
    exe = ResoLoop`ResoLoopExecutable[];
    If[FailureQ[exe], Return[exe]];
    argv = iStr /@ args;
    timeout = Replace[OptionValue["Timeout"], Automatic -> ResoLoop`$ResoLoopLongTimeout];
    If[StringQ[OptionValue["URL"]] && !MemberQ[argv, "--url"], argv = Join[argv, {"--url", OptionValue["URL"]}]];
    If[iNeedsConnectionQ[argv] && !MemberQ[argv, "--url"],
      If[!StringQ[ResoLoop`$ResoLoopURL],
        With[{c = ResoLoop`ResoLoopConnect[]}, If[FailureQ[c], Return[c]]]];
      argv = iAddURL[argv]];
    If[!MemberQ[argv, "--json"], AppendTo[argv, "--json"]];
    If[!MemberQ[argv, "--command-timeout"], argv = Join[argv, {"--command-timeout", iNumberString[timeout]}]];
    guard = iGuard[argv, dir, OptionValue["Confirm"], OptionValue["Adopt"], OptionValue["Owner"]];
    If[FailureQ[guard], Return[guard]];
    If[iMutationQ[argv] && TrueQ[$iLocks[dir]],
      Return[iFailure["Busy", "このプロジェクトでは別の変更が実行中です: " <> dir, <|"Directory" -> dir|>]]];
    id = "rl-" <> DateString[{"Year", "Month", "Day", "-", "Hour", "Minute", "Second"}] <> "-" <> StringTake[CreateUUID[], 8];
    wd = iWorkingDirectory[];
    bat = FileNameJoin[{wd, id <> ".bat"}];
    out = FileNameJoin[{wd, id <> ".out"}];
    err = FileNameJoin[{wd, id <> ".err"}];
    code = FileNameJoin[{wd, id <> ".code"}];
    iWriteUTF8[bat, StringJoin[
      "@echo off\r\n", "chcp 65001 >nul\r\n",
      "cd /d ", iBatQuote[dir], "\r\n",
      iBatQuote[exe], " ", StringRiffle[iBatQuote /@ argv, " "], " > ", iBatQuote[out], " 2> ", iBatQuote[err], "\r\n",
      "echo %ERRORLEVEL% > ", iBatQuote[code], "\r\n"]];
    proc = Quiet @ Check[StartProcess[{"cmd", "/c", bat}], $Failed];
    If[Head[proc] =!= ProcessObject,
      Return[iFailure["SpawnFailed", "resoloop を起動できませんでした。", <|"Bat" -> bat|>]]];
    If[iMutationQ[argv], $iLocks[dir] = True];
    job = <|"Job" -> id, "Process" -> proc, "Arguments" -> argv, "Directory" -> dir, "Started" -> AbsoluteTime[],
      "Timeout" -> timeout, "Out" -> out, "Err" -> err, "Code" -> code, "Bat" -> bat,
      "Mutation" -> iMutationQ[argv], "Raw" -> OptionValue["Raw"]|>;
    $iJobs[id] = job;
    job];

iReadFileString[file_String] :=
  If[FileExistsQ[file], Quiet @ Check[ByteArrayToString[ReadByteArray[file], "UTF-8"], ""], ""];

ResoLoop`ResoLoopAsyncStatus[job_Association] :=
  Module[{proc = job["Process"], st},
    st = Quiet @ Check[ProcessStatus[proc], "Finished"];
    Which[
      st === "Running" && AbsoluteTime[] - job["Started"] > job["Timeout"] + 15,
        Quiet @ KillProcess[proc]; iReleaseJob[job]; "Killed",
      st === "Running", "Running",
      True, iReleaseJob[job]; "Finished"]];

iReleaseJob[job_Association] :=
  If[TrueQ[job["Mutation"]] && KeyExistsQ[$iJobs, job["Job"]],
    $iLocks[job["Directory"]] = False; KeyDropFrom[$iJobs, job["Job"]]];

ResoLoop`ResoLoopAsyncResult[job_Association] :=
  Module[{st = ResoLoop`ResoLoopAsyncStatus[job], out, err, resp, exit},
    If[st === "Running", Return[iFailure["Running", "まだ実行中です: " <> job["Job"]]]];
    out = iReadFileString[job["Out"]];
    err = iReadFileString[job["Err"]];
    exit = Quiet @ Check[ToExpression[StringTrim[iReadFileString[job["Code"]]]], -1];
    resp = iParseResponse[out, err];
    ResoLoop`$ResoLoopLastResult = If[AssociationQ[resp], Join[resp, <|"Arguments" -> job["Arguments"]|>], None];
    Which[
      st === "Killed",
        iFailure["COMMAND_TIMEOUT", "resoloop が " <> iNumberString[job["Timeout"]] <> " 秒で終わりませんでした: " <> StringRiffle[job["Arguments"], " "]],
      !AssociationQ[resp],
        iFailure["NO_JSON", "resoloop の応答に JSON がありません (exit " <> ToString[exit] <> ")",
          <|"StandardOutput" -> StringTake[out, UpTo[2000]], "StandardError" -> StringTake[err, UpTo[2000]], "ExitCode" -> exit|>],
      TrueQ[resp["ok"]], If[TrueQ[job["Raw"]], resp, Lookup[resp, "data", <||>]],
      True,
        With[{e = Lookup[resp, "error", <||>]},
          iFailure[Lookup[e, "code", "UNKNOWN"], Lookup[e, "message", "resoloop error"],
            <|"Context" -> Lookup[e, "context", <||>], "Suggestions" -> Lookup[e, "suggestions", {}]|>]]]];

ResoLoop`ResoLoopAsyncWait[job_Association, timeout_ : Automatic] :=
  Module[{limit = Replace[timeout, Automatic -> job["Timeout"] + 15], t0 = AbsoluteTime[]},
    While[ResoLoop`ResoLoopAsyncStatus[job] === "Running" && AbsoluteTime[] - t0 < limit, Pause[0.5]];
    ResoLoop`ResoLoopAsyncResult[job]];

ResoLoop`ResoLoopAsyncKill[job_Association] :=
  (Quiet @ KillProcess[job["Process"]]; iReleaseJob[job]; "Killed");

(* ============================================================
   接続
   ============================================================ *)

Options[ResoLoop`ResoLoopDiscover] = {"DiscoverySeconds" -> 12, "Project" -> Automatic};
ResoLoop`ResoLoopDiscover[OptionsPattern[]] :=
  Module[{dir = ResoLoop`ResoLoopProject[OptionValue["Project"]], r},
    If[FailureQ[dir], dir = ResoLoop`$ResoLoopProjectsDirectory];
    If[!DirectoryQ[dir], dir = $HomeDirectory];
    r = iRunCore[{"discover", "--discovery-seconds", OptionValue["DiscoverySeconds"]}, dir,
      OptionValue["DiscoverySeconds"] + 30];
    If[FailureQ[r], r, Lookup[r, "sessions", {}]]];

Options[ResoLoop`ResoLoopConnect] = {"Session" -> Automatic, "URL" -> Automatic, "DiscoverySeconds" -> 12, "Project" -> Automatic};
ResoLoop`ResoLoopConnect[OptionsPattern[]] :=
  Module[{sessions, picked, url, dir, st, name = OptionValue["Session"]},
    dir = ResoLoop`ResoLoopProject[OptionValue["Project"]];
    If[FailureQ[dir], dir = If[DirectoryQ[ResoLoop`$ResoLoopProjectsDirectory], ResoLoop`$ResoLoopProjectsDirectory, $HomeDirectory]];
    If[StringQ[OptionValue["URL"]],
      url = OptionValue["URL"]; picked = <|"sessionName" -> None, "sessionId" -> None|>,
      sessions = ResoLoop`ResoLoopDiscover["DiscoverySeconds" -> OptionValue["DiscoverySeconds"], "Project" -> OptionValue["Project"]];
      If[FailureQ[sessions], Return[sessions]];
      If[sessions === {},
        sessions = ResoLoop`ResoLoopDiscover["DiscoverySeconds" -> 20, "Project" -> OptionValue["Project"]];
        If[FailureQ[sessions], Return[sessions]]];
      If[StringQ[name],
        sessions = Select[sessions, Lookup[#, "sessionName", ""] === name || Lookup[#, "sessionId", ""] === name ||
          StringContainsQ[Lookup[#, "sessionName", ""], name, IgnoreCase -> True] &]];
      Which[
        sessions === {},
          Return[iFailure["ResoniteLinkOff",
            "ResoniteLink の通知が見つかりません。Resonite の Dashboard → Session → Settings で「Enable ResoniteLink」をオンにしてください (本パッケージは常時オンを前提にしています)。",
            <|"Session" -> name|>]],
        Length[sessions] > 1,
          Return[iFailure["AmbiguousSession",
            "ResoniteLink のセッションが複数あります。\"Session\" -> 名前 で選んでください: " <>
              StringRiffle[Lookup[#, "sessionName", "?"] & /@ sessions, ", "],
            <|"Sessions" -> sessions|>]]];
      picked = First[sessions];
      url = picked["url"]];
    st = iRunCore[{"status", "--url", url}, dir, ResoLoop`$ResoLoopDefaultTimeout];
    If[FailureQ[st], Return[st]];
    ResoLoop`$ResoLoopURL = url;
    ResoLoop`$ResoLoopSession = Lookup[picked, "sessionName", None];
    $iSessionId = Lookup[picked, "sessionId", None];
    $iConnectedAt = AbsoluteTime[];
    url];

ResoLoop`ResoLoopDisconnect[] :=
  (ResoLoop`$ResoLoopURL = None; ResoLoop`$ResoLoopSession = None; $iSessionId = None; $iConnectedAt = None; None);

ResoLoop`ResoLoopSessionInfo[] :=
  <|"URL" -> ResoLoop`$ResoLoopURL, "Session" -> ResoLoop`$ResoLoopSession, "SessionId" -> $iSessionId,
    "ConnectedAt" -> If[NumericQ[$iConnectedAt], DateObject[$iConnectedAt], None]|>;

ResoLoop`ResoLoopPrivacyLevel[] :=
  If[Names["ResoniteRealtime`ResoniteAccessLevel"] =!= {} &&
     Length[DownValues[Symbol["ResoniteRealtime`ResoniteAccessLevel"]]] > 0,
    With[{v = Quiet @ Check[Symbol["ResoniteRealtime`ResoniteAccessLevel"][], $Failed]},
      If[NumericQ[v], v, ResoLoop`$ResoLoopDefaultPrivacyLevel]],
    ResoLoop`$ResoLoopDefaultPrivacyLevel];

(* ============================================================
   環境
   ============================================================ *)

$iProjOpt = {"Project" -> Automatic};

ResoLoop`ResoLoopVersion[opts : OptionsPattern[$iProjOpt]] :=
  With[{r = ResoLoop`ResoLoopRun[{"--version"}, opts]}, If[FailureQ[r], r, Lookup[r, "version", None]]];

(* doctor は未接続でも走らせたいので、接続キャッシュが無ければ --url auto (自前探索) を渡す。
   Flux-SDK のプローブ (3320 ノード読込) と探索 12 s を含むので長めのタイムアウト。 *)
ResoLoop`ResoLoopDoctor[opts : OptionsPattern[$iProjOpt]] :=
  ResoLoop`ResoLoopRun[
    Join[{"doctor"}, If[StringQ[ResoLoop`$ResoLoopURL], {"--url", ResoLoop`$ResoLoopURL}, {"--url", "auto"}]],
    "Timeout" -> 120, opts];

ResoLoop`ResoLoopStatus[opts : OptionsPattern[$iProjOpt]] :=
  ResoLoop`ResoLoopRun[{"status"}, opts];

(* ============================================================
   観測
   ============================================================ *)

iStateArgs[None | Automatic, _] := {};
iStateArgs[state_String, dir_String] :=
  {"--state", If[StringEndsQ[state, ".json", IgnoreCase -> True] || StringContainsQ[state, "/" | "\\"],
    If[iAbsolutePathQ[state], state, FileNameJoin[{dir, state}]],
    FileNameJoin[{dir, ".resoloop", "state", state <> ".json"}]]};

iAbsolutePathQ[s_String] := StringMatchQ[s, RegularExpression["^([A-Za-z]:[\\\\/]|[\\\\/]{2}).*"]];

iFile[file_String, dir_String] := If[iAbsolutePathQ[file], file, FileNameJoin[{dir, file}]];

iProjectDirOf[opt_] := With[{d = ResoLoop`ResoLoopProject[opt]}, If[FailureQ[d], "", d]];

Options[ResoLoop`ResoLoopHierarchy] = {"IncludeComponents" -> False, "Summary" -> False, "State" -> None, "Project" -> Automatic};
ResoLoop`ResoLoopHierarchy[under_String : "Root", depth_Integer : 1, OptionsPattern[]] :=
  ResoLoop`ResoLoopRun[Join[{"hierarchy", "--under", under, "--depth", depth},
      If[TrueQ[OptionValue["IncludeComponents"]], {"--include-components"}, {}],
      If[TrueQ[OptionValue["Summary"]], {"--summary"}, {}],
      iStateArgs[OptionValue["State"], iProjectDirOf[OptionValue["Project"]]]],
    "Project" -> OptionValue["Project"]];

Options[ResoLoop`ResoLoopFind] = {"Name" -> None, "Exact" -> False, "Component" -> None, "Under" -> None,
  "DirectChildren" -> False, "Depth" -> None, "Project" -> Automatic};
ResoLoop`ResoLoopFind[OptionsPattern[]] :=
  Module[{argv = {"find"}},
    If[StringQ[OptionValue["Name"]], argv = Join[argv, {"--name", OptionValue["Name"]}]];
    If[TrueQ[OptionValue["Exact"]], AppendTo[argv, "--exact"]];
    If[StringQ[OptionValue["Component"]], argv = Join[argv, {"--component", OptionValue["Component"]}]];
    If[StringQ[OptionValue["Under"]], argv = Join[argv, {"--under", OptionValue["Under"]}]];
    If[TrueQ[OptionValue["DirectChildren"]], AppendTo[argv, "--direct-children"]];
    If[IntegerQ[OptionValue["Depth"]], argv = Join[argv, {"--depth", OptionValue["Depth"]}]];
    If[!StringQ[OptionValue["Name"]] && !StringQ[OptionValue["Component"]],
      Return[iFailure["FIND_FILTER_MISSING", "ResoLoopFind には \"Name\" か \"Component\" が要ります。"]]];
    ResoLoop`ResoLoopRun[argv, "Project" -> OptionValue["Project"]]];

Options[ResoLoop`ResoLoopInspect] = {"State" -> None, "Depth" -> None, "Members" -> False, "Component" -> None,
  "Member" -> None, "ComponentsOnly" -> False, "Project" -> Automatic};
ResoLoop`ResoLoopInspect[target_String, OptionsPattern[]] :=
  Module[{argv = {"inspect", target}, dir = iProjectDirOf[OptionValue["Project"]]},
    If[StringStartsQ[target, "$"] && OptionValue["State"] === None,
      Return[iFailure["StateRequired", "安定セレクタ " <> target <> " には \"State\" -> ownership key かファイル が要ります。"]]];
    argv = Join[argv, iStateArgs[OptionValue["State"], dir]];
    If[IntegerQ[OptionValue["Depth"]], argv = Join[argv, {"--depth", OptionValue["Depth"]}]];
    If[TrueQ[OptionValue["Members"]], AppendTo[argv, "--members"]];
    If[StringQ[OptionValue["Component"]], argv = Join[argv, {"--component", OptionValue["Component"]}]];
    If[StringQ[OptionValue["Member"]], argv = Join[argv, {"--member", OptionValue["Member"]}]];
    If[TrueQ[OptionValue["ComponentsOnly"]], AppendTo[argv, "--components-only"]];
    ResoLoop`ResoLoopRun[argv, "Project" -> OptionValue["Project"]]];

Options[ResoLoop`ResoLoopComponentInspect] = {"State" -> None, "Project" -> Automatic};
ResoLoop`ResoLoopComponentInspect[target_String, OptionsPattern[]] :=
  Module[{dir = iProjectDirOf[OptionValue["Project"]]},
    If[StringStartsQ[target, "$"] && OptionValue["State"] === None,
      Return[iFailure["StateRequired", "安定セレクタ " <> target <> " には \"State\" が要ります。"]]];
    ResoLoop`ResoLoopRun[Join[{"component", "inspect", target}, iStateArgs[OptionValue["State"], dir]],
      "Project" -> OptionValue["Project"]]];

Options[ResoLoop`ResoLoopTypeSearch] = {"Limit" -> 50, "Project" -> Automatic};
ResoLoop`ResoLoopTypeSearch[query_String, OptionsPattern[]] :=
  ResoLoop`ResoLoopRun[{"type", "search", query, "--limit", OptionValue["Limit"]}, "Project" -> OptionValue["Project"]];

Options[ResoLoop`ResoLoopTypeDescribe] = {"Member" -> None, "Project" -> Automatic};
ResoLoop`ResoLoopTypeDescribe[type_String, OptionsPattern[]] :=
  ResoLoop`ResoLoopRun[Join[{"type", "describe", type},
      If[StringQ[OptionValue["Member"]], {"--member", OptionValue["Member"]}, {}]],
    "Project" -> OptionValue["Project"]];

ResoLoop`ResoLoopTypeSpecialize[open_String, args_List, opts : OptionsPattern[$iProjOpt]] :=
  With[{r = ResoLoop`ResoLoopRun[Join[{"type", "specialize", open}, args], opts]},
    If[FailureQ[r], r, Lookup[r, "specialized", r]]];

(* ============================================================
   宣言 (validate / diff / apply / test / capture / audit)
   ============================================================ *)

Options[ResoLoop`ResoLoopValidate] = {"Strict" -> False, "Project" -> Automatic};
ResoLoop`ResoLoopValidate[file_String, OptionsPattern[]] :=
  With[{dir = iProjectDirOf[OptionValue["Project"]]},
    ResoLoop`ResoLoopRun[Join[{"validate", iFile[file, dir]}, If[TrueQ[OptionValue["Strict"]], {"--strict"}, {}]],
      "Project" -> OptionValue["Project"]]];

Options[ResoLoop`ResoLoopDiff] = {"Mode" -> "Changes", "State" -> None, "Adopt" -> False, "Project" -> Automatic};
ResoLoop`ResoLoopDiff[file_String, OptionsPattern[]] :=
  Module[{dir = iProjectDirOf[OptionValue["Project"]], argv},
    argv = Join[{"diff", iFile[file, dir]}, iStateArgs[OptionValue["State"], dir],
      Replace[OptionValue["Mode"], {"Changes" -> {"--changes-only"}, "Creates" -> {"--creates-only"},
        "Deletes" -> {"--deletes-only"}, "Summary" -> {"--summary"}, _ -> {}}],
      If[TrueQ[OptionValue["Adopt"]], {"--adopt"}, {}]];
    ResoLoop`ResoLoopRun[argv, "Project" -> OptionValue["Project"], "Adopt" -> OptionValue["Adopt"]]];

Options[ResoLoop`ResoLoopApply] = {"State" -> None, "Prune" -> False, "Confirm" -> False, "Adopt" -> False,
  "Profile" -> False, "Quiet" -> True, "Timeout" -> Automatic, "Project" -> Automatic};
ResoLoop`ResoLoopApply[file_String, OptionsPattern[]] :=
  Module[{dir = iProjectDirOf[OptionValue["Project"]], argv},
    argv = Join[{"apply", iFile[file, dir]}, iStateArgs[OptionValue["State"], dir],
      If[TrueQ[OptionValue["Adopt"]], {"--adopt"}, {}],
      If[TrueQ[OptionValue["Profile"]], {"--profile"}, {}],
      If[TrueQ[OptionValue["Quiet"]], {"--quiet"}, {}],
      If[TrueQ[OptionValue["Prune"]], {"--prune", "--yes"}, {}]];
    ResoLoop`ResoLoopRun[argv, "Project" -> OptionValue["Project"], "Confirm" -> OptionValue["Confirm"],
      "Adopt" -> OptionValue["Adopt"], "Timeout" -> OptionValue["Timeout"]]];

Options[ResoLoop`ResoLoopTest] = {"State" -> None, "Probe" -> False, "Confirm" -> False, "Project" -> Automatic};
ResoLoop`ResoLoopTest[file_String, OptionsPattern[]] :=
  Module[{dir = iProjectDirOf[OptionValue["Project"]], argv},
    argv = Join[{"test", iFile[file, dir]}, iStateArgs[OptionValue["State"], dir],
      If[TrueQ[OptionValue["Probe"]], {"--probe", "--yes"}, {}]];
    ResoLoop`ResoLoopRun[argv, "Project" -> OptionValue["Project"], "Confirm" -> OptionValue["Confirm"]]];

Options[ResoLoop`ResoLoopCapture] = {"Width" -> None, "Height" -> None, "Import" -> False, "Project" -> Automatic};
ResoLoop`ResoLoopCapture[file_String, camera_String : "main", output_String : Automatic, OptionsPattern[]] :=
  Module[{dir = iProjectDirOf[OptionValue["Project"]], out, argv, r},
    out = If[output === Automatic, FileNameJoin[{dir, "artifacts", FileBaseName[file] <> ".jpg"}], iFile[output, dir]];
    If[!DirectoryQ[DirectoryName[out]], Quiet @ CreateDirectory[DirectoryName[out], CreateIntermediateDirectories -> True]];
    argv = Join[{"capture", iFile[file, dir], "--camera", camera, "--output", out},
      If[IntegerQ[OptionValue["Width"]], {"--width", OptionValue["Width"]}, {}],
      If[IntegerQ[OptionValue["Height"]], {"--height", OptionValue["Height"]}, {}]];
    r = ResoLoop`ResoLoopRun[argv, "Project" -> OptionValue["Project"]];
    If[FailureQ[r] || !TrueQ[OptionValue["Import"]], r,
      Join[r, <|"Image" -> Quiet @ Check[Import[Lookup[r, "output", out]], None]|>]]];

ResoLoop`ResoLoopSceneSummary[file_String, output_String : Automatic, opts : OptionsPattern[$iProjOpt]] :=
  With[{dir = iProjectDirOf[OptionValue[ResoLoop`ResoLoopSceneSummary, {opts}, "Project"]]},
    ResoLoop`ResoLoopRun[{"scene", "summary", iFile[file, dir], "--output",
      If[output === Automatic, FileNameJoin[{dir, "artifacts", FileBaseName[file] <> ".scene.json"}], iFile[output, dir]]}, opts]];
Options[ResoLoop`ResoLoopSceneSummary] = $iProjOpt;

Options[ResoLoop`ResoLoopItemAudit] = {"Strict" -> True, "AllowExternalRoles" -> Automatic, "State" -> None,
  "Report" -> False, "Project" -> Automatic};
(* "AllowExternalRoles" -> Automatic は二段: まず許可なしで監査し、報告された externalRoleCandidates のうち
   既定 (エンジン既定のシェーダー/フォント/テキスト材質/_lastParent) に含まれるものだけを許可して再監査する。
   --strict は「使われなかった許可ロール」を ITEM_ALLOW_ROLE_UNUSED として失敗にするので、4 つ全部を
   無条件に渡すと該当参照の無い物 (例: 文字の無い球) で落ちる (2026-09-22 実機で判明)。 *)
ResoLoop`ResoLoopItemAudit[root_String, OptionsPattern[]] :=
  Module[{dir = iProjectDirOf[OptionValue["Project"]], roles, base, r, report, cands},
    base = Join[{"item", "audit", root}, iStateArgs[OptionValue["State"], dir],
      If[TrueQ[OptionValue["Strict"]], {"--strict"}, {}]];
    roles = OptionValue["AllowExternalRoles"];
    If[roles === Automatic,
      r = ResoLoop`ResoLoopRun[base, "Project" -> OptionValue["Project"]];
      (* Failure は Association ではないので Lookup でなく part 抽出 r["Context"] で読む *)
      report = If[FailureQ[r], Lookup[iFailureContext[r], "report", <||>], r];
      cands = Replace[Lookup[report, "externalRoleCandidates", {}], Except[_List] -> {}];
      roles = Select[cands, MemberQ[ResoLoop`$ResoLoopDefaultExternalRoles, #] &];
      If[FailureQ[r] && r["Code"] === "ITEM_NOT_PORTABLE" && roles =!= {},
        r = ResoLoop`ResoLoopRun[Join[base, Flatten[{"--allow-external-role", #} & /@ roles]],
          "Project" -> OptionValue["Project"]]],
      roles = Replace[roles, None -> {}];
      r = ResoLoop`ResoLoopRun[Join[base, Flatten[{"--allow-external-role", #} & /@ roles]],
        "Project" -> OptionValue["Project"]]];
    If[TrueQ[OptionValue["Report"]] && FailureQ[r] && r["Code"] === "ITEM_NOT_PORTABLE",
      Lookup[iFailureContext[r], "report", r], r]];

iFailureContext[f_Failure] := Replace[Quiet @ Check[f["Context"], <||>], Except[_Association] -> <||>];
iFailureContext[_] := <||>;

(* ============================================================
   Flux
   ============================================================ *)

iFluxProject[Automatic, dir_String] := FileNameJoin[{dir, "flux"}];
iFluxProject[p_String, dir_String] := iFile[p, dir];

ResoLoop`ResoLoopFluxStatus[opts : OptionsPattern[$iProjOpt]] := ResoLoop`ResoLoopRun[{"flux", "status"}, opts];

Options[ResoLoop`ResoLoopFluxCheck] = {"FluxProject" -> Automatic, "Project" -> Automatic};
ResoLoop`ResoLoopFluxCheck[pg_String, OptionsPattern[]] :=
  With[{dir = iProjectDirOf[OptionValue["Project"]]},
    ResoLoop`ResoLoopRun[{"flux", "check", iFile[pg, dir], "--project", iFluxProject[OptionValue["FluxProject"], dir]},
      "Project" -> OptionValue["Project"]]];

Options[ResoLoop`ResoLoopFluxBuild] = Options[ResoLoop`ResoLoopFluxCheck];
ResoLoop`ResoLoopFluxBuild[pg_String, OptionsPattern[]] :=
  With[{dir = iProjectDirOf[OptionValue["Project"]]},
    ResoLoop`ResoLoopRun[{"flux", "build", iFile[pg, dir], "--project", iFluxProject[OptionValue["FluxProject"], dir]},
      "Project" -> OptionValue["Project"]]];

Options[ResoLoop`ResoLoopFluxNodeSearch] = {"Limit" -> 50, "Project" -> Automatic};
ResoLoop`ResoLoopFluxNodeSearch[query_String, OptionsPattern[]] :=
  With[{r = ResoLoop`ResoLoopRun[{"flux", "node", "search", query, "--limit", OptionValue["Limit"]}, "Project" -> OptionValue["Project"]]},
    If[FailureQ[r], r, Lookup[r, "nodes", r]]];

ResoLoop`ResoLoopFluxNodeDescribe[name_String, opts : OptionsPattern[$iProjOpt]] :=
  With[{r = ResoLoop`ResoLoopRun[{"flux", "node", "describe", name}, opts]},
    If[FailureQ[r], r, Lookup[r, "nodes", r]]];

ResoLoop`ResoLoopFluxValidateManifest[manifest_String, opts : OptionsPattern[$iProjOpt]] :=
  With[{dir = iProjectDirOf[OptionValue[ResoLoop`ResoLoopFluxValidateManifest, {opts}, "Project"]]},
    ResoLoop`ResoLoopRun[{"flux", "validate-manifest", iFile[manifest, dir]}, opts]];
Options[ResoLoop`ResoLoopFluxValidateManifest] = $iProjOpt;

ResoLoop`ResoLoopFluxDeployManifest[manifest_String, opts : OptionsPattern[$iProjOpt]] :=
  With[{dir = iProjectDirOf[OptionValue[ResoLoop`ResoLoopFluxDeployManifest, {opts}, "Project"]]},
    ResoLoop`ResoLoopRun[{"flux", "deploy-manifest", iFile[manifest, dir]}, opts]];
Options[ResoLoop`ResoLoopFluxDeployManifest] = $iProjOpt;

(* ============================================================
   原始操作
   ============================================================ *)

Options[ResoLoop`ResoLoopSlotCreate] = {"Name" -> None, "Parent" -> "Root", "Position" -> None, "Rotation" -> None,
  "Scale" -> None, "Project" -> Automatic};
ResoLoop`ResoLoopSlotCreate[OptionsPattern[]] :=
  Module[{argv = {"slot", "create"}},
    If[!StringQ[OptionValue["Name"]], Return[iFailure["NameRequired", "\"Name\" が要ります。"]]];
    argv = Join[argv, {"--name", OptionValue["Name"], "--parent", OptionValue["Parent"]}];
    If[OptionValue["Position"] =!= None, argv = Join[argv, {"--position", iVector[OptionValue["Position"]]}]];
    If[OptionValue["Rotation"] =!= None, argv = Join[argv, {"--rotation", iVector[OptionValue["Rotation"]]}]];
    If[OptionValue["Scale"] =!= None, argv = Join[argv, {"--scale", iVector[OptionValue["Scale"]]}]];
    ResoLoop`ResoLoopRun[argv, "Project" -> OptionValue["Project"]]];

Options[ResoLoop`ResoLoopSlotSet] = {"Name" -> None, "Position" -> None, "Rotation" -> None, "Scale" -> None, "Project" -> Automatic};
ResoLoop`ResoLoopSlotSet[id_String, OptionsPattern[]] :=
  Module[{argv = {"slot", "set", id}},
    If[StringQ[OptionValue["Name"]], argv = Join[argv, {"--name", OptionValue["Name"]}]];
    If[OptionValue["Position"] =!= None, argv = Join[argv, {"--position", iVector[OptionValue["Position"]]}]];
    If[OptionValue["Rotation"] =!= None, argv = Join[argv, {"--rotation", iVector[OptionValue["Rotation"]]}]];
    If[OptionValue["Scale"] =!= None, argv = Join[argv, {"--scale", iVector[OptionValue["Scale"]]}]];
    ResoLoop`ResoLoopRun[argv, "Project" -> OptionValue["Project"]]];

Options[ResoLoop`ResoLoopSlotDelete] = {"Confirm" -> False, "Project" -> Automatic};
ResoLoop`ResoLoopSlotDelete[id_String, OptionsPattern[]] :=
  If[!TrueQ[OptionValue["Confirm"]], iConfirmRequired["slot delete"],
    ResoLoop`ResoLoopRun[{"slot", "delete", id, "--yes"}, "Project" -> OptionValue["Project"], "Confirm" -> True]];

ResoLoop`ResoLoopComponentAdd[slotId_String, type_String, sets_Association : <||>, opts : OptionsPattern[$iProjOpt]] :=
  ResoLoop`ResoLoopRun[Join[{"component", "add", slotId, type},
      Flatten[KeyValueMap[{"--set", #1 <> "=" <> iSetValue[#2]} &, sets]]], opts];
Options[ResoLoop`ResoLoopComponentAdd] = $iProjOpt;

iSetValue[v_List] := iVector[v];
iSetValue[v_Association] := ByteArrayToString[ExportByteArray[v, "RawJSON"], "UTF-8"];
iSetValue[v_] := iStr[v];

Options[ResoLoop`ResoLoopComponentSet] = {"Owner" -> None, "State" -> None, "Project" -> Automatic};
ResoLoop`ResoLoopComponentSet[target_String, member_String, value_, OptionsPattern[]] :=
  With[{dir = iProjectDirOf[OptionValue["Project"]]},
    ResoLoop`ResoLoopRun[Join[{"component", "set", target, member, iSetValue[value]}, iStateArgs[OptionValue["State"], dir]],
      "Project" -> OptionValue["Project"], "Owner" -> OptionValue["Owner"]]];

Options[ResoLoop`ResoLoopComponentRemove] = {"Owner" -> None, "State" -> None, "Confirm" -> False, "Project" -> Automatic};
ResoLoop`ResoLoopComponentRemove[target_String, OptionsPattern[]] :=
  With[{dir = iProjectDirOf[OptionValue["Project"]]},
    If[!TrueQ[OptionValue["Confirm"]], iConfirmRequired["component remove"],
      ResoLoop`ResoLoopRun[Join[{"component", "remove", target, "--yes"}, iStateArgs[OptionValue["State"], dir]],
        "Project" -> OptionValue["Project"], "Owner" -> OptionValue["Owner"], "Confirm" -> True]]];

ResoLoop`$ResoLoopPackageDirectory = $iPackageDirectory;

(* ============================================================
   NBAccess 許可ヘッド (ClaudeEval の runtime がノートブックで承認なしに実行してよい関数)
   2 層とも登録しないと UnknownHeadRequiresApproval で毎回承認になる
   (memory: nbaccess-head-registration-two-layers)。ワイルドカードは使わず列挙する。
   読み取り専用と、境界の決まった操作 (建築ジョブ = builder policy 下の別プロセス) だけ。
   apply / delete / remove / deploy / 生の Run は承認対象のまま (NBRegisterApprovalHeads)。
   ============================================================ *)
$iAgentHeads = {
  "ResoLoopConnect", "ResoLoopDisconnect", "ResoLoopSessionInfo", "ResoLoopStatus", "ResoLoopDoctor",
  "ResoLoopVersion", "ResoLoopDiscover", "ResoLoopPrivacyLevel", "ResoLoopLog", "ResoLoopLocks",
  "ResoLoopProjects", "ResoLoopProject", "ResoLoopOwnedQ",
  "ResoLoopHierarchy", "ResoLoopFind", "ResoLoopInspect", "ResoLoopComponentInspect",
  "ResoLoopTypeSearch", "ResoLoopTypeDescribe", "ResoLoopTypeSpecialize",
  "ResoLoopValidate", "ResoLoopDiff", "ResoLoopSceneSummary", "ResoLoopItemAudit", "ResoLoopCapture", "ResoLoopTest",
  "ResoLoopFluxStatus", "ResoLoopFluxCheck", "ResoLoopFluxBuild", "ResoLoopFluxNodeSearch",
  "ResoLoopFluxNodeDescribe", "ResoLoopFluxValidateManifest",
  "ResoLoopBuildSubmit", "ResoLoopBuildWatch", "ResoLoopJobStatus", "ResoLoopJobResult", "ResoLoopJobWait", "ResoLoopJobs",
  "ResoLoopJobEvents", "ResoLoopJobCancel", "ResoLoopBuildPrompt", "ResoLoopBuildTarget", "ResoLoopUserPlacement",
  "ResoLoopMCPTools", "ResoLoopMCPPromptDirective"};
$iApprovalHeads = {
  "ResoLoopRun", "ResoLoopRunAsync", "ResoLoopApply", "ResoLoopFluxDeployManifest",
  "ResoLoopSlotCreate", "ResoLoopSlotSet", "ResoLoopSlotDelete",
  "ResoLoopComponentAdd", "ResoLoopComponentSet", "ResoLoopComponentRemove",
  "ResoLoopProjectSync", "ResoLoopMCPCallTool", "ResoLoopMCPRegister"};

(* SlideWorkflow と同じく直接参照する (シンボルは読み込み時に NBAccess` 文脈に作られ、NBAccess が後から
   定義を与える)。NBAccess 不在は DownValues の有無で判定する。 *)
ResoLoop`ResoLoopRegisterHeads[] :=
  If[Length[DownValues[NBAccess`NBRegisterAllowedHeads]] > 0,
    Quiet @ Check[NBAccess`NBRegisterAllowedHeads[$iAgentHeads], Null];
    Quiet @ Check[NBAccess`NBRegisterTrustedPackageHeads["ResoLoop`", $iAgentHeads], Null];
    Quiet @ Check[NBAccess`NBRegisterApprovalHeads[$iApprovalHeads], Null];
    <|"Registered" -> Length[$iAgentHeads], "Approval" -> Length[$iApprovalHeads]|>,
    Missing["NoNBAccess"]];

End[];
EndPackage[];

(* 補助モジュール (同じディレクトリ、存在すれば): 建築ジョブと MCP 登録 *)
Block[{$CharacterEncoding = "UTF-8"},
  With[{f = FileNameJoin[{ResoLoop`$ResoLoopPackageDirectory, "ResoLoop_builder.wl"}]}, If[FileExistsQ[f], Get[f]]];
  With[{f = FileNameJoin[{ResoLoop`$ResoLoopPackageDirectory, "ResoLoop_mcp.wl"}]}, If[FileExistsQ[f], Get[f]]]];

(* 補助モジュールの head も含めて NBAccess に登録 (無ければ Missing) *)
ResoLoop`ResoLoopRegisterHeads[];

(* ClaudeEval がプロンプトの語からこのパッケージの api.md を文脈に付ける (SlideWorkflow と同じ機構) *)
If[Names["ClaudeCode`$ClaudePackageKeywordMap"] =!= {} && AssociationQ[ClaudeCode`$ClaudePackageKeywordMap],
  ClaudeCode`$ClaudePackageKeywordMap["ResoLoop"] =
    {"ResoLoop", "resoloop", "Resonite", "ResoniteLink", "ProtoFlux", "ProtoGraph", "Flux-SDK",
     "レゾナイト", "ワールドに作って", "建築ジョブ"}];

Print[Style["ResoLoop パッケージがロードされました (v" <> ResoLoop`$ResoLoopVersion <> ")。", Bold]];
Print["
  ResoLoopConnect[]                       → ResoniteLink を探索して接続 (常時オン前提)
  ResoLoopStatus[] / ResoLoopDoctor[]     → 接続・環境の確認
  ResoLoopHierarchy[under, depth] / ResoLoopFind[\"Name\" -> ...] / ResoLoopInspect[id]
  ResoLoopValidate[file] → ResoLoopDiff[file] → ResoLoopApply[file] → ResoLoopTest / ResoLoopCapture
  ResoLoopFluxCheck / ResoLoopFluxBuild / ResoLoopFluxDeployManifest[manifest]
  ResoLoopSlotDelete[id, \"Confirm\" -> True]  (削除・prune は Confirm 必須、所有境界 ResoLoop_* 内のみ)
  ResoLoopRun[{...}] は生の CLI (同じ制約つき)、ResoLoopRunAsync は非ブロック版
"];
