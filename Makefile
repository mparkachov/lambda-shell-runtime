.PHONY: build-layer package-layer smoke-test clean

build-layer:
	./scripts/build_layer.sh

package-layer: build-layer
	./scripts/package_layer.sh

smoke-test: build-layer
	./scripts/smoke_test.sh

clean:
	rm -rf layer/opt dist
