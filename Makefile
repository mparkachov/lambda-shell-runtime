.PHONY: build build-layer package-layer smoke-test test clean

SHELLSPEC ?= ./vendor/shellspec/shellspec
SHELLSPEC_ARGS ?=

build: build-layer

build-layer:
	./scripts/build_layer.sh

package-layer: build-layer
	./scripts/package_layer.sh

smoke-test: build-layer
	./scripts/smoke_test.sh

test:
	$(SHELLSPEC) $(SHELLSPEC_ARGS) spec

clean:
	rm -rf layer/opt dist
