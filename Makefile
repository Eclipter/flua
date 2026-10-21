SHELL := /bin/zsh
.PHONY: build test smoke run release wallpaper-test clean
build:
	@./scripts/build.sh
test:
	@./scripts/test.sh
smoke:
	@./scripts/smoke.sh
run: build
	@open build/Flua.app
release: build
	@./scripts/release.sh
wallpaper-test:
	@sh Sources/WallpaperExtension/build-and-test.sh
clean:
	rm -rf .build build dist
