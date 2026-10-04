.PHONY: build-agent build-agent-windows deploy deploy-windows run-agent

build-agent:
	cargo zigbuild --target x86_64-unknown-linux-gnu --release -p watchman-agent

build-agent-windows:
	cargo zigbuild --target x86_64-pc-windows-gnu --release -p watchman-agent

deploy: build-agent
	./deploy/deploy.sh

deploy-windows: build-agent-windows
	./deploy/deploy-windows.sh

run-agent:
	cd agent && cargo run
