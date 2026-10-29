<p align="center"><img src="docs/banner.png" alt="Confluo — Every device. One sound."></p>

Confluo mixes your Mac's audio with audio from your iPhones into one output, each source with its own volume.
iPhones connect over AirPlay, no app needed on the phone.

## Download

Get **Confluo-x.y.z.dmg** from the [latest release](https://github.com/Monayzera/confluo-audio/releases/latest), open it and drag **Confluo** to Applications.

Then on the iPhone: Control Center → AirPlay → **“Mac name · Confluo”**.

### “Confluo was blocked to protect your Mac”

Confluo is open source and signed, but not notarized by Apple (that requires a paid Apple Developer account), so macOS blocks the first launch. To allow it once:

1. Open Confluo from Applications and dismiss the warning.
2. Go to **System Settings → Privacy & Security**, scroll to **Security**.
3. Click **Open Anyway** next to the Confluo message and confirm with your password or Touch ID.

If the button doesn't appear, run this in Terminal and open Confluo again:

```bash
xattr -dr com.apple.quarantine /Applications/Confluo.app
```

Needed only once. Updates install from inside the app without warnings.

## Requirements

| | |
| --- | --- |
| macOS | 14.4 Sonoma or later |
| Mac | Apple silicon and Intel (universal build; tested on Apple silicon) |
| iPhone / iPad | Any with AirPlay, on the same Wi-Fi as the Mac |
| Permissions | System Audio Recording, Local Network, Notifications |

## Limitations

- macOS can't receive Bluetooth audio, so iPhones use AirPlay over Wi-Fi.
- *Low* latency (default, ~0.15 s) makes video on the iPhone run ahead of its sound. Use *Synced with video* for that.
- AirPlay 1 only. Up to 6 iPhones at once.
- Liquid Glass styling needs macOS 26; earlier versions use standard materials.

## Updates

Confluo checks GitHub once a day and asks before installing. Change it or check manually in **Settings → Updates**.

## Build from source

Requires Xcode 16+.

```bash
git clone https://github.com/Monayzera/confluo-audio.git
cd confluo-audio
./scripts/build-app.sh --install
```

Tests: `swift test`. Releases: bump `VERSION`, commit, run `./scripts/release.sh` (needs `pip install dmgbuild`).

## License

[MIT](LICENSE)
