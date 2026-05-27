import unittest

from scripts.pr_ai_review_report import (
    build_markdown,
    labels_for_review,
    normalize_review,
)


class PrAiReviewReportTest(unittest.TestCase):
    def test_normalize_keeps_low_risk_without_human_review(self):
        review = normalize_review(
            {
                "schema_version": 1,
                "risk_level": "low",
                "human_review_required": False,
                "golden_path_impact": {
                    "level": "none",
                    "paths": ["none"],
                    "reason_zh": "仅文档变化。",
                    "reason_en": "Docs only.",
                },
                "summary_zh": "低风险文档变化。",
                "summary_en": "Low-risk docs change.",
                "affected_areas": ["docs"],
                "findings": [],
                "test_gaps": [],
                "confidence": "high",
            },
            context={"pr_number": 12, "head_sha": "abc", "run_id": "99"},
        )

        self.assertEqual(review["risk_level"], "low")
        self.assertFalse(review["human_review_required"])
        self.assertEqual([label.name for label in labels_for_review(review)], ["ai: low risk"])

    def test_normalize_invalid_result_falls_back_to_critical(self):
        review = normalize_review(
            {
                "risk_level": "surprising",
                "golden_path_impact": {"level": "mystery"},
                "summary_zh": "无法判断。",
                "summary_en": "Unknown.",
                "confidence": "certain",
            },
            context={"pr_number": 13, "head_sha": "def"},
        )

        self.assertEqual(review["risk_level"], "critical")
        self.assertTrue(review["human_review_required"])
        self.assertEqual(review["golden_path_impact"]["level"], "confirmed")
        self.assertEqual(review["confidence"], "low")

    def test_build_markdown_includes_bilingual_decision_and_findings(self):
        review = normalize_review(
            {
                "risk_level": "high",
                "human_review_required": True,
                "golden_path_impact": {
                    "level": "likely",
                    "paths": ["agent_pipeline"],
                    "reason_zh": "修改了任务处理链路。",
                    "reason_en": "Task processing path changed.",
                },
                "summary_zh": "需要 maintainer 审核。",
                "summary_en": "Maintainer review is required.",
                "affected_areas": ["agent", "service"],
                "findings": [
                    {
                        "severity": "high",
                        "category": "architecture",
                        "title_zh": "Service 边界需要确认",
                        "title_en": "Service boundary needs confirmation",
                        "evidence": ["lib/data/services/example.dart"],
                        "recommendation_zh": "补充测试。",
                        "recommendation_en": "Add tests.",
                        "blocks_merge": True,
                    }
                ],
                "test_gaps": [
                    {
                        "area": "agent",
                        "gap_zh": "缺少任务失败路径测试",
                        "gap_en": "Missing task failure-path coverage",
                        "suggested_check": "flutter test test/agent",
                    }
                ],
                "confidence": "medium",
            },
            context={"pr_number": 14, "head_sha": "ghi", "run_id": "100"},
        )

        markdown = build_markdown(review)

        self.assertIn("风险等级：`高风险`", markdown)
        self.assertIn("Human review required: `YES`", markdown)
        self.assertIn("`agent_pipeline`", markdown)
        self.assertIn("Service 边界需要确认", markdown)
        self.assertIn("Service boundary needs confirmation", markdown)


if __name__ == "__main__":
    unittest.main()
