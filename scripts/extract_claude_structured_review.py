#!/usr/bin/env python3
"""Extract Memex PR AI review JSON from Claude Code Action output."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Iterable


REQUIRED_KEYS = {
    "schema_version",
    "risk_level",
    "human_review_required",
    "golden_path_impact",
    "summary_zh",
    "summary_en",
    "affected_areas",
    "findings",
    "test_gaps",
    "confidence",
}

RECOVERABLE_DEFAULTS = {
    "confidence": "not_provided",
}

REVIEW_SIGNAL_KEYS = REQUIRED_KEYS.difference({"schema_version"})


def _candidate_review(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None

    missing = REQUIRED_KEYS.difference(value)
    unrecoverable = missing.difference(RECOVERABLE_DEFAULTS)
    if unrecoverable:
        if len(REVIEW_SIGNAL_KEYS.intersection(value)) >= 2:
            print(
                "::warning::Claude PR review JSON missing unrecoverable "
                f"required keys: {', '.join(sorted(unrecoverable))}.",
            )
        return None

    if not missing:
        return value

    recovered = dict(value)
    for key in sorted(missing):
        recovered[key] = RECOVERABLE_DEFAULTS[key]
    print(
        "::warning::Claude PR review JSON missing required keys: "
        f"{', '.join(sorted(missing))}; marked recoverable fields as not_provided.",
    )
    return recovered


def parse_json_object(text: str) -> dict[str, Any] | None:
    text = text.strip()
    if not text:
        return None

    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", text, flags=re.DOTALL)
    if fenced:
        text = fenced.group(1).strip()

    decoder = json.JSONDecoder()
    for index, char in enumerate(text):
        if char != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        review = _candidate_review(value)
        if review is not None:
            return review
    return None


def extract_texts(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
        return
    if isinstance(value, list):
        for item in value:
            yield from extract_texts(item)
        return
    if not isinstance(value, dict):
        return

    text = value.get("text")
    if isinstance(text, str):
        yield text

    structured = value.get("structured_output")
    if isinstance(structured, dict):
        yield json.dumps(structured, ensure_ascii=False)

    result = value.get("result")
    if isinstance(result, str):
        yield result

    message = value.get("message")
    if isinstance(message, dict):
        yield from extract_texts(message.get("content"))

    content = value.get("content")
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                yield block["text"]
            else:
                yield from extract_texts(block)
    elif isinstance(content, str):
        yield content


def extract_from_execution_file(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    value = json.loads(path.read_text(encoding="utf-8"))
    messages = value if isinstance(value, list) else [value]
    for message in reversed(messages):
        for text in extract_texts(message):
            parsed = parse_json_object(text)
            if parsed:
                return parsed
    return None


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract Claude PR review JSON.")
    parser.add_argument("--structured-env", default="STRUCTURED_OUTPUT")
    parser.add_argument("--execution-file-env", default="EXECUTION_FILE")
    parser.add_argument("--output", required=True)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    structured = os.environ.get(args.structured_env, "").strip()
    parsed = parse_json_object(structured)

    if parsed is None:
        execution_file = os.environ.get(args.execution_file_env, "").strip()
        if execution_file:
            parsed = extract_from_execution_file(Path(execution_file))

    if parsed is None:
        print("::warning::Could not extract Claude PR review JSON.")
        return 0

    Path(args.output).write_text(
        json.dumps(parsed, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
