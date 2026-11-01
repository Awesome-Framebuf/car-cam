#!/usr/bin/env python3
"""Writes a QR code per release file to docs/images/qr/. Needs: pip install segno

Usage: tool/make_qr_codes.py v1.0.0 v2.0.0
"""
import pathlib
import sys

import segno

REPO = "https://github.com/Awesome-Framebuf/car-cam"
FILES = {"android": "CarCam.apk", "iphone": "CarCam-unsigned.ipa"}

out = pathlib.Path(__file__).resolve().parent.parent / "docs" / "images" / "qr"
out.mkdir(parents=True, exist_ok=True)
for version in sys.argv[1:]:
    for platform, name in FILES.items():
        url = f"{REPO}/releases/download/{version}/{name}"
        segno.make(url, error="m", boost_error=False).save(
            out / f"{version}-{platform}.png", scale=6, border=4
        )
        print(version, platform, url)
