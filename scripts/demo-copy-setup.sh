# Source this script from demo.tape on Linux. The temporary cp wrapper runs
# GNU cp with delayed reads so small files show visible progress. It is only
# used by the recording shell; zpg does not need this wrapper or strace.

command -v strace >/dev/null || return 1
ZPG_DEMO_REAL_CP=$(command -v cp)
export ZPG_DEMO_REAL_CP
zpg_demo_exe=$(realpath "$(command -v zpg)")
zpg_demo_dir=$(mktemp -d -t zpg-demo-copy.XXXXXXXX)
trap 'rm -rf -- "$zpg_demo_dir"' EXIT

mkdir -p "$zpg_demo_dir/bin"
ln -s "$zpg_demo_exe" "$zpg_demo_dir/bin/zpg"
python3 - "$zpg_demo_dir" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]) / 'source'
for name in ('index.bin', 'assets/texture.bin', 'data/records.bin'):
    path = source / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'x' * (2 * 1024 * 1024))
PY

# Disable cloning, sparse copying, and copy_file_range so cp uses read/write.
# strace delays each read by 300 ms and sends its own trace to /dev/null.
cat > "$zpg_demo_dir/bin/cp" <<'SH'
#!/bin/sh
exec strace -qq -o /dev/null \
    -e trace=read,copy_file_range \
    -e inject=copy_file_range:error=ENOSYS \
    -e inject=read:delay_enter=300ms \
    "$ZPG_DEMO_REAL_CP" --reflink=never --sparse=never "$@"
SH
chmod +x "$zpg_demo_dir/bin/cp"
export PATH="$zpg_demo_dir/bin:$PATH"
cd "$zpg_demo_dir" || return 1
