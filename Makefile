.PHONY: build-agent deploy run-agent

build-agent:
	cargo zigbuild --target x86_64-unknown-linux-gnu --release -p watchman-agent

deploy: build-agent
	./deploy/deploy.sh

run-agent:
	cd agent && cargo run
