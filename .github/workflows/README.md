# GitHub Actions Secrets Setup

To enable the iOS CI build, add these secrets in your repository Settings → Secrets and variables → Actions:

| Secret | How to get it |
|--------|--------------|
| `APPLE_CERT_BASE64` | Export your distribution/development cert from Keychain as .p12, then: `base64 -i cert.p12 \| pbcopy` |
| `APPLE_CERT_PASSWORD` | The password you set when exporting the .p12 |
| `APPLE_PROVISIONING_PROFILE` | Download from developer.apple.com, then: `base64 -i Alysha.mobileprovision \| pbcopy` |
| `APPLE_TEAM_ID` | Your 10-character team ID from developer.apple.com/account |

**Device UDID registration:** Your iPhone's UDID must be registered in the provisioning profile. Find your UDID by connecting to Xcode and checking the Devices window.

**Install flow:**
1. A build completes → GitHub Release is created automatically
2. Open the Release page in **Safari on your iPhone**
3. Tap `install.html` in the Assets list
4. Tap "Install Alysha" → confirm
5. Go to Settings → General → VPN & Device Management → trust the developer cert
