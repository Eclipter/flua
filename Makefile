SHELL := /bin/zsh
.PHONY: build test smoke run release wallpaper-test scroll-test lint clean
build:
	@./scripts/build.sh
lint:
	@python3 scripts/lint.py
test:
	@./scripts/test.sh
smoke:
	@./scripts/smoke.sh
scroll-test:
	@./scripts/scroll-test.sh
run: build
	@open build/Flua.app
release:
	@./scripts/release.sh
wallpaper-test:
	@sh Sources/WallpaperExtension/build-and-test.sh
clean:
	rm -rf .build build dist Sources/WallpaperExtension/Built
