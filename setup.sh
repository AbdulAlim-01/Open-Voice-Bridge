#!/usr/bin/env bash
# =============================================================================
#  setup.sh — Open-Source TTS API: One-shot installer
#  Works on: Linux (x86_64 / arm64) | macOS | Windows (Git Bash / WSL)
#
#  Downloads and sets up:
#    • Piper TTS binary + voices
#    • Kokoro-ONNX Python package + model
#    • Node.js dependencies (npm install)
#    • .env file (if not already present)
#
#  Usage:
#    Linux/macOS/WSL:  bash setup.sh
#    Windows Git Bash: bash setup.sh
# =============================================================================
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

# ─── Detect OS / arch ─────────────────────────────────────────────────────────
OS="$(uname -s 2>/dev/null || echo Windows)"
ARCH="$(uname -m 2>/dev/null || echo x86_64)"

case "$OS" in
  Linux*)   PLATFORM="linux" ;;
  Darwin*)  PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*|Windows*) PLATFORM="windows" ;;
  *)        PLATFORM="linux" ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH_TAG="x86_64" ;;
  aarch64|arm64) ARCH_TAG="aarch64" ;;
  *) warn "Unknown arch $ARCH, defaulting to x86_64"; ARCH_TAG="x86_64" ;;
esac

info "Detected platform: $PLATFORM / $ARCH_TAG"

# ─── Directories ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINES_DIR="$SCRIPT_DIR/engines"
PIPER_DIR="$ENGINES_DIR/piper"
PIPER_VOICES_DIR="$PIPER_DIR/voices"
KOKORO_DIR="$ENGINES_DIR/kokoro"

mkdir -p "$PIPER_VOICES_DIR" "$KOKORO_DIR"

# ─── Helper: download with progress ───────────────────────────────────────────
download() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL --progress-bar -o "$dest" "$url"
  elif command -v wget &>/dev/null; then
    wget -q --show-progress -O "$dest" "$url"
  else
    error "Neither curl nor wget found. Please install one and re-run."
  fi
}

# ─── Check prerequisites ───────────────────────────────────────────────────────
check_prereqs() {
  info "Checking prerequisites..."

  # Node.js
  if command -v node &>/dev/null; then
    NODE_VER=$(node --version)
    success "Node.js $NODE_VER found"
  else
    error "Node.js not found. Install from https://nodejs.org (v18+) then re-run."
  fi

  # npm
  if command -v npm &>/dev/null; then
    success "npm $(npm --version) found"
  else
    error "npm not found. It should come with Node.js."
  fi

  # Python
  PYTHON_CMD=""
  for cmd in python3 python; do
    if command -v "$cmd" &>/dev/null; then
      PY_VER=$("$cmd" --version 2>&1)
      success "$PY_VER found ($cmd)"
      PYTHON_CMD="$cmd"
      break
    fi
  done
  if [ -z "$PYTHON_CMD" ]; then
    error "Python not found. Install Python 3.9+ from https://python.org then re-run."
  fi

  # pip
  if "$PYTHON_CMD" -m pip --version &>/dev/null; then
    success "pip found"
  else
    error "pip not found. Install pip then re-run."
  fi

  # tar / unzip (for Piper archive)
  if command -v tar &>/dev/null; then
    success "tar found"
  else
    warn "tar not found — Piper extraction may fail on some archives."
  fi
}

# ─── Install Piper binary ──────────────────────────────────────────────────────
install_piper() {
  info "Setting up Piper TTS binary..."

  # Latest Piper release (2023.11.14-2 — stable, widely tested)
  local BASE="https://github.com/rhasspy/piper/releases/download/2023.11.14-2"

  if [ "$PLATFORM" = "windows" ]; then
    local ARCHIVE="piper_windows_amd64.zip"
    local PIPER_BIN="$PIPER_DIR/piper.exe"
    if [ -f "$PIPER_BIN" ]; then success "Piper already installed"; return; fi
    info "Downloading Piper for Windows..."
    download "$BASE/$ARCHIVE" "$PIPER_DIR/$ARCHIVE"
    if command -v unzip &>/dev/null; then
      unzip -q -o "$PIPER_DIR/$ARCHIVE" -d "$PIPER_DIR"
    else
      warn "unzip not found. Please extract $PIPER_DIR/$ARCHIVE manually into $PIPER_DIR"
    fi
    rm -f "$PIPER_DIR/$ARCHIVE"
  elif [ "$PLATFORM" = "macos" ]; then
    local ARCHIVE="piper_macos_x64.tar.gz"
    local PIPER_BIN="$PIPER_DIR/piper"
    if [ -f "$PIPER_BIN" ]; then success "Piper already installed"; return; fi
    info "Downloading Piper for macOS..."
    download "$BASE/$ARCHIVE" "$PIPER_DIR/$ARCHIVE"
    tar -xzf "$PIPER_DIR/$ARCHIVE" -C "$PIPER_DIR" --strip-components=1
    rm -f "$PIPER_DIR/$ARCHIVE"
    chmod +x "$PIPER_BIN"
  else
    # Linux
    local ARCHIVE
    if [ "$ARCH_TAG" = "aarch64" ]; then
      ARCHIVE="piper_linux_aarch64.tar.gz"
    else
      ARCHIVE="piper_linux_x86_64.tar.gz"
    fi
    local PIPER_BIN="$PIPER_DIR/piper"
    if [ -f "$PIPER_BIN" ]; then success "Piper already installed"; return; fi
    info "Downloading Piper for Linux ($ARCH_TAG)..."
    download "$BASE/$ARCHIVE" "$PIPER_DIR/$ARCHIVE"
    tar -xzf "$PIPER_DIR/$ARCHIVE" -C "$PIPER_DIR" --strip-components=1
    rm -f "$PIPER_DIR/$ARCHIVE"
    chmod +x "$PIPER_BIN"
  fi

  success "Piper installed → $PIPER_DIR"
}

# ─── Download Piper voices ─────────────────────────────────────────────────────
install_piper_voices() {
  info "Downloading Piper voices..."

  # Each voice needs both the .onnx model and the .onnx.json config.
  local VOICE_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main"

  declare -A VOICES=(
    # English US — female / male
    ["en_US-hfc_female-medium"]="en/en_US/hfc_female/medium"
    ["en_US-hfc_male-medium"]="en/en_US/hfc_male/medium"
    ["en_US-amy-medium"]="en/en_US/amy/medium"
    ["en_US-ryan-high"]="en/en_US/ryan/high"
    # English GB
    ["en_GB-alan-medium"]="en/en_GB/alan/medium"
  )

  for VOICE_ID in "${!VOICES[@]}"; do
    local SUBPATH="${VOICES[$VOICE_ID]}"
    local ONNX="$PIPER_VOICES_DIR/${VOICE_ID}.onnx"
    local JSON="$PIPER_VOICES_DIR/${VOICE_ID}.onnx.json"

    if [ -f "$ONNX" ] && [ -f "$JSON" ]; then
      success "Voice already downloaded: $VOICE_ID"
      continue
    fi

    info "Downloading voice: $VOICE_ID"
    download "$VOICE_BASE/$SUBPATH/${VOICE_ID}.onnx"      "$ONNX"
    download "$VOICE_BASE/$SUBPATH/${VOICE_ID}.onnx.json" "$JSON"
    success "Voice ready: $VOICE_ID"
  done
}

# ─── Install Kokoro-ONNX ───────────────────────────────────────────────────────
install_kokoro() {
  info "Installing Kokoro-ONNX Python package..."

  # Install kokoro-onnx and its runtime deps
  "$PYTHON_CMD" -m pip install --upgrade kokoro-onnx onnxruntime soundfile numpy \
    --quiet --no-warn-script-location

  success "Kokoro-ONNX Python packages installed"

  # Write the kokoro_tts.py helper script
  cat > "$KOKORO_DIR/kokoro_tts.py" << 'PYEOF'
"""
kokoro_tts.py — stdin → raw PCM stdout
Usage: echo "Hello" | python kokoro_tts.py
Env:   KOKORO_VOICE (default: af_heart)
"""
import sys, os
import numpy as np

voice = os.environ.get("KOKORO_VOICE", "af_heart")

try:
    from kokoro_onnx import Kokoro
except ImportError:
    sys.stderr.write("[Kokoro] ERROR: kokoro-onnx not installed. Run: pip install kokoro-onnx\n")
    sys.exit(1)

def main():
    text = sys.stdin.readline().strip()
    if not text:
        sys.stderr.write("[Kokoro] ERROR: empty input\n")
        sys.exit(1)

    try:
        kokoro = Kokoro("kokoro-v0_19.onnx", "voices.bin")
        samples, sample_rate = kokoro.create(text, voice=voice, speed=1.0, lang="en-us")
        # Convert float32 → int16 PCM
        pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype(np.int16)
        sys.stdout.buffer.write(pcm.tobytes())
    except Exception as e:
        sys.stderr.write(f"[Kokoro] ERROR: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
PYEOF

  success "kokoro_tts.py written → $KOKORO_DIR/kokoro_tts.py"
}

# ─── Download Kokoro model files ───────────────────────────────────────────────
install_kokoro_models() {
  info "Downloading Kokoro model files (this may take a minute)..."

  local KOKORO_HF="https://huggingface.co/hexgrad/Kokoro-82M/resolve/main"
  local MODEL="$KOKORO_DIR/kokoro-v0_19.onnx"
  local VOICES_BIN="$KOKORO_DIR/voices.bin"

  if [ ! -f "$MODEL" ]; then
    info "Downloading kokoro-v0_19.onnx (~83 MB)..."
    download "$KOKORO_HF/kokoro-v0_19.onnx" "$MODEL"
    success "Model downloaded"
  else
    success "Kokoro model already present"
  fi

  if [ ! -f "$VOICES_BIN" ]; then
    info "Downloading voices.bin (~4 MB)..."
    download "$KOKORO_HF/voices.bin" "$VOICES_BIN"
    success "Voices binary downloaded"
  else
    success "Kokoro voices.bin already present"
  fi
}

# ─── npm install ───────────────────────────────────────────────────────────────
install_node_deps() {
  info "Installing Node.js dependencies..."
  if [ -f "$SCRIPT_DIR/package.json" ]; then
    (cd "$SCRIPT_DIR" && npm install --silent)
    success "npm install complete"
  else
    warn "No package.json found — skipping npm install"
  fi
}

# ─── Generate .env ─────────────────────────────────────────────────────────────
generate_env() {
  local ENV_FILE="$SCRIPT_DIR/.env"
  if [ -f "$ENV_FILE" ]; then
    success ".env already exists — not overwriting"
    return
  fi

  info "Generating .env file..."

  # Resolve absolute paths for the env
  if [ "$PLATFORM" = "windows" ]; then
    PIPER_BIN_PATH="$PIPER_DIR/piper.exe"
  else
    PIPER_BIN_PATH="$PIPER_DIR/piper"
  fi

  cat > "$ENV_FILE" << ENVEOF
# ── TTS Engine (kokoro | piper) ────────────────────────────────────────────────
TTS_ENGINE=kokoro

# ── Kokoro ─────────────────────────────────────────────────────────────────────
PYTHON_PATH=$PYTHON_CMD
KOKORO_VOICE=af_heart
KOKORO_SAMPLE_RATE=24000
KOKORO_SCRIPT=$KOKORO_DIR/kokoro_tts.py

# ── Piper ──────────────────────────────────────────────────────────────────────
PIPER_PATH=$PIPER_BIN_PATH
PIPER_VOICES=$PIPER_VOICES_DIR
PIPER_SAMPLE_RATE=22050

# ── Server ─────────────────────────────────────────────────────────────────────
PORT=3000
TTS_CONCURRENCY=5
ENVEOF

  success ".env created"
}

# ─── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║        TTS API — Setup Complete  ✓               ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Start server:  ${CYAN}node server.js${NC}"
  echo -e "  Test (browser): ${CYAN}http://localhost:3000/tts?chunk=Hello+world${NC}"
  echo -e "  Voices:         ${CYAN}http://localhost:3000/tts/voices${NC}"
  echo ""
  echo -e "  Edit ${YELLOW}.env${NC} to switch engines or change voices."
  echo ""
}

# ─── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}   Open-Source TTS API — Setup Script                 ${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
  echo ""

  check_prereqs
  install_piper
  install_piper_voices
  install_kokoro
  install_kokoro_models
  install_node_deps
  generate_env
  print_summary
}

main
