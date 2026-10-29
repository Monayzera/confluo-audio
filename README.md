# Confluo

Confluo turns your Mac into an audio hub: it receives audio from one or more iPhones over AirPlay and mixes it with the Mac's own sound into a single stream on your current output — headphones, AirPods, speakers. Game audio on the Mac and music from the iPhone play at the same time, each with its own volume.

## Features

- **AirPlay receiver** built in: the Mac shows up on the iPhone as “*Mac name* · Confluo” (renameable). No app needed on the iPhone.
- **Several iPhones at once**, each one a separate source in the mixer.
- **This Mac as a source**: system audio is captured with a Core Audio process tap and remixed, so it gets its own volume.
- **Per-source volume, mute and solo**, plus an independent master volume and a soft limiter that prevents clipping when sources add up.
- **Live level meters**, now playing (title, artist, artwork) and play/pause/next/previous for each iPhone.
- **Low latency**: iPhone audio plays about 0.15–0.3 s after it leaves the phone, instead of AirPlay's usual 2 seconds. A *Synced with video* mode keeps AirPlay's schedule when you watch videos on the iPhone.
- **iPhone volume buttons** move that iPhone's slider in Confluo.
- **Follows the system output**: switch to your AirPods in macOS and Confluo follows.
- **Menu bar app** with a quick mixer popover and a full window (Mixer, Devices, Shortcuts, Settings).
- **Global shortcuts** (all configurable): ⌃⌥M mute/unmute iPhones, ⌃⌥↑ / ⌃⌥↓ master volume, ⌃⌥A open the mixer.
- Remembers devices, opens at login, optional notifications, English and Brazilian Portuguese.
- Liquid Glass controls on macOS 26 and later, native materials on earlier versions.

## Requirements

- macOS 14.4 or later (Apple silicon or Intel).
- iPhone/iPad on the same network as the Mac.
- Xcode 16 or later (Swift 6 toolchain) to build.

## Build and run

```bash
./scripts/build-app.sh
open build/Confluo.app
```

To install into `/Applications` (recommended, so “Open at login” keeps working):

```bash
./scripts/build-app.sh --install
```

The script signs ad hoc by default. To sign with your own certificate set `CONFLUO_SIGN_IDENTITY`, which also keeps macOS permissions across rebuilds:

```bash
CONFLUO_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

Run the tests with `swift test`.

## Using it

1. Open Confluo. Approve **System Audio Recording** (needed for the Mac's own volume), **Notifications** and **Local Network** when macOS asks.
2. On the iPhone, open Control Center, tap the AirPlay icon on the music controls and pick “*Mac name* · Confluo”.
3. Adjust each source from the menu bar icon.

If you do not want the Mac's audio to pass through Confluo, turn off **Mix this Mac's audio** in Settings; the Mac then plays directly and only the iPhones go through the mixer.

## How it works

| Part | Implementation |
| --- | --- |
| Receiver | AirPlay 1 (RAOP) over RTSP/RTP: Bonjour `_raop._tcp`, Apple-Challenge, RSA-OAEP session key, AES-128-CBC packets, ALAC decoding with `AudioConverter`, retransmission requests, timing replies, metadata and artwork. |
| Sync | *Low* and *Balanced* modes keep a small adaptive jitter buffer sized from the worst packet arrival of the last 3 seconds plus a safety margin. *Synced with video* schedules from the sender's sync packets and NTP clock, as AirPlay intends. Clock drift is absorbed with sub-0.2% resampling. |
| Mac audio | `CATapDescription` global tap that excludes Confluo itself, muted while tapped, read through a private tap-only aggregate device. |
| Mixer | Lock-free C core: per-source ring buffers, cubic interpolation, smoothed gain changes, soft limiter, peak meters. |
| Output | `kAudioUnitSubType_DefaultOutput`, output only, so Bluetooth headphones stay in high-quality mode. |
| Remote control | DACP (`_dacp._tcp`) to send play/pause/skip and volume back to the iPhone. |

## Limitations

- **macOS cannot receive Bluetooth audio** (there is no public A2DP sink API), so iPhones connect over AirPlay on Wi-Fi.
- In *Low* latency mode the iPhone still delays its own video by about 2 seconds to match AirPlay, so video on the iPhone will show sound before picture; switch to *Synced with video* for that. On a weak Wi-Fi, *Balanced* avoids dropouts.
- AirPlay 2-only features (multi-room grouping, lower buffered latency) are not supported.
- iOS keeps AirPlay 1 support, but Apple could change that in a future release.

## Notes

The RSA key used for the AirPlay 1 handshake is the AirPort Express key published in 2011 and used by open-source receivers such as shairport-sync. Confluo does not include code from those projects.

## License

MIT — see [LICENSE](LICENSE).
