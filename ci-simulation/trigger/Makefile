# trigger/ —— PR 校验 + report 回填 的本地演练入口
#
#   make demo    用样例结果渲染一份 report（看最终长什么样）
#   make list    打印每个 step 的结果
#   make check   判定红绿（有 failed 就 exit 1）
#   make post    演练回填（没有 token 就只打印 payload）
#   make clean   清掉生成物
SHELL := bash
HERE := $(shell pwd)
RESULTS ?= $(HERE)/artifacts/results
REPORT  ?= $(HERE)/artifacts/report.md
SAMPLES := $(HERE)/samples

.PHONY: demo samples list check post clean

samples:
	@mkdir -p $(RESULTS)
	@cp $(SAMPLES)/*.json $(RESULTS)/

demo: samples list
	@mkdir -p $(dir $(REPORT))
	@PR_NUMBER=123 REPO_FULL_NAME=acme/platform BUILD_ID=demo-build-id \
	 PROJECT_ID=acme-proj LOCATION=us-central1 SHORT_SHA=1a2b3c4 \
	 HEAD_BRANCH=feat/example BASE_BRANCH=main TRIGGER_NAME=pr-validate-with-report \
	 RESULT_DIR=$(RESULTS) python3 $(HERE)/scripts/render_report.py --out $(REPORT)
	@echo "----- $(REPORT) -----"
	@cat $(REPORT)

list:
	@RESULT_DIR=$(RESULTS) python3 $(HERE)/scripts/ci_result.py list

check:
	@RESULT_DIR=$(RESULTS) python3 $(HERE)/scripts/ci_result.py check

post:
	@REPO=$${REPO:-acme/platform} PR_NUMBER=$${PR_NUMBER:-123} \
	 python3 $(HERE)/scripts/post_report.py --body $(REPORT) --dry-run

clean:
	@rm -rf $(HERE)/artifacts
