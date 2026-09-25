#!/bin/bash
# boot.sh — เปิด pod MiniMax H3 แบบล็อกเวอร์ชัน
# ทุกอย่างอยู่ใน Network Volume ที่ /workspace/h3 ติดตั้งครั้งเดียว ครั้งต่อไปแค่เปิด ComfyUI
# ไม่มีการอัปเดตเองเด็ดขาด: จะเปลี่ยนเวอร์ชันต้องแก้ lock.env + เพิ่ม LOCK_VERSION เท่านั้น

H3=/workspace/h3
LOG=$H3/logs/boot.log
mkdir -p "$H3/logs"
exec > >(tee -a "$LOG") 2>&1
echo "==================== BOOT $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===================="

# บริการพื้นฐานของ RunPod (ssh / jupyter / nginx) — เปิดไว้ก่อน จะได้ดู log ได้ระหว่างติดตั้ง
if [ -x /start.sh ]; then nohup /start.sh > "$H3/logs/runpod_start.log" 2>&1 & fi

# ---------- สถานะสำหรับแอป: ก่อน ComfyUI ขึ้น พอร์ต 8188 ตอบ /h3_status.json ----------
# state = booting | installing | models | starting | fatal  ·  code = รหัสปัญหา (แอปแปลเป็นไทยเอง)
mkdir -p /tmp/h3s
status() { printf '{"state":"%s","code":"%s","lock":"%s"}
' "$1" "${2:-}" "${LOCK_VERSION:-}" > /tmp/h3s/h3_status.json; }
status_server_on() { python3 -m http.server 8188 --bind 0.0.0.0 --directory /tmp/h3s > /dev/null 2>&1 & SPID=$!; }
status_server_off() { [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; SPID=""; }
fatal() { echo "FATAL[$1]: $2"; status fatal "$1"; [ -z "$SPID" ] && status_server_on; sleep infinity; }
status booting
status_server_on

# เครื่องที่ไดรเวอร์รองรับ CUDA ต่ำกว่า 13 ใช้ torch cu130 ไม่ได้
CV=$(nvidia-smi 2>/dev/null | grep -o "CUDA Version: [0-9]*" | grep -o "[0-9]*$")
echo "driver CUDA: ${CV:-?}"
if [ -n "$CV" ] && [ "$CV" -lt 13 ]; then fatal CUDA_TOO_OLD "เครื่องนี้รองรับ CUDA $CV ต่ำกว่า 13 — ปิดแล้วจองเครื่องใหม่"; fi

# ---------- ไฟล์ล็อก: เอาจาก GitHub (commit ที่เทมเพลตชี้) ถ้าไม่ได้ใช้สำเนาใน volume ----------
if [ -n "$H3_RAW" ] && curl -fsSL --retry 3 "$H3_RAW/lock.env" -o /tmp/lock.env; then
    cp /tmp/lock.env "$H3/lock.env"
    curl -fsSL --retry 3 "$H3_RAW/boot.sh" -o "$H3/boot.sh" || true
    curl -fsSL --retry 3 "$H3_RAW/requirements-lock.txt" -o /tmp/requirements-lock.txt 2>/dev/null \
        && cp /tmp/requirements-lock.txt "$H3/requirements-lock.txt" || rm -f "$H3/requirements-lock.txt"
    echo "lock.env from $H3_RAW"
elif [ -f "$H3/lock.env" ]; then
    echo "GitHub unreachable — using cached $H3/lock.env"
else
    fatal NO_LOCK "no lock.env (set H3_RAW in the template)"
fi
source "$H3/lock.env"

# กันลืมเลือก Network Volume: ถ้ายังไม่เคยติดตั้งและ /workspace มีที่ว่างไม่ถึง 60 GB = ไม่ได้ต่อ Volume
if [ ! -f "$H3/installed_version" ] && [ "$(df -BG --output=avail /workspace | tail -1 | tr -dc 0-9)" -lt 60 ]; then
    fatal NO_VOLUME "ไม่พบ Network Volume h3-studio — ปิด pod นี้ แล้ว Deploy ใหม่โดยเลือก Network volume: h3-studio"
fi

PY_SYS=$(command -v python3.12 || command -v python3)
VENV=$H3/venv
COMFY=$H3/ComfyUI
export PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

# ---------- ติดตั้ง (เฉพาะครั้งแรก หรือเมื่อ LOCK_VERSION เปลี่ยน) ----------
install_all() {
    echo ">>> INSTALL lock v$LOCK_VERSION"
    rm -rf "$VENV" "$COMFY.new"
    # venv ใช้ torch ของ base image (ล็อกด้วย tag+digest ของเทมเพลต) — torch อยู่บนดิสก์เครื่อง โหลดเร็วกว่า volume
    "$PY_SYS" -m venv --system-site-packages "$VENV" || return 1
    local PIP="$VENV/bin/python -m pip"
    $PIP freeze --all 2>/dev/null | grep -Ei '^(torch|torchvision|torchaudio|triton)==' > "$H3/constraints.txt"
    echo "torch from base image:"; cat "$H3/constraints.txt"
    # torchvision/torchaudio ต้องมาจาก index cu130 ให้ตรงกับ torch ของ image
    # (ถ้าปล่อยให้ pip ดึงจาก PyPI จะได้ตัวที่ไม่เข้ากัน → "operator torchvision::nms does not exist")
    local TV; TV=$(grep -i '^torch==' "$H3/constraints.txt" | cut -d= -f3)
    case "$TV" in 2.9.1*) VIS=0.24.1 ;; *) echo "unknown torch $TV — add its torchvision version"; return 1 ;; esac
    local CU="+${TV#*+}"
    grep -qi '^torchvision==' "$H3/constraints.txt" || \
        { $PIP install --no-deps "torchvision==$VIS$CU" --index-url https://download.pytorch.org/whl/cu130 || return 1; }
    grep -qi '^torchaudio==' "$H3/constraints.txt" || \
        { $PIP install --no-deps "torchaudio==${TV%%+*}$CU" --index-url https://download.pytorch.org/whl/cu130 || return 1; }
    $PIP freeze --all 2>/dev/null | grep -Ei '^(torch|torchvision|torchaudio|triton)==' > "$H3/constraints.txt"
    echo "torch stack (locked):"; cat "$H3/constraints.txt"

    git clone -q "$COMFYUI_REPO" "$COMFY.new" && git -C "$COMFY.new" checkout -q "$COMFYUI_COMMIT" || return 1
    echo "$NODES" | while IFS='|' read -r name repo commit; do
        [ -z "$name" ] && continue
        git clone -q "$repo" "$COMFY.new/custom_nodes/$name" && git -C "$COMFY.new/custom_nodes/$name" checkout -q "$commit" \
            || { echo "node clone failed: $name"; exit 1; }
        echo "node $name @ ${commit:0:10}"
    done || return 1

    if [ -f "$H3/requirements-lock.txt" ]; then
        echo "pip: exact lock file"
        $PIP install -c "$H3/constraints.txt" -r "$H3/requirements-lock.txt" || return 1
    else
        echo "pip: first resolve (will be frozen into requirements-lock.txt)"
        local REQS="-r $COMFY.new/requirements.txt"
        for f in "$COMFY.new"/custom_nodes/*/requirements.txt; do [ -f "$f" ] && REQS="$REQS -r $f"; done
        $PIP install -c "$H3/constraints.txt" $REQS "transformers==5.3.0" "huggingface_hub[hf_xet]" || return 1
    fi
    $PIP freeze > "$H3/pip-freeze.txt"
    # ตรวจก่อนว่า torch stack ใช้ได้จริง (กันพังเงียบ ๆ ตอนเปิด ComfyUI)
    "$VENV/bin/python" -c "import torch, torchvision, torchaudio, torchvision.ops; print('torch check ok', torch.__version__, torchvision.__version__, torch.cuda.is_available())" \
        || { echo "torch stack check failed"; return 1; }
    grep -Ei '^(torch|torchvision|torchaudio)==' "$H3/pip-freeze.txt" | diff - <(grep -Ei '^(torch|torchvision|torchaudio)==' "$H3/constraints.txt") >/dev/null \
        || { echo "pip changed the torch stack:"; grep -Ei '^(torch|torchvision|torchaudio)==' "$H3/pip-freeze.txt"; return 1; }

    # ย้ายโฟลเดอร์ models/ input/ output/ เดิมไว้ ไม่ให้หาย
    if [ -d "$COMFY" ]; then
        for d in models input output user; do
            [ -d "$COMFY/$d" ] && { rm -rf "$COMFY.new/$d"; mv "$COMFY/$d" "$COMFY.new/$d"; }
        done
        rm -rf "$COMFY"
    fi
    mv "$COMFY.new" "$COMFY"
    echo "$LOCK_VERSION" > "$H3/installed_version"
    echo ">>> INSTALL done"
}

if [ "$(cat "$H3/installed_version" 2>/dev/null)" != "$LOCK_VERSION" ] || [ ! -f "$COMFY/main.py" ]; then
    status installing
    install_all || fatal INSTALL "install failed — see $LOG"
else
    echo "installed lock v$LOCK_VERSION — skip install"
fi

# ---------- โมเดล: โหลดเฉพาะไฟล์ที่ยังไม่มี ตาม revision ที่ล็อกไว้ ----------
export HF_XET_HIGH_PERFORMANCE=1 HF_HUB_DISABLE_PROGRESS_BARS=1
status models
MODELS="$MODELS" COMFY="$COMFY" H3="$H3" "$VENV/bin/python" - <<'PY' || fatal MODELS "model download failed"
import os, shutil, sys, time
from huggingface_hub import hf_hub_download, get_hf_file_metadata, hf_hub_url
comfy, h3 = os.environ["COMFY"], os.environ["H3"]
for line in os.environ["MODELS"].strip().splitlines():
    folder, repo, rev, path = [x.strip() for x in line.split("|")]
    dest = os.path.join(comfy, "models", folder, os.path.basename(path))
    try:
        size = get_hf_file_metadata(hf_hub_url(repo, path, revision=rev)).size
    except Exception as e:
        size = None
        print(f"  (size check offline: {e.__class__.__name__})")
    if os.path.exists(dest) and (size is None or os.path.getsize(dest) == size):
        print(f"ok    {folder}/{os.path.basename(path)}")
        continue
    t = time.time()
    print(f"get   {folder}/{os.path.basename(path)}  ({(size or 0)/1e9:.1f} GB)", flush=True)
    stage = os.path.join(h3, "dl", repo.replace("/", "__"))
    src = hf_hub_download(repo, path, revision=rev, local_dir=stage)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.move(src, dest)
    if size is not None and os.path.getsize(dest) != size:
        sys.exit(f"size mismatch: {dest}")
    print(f"done  {os.path.basename(path)} in {time.time()-t:.0f}s", flush=True)
shutil.rmtree(os.path.join(h3, "dl"), ignore_errors=True)
PY

# ---------- เปิด ComfyUI (ถ้าล่มจะเปิดใหม่ให้เอง) ----------
export TORCH_FORCE_WEIGHTS_ONLY_LOAD=1
cd "$COMFY"
echo ">>> ComfyUI lock v$LOCK_VERSION starting on :8188"
status starting
status_server_off
fails=0
while true; do
    t0=$SECONDS
    "$VENV/bin/python" main.py --listen 0.0.0.0 --port 8188 >> "$H3/logs/comfyui.log" 2>&1
    rc=$?
    if [ $((SECONDS - t0)) -lt 120 ]; then fails=$((fails + 1)); else fails=0; fi
    echo "ComfyUI exited ($rc) at $(date -u +%H:%M:%S)"
    if [ $fails -ge 3 ]; then
        echo "FATAL[COMFY_CRASH]: ComfyUI crashes on start — last error:"; grep -E "Error|error" "$H3/logs/comfyui.log" | tail -5
        status fatal COMFY_CRASH; status_server_on; sleep 600; status_server_off; fails=0
    else
        sleep 5
    fi
done
