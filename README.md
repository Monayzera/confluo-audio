<p align="center"><img src="docs/banner.png" alt="Confluo — Every device. One sound."></p>

Confluo mixes your Mac's audio with audio from your iPhones into one output, each source with its own volume.
iPhones connect over AirPlay, no app needed on the phone.

## Download

Get **Confluo-x.y.z.dmg** from the [latest release](https://github.com/Monayzera/confluo-audio/releases/latest), open it and drag **Confluo** to Applications.

The app is not notarized. On first launch macOS blocks it: open **System Settings → Privacy & Security** and click **Open Anyway**. Needed only once; updates install from inside the app.

Then on the iPhone: Control Center → AirPlay → **“Mac name · Confluo”**.

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
