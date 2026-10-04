#!/usr/bin/env python3
"""Runner for `wikiindex requests`: hands one request from WikiViewer to
Claude Code running in the vault, and prints one JSON line with the result.

    wikiindex requests --publish DIR --vault DIR --runner scripts/claude-request.py

wikiindex runs this with the request file (a HostRequest, see
WikiKit/Sources/WikiShared/HostRequest.swift) as the only argument and the
vault as the working directory. The last line printed is read back:

    {"answer_path": "wiki/asks/@....md", "message": "..."}
    {"error": "why it failed"}

What Claude may do is confined here, not in the app or in wikiindex:
- tools: reading the vault, the Skill tool, the vault's own scripts, git
  add/commit, and Write/Edit only under wiki/; no web access, no other
  shell commands (see THREAT_MODEL.md, "Requests from the app");
- the request text is the reader's own and is quoted as data in the
  prompt, never as instructions to follow without the skill's rules.

Environment:
  CLAUDE_BIN                 claude executable (default: claude on PATH)
  WIKIVIEWER_CLAUDE_MODEL    --model to pass, if set
  WIKIVIEWER_MAX_BUDGET_USD  --max-budget-usd (default 5)
  WIKIVIEWER_DRY_RUN=1       print the prompt and command, run nothing
  WIKIVIEWER_PODCAST_WORK    scratch folder for podcast episodes (default
                             ~/Library/Application Support/WikiIndexer/podcast-work)
  VOICEVOX_URL               the VOICEVOX engine (default http://127.0.0.1:50021)
"""

import datetime
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

# Tools Claude may use for any request. Write and Edit are limited to wiki/
# (paths relative to the vault, the working directory).
ALLOWED_TOOLS = [
    "Read", "Glob", "Grep", "Skill", "TodoWrite",
    "Write(wiki/**)", "Edit(wiki/**)", "MultiEdit(wiki/**)",
    "Bash(python3 scripts/*)", "Bash(bash scripts/*)",
    "Bash(rg *)", "Bash(git status*)", "Bash(git diff*)", "Bash(git add *)", "Bash(git commit *)",
]
DISALLOWED_TOOLS = ["WebFetch", "WebSearch", "NotebookEdit"]
# Podcast episodes (#44): the explainer-studio audio skills write a guide
# plan, a dialogue, a VOICEVOX script and the audio in a scratch folder
# outside the vault; only the finished m4a and the episode note go into the
# vault, under these folders.
PODCAST_NOTES = "wiki/podcasts"
PODCAST_AUDIO = "Attachments/podcasts"


def podcast_work():
    return Path(os.environ.get("WIKIVIEWER_PODCAST_WORK")
                or Path.home() / "Library/Application Support/WikiIndexer/podcast-work").resolve()


def podcast_tools(work):
    return [
        "Read", "Glob", "Grep", "Skill", "TodoWrite",
        f"Write({PODCAST_NOTES}/**)", f"Write({PODCAST_AUDIO}/**)", f"Write(/{work}/**)", f"Edit(/{work}/**)",
        "Bash(*dialogue-to-audio.sh*)", "Bash(ffmpeg *)", "Bash(ffprobe *)", "Bash(afinfo *)",
        "Bash(python3 scripts/*)", "Bash(mkdir -p *)",
    ]


def voicevox_ready():
    """The engine answers, or the VOICEVOX app is installed (the narrate
    script starts it)."""
    url = os.environ.get("VOICEVOX_URL", "http://127.0.0.1:50021").rstrip("/") + "/version"
    try:
        with urllib.request.urlopen(url, timeout=3):
            return True
    except Exception:
        return Path("/Applications/VOICEVOX.app").exists()


# Kinds that only read the vault (the answer travels back in the status).
READ_ONLY_KINDS = {"explain"}
READ_ONLY_TOOLS = ["Read", "Glob", "Grep"]
READ_ONLY_DISALLOWED = DISALLOWED_TOOLS + ["Write", "Edit", "MultiEdit", "Bash"]

RESULT_SCHEMA = {
    "type": "object",
    "properties": {
        "answer_path": {"type": ["string", "null"], "description": "vault-relative path of the note written, or null"},
        "message": {"type": "string", "description": "one or two sentences in Japanese for the reader"},
        "findings": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string", "enum": ["missing", "misconception"]},
                    "text": {"type": "string"},
                    "heading": {"type": ["string", "null"]},
                },
                "required": ["kind", "text"],
            },
        },
    },
    "required": ["answer_path", "message"],
}

QUESTIONS = {
    "verify": "この部分の主張は本当か(wiki のソースがどこまで支持するか)",
    "premise": "この部分は何を前提にしているか",
    "counterexample": "この部分への反例や、成り立たない条件はあるか",
}


def quoted(text):
    """Request text as a fenced block: data to answer, not instructions."""
    fence = "~~~~"
    while fence in text:
        fence += "~"
    return f"{fence}\n{text}\n{fence}"


def describe_note(req):
    lines = [f"対象ノート: `{req['notePath']}`" + (f"(題: {req['noteTitle']})" if req.get("noteTitle") else "")]
    if req.get("heading"):
        lines.append(f"見出し: {req['heading']}")
    if req.get("excerpt"):
        lines.append("読者が選んだ段落:\n" + quoted(req["excerpt"]))
    return "\n".join(lines)


def ask_prompt(req):
    question = req.get("question")
    asked = QUESTIONS.get(question, "")
    if req.get("text"):
        asked = (asked + "\n補足: " if asked else "") + req["text"]
    note = req["notePath"]
    if question == "verify":
        route = (
            "wiki-thesis skill に従い、問いを命題に直して判定し、`wiki/questions/` に `type: thesis` のページを書く。"
            "`origin` か `related` に対象ノートへのリンクを入れる。"
        )
    elif note.startswith("wiki/sources/"):
        route = (
            "wiki-ask-source skill に従い、この source の ask ページ(`wiki/asks/` の同じ basename)に今日の日付の節で "
            "Q&A を積み、source 側の `asks:` で相互リンクする。"
        )
    else:
        route = (
            "wiki-query skill の standard モードで答え、回答を `wiki/questions/` に保存する。"
            "frontmatter の `related` に対象ノートへのリンクを入れる。"
        )
    return f"""WikiViewer(読み取り専用のビューワ)で読者がノートを読みながら出した質問に答える。

{describe_note(req)}

質問:
{quoted(asked)}

手順: {route}
vault の CLAUDE.md と wiki/CLAUDE.md の規約(既存ノートを書き換えない、日本語常体、出典)に従う。
書き込めるのは `wiki/` 配下だけである。Web は使えない。答えられなければ、その旨をノートではなく message に書く。
最後に、書いたノートの vault 相対パスを answer_path に、読者向けの一言を message に入れて返す。"""


def path_prompt(req):
    start = ""
    if req.get("notePath"):
        start = f"\n読者はノート `{req['notePath']}` を読んでいて、ここから始めたい。"
    return f"""WikiViewer の読者が、ある主題を理解するための読む順番(学習経路)を求めている。{start}

主題:
{quoted(req['text'])}

vault に既にあるノート(wiki の concept / source / entity と、一次レイヤーのノート)を、前提になるものが先に来る順に並べた学習経路ノートを 1 枚書く。
- 前提関係の根拠は、リンクグラフ(wiki-related の配役つき近傍、とくに definition の役)と各ページの定義節で判断する。根拠のない順番は付けない。
- 材料が欠けている箇所は、wiki-gap の考え方で「橋渡し文献が要る」段として明示する。最新の `wiki/meta/gap-report-*.md` に該当する候補があればリンクする。
- 書き込めるのは `wiki/` 配下だけである。既存ノートは書き換えない。Web は使えない。

置き場所と形式(アプリはこの形式を読む):
- パス: `wiki/paths/<主題>.md`(同名があれば日付を付ける)。
- frontmatter は vault の規約(wiki/meta/conventions.md §2)に従い、`type: path`、`topic: "<主題>"`、`status: seed` を持つ。
- 本文の `## 経路` 節に、**行頭から始まる番号付きリスト**で段を書く。1 段 = 1 行。段の最初の wikilink がその段で読むノートで、続けて「— なぜこの位置か」を一文で書く。見出しを指すなら `[[ノート#見出し]]`。
- 橋渡し文献が要る段は wikilink を置かず、「橋渡し: <欠けている話題> — <何が欠けていて、どんな文献が要るか>」と書く。
- 補足は番号付きリストの外(段の下の字下げした箇条書きや別の節)に書く。

最後に、書いたノートの vault 相対パスを answer_path に、読者向けの一言を message に入れて返す。"""


def explain_prompt(req):
    return f"""WikiViewer の読者が、ノートを読んだあと自分の言葉で要点を説明した。説明をノートと照合する。

対象ノート: `{req['notePath']}`(題: {req.get('noteTitle') or ''})

読者の説明(音声入力の書き起こしを含む。誤字は気にしない):
{quoted(req['text'])}

ノートを Read で読み、説明と照合して、次の 2 種類だけを findings に返す。褒め言葉や言い換えの提案は要らない。
- kind "missing": ノートの要点なのに説明から抜けているもの
- kind "misconception": ノートの記述と食い違う、または誤解しているもの
各項目の text は 1〜2 文の日本語常体で、何がどう違うかを具体的に書く。heading にはその点が書かれているノートの見出し(`#` は付けない。無ければ null)。
抜けも誤解も無ければ findings は空にし、message に一言そう書く。
ファイルは書かない(answer_path は null)。Web は使えない。"""


def podcast_prompt(req):
    today = datetime.date.today().isoformat()
    work = podcast_work() / req.get("id", "episode").lower()
    if req.get("notePath"):
        subject = f"ノート `{req['notePath']}`(題: {req.get('noteTitle') or ''})と、その出典・関連ページ"
    else:
        subject = "次の主題に関わる vault のページ"
    extra = f"\n主題・指示:\n{quoted(req['text'])}" if req.get("text") else ""
    return f"""vault の内容から、2 人の掛け合いで聴く音声の回(ポッドキャスト)を 1 本作る。
材料: {subject}{extra}

手順:
1. 材料のページを読み、聴き手が復習できるよう要点・対立点・未解決の問いを含む Markdown の台本素材を
   作業フォルダ `{work}` に書く(vault には書かない)。引用元のページ名を残す。
2. その Markdown を出発点に explainer-studio の explainer-audio-guide skill で音声まで作る(既定の 2 人の配役、
   10〜20 分)。中間生成物はすべて作業フォルダに置く。
3. 章のタイムスタンプ: Guide plan の節ごとに台本を分けて合成し、ffmpeg で連結し、ffprobe の長さの累積を各章の開始時刻にする。
   分けられないときは章を時刻なしの箇条書きにする。
4. 完成した m4a を ffmpeg で `{PODCAST_AUDIO}/{today} <題>.m4a` に書き出し(cp や mv は使えない)、回のノートを `{PODCAST_NOTES}/{today} <題>.md` に書く。
   frontmatter(vault の規約の日付タグなどに加えて): `type: episode`、`audio: "[[{today} <題>.m4a]]"`、`date: {today}`、
   `duration: <秒>`、`sources:` に材料のページ。本文の `## 章` に `- [mm:ss] 話題 [[ページ#見出し]]` の行を並べる
   (各章が主に扱うページへリンクする)。
書き込めるのは `{PODCAST_NOTES}/`・`{PODCAST_AUDIO}/`・作業フォルダだけ。既存ノートは書き換えない。Web は使えない。
最後に、回のノートの vault 相対パスを answer_path に、読者向けの一言(長さを含む)を message に入れて返す。"""


PROMPTS = {"ask": ask_prompt, "path": path_prompt, "explain": explain_prompt, "podcast": podcast_prompt}


def run_claude(prompt, read_only=False, tools=None, add_dirs=()):
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise RuntimeError("claude is not installed or not on PATH (set CLAUDE_BIN)")
    cmd = [
        claude, "-p", prompt,
        "--output-format", "json",
        "--json-schema", json.dumps(RESULT_SCHEMA),
        "--allowedTools", *(tools or (READ_ONLY_TOOLS if read_only else ALLOWED_TOOLS)),
        "--disallowedTools", *(READ_ONLY_DISALLOWED if read_only else DISALLOWED_TOOLS),
        "--max-budget-usd", os.environ.get("WIKIVIEWER_MAX_BUDGET_USD", "5"),
        "--no-session-persistence",
    ]
    for d in add_dirs:
        cmd += ["--add-dir", str(d)]
    if os.environ.get("WIKIVIEWER_CLAUDE_MODEL"):
        cmd += ["--model", os.environ["WIKIVIEWER_CLAUDE_MODEL"]]
    if os.environ.get("WIKIVIEWER_DRY_RUN") == "1":
        print(prompt, file=sys.stderr)
        print(cmd[:2] + ["<prompt>"] + cmd[3:], file=sys.stderr)
        return {"answer_path": None, "message": "dry run"}
    proc = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    sys.stderr.write(proc.stderr[-4000:])
    if proc.returncode != 0:
        # With --output-format json the reason (e.g. an expired login) is
        # in the envelope on stdout, not on stderr.
        try:
            reason = json.loads(proc.stdout).get("result")
        except ValueError:
            reason = None
        raise RuntimeError(f"claude exited with {proc.returncode}: {reason or proc.stderr.strip()[-300:]}")
    return parse_output(proc.stdout)


def parse_output(stdout):
    """The structured result from `claude -p --output-format json`."""
    envelope = json.loads(stdout)
    if envelope.get("is_error"):
        raise RuntimeError(str(envelope.get("result") or envelope.get("subtype") or "claude reported an error"))
    result = envelope.get("structured_output")
    if result is None:
        text = (envelope.get("result") or "").strip()
        start, end = text.find("{"), text.rfind("}")
        result = json.loads(text[start:end + 1]) if start >= 0 and end > start else {"answer_path": None, "message": text[:500]}
    return result


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1], encoding="utf-8") as f:
        req = json.load(f)
    try:
        make = PROMPTS.get(req.get("kind"))
        if make is None:
            raise RuntimeError(f"this runner does not handle {req.get('kind')!r} requests")
        if req.get("kind") == "podcast":
            if not voicevox_ready():
                raise RuntimeError("VOICEVOX is not installed or not running on this Mac (see SETUP.md, Audio episodes)")
            if not shutil.which("ffmpeg"):
                raise RuntimeError("ffmpeg is not installed on this Mac")
            work = podcast_work() / req.get("id", "episode").lower()
            work.mkdir(parents=True, exist_ok=True)
            result = run_claude(make(req), tools=podcast_tools(work), add_dirs=[work])
        else:
            result = run_claude(make(req), read_only=req.get("kind") in READ_ONLY_KINDS)
        if req.get("kind") in READ_ONLY_KINDS:
            result["answer_path"] = None
        out = {"answer_path": result.get("answer_path"), "message": result.get("message")}
        if result.get("findings"):
            out["findings"] = result["findings"]
    except Exception as e:  # reported to the app as the request's failure
        out = {"error": str(e)[:500]}
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
