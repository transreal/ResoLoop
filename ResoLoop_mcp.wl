(* ::Package:: *)

(* ResoLoop_mcp.wl -- SourceVault MCP へ resoloop の tool 群 sourcevault_resonite_... を登録する (G1)
   (注意: このヘッダで tool 名の末尾にアスタリスクと閉じ括弧を続けて書くとコメントが閉じる)

   This file is encoded in UTF-8. ResoLoop.wl が自動でロードする (同じ ResoLoop` コンテキスト)。
   設計: ResoLoop_info/design/resoloop_integration_spec_v0_1.md §4。

   SourceVault MCP のツール表に載せると、Claude Code CLI (--mcp-config) とローカル LLM
   ($ClaudeLocalToolLoop) の両経路に同時に届く。登録は SourceVault_mcp.wl の拡張点
   SourceVault`$SourceVaultMCPExternalTools (SourceVaultMCPRegisterTools) を使う。SourceVault より先に
   ロードされてもよいように、連想へ直接書く (SourceVault_mcp.wl はロード時に既存の登録を保持する)。
   service kernel でも載るよう SourceVault`$SourceVaultServiceExtraPackages に "ResoLoop.wl" を足す
   (反映には service 再起動)。

   handler の戻り値は SourceVault の MCP result <|"content" -> {<|"type"->"text","text"->...|>}, "isError"|>。
   本文は JSON 文字列 (rule 30: ExportByteArray → UTF-8)。長い結果は $ResoLoopMCPMaxChars で切る。
*)

BeginPackage["ResoLoop`"];

ResoLoop`ResoLoopMCPTools::usage = "ResoLoopMCPTools[] は sourcevault_resonite_* の MCP tool 定義 (name/description/inputSchema) のリスト。";
ResoLoop`ResoLoopMCPCallTool::usage = "ResoLoopMCPCallTool[name, args] は tool を実行し MCP result <|\"content\",\"isError\"|> を返す (SourceVault MCP から呼ばれる handler)。";
ResoLoop`ResoLoopMCPRegister::usage =
  "ResoLoopMCPRegister[] は SourceVault MCP の外部登録簿に resoloop の tool 群を (再) 登録し、service の追加パッケージに ResoLoop.wl を載せる。ロード時に自動で呼ばれる。";
ResoLoop`ResoLoopMCPPromptDirective::usage = "ResoLoopMCPPromptDirective[] は headless CLI のプロンプトに注入する方針文 (MCP-first)。";
ResoLoop`$ResoLoopMCPAllowedTools::usage =
  "$ResoLoopMCPAllowedTools は headless CLI (--print、対話承認不可) で pre-allow する tool 名。remove は載せない (削除は人が決める)。";
ResoLoop`$ResoLoopMCPMaxChars::usage = "$ResoLoopMCPMaxChars は tool 結果本文の上限文字数 (既定 8000)。";

Begin["`Private`"];

If[!ListQ[ResoLoop`$ResoLoopMCPAllowedTools],
  ResoLoop`$ResoLoopMCPAllowedTools = {"sourcevault_resonite_status", "sourcevault_resonite_query",
    "sourcevault_resonite_build", "sourcevault_resonite_job_status", "sourcevault_resonite_job_result",
    "sourcevault_resonite_adjust"}];
If[!IntegerQ[ResoLoop`$ResoLoopMCPMaxChars], ResoLoop`$ResoLoopMCPMaxChars = 8000];

(* ============================================================
   tool 定義
   ============================================================ *)

imProp[type_String, desc_String] := <|"type" -> type, "description" -> desc|>;

ResoLoop`ResoLoopMCPTools[] := {
  <|"name" -> "sourcevault_resonite_status",
    "description" -> "Resonite (resoloop / ResoniteLink) の接続状態と、実行中の建築ジョブを返す。Resonite の世界に関する作業を始める前に 1 回呼ぶ。",
    "inputSchema" -> <|"type" -> "object", "properties" -> <||>|>|>,
  <|"name" -> "sourcevault_resonite_query",
    "description" -> "Resonite の世界を読み取り専用で観測する。世界に何があるか / ある物の中身 / Component や ProtoFlux ノードの型を、推測せずこれで確認する。kind: hierarchy (under, depth<=3) | find (name か component) | inspect (id, members) | component_inspect (id, state) | type_search (query) | type_describe (type, member) | flux_node_search (query) | flux_node_describe (name)。",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "kind" -> <|"type" -> "string", "enum" -> {"hierarchy", "find", "inspect", "component_inspect", "type_search", "type_describe", "flux_node_search", "flux_node_describe"}|>,
        "under" -> imProp["string", "hierarchy の起点 Slot ID か名前パス (既定 Root)"],
        "depth" -> imProp["integer", "hierarchy の深さ (既定 1、最大 3)"],
        "includeComponents" -> imProp["boolean", "hierarchy に Component も含める"],
        "name" -> imProp["string", "find: Slot 名 (部分一致。exact で完全一致) / flux_node_describe: ノード名"],
        "component" -> imProp["string", "find: Component 型名で探す"],
        "exact" -> imProp["boolean", "find: 完全一致"],
        "id" -> imProp["string", "inspect / component_inspect: Slot/Component ID、または $slot:key / $component:key (state 必須)"],
        "state" -> imProp["string", "安定セレクタを解決する ownership key (例 vb-20260922-...)"],
        "members" -> imProp["boolean", "inspect: メンバー値も返す"],
        "query" -> imProp["string", "type_search / flux_node_search の検索語"],
        "type" -> imProp["string", "type_describe: 型名 (例 FrooxEngine.Grabbable)"],
        "member" -> imProp["string", "type_describe: enum 値などを見たいメンバー名"],
        "project" -> imProp["string", "resoloop プロジェクト名 (既定 VoiceBuilds)"]|>,
      "required" -> {"kind"}|>|>,
  <|"name" -> "sourcevault_resonite_build",
    "description" -> "自然文の依頼 (例「青い箱を目の前に作って」) を Resonite の世界に実装する建築ジョブを起動する。非同期: 即座に jobId を返す。完了は sourcevault_resonite_job_status が done になったとき (30 秒〜数分)。それまで利用者に『作りました』と言わない。同じプロジェクトで同時に走るのは 1 件。",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "request" -> imProp["string", "作る物の依頼文 (日本語 1〜3 文。大きさ・色・機能・置き場所があれば含める)"],
        "project" -> imProp["string", "resoloop プロジェクト名 (既定 VoiceBuilds)"],
        "user" -> imProp["string", "正面に置く利用者の名前 (複数人いるとき)"],
        "distance" -> imProp["number", "利用者からの距離 m (既定 1.0)"]|>,
      "required" -> {"request"}|>|>,
  <|"name" -> "sourcevault_resonite_job_status",
    "description" -> "建築ジョブの進捗 (status: running|done|failed|cancelled、phase: inspecting|authoring|validating|applying|deploying|verifying|done)。jobId 省略で直近。done になったら sourcevault_resonite_job_result で要約と画像パスを取る。",
    "inputSchema" -> <|"type" -> "object", "properties" -> <|"jobId" -> imProp["string", "sourcevault_resonite_build が返した jobId"]|>|>|>,
  <|"name" -> "sourcevault_resonite_job_result",
    "description" -> "完了した建築ジョブの結果: summary (何をどこに作ったか)、rootName、capture (撮影画像のパス)、verification、notes (未確認事項)。",
    "inputSchema" -> <|"type" -> "object", "properties" -> <|"jobId" -> imProp["string", "jobId (省略で直近)"]|>|>|>,
  <|"name" -> "sourcevault_resonite_adjust",
    "description" -> "resoloop が作った物 (ResoLoop_* の root) の小さな調整: 位置 / 回転 / 大きさ / 名前、または Component の 1 フィールド。target は ownership key (vb-...) か Slot ID。所有外の物は拒否される。",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "target" -> imProp["string", "ownership key (例 vb-20260922-110501-ab12) または root Slot ID"],
        "position" -> <|"type" -> "array", "items" -> <|"type" -> "number"|>, "description" -> "新しい位置 [x,y,z] (ワールド Root 基準)"|>,
        "rotation" -> <|"type" -> "array", "items" -> <|"type" -> "number"|>, "description" -> "新しい回転 [x,y,z,w]"|>,
        "scale" -> <|"type" -> "array", "items" -> <|"type" -> "number"|>, "description" -> "新しい scale [x,y,z]"|>,
        "name" -> imProp["string", "新しい root 名 (ResoLoop_ で始める)"],
        "componentKey" -> imProp["string", "宣言の component key (例 mat-box)。member / value と一緒に使う"],
        "member" -> imProp["string", "変更するメンバー名 (例 AlbedoColor)"],
        "value" -> imProp["string", "新しい値 (JSON 表記: [0.1,0.5,0.9,1] / true / 2.5 / \"text\")"],
        "project" -> imProp["string", "resoloop プロジェクト名 (既定 VoiceBuilds)"]|>,
      "required" -> {"target"}|>|>,
  <|"name" -> "sourcevault_resonite_remove",
    "description" -> "resoloop が作った物 (ResoLoop_* の root) を消す。confirm が true でなければ何も消さず、対象名と子 Slot 数を返すだけ。利用者が明示的に同意したときだけ confirm: true で呼ぶ。",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "target" -> imProp["string", "ownership key または root Slot ID"],
        "confirm" -> imProp["boolean", "利用者が削除に同意したときだけ true"],
        "project" -> imProp["string", "resoloop プロジェクト名 (既定 VoiceBuilds)"]|>,
      "required" -> {"target"}|>|>
};

ResoLoop`ResoLoopMCPPromptDirective[] :=
  If[$Language === "Japanese",
    "Resonite の世界に関する依頼 (何があるか見る・作る・直す・消す) は mcp__sourcevault__sourcevault_resonite_* で解決する。\n" <>
    "  - 世界の中身を推測で答えない: sourcevault_resonite_query (hierarchy / find / inspect) で観測してから答える。\n" <>
    "  - 建築は sourcevault_resonite_build を 1 回呼んで jobId を受け取り、sourcevault_resonite_job_status が done になるまで\n" <>
    "    『作りました』と言わない (30 秒〜数分)。done になったら job_result の summary と capture を報告する。\n" <>
    "  - 削除は人が決める。sourcevault_resonite_remove は利用者が明示的に同意した後でだけ confirm: true にする。",
    "Requests about the Resonite world (look / build / adjust / remove) are resolved with mcp__sourcevault__sourcevault_resonite_*.\n" <>
    "  - Never guess what is in the world: observe with sourcevault_resonite_query first.\n" <>
    "  - Building is asynchronous: call sourcevault_resonite_build once, keep the jobId, and do not say it is built until\n" <>
    "    sourcevault_resonite_job_status reports done (30 s to a few minutes). Then report job_result's summary and capture.\n" <>
    "  - Deletion is the person's decision: call sourcevault_resonite_remove with confirm: true only after explicit consent."];

(* ============================================================
   結果の整形
   ============================================================ *)

imSafe[a_Association] := Map[imSafe, KeyMap[ToString, a]];
imSafe[l_List] := imSafe /@ l;
imSafe[d_DateObject] := DateString[d, "ISODateTime"];
imSafe[f_Failure] := <|"failure" -> ToString[f[[1]]], "code" -> Lookup[f[[2]], "Code", None], "message" -> ToString[Lookup[f[[2]], "MessageTemplate", ""]]|>;
imSafe[_Missing] := Null;
imSafe[x_String] := x;
imSafe[x_?NumericQ] := If[IntegerQ[x], x, N[x]];
imSafe[True] := True;
imSafe[False] := False;
imSafe[Null] := Null;
imSafe[x_] := ToString[x, InputForm];

imJSON[expr_] := ByteArrayToString[ExportByteArray[imSafe[expr], "RawJSON"], "UTF-8"];

imText[expr_] :=
  Module[{s = If[StringQ[expr], expr, imJSON[expr]]},
    If[StringLength[s] > ResoLoop`$ResoLoopMCPMaxChars,
      s = StringTake[s, ResoLoop`$ResoLoopMCPMaxChars] <> "\n... (truncated; narrow the query with under/depth/name)"];
    <|"content" -> {<|"type" -> "text", "text" -> s|>}, "isError" -> False|>];

imError[f_Failure] :=
  <|"content" -> {<|"type" -> "text", "text" -> imJSON[<|"error" -> Lookup[f[[2]], "Code", ToString[f[[1]]]],
      "message" -> ToString[Lookup[f[[2]], "MessageTemplate", ""]],
      "suggestions" -> Lookup[f[[2]], "Suggestions", {}],
      "context" -> Lookup[f[[2]], "Context", <||>]|>]|>}, "isError" -> True|>;
imError[msg_String] := <|"content" -> {<|"type" -> "text", "text" -> imJSON[<|"error" -> "InvalidArguments", "message" -> msg|>]|>}, "isError" -> True|>;

imOut[r_] := If[FailureQ[r], imError[r], imText[r]];

imProject[args_Association] := With[{p = Lookup[args, "project", None]},
  If[StringQ[p] && p =!= "", p, ResoLoop`$ResoLoopBuilderProject]];

imStr[args_Association, key_String, default_ : None] := With[{v = Lookup[args, key, default]}, If[StringQ[v] && v =!= "", v, default]];
imBool[args_Association, key_String] := TrueQ[Lookup[args, key, False]];
imInt[args_Association, key_String, default_] := With[{v = Lookup[args, key, default]}, If[IntegerQ[v], v, If[NumericQ[v], Round[v], default]]];

(* 観測結果の要約: hierarchy の children を name/id/position だけに (深さ 1 なら十分な情報量) *)
imSlim[a_Association] :=
  Module[{keep = KeyTake[a, {"id", "name", "path", "position", "isActive"}], comps, kids},
    comps = Lookup[a, "components", {}];
    kids = Lookup[a, "children", {}];
    Join[keep,
      If[ListQ[comps] && comps =!= {}, <|"components" -> (If[AssociationQ[#], Lookup[#, "type", #], #] & /@ comps)|>, <||>],
      If[ListQ[kids] && kids =!= {}, <|"children" -> (imSlim /@ Select[kids, AssociationQ])|>, <||>]]];
imSlim[x_] := x;

(* ownership key か Slot ID → root Slot の id / name / path *)
imResolveRoot[target_String, project_String] :=
  Module[{r},
    r = If[StringStartsQ[target, "Reso_"] || target === "Root",
      ResoLoop`ResoLoopInspect[target, "Depth" -> 1, "Project" -> project],
      ResoLoop`ResoLoopInspect["$slot:root", "State" -> target, "Depth" -> 1, "Project" -> project]];
    If[FailureQ[r], r,
      <|"Id" -> Lookup[r, "id", None], "Name" -> Lookup[r, "name", None], "Path" -> Lookup[r, "path", None],
        "Children" -> Length[Replace[Lookup[r, "children", {}], Except[_List] -> {}]]|>]];

(* ============================================================
   handler
   ============================================================ *)

ResoLoop`ResoLoopMCPCallTool[name_String, args_Association] :=
  Module[{project = imProject[args], r, kind, root},
    Switch[name,
      "sourcevault_resonite_status",
        r = ResoLoop`ResoLoopStatus["Project" -> project];
        imOut[If[FailureQ[r], r,
          <|"connected" -> True, "session" -> ResoLoop`ResoLoopSessionInfo[],
            "resoniteVersion" -> Lookup[r, "resoniteVersion", None], "resoniteLinkVersion" -> Lookup[r, "resoniteLinkVersion", None],
            "latencyMs" -> Lookup[r, "latencyMs", None], "privacyLevel" -> ResoLoop`ResoLoopPrivacyLevel[],
            "project" -> project,
            "jobs" -> Select[ResoLoop`ResoLoopJobs[], MemberQ[{"queued", "running"}, #["Status"]] &]|>]],

      "sourcevault_resonite_query",
        kind = imStr[args, "kind", ""];
        r = Switch[kind,
          "hierarchy",
            With[{h = ResoLoop`ResoLoopHierarchy[imStr[args, "under", "Root"], Min[imInt[args, "depth", 1], 3],
                "IncludeComponents" -> imBool[args, "includeComponents"], "Project" -> project]},
              If[FailureQ[h], h, imSlim[h]]],
          "find",
            ResoLoop`ResoLoopFind["Name" -> imStr[args, "name"], "Component" -> imStr[args, "component"],
              "Exact" -> imBool[args, "exact"], "Under" -> imStr[args, "under"], "Project" -> project],
          "inspect",
            If[!StringQ[imStr[args, "id"]], Failure["ResoLoop", <|"Code" -> "InvalidArguments", "MessageTemplate" -> "inspect には id が要ります。"|>],
              ResoLoop`ResoLoopInspect[imStr[args, "id"], "State" -> imStr[args, "state"], "Members" -> imBool[args, "members"],
                "Depth" -> imInt[args, "depth", 0], "Project" -> project]],
          "component_inspect",
            If[!StringQ[imStr[args, "id"]], Failure["ResoLoop", <|"Code" -> "InvalidArguments", "MessageTemplate" -> "component_inspect には id が要ります。"|>],
              ResoLoop`ResoLoopComponentInspect[imStr[args, "id"], "State" -> imStr[args, "state"], "Project" -> project]],
          "type_search", ResoLoop`ResoLoopTypeSearch[imStr[args, "query", ""], "Limit" -> 30, "Project" -> project],
          "type_describe", ResoLoop`ResoLoopTypeDescribe[imStr[args, "type", ""], "Member" -> imStr[args, "member"], "Project" -> project],
          "flux_node_search", ResoLoop`ResoLoopFluxNodeSearch[imStr[args, "query", ""], "Limit" -> 30, "Project" -> project],
          "flux_node_describe", ResoLoop`ResoLoopFluxNodeDescribe[imStr[args, "name", ""], "Project" -> project],
          _, Failure["ResoLoop", <|"Code" -> "InvalidArguments", "MessageTemplate" -> "kind が不正です: " <> ToString[kind]|>]];
        imOut[If[FailureQ[r], r, <|"kind" -> kind, "privacyLevel" -> ResoLoop`ResoLoopPrivacyLevel[], "data" -> r|>]],

      "sourcevault_resonite_build",
        If[!StringQ[imStr[args, "request"]], Return[imError["request が要ります。"]]];
        r = ResoLoop`ResoLoopBuildSubmit[imStr[args, "request"], "Project" -> project, "Origin" -> "MCP",
          "Placement" -> <|"User" -> Replace[imStr[args, "user"], None -> Automatic],
            "Distance" -> With[{d = Lookup[args, "distance", 1.0]}, If[NumericQ[d], d, 1.0]]|>];
        imOut[If[FailureQ[r], r,
          Join[r, <|"message" -> "建築ジョブを起動しました。sourcevault_resonite_job_status で進捗を確認し、done になるまで完了と言わないでください (30 秒〜数分)。"|>]]],

      "sourcevault_resonite_job_status",
        imOut[ResoLoop`ResoLoopJobStatus[Replace[imStr[args, "jobId"], None -> Automatic]]],

      "sourcevault_resonite_job_result",
        r = ResoLoop`ResoLoopJobResult[Replace[imStr[args, "jobId"], None -> Automatic]];
        imOut[If[FailureQ[r], r, KeyDrop[r, {"Events", "ResultText"}]]],

      "sourcevault_resonite_adjust",
        If[!StringQ[imStr[args, "target"]], Return[imError["target が要ります。"]]];
        root = imResolveRoot[imStr[args, "target"], project];
        If[FailureQ[root], Return[imError[root]]];
        r = Which[
          StringQ[imStr[args, "componentKey"]] && StringQ[imStr[args, "member"]],
            ResoLoop`ResoLoopComponentSet["$component:" <> imStr[args, "componentKey"], imStr[args, "member"],
              Lookup[args, "value", ""], "State" -> imStr[args, "target"], "Project" -> project],
          True,
            ResoLoop`ResoLoopSlotSet[root["Id"],
              "Position" -> Replace[Lookup[args, "position", None], Except[_List] -> None],
              "Rotation" -> Replace[Lookup[args, "rotation", None], Except[_List] -> None],
              "Scale" -> Replace[Lookup[args, "scale", None], Except[_List] -> None],
              "Name" -> imStr[args, "name"], "Project" -> project]];
        imOut[If[FailureQ[r], r, <|"adjusted" -> root, "result" -> r|>]],

      "sourcevault_resonite_remove",
        If[!StringQ[imStr[args, "target"]], Return[imError["target が要ります。"]]];
        root = imResolveRoot[imStr[args, "target"], project];
        If[FailureQ[root], Return[imError[root]]];
        If[!imBool[args, "confirm"],
          imText[<|"confirmRequired" -> True, "target" -> root,
            "message" -> "まだ消していません。利用者に『" <> ToString[root["Name"]] <> "』(子 Slot " <> ToString[root["Children"]] <> " 個) を消してよいか確認し、同意があれば confirm: true で呼び直してください。"|>],
          r = ResoLoop`ResoLoopSlotDelete[root["Id"], "Confirm" -> True, "Project" -> project];
          imOut[If[FailureQ[r], r, <|"removed" -> root|>]]],

      _, imError["Unknown resonite tool: " <> name]]];

(* ============================================================
   登録
   ============================================================ *)

ResoLoop`ResoLoopMCPRegister[] :=
  Module[{},
    If[!AssociationQ[SourceVault`$SourceVaultMCPExternalTools], SourceVault`$SourceVaultMCPExternalTools = <||>];
    SourceVault`$SourceVaultMCPExternalTools["resoloop"] = <|
      "Tools" -> ResoLoop`ResoLoopMCPTools[],
      "Handler" -> ResoLoop`ResoLoopMCPCallTool,
      "AllowedTools" -> ResoLoop`$ResoLoopMCPAllowedTools,
      "PromptDirective" -> ResoLoop`ResoLoopMCPPromptDirective|>;
    If[!ListQ[SourceVault`$SourceVaultServiceExtraPackages], SourceVault`$SourceVaultServiceExtraPackages = {}];
    If[!MemberQ[SourceVault`$SourceVaultServiceExtraPackages, "ResoLoop.wl"],
      AppendTo[SourceVault`$SourceVaultServiceExtraPackages, "ResoLoop.wl"]];
    (* headless CLI の AllowedTools は登録時に List で確定するので、SourceVault が先にロード済みなら再登録して合流させる *)
    If[Length[DownValues[SourceVault`SourceVaultRefreshCLIMCP]] > 0,
      Quiet @ Check[SourceVault`SourceVaultRefreshCLIMCP[], Null]];
    "resoloop"];

ResoLoop`ResoLoopMCPRegister[];

End[];
EndPackage[];
