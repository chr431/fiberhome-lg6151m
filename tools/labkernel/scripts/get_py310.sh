#!/bin/bash
# get_py310.sh -- fetch uv, install standalone CPython 3.10 (for MTK sign tool
# .pyc-only lib), print the interpreter path.
set -eu
LK="$HOME/lab-kernel"
cd "$LK"
if [ ! -x uv/uv ]; then
    mkdir -p uv
    for i in 1 2 3 4 5; do
        curl -fL --speed-limit 20000 --speed-time 20 --max-time 180 \
             -o uv.tar.gz \
             https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz && break
        sleep 2
    done
    tar xf uv.tar.gz -C uv --strip-components=1
fi
export UV_PYTHON_INSTALL_DIR="$LK/uv-python"
./uv/uv python install cpython-3.10.14
find "$LK/uv-python" -name "python3.10" -type f | head -3
echo GET_PY310_DONE
