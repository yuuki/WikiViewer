#!/usr/bin/env python3
"""Queues a podcast episode request (#44) for `wikiindex requests`, the same
way the app does, so a nightly LaunchAgent can ask for "today's episode":

    python3 scripts/podcast-request.py --inbox PUBLISH/inbox
    python3 scripts/podcast-request.py --inbox PUBLISH/inbox --note "wiki/concepts/X.md"
    python3 scripts/podcast-request.py --inbox PUBLISH/inbox --topic "このクラスタの対立点"

Without --note or --topic the episode is about the sources ingested today
(the newest entries of wiki/log.md). The worker runs it with
scripts/claude-request.py, which needs VOICEVOX and ffmpeg on this Mac.
"""

import argparse
import datetime
import json
import os
import tempfile
import uuid
from pathlib import Path

DEFAULT_TOPIC = ("今日 wiki/log.md に記録された取り込み(ingest)の source を、"
                 "何が新しく分かったか・既存の concept とどうつながるかを中心に紹介する回")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--inbox", required=True, type=Path)
    parser.add_argument("--note", help="vault path of the note the episode is about")
    parser.add_argument("--topic", help="what the episode is about, in words")
    args = parser.parse_args()
    request_id = uuid.uuid4()
    request = {
        "version": 1,
        "id": str(request_id).upper(),
        "kind": "podcast",
        "createdAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "device": "nightly",
        "text": args.topic or (None if args.note else DEFAULT_TOPIC),
    }
    if args.note:
        request["notePath"] = args.note
    request = {k: v for k, v in request.items() if v is not None}
    args.inbox.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=args.inbox, prefix=".podcast-", delete=False) as tmp:
        json.dump(request, tmp, ensure_ascii=False)
    os.replace(tmp.name, args.inbox / f"{request_id}.json")
    print(f"queued {request_id}")


if __name__ == "__main__":
    main()
