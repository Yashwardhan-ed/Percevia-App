#!/usr/bin/env bash
  set -euo pipefail

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  MODEL_PATH="$REPO_ROOT/models_local/gemma-4-E2B-it.litertlm"
  PACKAGE_NAME="com.example.percevia"
  TARGET_DIR="/storage/emulated/0/Android/data/${PACKAGE_NAME}/files/models"

  if [ ! -f "$MODEL_PATH" ]; then
    echo "Model file not found: $MODEL_PATH" >&2
    echo "Run create_gemma_model.py or place the model in models_local/." >&2
    exit 1
  fi

  echo "Pushing Gemma model to device..."
  
  # Ensure the internal app directory exists
  MSYS_NO_PATHCONV=1 adb shell run-as "$PACKAGE_NAME" mkdir -p /data/user/0/"$PACKAGE_NAME"/app_flutter/models

  # Push to a temporary location first
  TMP_PATH="/data/local/tmp/$(basename "$MODEL_PATH")"
  cd "$REPO_ROOT"
  MSYS_NO_PATHCONV=1 adb push "models_local/$(basename "$MODEL_PATH")" "$TMP_PATH"
  
  # Stream the file from the ADB shell user directly into the app sandbox safely
  MSYS_NO_PATHCONV=1 adb shell "cat \"$TMP_PATH\" | run-as \"$PACKAGE_NAME\" sh -c 'cat > /data/user/0/$PACKAGE_NAME/app_flutter/models/$(basename "$MODEL_PATH")'"
  MSYS_NO_PATHCONV=1 adb shell rm "$TMP_PATH"

  echo "Done. You can launch the app and tap Retry if prompted."