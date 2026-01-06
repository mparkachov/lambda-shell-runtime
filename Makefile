.PHONY: build build-layer build-arm64 build-amd64 build-all package-layer package-arm64 package-amd64 package-all test test-smoke test-unit test-int test-shellspec test-all check-release delete-release delete-sar delete-dev-arm64 delete-dev-amd64 delete-dev delete-release-arm64 delete-release-amd64 publish-sar publish-arm64 publish-amd64 publish-wrapper publish-all publish-dev-arm64 publish-dev-amd64 deploy-sar deploy-dev-arm64 deploy-dev-amd64 deploy-dev release aws-check aws-setup aws-setup-dev clean

ENV ?= prod
ARCH ?=
export ENV ARCH

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

test: test-smoke test-unit test-int

test-smoke:
	$(SHELLSPEC) $(SHELLSPEC_ARGS) spec/test-smoke_spec.sh

test-unit:
	$(SHELLSPEC) $(SHELLSPEC_ARGS) spec/test-unit_spec.sh

test-int:
	$(SHELLSPEC) $(SHELLSPEC_ARGS) spec/test-int_spec.sh

check-release:
	./scripts/check_release.sh

delete-release:
	./scripts/delete_release.sh

delete-sar:
	./scripts/delete_sar.sh

delete-dev-arm64:
	ENV=dev ARCH=arm64 ./scripts/delete_sar.sh

delete-dev-amd64:
	ENV=dev ARCH=amd64 ./scripts/delete_sar.sh

delete-dev: delete-dev-arm64 delete-dev-amd64

delete-release-arm64: delete-dev-arm64

delete-release-amd64: delete-dev-amd64

publish-sar:
	./scripts/publish_sar.sh

publish-arm64:
	ENV=prod ARCH=arm64 ./scripts/publish_sar.sh

publish-amd64:
	ENV=prod ARCH=amd64 ./scripts/publish_sar.sh

publish-wrapper:
	ENV=prod ARCH=wrapper ./scripts/publish_sar.sh

publish-all:
	ENV=prod ARCH=all ./scripts/publish_sar.sh

publish-dev-arm64:
	ENV=dev ARCH=arm64 ./scripts/publish_sar.sh

publish-dev-amd64:
	ENV=dev ARCH=amd64 ./scripts/publish_sar.sh

deploy-sar:
	./scripts/deploy_sar.sh

deploy-dev-arm64:
	ENV=dev ARCH=arm64 ./scripts/deploy_sar.sh

deploy-dev-amd64:
	ENV=dev ARCH=amd64 ./scripts/deploy_sar.sh

deploy-dev: deploy-dev-arm64 deploy-dev-amd64

release:
	ENV=prod ./scripts/check_release.sh; status=$$?; \
	if [ $$status -eq 2 ]; then exit 0; fi; \
	if [ $$status -ne 0 ]; then exit $$status; fi; \
	$(MAKE) package-all; \
	ENV=prod ./scripts/release.sh

aws-check:
	./scripts/aws_check.sh

aws-setup:
	./scripts/aws_setup.sh

aws-setup-dev:
	ENV=dev SKIP_SAR_PUBLISH=1 ./scripts/aws_setup.sh

clean:
	rm -rf layer/opt layer/arm64 layer/amd64 dist
