#!/usr/bin/env python3
"""Publish Claude's structured PR AI review result.

The workflow that calls this script runs on trusted default-branch code. The PR
branch is treated as data: this script reads Claude's JSON result, normalizes it,
posts one sticky PR comment, and syncs labels. It never executes PR code.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sys
from typing import Any
import urllib.error
import urllib.parse
import urllib.request


COMMENT_MARKER = "<!-- memex-pr-ai-review -->"
API_VERSION = "2022-11-28"

RISK_LABELS = {
    "low": ("ai: low risk", "0e8a16", "AI review classified the PR as low risk"),
    "medium": ("ai: medium risk", "fbca04", "AI review classified the PR as medium risk"),
    "high": ("ai: high risk", "d93f0b", "AI review classified the PR as high risk"),
    "critical": ("ai: critical risk", "b60205", "AI review classified the PR as critical risk"),
}
HUMAN_REVIEW_LABEL = (
    "needs human review",
    "d93f0b",
    "AI review or policy signals require maintainer review",
)
GOLDEN_PATH_LABEL = (
    "golden path impact",
    "fbca04",
    "AI review found possible impact to a core user flow",
)

RISK_ZH = {
    "low": "低风险",
    "medium": "中风险",
    "high": "高风险",
    "critical": "严重风险",
}
RISK_EN = {
    "low": "LOW",
    "medium": "MEDIUM",
    "high": "HIGH",
    "critical": "CRITICAL",
}
GOLDEN_ZH = {
    "none": "无",
    "possible": "可能",
    "likely": "较可能",
    "confirmed": "已确认",
}
GOLDEN_EN = {
    "none": "NONE",
    "possible": "POSSIBLE",
    "likely": "LIKELY",
    "confirmed": "CONFIRMED",
}


@dataclass(frozen=True)
class Label:
    name: str
    color: str
    description: str


class GitHubApiError(RuntimeError):
    def __init__(self, *, method: str, path: str, status: int, body: str) -> None:
        self.method = method
        self.path = path
        self.status = status
        self.body = body.strip()
        super().__init__(self.__str__())

    def __str__(self) -> str:
        details = f": {self.body}" if self.body else ""
        return f"GitHub API {self.method} {self.path} failed with HTTP {self.status}{details}"


class GitHubClient:
    def __init__(self, *, repo: str, token: str) -> None:
        self.repo = repo
        self.token = token

    def _headers(self) -> dict[str, str]:
        return {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": "memex-pr-ai-review",
        }

    def request_json(
        self,
        method: str,
        path: str,
        *,
        data: dict[str, Any] | None = None,
        query: dict[str, str | int] | None = None,
    ) -> Any:
        url = path if path.startswith("https://") else f"https://api.github.com/repos/{self.repo}{path}"
        if query:
            separator = "&" if "?" in url else "?"
            url = f"{url}{separator}{urllib.parse.urlencode(query)}"
        body = None if data is None else json.dumps(data).encode("utf-8")
        headers = self._headers()
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="replace")
            raise GitHubApiError(
                method=method,
                path=path,
                status=exc.code,
                body=error_body,
            ) from exc
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))

    def issue_comments(self, pr_number: int) -> list[dict[str, Any]]:
        comments: list[dict[str, Any]] = []
        page = 1
        while True:
            data = self.request_json(
                "GET",
                f"/issues/{pr_number}/comments",
                query={"per_page": 100, "page": page},
            )
            comments.extend(data)
            if len(data) < 100:
                return comments
            page += 1

    def upsert_comment(self, *, pr_number: int, body: str) -> None:
        existing = next(
            (
                comment
                for comment in self.issue_comments(pr_number)
                if COMMENT_MARKER in (comment.get("body") or "")
            ),
            None,
        )
        if existing:
            self.request_json("PATCH", f"/issues/comments/{existing['id']}", data={"body": body})
        else:
            self.request_json("POST", f"/issues/{pr_number}/comments", data={"body": body})

    def ensure_label(self, label: Label) -> None:
        payload = {
            "name": label.name,
            "color": label.color,
            "description": label.description,
        }
        encoded = urllib.parse.quote(label.name, safe="")
        try:
            self.request_json("GET", f"/labels/{encoded}")
        except GitHubApiError as exc:
            if exc.status != 404:
                raise
            self.request_json("POST", "/labels", data=payload)
            return
        self.request_json(
            "PATCH",
            f"/labels/{encoded}",
            data={"new_name": label.name, "color": label.color, "description": label.description},
        )

    def add_labels(self, *, pr_number: int, labels: list[str]) -> None:
        if labels:
            self.request_json("POST", f"/issues/{pr_number}/labels", data={"labels": labels})

    def remove_label(self, *, pr_number: int, label: str) -> None:
        encoded = urllib.parse.quote(label, safe="")
        try:
            self.request_json("DELETE", f"/issues/{pr_number}/labels/{encoded}")
        except GitHubApiError as exc:
            if exc.status != 404:
                raise


def load_json(path: str | Path) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def require_string(value: Any, *, default: str = "") -> str:
    return value if isinstance(value, str) else default


def normalize_review(raw: dict[str, Any], *, context: dict[str, Any]) -> dict[str, Any]:
    risk_level = require_string(raw.get("risk_level"), default="critical")
    if risk_level not in RISK_LABELS:
        risk_level = "critical"

    golden = raw.get("golden_path_impact")
    golden = golden if isinstance(golden, dict) else {}
    golden_level = require_string(golden.get("level"), default="confirmed")
    if golden_level not in GOLDEN_ZH:
        golden_level = "confirmed"

    human_review_required = raw.get("human_review_required")
    if not isinstance(human_review_required, bool):
        human_review_required = risk_level in {"high", "critical"} or golden_level in {
            "likely",
            "confirmed",
        }

    normalized = {
        "schema_version": 1,
        "workflow": "PR AI Review",
        "pr_number": context.get("pr_number"),
        "head_sha": context.get("head_sha"),
        "run_id": context.get("run_id"),
        "risk_level": risk_level,
        "risk_level_zh": RISK_ZH[risk_level],
        "human_review_required": human_review_required,
        "golden_path_impact": {
            "level": golden_level,
            "level_zh": GOLDEN_ZH[golden_level],
            "paths": golden.get("paths") if isinstance(golden.get("paths"), list) else [],
            "reason_zh": require_string(golden.get("reason_zh"), default="未提供说明。"),
            "reason_en": require_string(golden.get("reason_en"), default="No rationale provided."),
        },
        "summary_zh": require_string(raw.get("summary_zh"), default="AI 未提供中文摘要。"),
        "summary_en": require_string(raw.get("summary_en"), default="AI did not provide an English summary."),
        "affected_areas": raw.get("affected_areas") if isinstance(raw.get("affected_areas"), list) else [],
        "findings": raw.get("findings") if isinstance(raw.get("findings"), list) else [],
        "test_gaps": raw.get("test_gaps") if isinstance(raw.get("test_gaps"), list) else [],
        "confidence": require_string(raw.get("confidence"), default="low"),
    }
    if normalized["confidence"] not in {"low", "medium", "high"}:
        normalized["confidence"] = "low"
    return normalized


def bool_zh(value: bool) -> str:
    return "是" if value else "否"


def bool_en(value: bool) -> str:
    return "YES" if value else "NO"


def bullet_lines(items: list[str], *, empty: str) -> list[str]:
    if not items:
        return [f"- {empty}"]
    return [f"- `{item}`" for item in items]


def build_findings_zh(findings: list[Any]) -> list[str]:
    if not findings:
        return ["- 未发现需要单独列出的风险项。"]
    lines: list[str] = []
    for item in findings:
        if not isinstance(item, dict):
            continue
        severity = require_string(item.get("severity"), default="info")
        title = require_string(item.get("title_zh"), default="未命名风险")
        recommendation = require_string(item.get("recommendation_zh"), default="")
        evidence = item.get("evidence") if isinstance(item.get("evidence"), list) else []
        evidence_text = ", ".join(str(entry) for entry in evidence[:4]) if evidence else "无明确引用"
        lines.append(f"- `{severity}` {title}。证据：{evidence_text}。")
        if recommendation:
            lines.append(f"  建议：{recommendation}")
    return lines or ["- 未发现需要单独列出的风险项。"]


def build_findings_en(findings: list[Any]) -> list[str]:
    if not findings:
        return ["- No separate risk finding was reported."]
    lines: list[str] = []
    for item in findings:
        if not isinstance(item, dict):
            continue
        severity = require_string(item.get("severity"), default="info")
        title = require_string(item.get("title_en"), default="Untitled risk")
        recommendation = require_string(item.get("recommendation_en"), default="")
        evidence = item.get("evidence") if isinstance(item.get("evidence"), list) else []
        evidence_text = ", ".join(str(entry) for entry in evidence[:4]) if evidence else "no explicit reference"
        lines.append(f"- `{severity}` {title}. Evidence: {evidence_text}.")
        if recommendation:
            lines.append(f"  Recommendation: {recommendation}")
    return lines or ["- No separate risk finding was reported."]


def build_test_gaps_zh(test_gaps: list[Any]) -> list[str]:
    if not test_gaps:
        return ["- 未发现新的测试缺口。"]
    lines: list[str] = []
    for gap in test_gaps:
        if not isinstance(gap, dict):
            continue
        area = require_string(gap.get("area"), default="unknown")
        text = require_string(gap.get("gap_zh"), default="未说明测试缺口")
        check = require_string(gap.get("suggested_check"), default="")
        suffix = f" 建议检查：`{check}`。" if check else ""
        lines.append(f"- `{area}` {text}。{suffix}")
    return lines or ["- 未发现新的测试缺口。"]


def build_test_gaps_en(test_gaps: list[Any]) -> list[str]:
    if not test_gaps:
        return ["- No new test gap was reported."]
    lines: list[str] = []
    for gap in test_gaps:
        if not isinstance(gap, dict):
            continue
        area = require_string(gap.get("area"), default="unknown")
        text = require_string(gap.get("gap_en"), default="No test gap detail provided")
        check = require_string(gap.get("suggested_check"), default="")
        suffix = f" Suggested check: `{check}`." if check else ""
        lines.append(f"- `{area}` {text}.{suffix}")
    return lines or ["- No new test gap was reported."]


def build_markdown(review: dict[str, Any]) -> str:
    risk = review["risk_level"]
    golden = review["golden_path_impact"]
    affected = [str(item) for item in review.get("affected_areas", [])]
    paths = [str(item) for item in golden.get("paths", [])]
    run_id = review.get("run_id")
    run_line = f"- Workflow run：`{run_id}`" if run_id else "- Workflow run：unknown"
    run_line_en = f"- Workflow run: `{run_id}`" if run_id else "- Workflow run: unknown"

    lines = [
        COMMENT_MARKER,
        "# PR AI Review / PR AI 语义预检",
        "",
        "## 中文",
        "",
        f"- 风险等级：`{RISK_ZH[risk]}`",
        f"- 需要人工审核：`{bool_zh(review['human_review_required'])}`",
        f"- 黄金链路影响：`{GOLDEN_ZH[golden['level']]}`",
        f"- 置信度：`{review['confidence']}`",
        run_line,
        "",
        review["summary_zh"],
        "",
        "### 影响范围",
        *bullet_lines(affected, empty="未识别到特定影响范围。"),
        "",
        "### 黄金链路",
        *bullet_lines(paths, empty="未识别到黄金链路影响。"),
        f"- 说明：{golden['reason_zh']}",
        "",
        "### 风险项",
        *build_findings_zh(review.get("findings", [])),
        "",
        "### 测试缺口",
        *build_test_gaps_zh(review.get("test_gaps", [])),
        "",
        "## English",
        "",
        f"- Risk level: `{RISK_EN[risk]}`",
        f"- Human review required: `{bool_en(review['human_review_required'])}`",
        f"- Golden path impact: `{GOLDEN_EN[golden['level']]}`",
        f"- Confidence: `{review['confidence']}`",
        run_line_en,
        "",
        review["summary_en"],
        "",
        "### Affected Areas",
        *bullet_lines(affected, empty="No specific affected area was identified."),
        "",
        "### Golden Path",
        *bullet_lines(paths, empty="No golden path impact was identified."),
        f"- Rationale: {golden['reason_en']}",
        "",
        "### Findings",
        *build_findings_en(review.get("findings", [])),
        "",
        "### Test Gaps",
        *build_test_gaps_en(review.get("test_gaps", [])),
        "",
        "> AI review is advisory. Maintainers should verify the result before merging.",
        "",
    ]
    return "\n".join(lines)


def labels_for_review(review: dict[str, Any]) -> list[Label]:
    labels = [Label(*RISK_LABELS[review["risk_level"]])]
    if review["human_review_required"]:
        labels.append(Label(*HUMAN_REVIEW_LABEL))
    if review["golden_path_impact"]["level"] != "none":
        labels.append(Label(*GOLDEN_PATH_LABEL))
    return labels


def sync_labels(client: GitHubClient, *, pr_number: int, review: dict[str, Any]) -> None:
    managed = [Label(*value).name for value in RISK_LABELS.values()]
    managed.extend([HUMAN_REVIEW_LABEL[0], GOLDEN_PATH_LABEL[0]])
    for name in managed:
        client.remove_label(pr_number=pr_number, label=name)

    labels = labels_for_review(review)
    for label in labels:
        client.ensure_label(label)
    client.add_labels(pr_number=pr_number, labels=[label.name for label in labels])


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Publish PR AI review result.")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr-number", required=True, type=int)
    parser.add_argument("--context", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--json-output", required=True)
    parser.add_argument("--markdown-output", required=True)
    parser.add_argument("--token-env", default="GITHUB_TOKEN")
    parser.add_argument("--post-comment", action="store_true")
    parser.add_argument("--sync-labels", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    context = load_json(args.context)
    raw = load_json(args.result)
    review = normalize_review(raw, context=context)
    markdown = build_markdown(review)

    Path(args.json_output).write_text(
        json.dumps(review, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    Path(args.markdown_output).write_text(markdown, encoding="utf-8")

    if args.post_comment or args.sync_labels:
        token = os.environ.get(args.token_env)
        if not token:
            print(f"::warning::{args.token_env} is not set; skipping GitHub mutations.")
            return 0
        client = GitHubClient(repo=args.repo, token=token)
        if args.post_comment:
            client.upsert_comment(pr_number=args.pr_number, body=markdown)
        if args.sync_labels:
            sync_labels(client, pr_number=args.pr_number, review=review)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
