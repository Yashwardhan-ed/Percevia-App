"""Download the Gemma model used by Percevia.

This script fetches the prebuilt .litertlm file and stores it under
models_local/ on the dev machine. The file is intentionally NOT bundled into
the Flutter asset bundle (2.5 GB exceeds Android's APK packaging limits);
instead it is pushed to the device via adb and loaded via FileSource at
runtime by GemmaLocalService.

After running this script, push the file to the device:

    adb shell mkdir -p /sdcard/Android/data/com.example.percevia/files/models
    adb push models_local/gemma-4-E2B-it.litertlm \
        /sdcard/Android/data/com.example.percevia/files/models/gemma-4-E2B-it.litertlm

Default source:
https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm
"""

from __future__ import annotations

import argparse
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


DEFAULT_URL = (
    "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/"
    "gemma-4-E2B-it.litertlm"
)
DEFAULT_OUTPUT = Path("models_local/gemma-4-E2B-it.litertlm")


def _build_request(url: str, token: str | None) -> urllib.request.Request:
    headers = {
        "User-Agent": "Percevia-Gemma-Downloader/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


def download_file(url: str, output_path: Path, token: str | None, overwrite: bool) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if output_path.exists() and not overwrite:
        print(f"Model already exists at {output_path}; use --overwrite to replace it.")
        return

    request = _build_request(url, token)

    try:
        with urllib.request.urlopen(request) as response, output_path.open("wb") as out_file:
            content_length = response.headers.get("Content-Length")
            total_bytes = int(content_length) if content_length and content_length.isdigit() else None
            downloaded_bytes = 0
            chunk_size = 1024 * 1024

            while True:
                chunk = response.read(chunk_size)
                if not chunk:
                    break
                out_file.write(chunk)
                downloaded_bytes += len(chunk)

                if total_bytes:
                    percent = (downloaded_bytes / total_bytes) * 100
                    print(
                        f"\rDownloading: {downloaded_bytes / (1024 * 1024):.1f} MB "
                        f"of {total_bytes / (1024 * 1024):.1f} MB ({percent:.1f}%)",
                        end="",
                        flush=True,
                    )
                else:
                    print(f"\rDownloading: {downloaded_bytes / (1024 * 1024):.1f} MB", end="", flush=True)

    except urllib.error.HTTPError as exc:
        print()
        print(f"Download failed with HTTP {exc.code}: {exc.reason}")
        if exc.code in {401, 403}:
            print(
                "This model repo is gated. Set HUGGINGFACE_TOKEN or HF_TOKEN and try again."
            )
        raise
    except urllib.error.URLError as exc:
        print()
        print(f"Download failed: {exc.reason}")
        raise

    print()
    print(f"Saved Gemma model to: {output_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Download the Gemma model for Percevia.")
    parser.add_argument("--url", default=DEFAULT_URL, help="Model URL to download.")
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="Destination path for the downloaded model asset.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite the output file if it already exists.",
    )
    args = parser.parse_args()

    token = os.environ.get("HUGGINGFACE_TOKEN") or os.environ.get("HF_TOKEN")
    output_path = Path(args.output)

    print("Downloading Gemma model asset for Percevia...")
    print(f"Source: {args.url}")
    print(f"Target: {output_path}")
    download_file(args.url, output_path, token, args.overwrite)
    return 0


if __name__ == "__main__":
    sys.exit(main())