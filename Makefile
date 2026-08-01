XCODEBUILD := xcodebuild
SCHEME := MacVolume
CONFIG := Debug
BUILD_DIR := build
XCODEBIN := $(HOME)/.local/bin

export PATH := $(XCODEBIN):$(PATH)

.PHONY: project build run clean

project:
	@xcodegen generate

build: project
	$(XCODEBUILD) -project MacVolume.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(BUILD_DIR) build

run: build
	@open $(BUILD_DIR)/Build/Products/$(CONFIG)/MacVolume.app

clean:
	@rm -rf $(BUILD_DIR) MacVolume.xcodeproj
