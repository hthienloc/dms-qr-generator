# QR Generator

Generate and scan QR codes instantly.

<img src="screenshot.png" width="400" alt="Screenshot">

## Install

Use the DMS CLI:
```bash
dms plugins install qrGenerator
```

Or manually:
```bash
git clone https://github.com/hthienloc/dms-qr-generator ~/.config/DankMaterialShell/plugins/qrGenerator
```

## Features

- **Real-time generation** - QR updates as you type
- **WiFi sharing** - One-click QR for current network
- **Scan QR codes** - Decode from dropped images
- **Clipboard integration** - Right-click to generate from clipboard
- **Export** - Save as PNG or scalable SVG
- **Privacy focused** - Auto-clears on close

## Usage

| Action | Result |
|--------|--------|
| Left click | Open generator |
| Right click | Paste & generate from clipboard |
| Middle click | Take screenshot & scan QR code |
| Drop image | Scan QR code |
| Drop text | Generate QR code |

## Requirements

- `qrencode` - QR generation: `sudo dnf install qrencode` / `sudo pacman -S qrencode`
- `zbarimg` - QR scanning (optional): `sudo dnf install zbar` / `sudo pacman -S zbar`

## License

GPL-3.0

## Roadmap / TODO

- [x] **High-quality SVG export** for scalable graphics.
- [ ] **Configurable Error Correction Level** (L, M, Q, H) for more robust codes.
- [ ] **Dedicated Templates** for VCard (Contact) and Calendar Event generation.
- [ ] **Local History** of generated/scanned QR codes (opt-in for privacy).
- [ ] **Custom Styling**: Foreground/Background color selection and optional center logo overlay.
- [ ] **Batch Generation** from a text file or newline-separated list.

