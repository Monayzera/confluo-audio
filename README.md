<p align="center"><img src="docs/banner.png" alt="Confluo — Every device. One sound."></p>

Confluo mixes your Mac's audio with audio from your iPhones into one output, each source with its own volume.
iPhones connect over AirPlay, no app needed on the phone.

## Install

Requires macOS 14.4+ and Xcode 16+.

```bash
git clone https://github.com/Monayzera/confluo-audio.git
cd confluo-audio
./scripts/build-app.sh --install
```

Open Confluo, allow the permissions macOS asks for, then on the iPhone pick **“Mac name · Confluo”** in Control Center → AirPlay.

Run tests with `swift test`.

## Limitations

- macOS can't receive Bluetooth audio, so iPhones use AirPlay over Wi-Fi.
- *Low* latency (default, ~0.15 s) makes video on the iPhone run ahead of its sound. Use *Synced with video* for that.
- AirPlay 1 only.

## License

[MIT](LICENSE)
