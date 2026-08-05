#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="skills"
STORAGE_ACCOUNT="${AZURE_BLOB_STORAGE_ACCOUNT_NAME:-}"
USE_CASES_DIR="use-cases"

# Written by hooks/select-use-cases.sh at preprovision time. See that file for
# why the question is asked up front instead of here.
SELECTION_FILE=".azure/${AZURE_ENV_NAME:-default}/kratos-upload-selection"

if [ -z "$STORAGE_ACCOUNT" ]; then
  echo "⚠️  AZURE_BLOB_STORAGE_ACCOUNT_NAME is not set. Skipping skills upload."
  exit 0
fi

if [ ! -d "$USE_CASES_DIR" ]; then
  echo "⚠️  '$USE_CASES_DIR' directory not found. Skipping skills upload."
  exit 0
fi

# Discover available use-cases
USE_CASES=()
for dir in "$USE_CASES_DIR"/*/; do
  name="$(basename "$dir")"
  [ "$name" = "*" ] && continue
  USE_CASES+=("$name")
done

if [ ${#USE_CASES[@]} -eq 0 ]; then
  echo "⚠️  No use-cases found in '$USE_CASES_DIR'. Skipping skills upload."
  exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          Upload Skills to Azure Blob Storage            ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Storage Account: $STORAGE_ACCOUNT"
echo "║  Container:       $CONTAINER_NAME"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Never prompt here. `azd up` repaints its progress table over whatever a hook
# writes, which used to eat the menu's last lines and the prompt itself. The
# choice is made by hooks/select-use-cases.sh before the deploy starts; this
# hook just carries it out.
SELECTION=""
if [ -f "$SELECTION_FILE" ]; then
  SELECTION="$(head -n 1 "$SELECTION_FILE" | tr -d '[:space:]')"
  rm -f "$SELECTION_FILE" 2>/dev/null || true
fi

# Direct env override, and the legacy flag, still work for scripted runs.
if [ -n "${KRATOS_UPLOAD_USE_CASES:-}" ]; then
  SELECTION="${KRATOS_UPLOAD_USE_CASES}"
elif [ -z "$SELECTION" ] && [ "${KRATOS_AUTO_UPLOAD_USE_CASES:-0}" = "1" ]; then
  SELECTION="all"
fi

if [ -z "$SELECTION" ]; then
  if [ -t 0 ] && [ -r /dev/tty ]; then
    # Run by hand from a real terminal: azd is not painting over anything, so
    # asking here is safe. This is the supported way to upload after the fact.
    SELECTION="ask"
  else
    # Reached when postdeploy runs without the selector, e.g. a bare
    # `azd deploy`, which has no preprovision phase.
    echo "ℹ️  No skills upload was requested, so nothing was uploaded."
    echo "    To choose interactively now:  ./hooks/postdeploy.sh"
    echo "    Or non-interactively:         KRATOS_UPLOAD_USE_CASES=all ./hooks/postdeploy.sh"
    exit 0
  fi
fi

# Running this script by hand is the supported way to get the menu, because
# then azd is not painting over the terminal.
if [ "$SELECTION" = "ask" ]; then
  ./hooks/select-use-cases.sh
  SELECTION="$(head -n 1 "$SELECTION_FILE" 2>/dev/null | tr -d '[:space:]')"
  rm -f "$SELECTION_FILE" 2>/dev/null || true
fi

if [ -z "$SELECTION" ] || [ "$SELECTION" = "none" ]; then
  echo "Skipping skills upload."
  exit 0
fi

SELECTED=()
if [ "$SELECTION" = "all" ]; then
  SELECTED=("${USE_CASES[@]}")
else
  # A comma-separated list of use-case names, already resolved from whatever
  # the user typed. Numbers are still accepted for anyone setting the env var
  # by hand.
  IFS=',' read -ra PARTS <<< "$SELECTION"
  for part in "${PARTS[@]}"; do
    part="$(printf '%s' "$part" | tr -d '[:space:]')"
    [ -z "$part" ] && continue
    if [[ "$part" =~ ^[0-9]+$ ]] && [ "$part" -ge 1 ] && [ "$part" -le "${#USE_CASES[@]}" ]; then
      SELECTED+=("${USE_CASES[$((part - 1))]}")
    elif [ -d "$USE_CASES_DIR/$part" ]; then
      SELECTED+=("$part")
    else
      echo "⚠️  Unknown use-case: $part"
    fi
  done
fi

if [ ${#SELECTED[@]} -eq 0 ]; then
  echo "No valid use-cases selected. Skipping."
  exit 0
fi

for use_case in "${SELECTED[@]}"; do
  LOCAL_PATH="$USE_CASES_DIR/$use_case"
  echo ""
  echo "🔄 Uploading '$use_case' → blob://$CONTAINER_NAME/$use_case/ ..."

  # Delete existing blobs for this use-case first (replace, not merge), BUT
  # preserve eval run history under evals/runs/ — those are runtime artefacts
  # written by the backend, not source-controlled inputs we ship from the repo.
  # Without this guard, every postdeploy wipes the entire eval history and
  # the e2e-smoke `04-evals` spec fails until a fresh validation run is queued.
  echo "   Clearing existing blobs under 'use-cases/$use_case/' (preserving evals/runs/)..."
  EXISTING_BLOBS="$(az storage blob list \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER_NAME" \
    --prefix "use-cases/$use_case/" \
    --auth-mode login \
    --query "[?!contains(name, '/evals/runs/')].name" \
    --output tsv 2>/dev/null || true)"

  if [ -n "$EXISTING_BLOBS" ]; then
    echo "$EXISTING_BLOBS" | while IFS= read -r blob_name; do
      [ -z "$blob_name" ] && continue
      az storage blob delete \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$CONTAINER_NAME" \
        --name "$blob_name" \
        --auth-mode login \
        --only-show-errors 2>/dev/null || true
    done
  fi

  # Upload all files from the local use-case folder
  az storage blob upload-batch \
    --account-name "$STORAGE_ACCOUNT" \
    --destination "$CONTAINER_NAME" \
    --source "$LOCAL_PATH" \
    --destination-path "use-cases/$use_case" \
    --auth-mode login \
    --overwrite \
    --only-show-errors

  echo "   ✅ '$use_case' uploaded successfully."
done

echo ""
echo "🎉 Skills upload complete."
