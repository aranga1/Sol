#!/usr/bin/env python3
"""
Generate an Apple Shortcuts .shortcut file that sends a note to Obsidian
via the obsidian://new URL scheme.

Usage:
    python generate_shortcut.py --vault Alysha --output SendToAlysha.shortcut
"""
import argparse
import plistlib
import uuid
from pathlib import Path


def uid():
    return str(uuid.uuid4()).upper()


def token_attachment(output_name: str, output_uuid: str) -> dict:
    """Reference to a previous action's output."""
    return {
        "Value": {
            "Type": "ActionOutput",
            "OutputName": output_name,
            "OutputUUID": output_uuid,
        },
        "WFSerializationType": "WFTextTokenAttachment",
    }


def text_with_tokens(template: str, tokens: dict) -> dict:
    """
    Build a WFTextTokenString value.
    template: string with \\ufffc as variable placeholders (in order)
    tokens: list of (output_name, output_uuid) in placeholder order
    """
    attachments = {}
    offset = 0
    token_iter = iter(tokens)
    for ch in template:
        if ch == "￼":
            name, tok_uuid = next(token_iter)
            attachments[f"{{{offset}, 1}}"] = {
                "Type": "ActionOutput",
                "OutputName": name,
                "OutputUUID": tok_uuid,
            }
        offset += 1

    return {
        "Value": {
            "string": template,
            "attachmentsByRange": attachments,
        },
        "WFSerializationType": "WFTextTokenString",
    }


def build_shortcut(vault_name: str = "Alysha") -> bytes:
    # UUIDs for each action's output
    u_body = uid()
    u_lines = uid()
    u_title = uid()
    u_enc_title = uid()
    u_enc_body = uid()
    u_url = uid()

    # Build the URL template
    # obsidian://new?vault=<vault>&name=<enc_title>&content=<enc_body>
    prefix = f"obsidian://new?vault={vault_name}&name="
    mid = "&content="
    url_template = prefix + "￼" + mid + "￼"
    url_tokens = [("Encoded Title", u_enc_title), ("Encoded Body", u_enc_body)]

    actions = [
        # 1. Get text from Share Sheet input (converts Apple Note to plain text)
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
            "WFWorkflowActionParameters": {
                "UUID": u_body,
                "CustomOutputName": "Note Body",
                "WFInput": {
                    "Value": {"Type": "ExtensionInput"},
                    "WFSerializationType": "WFTextTokenAttachment",
                },
            },
        },
        # 2. Split body by newline to isolate the title (first line)
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.text.split",
            "WFWorkflowActionParameters": {
                "UUID": u_lines,
                "CustomOutputName": "Lines",
                "WFTextSeparator": "Custom",
                "WFTextCustomSeparator": "\n",
                "text": token_attachment("Note Body", u_body),
            },
        },
        # 3. Get first line as title
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.getitemfromlist",
            "WFWorkflowActionParameters": {
                "UUID": u_title,
                "CustomOutputName": "Note Title",
                "WFItemSpecifier": "First Item",
                "WFInput": token_attachment("Lines", u_lines),
            },
        },
        # 4. URL-encode title
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.urlencode",
            "WFWorkflowActionParameters": {
                "UUID": u_enc_title,
                "CustomOutputName": "Encoded Title",
                "WFInput": token_attachment("Note Title", u_title),
            },
        },
        # 5. URL-encode body
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.urlencode",
            "WFWorkflowActionParameters": {
                "UUID": u_enc_body,
                "CustomOutputName": "Encoded Body",
                "WFInput": token_attachment("Note Body", u_body),
            },
        },
        # 6. Build obsidian:// URL
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
            "WFWorkflowActionParameters": {
                "UUID": u_url,
                "CustomOutputName": "Obsidian URL",
                "WFTextActionText": text_with_tokens(url_template, url_tokens),
            },
        },
        # 7. Open the URL → launches Obsidian and creates the note
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
            "WFWorkflowActionParameters": {
                "WFInput": token_attachment("Obsidian URL", u_url),
            },
        },
    ]

    shortcut = {
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowName": "Send to Alysha",
        "WFWorkflowIcon": {
            "WFWorkflowIconGlyphNumber": 59511,   # brain glyph
            "WFWorkflowIconStartColor": 4274264319,  # purple
        },
        # ActionExtension = appears in iOS Share Sheet
        "WFWorkflowTypes": ["ActionExtension"],
        "WFWorkflowInputContentItemClasses": [
            "WFNoteContentItem",    # Apple Notes note
            "WFStringContentItem",  # plain text fallback
        ],
        "WFWorkflowActions": actions,
        "WFWorkflowHasShortcutInputVariables": True,
    }

    return plistlib.dumps(shortcut, fmt=plistlib.FMT_BINARY)


def main():
    parser = argparse.ArgumentParser(
        description="Generate Send-to-Alysha Apple Shortcut file"
    )
    parser.add_argument("--vault", default="Alysha", help="Obsidian vault name")
    parser.add_argument(
        "--output",
        default="SendToAlysha.shortcut",
        help="Output .shortcut file path",
    )
    parser.add_argument(
        "--qr",
        metavar="QR_OUTPUT",
        help="Also generate a QR code PNG pointing to a hosted URL for this shortcut",
    )
    parser.add_argument(
        "--hosted-url",
        help="Public URL where the .shortcut file will be hosted (for --qr)",
    )
    args = parser.parse_args()

    data = build_shortcut(vault_name=args.vault)
    out = Path(args.output)
    out.write_bytes(data)
    print(f"Shortcut written to {out} ({len(data):,} bytes)")

    if args.qr:
        if not args.hosted_url:
            print("--hosted-url required when using --qr", file=__import__("sys").stderr)
            return
        try:
            import qrcode

            # shortcuts://import?url=<hosted_url> deep-links straight into Shortcuts.app
            install_url = f"shortcuts://import?url={args.hosted_url}"
            qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L)
            qr.add_data(install_url)
            qr.make(fit=True)
            qr.make_image().save(args.qr)
            print(f"QR code saved to {args.qr}")
            print(f"Install URL: {install_url}")
            print("\n  ── Scan to install shortcut ──\n")
            qr.print_ascii(invert=True)
        except ImportError:
            print("qrcode not installed — skipping QR generation")


if __name__ == "__main__":
    main()
