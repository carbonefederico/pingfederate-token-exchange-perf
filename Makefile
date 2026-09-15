SHELL := /usr/bin/env bash

.PHONY: deploy verify smoke test monitor port-forward-admin uninstall validate keys

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

