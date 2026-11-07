#!/bin/sh
# Runs the end-to-end test: real rendering in a hidden window, driven by scripted input.
# Screenshots land in the directory given as the first argument.
set -eu
cd "$(dirname "$0")/.."
out=${1:-build/e2e}
mkdir -p "$out"
c3c build tabla-e2e ${E2E_BUILD_FLAGS:-} >/dev/null

# A photo stored sideways, the way a phone saves one: red left, blue right, rotate 90 CW.
python3 - "$out/rotated.jpg" "$out/clipboard.png" <<'PY'
import sys
from PIL import Image
img = Image.new("RGB", (200, 100), (220, 30, 30))
img.paste((30, 30, 220), (100, 0, 200, 100))
exif = Image.Exif()
exif[0x0112] = 6
img.save(sys.argv[1], quality=95, exif=exif)
# Large enough that the clipboard owner has to use the incremental protocol.
noise = Image.effect_noise((1600, 1200), 80).convert("RGB")
noise.save(sys.argv[2])
PY

# A stand-in for zenity, so that no dialog appears on screen. It answers with one picture.
mkdir -p build/fake-bin
cat > build/fake-bin/zenity <<SH
#!/bin/sh
echo "$(cd "$out" && pwd)/clipboard.png"
SH
chmod +x build/fake-bin/zenity

cc scripts/fake_clipboard.c -lX11 -o build/fake_clipboard
build/fake_clipboard TABLA_TEST_SELECTION "$out/clipboard.png" &
owner=$!
trap 'kill $owner 2>/dev/null || true' EXIT
sleep 0.3
PATH="$PWD/build/fake-bin:$PATH" E2E_FAKE_ZENITY=1 build/tabla-e2e --e2e "$out"
