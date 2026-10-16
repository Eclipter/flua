SHELL := /bin/zsh
.PHONY: build test smoke run release native-test clean
build:
	@./scripts/build.sh
test:
	@./scripts/test.sh
smoke: build
	@./scripts/smoke.sh
run: build
	@open build/Flua.app
release: build
	@./scripts/release.sh
native-test:
	@sh experimental/WallpaperExtension/build-and-test.sh
clean:
	rm -rf .build build dist
