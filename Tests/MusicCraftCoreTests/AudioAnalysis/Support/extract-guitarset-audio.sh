#!/bin/bash
# Extract 5 GuitarSet audio files from audio_hex-pickup_debleeded.zip
# Usage: ./extract-guitarset-audio.sh /path/to/audio_hex-pickup_debleeded.zip

set -e

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/audio_hex-pickup_debleeded.zip"
    exit 1
fi

ZIP_PATH="$1"
FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Fixtures/real-audio/guitarset"

if [[ ! -f "$ZIP_PATH" ]]; then
    echo "Error: ZIP file not found: $ZIP_PATH"
    exit 1
fi

mkdir -p "$FIXTURE_DIR"

# 5 fixtures to extract (comping versions with hex clean audio)
# Format: "fixture_id|zip_entry_path"
FIXTURES=(
    "00_BN1-129-Eb_comp|00_BN1-129-Eb_comp_hex_cln.wav"
    "01_BN1-129-Eb_comp|01_BN1-129-Eb_comp_hex_cln.wav"
    "00_Funk1-114-Ab_comp|00_Funk1-114-Ab_comp_hex_cln.wav"
    "00_Rock1-130-A_comp|00_Rock1-130-A_comp_hex_cln.wav"
    "00_SS1-68-E_comp|00_SS1-68-E_comp_hex_cln.wav"
)

for entry in "${FIXTURES[@]}"; do
    IFS='|' read -r fixture_id zip_entry <<< "$entry"
    output_path="$FIXTURE_DIR/$fixture_id.wav"

    if [[ -f "$output_path" ]]; then
        echo "⊘ Already exists: $fixture_id.wav"
    else
        echo "⏳ Extracting: $fixture_id.wav"
        unzip -p "$ZIP_PATH" "$zip_entry" > "$output_path" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            size=$(ls -lh "$output_path" | awk '{print $5}')
            echo "✓ Extracted: $fixture_id.wav ($size)"
        else
            echo "⚠ Failed to extract: $zip_entry"
        fi
    fi
done

echo ""
echo "✓ Audio extraction complete."
