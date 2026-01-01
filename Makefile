.PHONY: build build-layer build-arm64 build-amd64 build-all package-layer package-arm64 package-amd64 package-all smoke-test test release aws-check aws-setup clean

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

release: package-all
	./scripts/release.sh

aws-check:
	./scripts/aws_check.sh

aws-setup:
	./scripts/aws_setup.sh

clean:
	rm -rf layer/opt layer/arm64 layer/amd64 dist
