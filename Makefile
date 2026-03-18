APP = Banti.app
BINARY = .build/debug/banti
BUNDLE_BINARY = $(APP)/Contents/MacOS/banti

build:
	swift build
	mkdir -p $(APP)/Contents/MacOS
	cp $(BINARY) $(BUNDLE_BINARY)
	cp Info.plist $(APP)/Contents/Info.plist

run: build
	./$(BUNDLE_BINARY)

test:
	swift test

clean:
	rm -rf .build $(APP)

.PHONY: build run test clean
