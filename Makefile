.PHONY: all dicts rust-test swift-test test app install previews ios-core clean

CERT_NAME ?= Talus Local Code Signing
CODESIGN_IDENTITY ?= auto
RAW_TABLES_DIR ?= ../raw-tables

CORE_LIB = Core/target/release/libwubi_core.a
CORE_HEADER = Core/include/wubi_core.h
CORE_FLAGS = -import-objc-header $(CORE_HEADER) $(CORE_LIB)
CORE_SOURCES = Core/Cargo.toml $(wildcard Core/src/*.rs) $(wildcard Core/src/bin/*.rs)

UI_SOURCES = Sources/WubiCoreBridge.swift Sources/CandidatePanel.swift Sources/SettingsWindow.swift
APP_SOURCES = $(UI_SOURCES) Sources/InputController.swift Sources/main.swift
FRAMEWORKS = -framework Cocoa -framework SwiftUI -framework InputMethodKit -framework Carbon

all: build/PrisWubi

$(CORE_LIB): $(CORE_SOURCES)
	cargo build --release --manifest-path Core/Cargo.toml

dicts: $(CORE_LIB)
	Core/target/release/build-dicts "$(RAW_TABLES_DIR)" Resources/Dicts

build/PrisWubi: $(APP_SOURCES) $(CORE_LIB) $(CORE_HEADER)
	mkdir -p build
	swiftc -O $(APP_SOURCES) $(CORE_FLAGS) $(FRAMEWORKS) -o $@

build/AppIcon.icns build/menu_icon.pdf: Scripts/DrawAssets.swift
	mkdir -p build/AppIcon.iconset
	find build/AppIcon.iconset -type f -delete
	swift Scripts/DrawAssets.swift build/icon-master.png build/menu_icon.pdf
	@for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do \
	  name=$${spec%:*}; size=$${spec#*:}; \
	  sips -z $$size $$size build/icon-master.png --out build/AppIcon.iconset/icon_$${name}.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

app: build/PrisWubi Resources/Info.plist build/AppIcon.icns build/menu_icon.pdf
	rm -rf build/PrisWubi.app
	mkdir -p build/PrisWubi.app/Contents/MacOS \
	         build/PrisWubi.app/Contents/Resources/Dicts \
	         build/PrisWubi.app/Contents/Resources/zh-Hans.lproj
	cp build/PrisWubi build/PrisWubi.app/Contents/MacOS/PrisWubi
	cp Resources/Info.plist build/PrisWubi.app/Contents/Info.plist
	cp Resources/zh-Hans.lproj/InfoPlist.strings build/PrisWubi.app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings
	cp build/AppIcon.icns build/PrisWubi.app/Contents/Resources/AppIcon.icns
	cp build/menu_icon.pdf build/PrisWubi.app/Contents/Resources/menu_icon.pdf
	cp Resources/Dicts/*.wbdict Resources/Dicts/*.wbaux build/PrisWubi.app/Contents/Resources/Dicts/
	@id="$$(sh Scripts/resolve-codesign-identity.sh "$(CODESIGN_IDENTITY)" "$(CERT_NAME)")"; \
	echo "Signing build/PrisWubi.app with identity: $$id"; \
	codesign --force --deep --sign "$$id" build/PrisWubi.app

install: app
	mkdir -p "$$HOME/Library/Input Methods"
	pkill -TERM -x PrisWubi || true
	sleep 0.4
	rm -rf "$$HOME/Library/Input Methods/PrisWubi.app"
	cp -R build/PrisWubi.app "$$HOME/Library/Input Methods/PrisWubi.app"
	swift -e 'import Carbon; let u = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Input Methods/PrisWubi.app"); TISRegisterInputSource(u as CFURL)'
	@echo "Installed to ~/Library/Input Methods/PrisWubi.app (enable 棱五笔 in System Settings -> Keyboard -> Input Sources)"

rust-test:
	cargo test --release --manifest-path Core/Cargo.toml

swift-test: $(CORE_LIB)
	mkdir -p build
	swiftc -O Sources/WubiCoreBridge.swift Tests/SwiftBridgeTests.swift $(CORE_FLAGS) -framework Foundation -framework AppKit -o build/swift-bridge-tests
	build/swift-bridge-tests

test: rust-test swift-test

previews: $(CORE_LIB)
	mkdir -p build/previews
	swiftc -O $(UI_SOURCES) Scripts/RenderPreviews.swift $(CORE_FLAGS) -framework Cocoa -framework SwiftUI -o build/render-previews
	build/render-previews build/previews

ios-core:
	rustup target add aarch64-apple-ios aarch64-apple-ios-sim
	cargo build --release --manifest-path Core/Cargo.toml --target aarch64-apple-ios
	cargo build --release --manifest-path Core/Cargo.toml --target aarch64-apple-ios-sim

clean:
	rm -rf build
	cargo clean --manifest-path Core/Cargo.toml
