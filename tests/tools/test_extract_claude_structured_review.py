import json
import tempfile
import unittest
from pathlib import Path

from scripts.extract_claude_structured_review import (
    extract_from_execution_file,
    parse_json_object,
)


def review(**overrides):
    data = {
        "schema_version": 1,
        "risk_level": "low",
        "human_review_required": False,
        "golden_path_impact": {
            "level": "none",
            "paths": ["none"],
            "reason_zh": "无。",
            "reason_en": "None.",
        },
        "summary_zh": "低风险。",
        "summary_en": "Low risk.",
        "affected_areas": ["docs"],
        "findings": [],
        "test_gaps": [],
        "confidence": "high",
    }
    data.update(overrides)
    return data


class ExtractClaudeStructuredReviewTest(unittest.TestCase):
    def test_parse_json_object_from_fenced_text(self):
        data = review(risk_level="medium")
        parsed = parse_json_object(f"```json\n{json.dumps(data)}\n```")

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed["risk_level"], "medium")

    def test_marks_missing_confidence_from_otherwise_complete_review(self):
        data = review(risk_level="low")
        del data["confidence"]

        parsed = parse_json_object(
            "I've reviewed the PR.\n```json\n"
            + json.dumps(data, ensure_ascii=False)
            + "\n```"
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed["confidence"], "not_provided")

    def test_rejects_review_missing_unrecoverable_required_key(self):
        data = review()
        del data["risk_level"]

        parsed = parse_json_object(json.dumps(data, ensure_ascii=False))

        self.assertIsNone(parsed)

    def test_extracts_last_assistant_json_from_execution_file(self):
        first = review(risk_level="high")
        second = review(risk_level="low")
        messages = [
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {"type": "text", "text": json.dumps(first)},
                    ]
                },
            },
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "text",
                            "text": "Here is the result:\n"
                            + json.dumps(second, ensure_ascii=False),
                        }
                    ]
                },
            },
        ]

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "claude-execution-output.json"
            path.write_text(json.dumps(messages), encoding="utf-8")

            parsed = extract_from_execution_file(path)

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed["risk_level"], "low")

    def test_extracts_result_json_with_missing_confidence_marker(self):
        data = review(risk_level="medium")
        del data["confidence"]
        messages = [
            {
                "type": "result",
                "subtype": "success",
                "result": "Done.\n```json\n"
                + json.dumps(data, ensure_ascii=False)
                + "\n```",
            }
        ]

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "claude-execution-output.json"
            path.write_text(json.dumps(messages), encoding="utf-8")

            parsed = extract_from_execution_file(path)

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed["risk_level"], "medium")
        self.assertEqual(parsed["confidence"], "not_provided")


if __name__ == "__main__":
    unittest.main()
