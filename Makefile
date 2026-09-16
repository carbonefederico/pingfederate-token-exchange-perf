SHELL := /usr/bin/env bash

.PHONY: deploy verify smoke test monitor port-forward-admin uninstall validate keys report

deploy:
	./scripts/deploy.sh

verify:
	./scripts/verify.sh

smoke:
	./scripts/smoke.sh

test:
	./scripts/run-in-cluster.sh

keys:
	./scripts/generate-signing-key.sh $(FORCE)

monitor:
	./scripts/monitor.sh

port-forward-admin:
	./scripts/port-forward-admin.sh

uninstall:
	./scripts/uninstall.sh

validate:
	./scripts/validate.sh

# Usage: make report RUN=20260916075741  (omit RUN to use the newest results dir)
report:
	./scripts/generate-report.py $(RUN)

