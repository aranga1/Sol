#!/usr/bin/env python3
"""Generate a QR code with Alysha connection info."""
import argparse, json, sys
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--terminal", action="store_true",
                        help="Also print ASCII QR to terminal")
    args = parser.parse_args()

    payload = json.dumps({"host": args.host, "port": args.port, "apiKey": args.api_key})

    try:
        import qrcode
        from qrcode.image.pure import PyPNGImage
    except ImportError:
        print("qrcode not installed — skipping QR generation", file=sys.stderr)
        print(f"\nManual connection info:\n{payload}\n")
        return

    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L)
    qr.add_data(payload)
    qr.make(fit=True)

    # Save PNG
    img = qr.make_image(fill_color="black", back_color="white")
    img.save(args.output)
    print(f"QR code saved to {args.output}")

    # Terminal ASCII
    if args.terminal:
        print("\n  ── Scan with Alysha iOS app ──\n")
        qr.print_ascii(invert=True)
        print()

if __name__ == "__main__":
    main()
