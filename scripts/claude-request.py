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
"""

import json
import os
import shutil
import subprocess
import sys

# Tools Claude may use for any request. Write and Edit are limited to wiki/
# (paths relative to the vault, the working directory).
ALLOWED_TOOLS = [
    "Read", "Glob", "Grep", "Skill", "TodoWrite",
    "Write(wiki/**)", "Edit(wiki/**)", "MultiEdit(wiki/**)",
    "Bash(python3 scripts/*)", "Bash(bash scripts/*)",
    "Bash(rg *)", "Bash(git status*)", "Bash(git diff*)", "Bash(git add *)", "Bash(git commit *)",
]
DISALLOWED_TOOLS = ["WebFetch", "WebSearch", "NotebookEdit"]

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


PROMPTS = {"ask": ask_prompt}


def run_claude(prompt):
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise RuntimeError("claude is not installed or not on PATH (set CLAUDE_BIN)")
    cmd = [
        claude, "-p", prompt,
        "--output-format", "json",
        "--json-schema", json.dumps(RESULT_SCHEMA),
        "--allowedTools", *ALLOWED_TOOLS,
        "--disallowedTools", *DISALLOWED_TOOLS,
        "--max-budget-usd", os.environ.get("WIKIVIEWER_MAX_BUDGET_USD", "5"),
        "--no-session-persistence",
    ]
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
        result = run_claude(make(req))
        out = {"answer_path": result.get("answer_path"), "message": result.get("message")}
        if result.get("findings"):
            out["findings"] = result["findings"]
    except Exception as e:  # reported to the app as the request's failure
        out = {"error": str(e)[:500]}
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
