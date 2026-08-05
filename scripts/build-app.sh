#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_DIR="$OUTPUT_DIR/SSClip.app"
BACKUP_APP="$OUTPUT_DIR/.SSClip.previous.app"
ICON_FILE="$PROJECT_DIR/Resources/AppIcon.icns"

if [[ ! -s "$ICON_FILE" ]]; then
    echo "Missing required app icon: $ICON_FILE" >&2
    exit 1
fi

cd "$PROJECT_DIR"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

mkdir -p "$OUTPUT_DIR"
STAGE_ROOT=$(mktemp -d "$OUTPUT_DIR/.ssclip-stage.XXXXXX")
STAGED_APP="$STAGE_ROOT/SSClip.app"

cleanup_stage() {
    if [[ -d "$STAGE_ROOT" ]]; then
        /bin/rm -R "$STAGE_ROOT"
    fi
}
trap cleanup_stage EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/SSClip" "$STAGED_APP/Contents/MacOS/SSClip"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ICON_FILE" "$STAGED_APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# Never overwrite a running executable in place. Renaming the complete bundle
# keeps already-mapped code pages intact while atomically publishing the new app.
if [[ -d "$BACKUP_APP" && ! -d "$APP_DIR" ]]; then
    mv "$BACKUP_APP" "$APP_DIR"
elif [[ -d "$BACKUP_APP" ]]; then
    /bin/rm -R "$BACKUP_APP"
fi

if [[ -d "$APP_DIR" ]]; then
    mv "$APP_DIR" "$BACKUP_APP"
    if ! mv "$STAGED_APP" "$APP_DIR"; then
        mv "$BACKUP_APP" "$APP_DIR"
        exit 1
    fi
    /bin/rm -R "$BACKUP_APP"
else
    mv "$STAGED_APP" "$APP_DIR"
fi

echo "Built $APP_DIR"
