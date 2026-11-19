BINARY := .build/display-brightness-toggle
APP := .build/LumaRecall.app
PREFIX ?= $(HOME)/.local

.PHONY: all install app
all: $(BINARY)

$(BINARY): $(wildcard Sources/*.swift)
	@mkdir -p .build
	xcrun swiftc -O $^ -o $@

install: $(BINARY)
	mkdir -p "$(PREFIX)/bin"
	install -m 755 "$(BINARY)" "$(PREFIX)/bin/display-brightness-toggle"

app: $(BINARY) Resources/Info.plist
	mkdir -p "$(APP)/Contents/MacOS"
	install -m 755 "$(BINARY)" "$(APP)/Contents/MacOS/DisplayBrightness"
	install -m 644 Resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
