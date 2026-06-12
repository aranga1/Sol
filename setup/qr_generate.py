#!/usr/bin/env python3
"""Generate a QR code with Sol connection info."""
import argparse, json, sys
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    # Connection QR mode
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    parser.add_argument("--api-key")
    # Generic URL QR mode (e.g. for shortcut install links)
    parser.add_argument("--url", help="Encode a raw URL instead of connection JSON")
    parser.add_argument("--label", default="Scan with Sol iOS app",
                        help="Label printed above the terminal QR")
    parser.add_argument("--output", required=True)
    parser.add_argument("--terminal", action="store_true",
                        help="Also print ASCII QR to terminal")
    args = parser.parse_args()

    if args.url:
        payload = args.url
    elif args.host and args.port and args.api_key:
        payload = json.dumps({"host": args.host, "port": args.port, "apiKey": args.api_key})
    else:
        print("Provide either --url or all of --host / --port / --api-key", file=sys.stderr)
        sys.exit(1)

    try:
        import qrcode
    except ImportError:
        print("qrcode not installed — skipping QR generation", file=sys.stderr)
        print(f"\nPayload:\n{payload}\n")
        return

    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L)
    qr.add_data(payload)
    qr.make(fit=True)

    img = qr.make_image(fill_color="black", back_color="white")
    img.save(args.output)
    print(f"QR code saved to {args.output}")

    if args.terminal:
        print(f"\n  ── {args.label} ──\n")
        qr.print_ascii(invert=True)
        print()

if __name__ == "__main__":
    main()
