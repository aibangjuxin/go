#!/usr/bin/env python3
"""集群 onboarding 的校验测试。

不连真集群：这里校验的是"集群规格"本身是否合法 —— CI 里能稳定复现的那种测试。
"""
from __future__ import annotations

import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(os.path.dirname(HERE))
SPEC_FILE = os.path.join(ROOT_DIR, "cluster", "cluster-spec.json")

REQUIRED_FIELDS = ("clusterName", "region", "project", "nodePools", "requiredLabels", "onboardingSteps")
REQUIRED_STEPS = ("create-nodes", "install-addons", "register-argocd", "wait-healthy")


def load_spec() -> dict:
    with open(SPEC_FILE, encoding="utf-8") as fh:
        return json.load(fh)


def validate_spec(spec: dict) -> None:
    """规格不合法就抛 ValueError。"""
    missing = [f for f in REQUIRED_FIELDS if f not in spec]
    if missing:
        raise ValueError("集群规格缺少字段: %s" % missing)
    if not spec["nodePools"]:
        raise ValueError("nodePools 不能为空")
    for pool in spec["nodePools"]:
        for field in ("name", "machineType", "nodeCount"):
            if field not in pool:
                raise ValueError("nodePool 缺少字段 %s" % field)
        if pool["nodeCount"] < 1:
            raise ValueError("nodePool %s 的 nodeCount 必须 >= 1" % pool["name"])


def simulate_onboarding(spec: dict) -> list:
    """把 onboarding 步骤跑一遍，返回每步的结果（纯本地模拟）。"""
    validate_spec(spec)
    report = []
    for step in spec["onboardingSteps"]:
        report.append({"step": step, "status": "ok"})
    return report


class TestClusterOnboarding(unittest.TestCase):
    def test_spec_file_exists(self) -> None:
        self.assertTrue(os.path.exists(SPEC_FILE), "cluster/cluster-spec.json 不存在")

    def test_spec_is_valid(self) -> None:
        validate_spec(load_spec())  # 不抛异常即通过

    def test_missing_field_raises(self) -> None:
        spec = load_spec()
        del spec["clusterName"]
        with self.assertRaises(ValueError):
            validate_spec(spec)

    def test_empty_node_pool_raises(self) -> None:
        spec = load_spec()
        spec["nodePools"] = []
        with self.assertRaises(ValueError):
            validate_spec(spec)

    def test_zero_node_count_raises(self) -> None:
        spec = load_spec()
        spec["nodePools"][0]["nodeCount"] = 0
        with self.assertRaises(ValueError):
            validate_spec(spec)

    def test_required_labels_present(self) -> None:
        labels = load_spec()["requiredLabels"]
        self.assertIn("argocd.argoproj.io/secret-type", labels)

    def test_onboarding_steps_cover_required(self) -> None:
        steps = load_spec()["onboardingSteps"]
        for step in REQUIRED_STEPS:
            self.assertIn(step, steps)

    def test_simulate_onboarding_all_ok(self) -> None:
        report = simulate_onboarding(load_spec())
        self.assertTrue(report)
        for item in report:
            self.assertEqual(item["status"], "ok")


if __name__ == "__main__":
    unittest.main()
