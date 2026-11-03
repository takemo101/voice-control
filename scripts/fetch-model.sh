#!/bin/bash
# Tiny-Jev 0.6B を、版（commit）を固定して models/tiny-jev-0.6b（MODEL_DIR で変更）に取得し、SHA-256 を検証する。
# 値は meeting-analyzer の DecisionModelCatalog（Sources/MeetingAnalyzerKit/Core/DecisionModel.swift）と同じ。
set -euo pipefail
cd "$(dirname "$0")/.."
REV=62449fb3272d68fb8c8fe8a33082566643a76d0b
BASE=https://huggingface.co/lostargon/Tiny-Jev/resolve/$REV
DIR="${MODEL_DIR:-models/tiny-jev-0.6b}"
mkdir -p "$DIR"
fetch() { # file sha256
  if [ -f "$DIR/$1" ] && [ "$(shasum -a 256 "$DIR/$1" | cut -d' ' -f1)" = "$2" ]; then echo "ok  $1"; return; fi
  curl -fsSL --retry 5 --retry-all-errors -C - -o "$DIR/$1" "$BASE/$1"
  [ "$(shasum -a 256 "$DIR/$1" | cut -d' ' -f1)" = "$2" ] || { echo "SHA-256 不一致: $1" >&2; exit 1; }
  echo "ok  $1"
}
fetch tokenizer.json e3fccc77adda606e2a461ffd17ca5a55a5a75ac40a5aa0a91c5307fb31b1efac
fetch model.safetensors 513411b17cb0eca54839ca3948b4353e7f65710723ffcde8d13e3cb04328633e
