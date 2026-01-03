.PHONY: build build-layer build-arm64 build-amd64 build-all package-layer package-arm64 package-amd64 package-all smoke-test test check-release delete-release delete-dev-arm64 delete-dev-amd64 delete-dev delete-release-arm64 delete-release-amd64 publish-dev-arm64 publish-dev-amd64 release aws-check aws-setup aws-setup-dev clean

SHELLSPEC ?= ./vendor/shellspec/shellspec
SHELLSPEC_ARGS ?=

build: build-layer

build-layer:
	./scripts/build_layer.sh

build-arm64:
	ARCH=arm64 ./scripts/build_layer.sh

build-amd64:
	ARCH=amd64 ./scripts/build_layer.sh

build-all:
	ARCH=all ./scripts/build_layer.sh

package-layer: build-layer
	./scripts/package_layer.sh

package-arm64: build-arm64
	ARCH=arm64 ./scripts/package_layer.sh

package-amd64: build-amd64
	ARCH=amd64 ./scripts/package_layer.sh

package-all: build-all
	ARCH=all ./scripts/package_layer.sh

smoke-test: build-layer
	./scripts/smoke_test.sh

test:
	$(SHELLSPEC) $(SHELLSPEC_ARGS) spec

check-release:
	./scripts/check_release.sh

delete-release:
	./scripts/delete_release.sh

delete-dev-arm64:
	ARCH=arm64 ./scripts/delete_dev_sar.sh

delete-dev-amd64:
	ARCH=amd64 ./scripts/delete_dev_sar.sh

delete-dev: delete-dev-arm64 delete-dev-amd64

delete-release-arm64: delete-dev-arm64

delete-release-amd64: delete-dev-amd64

publish-dev-arm64:
	./scripts/publish_dev_arm64.sh

publish-dev-amd64:
	./scripts/publish_dev_amd64.sh

release:
	./scripts/check_release.sh; status=$$?; \
	if [ $$status -eq 2 ]; then exit 0; fi; \
	if [ $$status -ne 0 ]; then exit $$status; fi; \
	$(MAKE) package-all; \
	./scripts/release.sh

aws-check:
	./scripts/aws_check.sh

aws-setup:
	./scripts/aws_setup.sh

aws-setup-dev:
	./scripts/aws_setup_dev.sh

clean:
	rm -rf layer/opt layer/arm64 layer/amd64 dist
