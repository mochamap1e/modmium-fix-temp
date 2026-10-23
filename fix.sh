#!/bin/sh
# Fetches chrome_device_policy.proto (+ imports), compiles it next to your
# script, and patches the script to decode device policy with the right type.
set -eu

TARGET="${1:-}"
if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
  echo "usage: $0 /path/to/your_script.py" >&2
  exit 1
fi
DIR=$(cd "$(dirname "$TARGET")" && pwd)
TARGET="$DIR/$(basename "$TARGET")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- 1. download protos -----------------------------------------------
fetch() {
  name=$1
  [ -s "$TMP/$name" ] && return 0
  gs="https://chromium.googlesource.com/chromium/src/+/main/components/policy/proto/$name?format=TEXT"
  gh="https://raw.githubusercontent.com/chromium/chromium/main/components/policy/proto/$name"
  if curl -fsSL "$gs" 2>/dev/null | base64 -d > "$TMP/$name" 2>/dev/null && [ -s "$TMP/$name" ]; then
    return 0
  fi
  curl -fsSL "$gh" -o "$TMP/$name" && [ -s "$TMP/$name" ]
}

echo "[1/4] Downloading protos..."
fetch chrome_device_policy.proto || { echo "Could not download chrome_device_policy.proto" >&2; exit 1; }

# Fetch imported protos (two passes covers nested imports)
for _pass in 1 2; do
  for f in "$TMP"/*.proto; do
    for imp in $(sed -n 's/^import[[:space:]]*"\(.*\)";.*/\1/p' "$f"); do
      case "$imp" in google/*) continue ;; esac
      fetch "$(basename "$imp")" || echo "  warning: could not fetch $imp"
    done
  done
done

# ---- 2. compile ----------------------------------------------------------
echo "[2/4] Compiling chrome_device_policy.proto..."

get_protoc() {
  if command -v protoc >/dev/null 2>&1; then
    PROTOC=protoc; PROTOC_INC=""; return 0
  fi

  case "$(uname -m)" in
    x86_64|amd64)  parch=x86_64 ;;
    aarch64|arm64) parch=aarch_64 ;;
    *) echo "  unsupported arch: $(uname -m)" >&2; return 1 ;;
  esac

  # Match protoc to the installed Python protobuf (4.25.3 -> 25.3, 3.20.3 -> 3.20.3)
  pyver=$(python3 -c 'import google.protobuf as p; print(p.__version__)' 2>/dev/null || true)
  case "$pyver" in
    "")  ver=25.3 ;;
    3.*) ver=$pyver ;;
    *)   ver=${pyver#*.} ;;
  esac

  PDIR="$DIR/.protoc"
  if [ ! -x "$PDIR/bin/protoc" ]; then
    echo "  downloading protoc $ver ($parch)..."
    mkdir -p "$PDIR"
    url="https://github.com/protocolbuffers/protobuf/releases/download/v$ver/protoc-$ver-linux-$parch.zip"
    curl -fsSL "$url" -o "$TMP/protoc.zip" || { echo "  download failed: $url" >&2; return 1; }
    python3 - "$TMP/protoc.zip" "$PDIR" <<'PYZ'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PYZ
    chmod +x "$PDIR/bin/protoc"
  fi

  # Test it actually runs (some ChromeOS mounts are noexec)
  "$PDIR/bin/protoc" --version >/dev/null 2>&1 || { echo "  downloaded protoc can't execute here" >&2; return 1; }
  PROTOC="$PDIR/bin/protoc"
  PROTOC_INC="-I $PDIR/include"
  return 0
}

if get_protoc; then
  # shellcheck disable=SC2086
  "$PROTOC" -I "$TMP" $PROTOC_INC --python_out="$DIR" "$TMP/chrome_device_policy.proto"
elif python3 -c 'import grpc_tools' >/dev/null 2>&1; then
  python3 -m grpc_tools.protoc -I "$TMP" --python_out="$DIR" "$TMP/chrome_device_policy.proto"
else
  echo "Could not get protoc. Try: pip install grpcio-tools" >&2
  exit 1
fi
[ -f "$DIR/chrome_device_policy_pb2.py" ] || { echo "Compile produced no pb2 file" >&2; exit 1; }

# ---- 3. patch the script ---------------------------------------------------
echo "[3/4] Patching $TARGET (backup: $TARGET.bak)..."
python3 - "$TARGET" <<'PY'
import re, shutil, sys

p = sys.argv[1]
src = open(p, encoding="utf-8").read()

if "decode_device_policy_fetch_response" in src:
    print("  already patched, skipping")
    sys.exit(0)

shutil.copy(p, p + ".bak")

# imports
old = "    import policy_common_definitions_pb2\n"
assert old in src, "could not find import block"
src = src.replace(
    old,
    old + "    import chrome_device_policy_pb2\n"
          "    from google.protobuf.json_format import MessageToDict\n",
    1,
)

# new decoder, inserted before main()
func = '''def decode_device_policy_fetch_response(blob: bytes, source="sourceCloud"):
    fetch_response = PolicyFetchResponse()
    fetch_response.ParseFromString(blob)

    policy_data = PolicyData()
    policy_data.ParseFromString(fetch_response.policy_data)
    print(f"  policy_type: {policy_data.policy_type}")

    settings = chrome_device_policy_pb2.ChromeDeviceSettingsProto()
    settings.ParseFromString(policy_data.policy_value)

    policies = {}
    for field, value in settings.ListFields():
        if hasattr(value, "DESCRIPTOR"):
            value = MessageToDict(value, preserving_proto_field_name=True)
        policies[field.name] = {
            "value": value,
            "scope": "machine",
            "level": "mandatory",
            "source": source,
        }
    return policies, policy_data

'''
assert "def main():" in src, "could not find main()"
src = src.replace("def main():", func + "def main():", 1)

# call site
pattern = (r'device_policies,\s*_,\s*_\s*=\s*decode_policy_fetch_response\('
           r'device_blob,\s*"machine",\s*args\.source\)')
src, n = re.subn(
    pattern,
    "device_policies, _ = decode_device_policy_fetch_response(device_blob, args.source)",
    src,
)
assert n == 1, "could not find the device decode call in main()"

open(p, "w", encoding="utf-8").write(src)
print("  patched")
PY

# ---- 4. sanity check -------------------------------------------------------
echo "[4/4] Syntax check..."
python3 -m py_compile "$TARGET"
echo "Done. Run your script again."
