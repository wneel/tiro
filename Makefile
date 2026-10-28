.PHONY: app install release strings clean

# make app SIGN_IDENTITY=- builds an ad-hoc signed app; see scripts/bundle.sh.
export SIGN_IDENTITY

app:
	scripts/bundle.sh

install: app
	-osascript -e 'tell application id "org.animalert.tiro" to quit' >/dev/null 2>&1
	-pkill -x Tiro
	rm -rf ~/Applications/Tiro.app
	mkdir -p ~/Applications
	ditto dist/Tiro.app ~/Applications/Tiro.app
	open ~/Applications/Tiro.app

release:
	scripts/release.sh

# Adds every key used in the sources to Resources/Localizable.xcstrings (new keys arrive untranslated).
strings:
	rm -rf .build.nosync-strings/stringsdata
	-find .build.nosync-strings -type d -name Tiro.build -prune -exec rm -rf {} +
	mkdir -p .build.nosync-strings/stringsdata
	swift build --scratch-path .build.nosync-strings -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc .build.nosync-strings/stringsdata
	xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata .build.nosync-strings/stringsdata/*.stringsdata

clean:
	rm -rf dist .build.nosync .build.nosync-strings
