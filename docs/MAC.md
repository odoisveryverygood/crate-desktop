# CRATE for Mac

Native Apple Silicon macOS app, macOS 26 or later. The app uses the existing `LidDisplayView`, `DeckView`, pad editor, song grid, keys, sampler, FX, import and export code. Jev and GPT use the shared orchestration and connect automatically to the desktop Cloudflare gateway after AI consent. Personal keys and the existing proxy are optional advanced connections. The Mac entry point supplies AppKit mouse/keyboard bridges and Mac lifecycle, microphone, file panels and settings.

## Build and run

With Xcode 27.1 and XcodeGen installed:

```sh
tools/build_mac.sh
open build/mac/Build/Products/Release/CRATE.app
```

`CONFIGURATION=Debug tools/build_mac.sh` builds the integration-check version. This script signs locally with an ad-hoc signature. A public installer still needs the team's distribution identity and notarization or Mac App Store submission.

The iOS project stays separate: `xcodegen generate` uses `project.yml`, while the Mac build uses `mac-project.yml`. The iOS target excludes `Sources/Mac`.

## Controls and storage

- The lid and deck appear side by side in wide windows and vertically in tall windows.
- Pads use Z/X/C/V, A/S/D/F, Q/W/E/R, 1/2/3/4. KEYS retains the existing musical typing mapping. Performance input yields to text fields and releases notes on focus loss.
- Cmd-O imports audio; Cmd-S saves; Cmd-Z / Cmd-Shift-Z undo/redo; Cmd-Shift-E opens projects/export. Performance → Audience Display opens the existing crowd view in another window.
- Import audio through Finder, the prompt's + control, or drag audio onto a pad. The same chop and bank-preservation rules apply.
- Projects, imported samples and exports are stored in `~/Library/Application Support/CRATE`. Starter audio is encoded as `~kit/` references; imported audio uses the existing `~docs/` references.
- CRATE → Settings contains the private AI connection and optional sample-library folder. The bundled starter kit makes playback work without developer-specific folders. The full indexed commercial library is not in this checkout. Verify redistribution rights before packaging additional sounds for public distribution.

## Jev and credentials

CRATE's proxy token is stored in the login Keychain under `com.shuhan.crate.mac.ai`. A user-supplied personal Jev key can also be saved under the `jev-key` Keychain account. It takes precedence for Jev requests and is sent only as a Bearer header to `https://api.typesafe.ai/v1/systemone`. The Mac build does not embed either credential. OpenAI can use a personal key in the `openai-key` account, sent only to `https://api.openai.com/v1/responses`. A personal Jev key does not enable GPT. Settings includes Test Jev and Test GPT actions, reporting success and timing without showing credentials. Personal keys are optional; the default hosted backend enrolls recipients automatically. The app and ZIP contain no provider credentials.

The shared `JevClient` preserves warm-up after AI consent, question sets, the 900 ms plan timeout, and per-bar performance. Local retrieval/templates remain playable when unavailable; GPT refinements stay off the first-beat path. These timeouts are not measured end-to-end latency claims.

For a development build, the existing DEBUG environment overrides remain available. Avoid placing credentials in shell history or logs. Do not commit `Config/Secrets.xcconfig` or secret files.

## Native integration checks

The Debug app supports:

```sh
build/mac/Build/Products/Debug/CRATE.app/Contents/MacOS/CRATE \
  -crateMacVerify 1 -crateMacVerifyOutput /absolute/path/to/check.json
```

Run this in an isolated development session. The checks use the actual audio engine and resources: all 16 starter pads, keyboard focus and key-up behavior, nonzero live audio output, WAV duration/content, M4A decoding, project round-trip, import-to-16-chops, neighboring-bank preservation, and local DIG. It saves test projects and exports into the Mac app's storage. Release builds exclude these checks and development flags.

Microphone recording and speech are ported but need a real permission/capture session on the user's Mac; compilation and audio-output checks do not establish capture quality. Live Jev responses and GPT-4.1 mini arrangement/flip responses were verified on the Mac. Purchases are not verified. The paywall remains off, matching current iOS main.

## Installing the full Duo library

The library audio is not tracked in Git. The source indexes in this checkout describe 555 one-shots and 77 loops, but none of their 632 audio files is present. Obtain the complete `~/duo-hack/build/library` folder from the Mac that produced the Duo build (or its WAV source `~/duo-hack/library`). Keep `oneshots.json`, `loops.json`, `grooves.json`, and the referenced `oneshots/` and `loops/` audio together. A ZIP of that folder is suitable for private transfer; unzip it before selecting it.

Settings → Choose Library Folder validates every referenced sound with AVAudioFile before accepting the folder. It reports actual counts and refuses missing/unreadable media. Restart CRATE to activate an accepted library.

For a private app-managed copy rather than an external-folder link:

```sh
python3 tools/import_mac_library.py /path/to/library --dry-run --verify-audio
python3 tools/import_mac_library.py /path/to/library --verify-audio
```

The installer copies only index files and referenced audio into a fresh folder under `~/Library/Application Support/CRATE/libraries`, updates the Mac library setting, and keeps existing libraries and projects. No commercial audio is added to Git or the downloadable app ZIP.

### Original synthesized library

`tools/generate_original_library.py /path/to/CRATE-Original-Library` creates an original procedural pack with 128 one-shots across all 16 pad categories and 56 four-bar loops (piano, electric piano, guitar, pad, strings, synth and bass). It requires NumPy. No third-party audio is used. The instrument labels describe synthesized timbres. The existing groove templates are copied into the output; all audio and tempo/key/chop metadata are generated by the script. Install with `tools/import_mac_library.py` or select the output folder in Mac Settings.

A local native-app check loaded the generated house piano sample into 16 Bank B chops, selected original drum sounds in Bank A, and exported non-silent 48 kHz stereo audio with no clipped samples. The prompt asked for 124 BPM, but the existing planner selected the 128 BPM loop; exact requested tempo is not established by this check. This pack is an original alternative, not a copy of the missing commercial Duo library.

### CRATE Studio sampler pack and browser

`tools/generate_sampler_library.py /path/to/CRATE-Studio-Library` builds 1,176 original one-shots and 520 four-bar loops (1,696 unique audio files). There are eight drum families, pitched instrument samples, and 20 loop instruments across all 13 supported styles. It requires NumPy, uses no external sample audio, and rejects duplicate audio by SHA-256. Instrument labels denote synthesized timbres. Style and mood scores are authored from recipes rather than measured by CLAP. The pack records known tempo, key, chords, onsets, and beat/chop timing. Four-millisecond boundary fades prevent clicks on repeat.

**⌘L / File → Sound Library** opens the Mac browser. Search by instrument, name, mood, category or tempo; filter one-shots/loops and style; preview; load any bank/pad; or chop a loop into 16 Bank D pads. Loading and chopping support Undo. Library chops use the imported-chop contract so flip/layer routing follows Bank D and the session can be restored after project reload. Previously saved projects and private libraries are preserved.

To produce a self-contained release, build the Mac Release target, then run:

```sh
python3 tools/package_mac_studio.py /path/to/built/CRATE.app /path/to/CRATE-Studio-Library /path/to/output
```

The pack is copied into `Contents/Resources/StudioLibrary`, verified, and ad-hoc signed with the app. `AppConfig` selects a user-chosen library first, then the bundled Studio library. Provider credentials remain in Keychain. Audio stays out of Git; the generator is committed. Distribution signing/notarization remains separate from the local build.

Native Studio checks can be run with the Debug app binary and `-crateMacStudioVerify 1 -crateOffline 1 -crateFixedSeed 1 -crateMacLibraryPath /path/to/library -crateMacStudioOutput /path/to/report.json`. These checks bypass user-project boot/save, validate instrument parsing and exact retrieval, decode playable chops and all style kits, exercise full-beat/layer/lane editing and Undo, and export through the actual audio engine. Explicitly named instruments survive Jev's broader choice list. When an exact-tempo sample is available it wins; otherwise the existing nearby-tempo policy applies. Short full-beat prompts with a BPM no longer get mistaken for tempo-only commands.

Melodic additions now allocate four chops per part and retain independent layers instead of always replacing the last line. New instruments use free D/B pads and then spare C pads; bass/keys on C1–C4 and manually loaded non-layer sounds are protected. Asking for the same instrument replaces that instrument's part; “another”/“second”/“extra” requests an additional part. Layers are reconstructed from saved pad IDs on reload and Undo reverses one addition at a time. The native suite checks five simultaneous layers, spare-C allocation and protected bass/keys.

## Mac GPT release (0.2)

The Mac arranger and FLIP IT both use `gpt-4.1-mini`. Responses use strict JSON schemas, `store: false`, and a 3,000-output-token cap. The client omits unsupported reasoning parameters for this model. A private personal key takes precedence over a proxy token. Provider error bodies are not logged; rejected keys and quota failures retain the locally playable beat.

Live isolated verification: arrangement applied, piano/drums decoded, AI chop flip applied without replacing samples, and audio exported (9/9 checks). `-crateMacGPTVerify 1 -crateMacGPTOutput /absolute/report.json` runs these checks in Debug after the user has enabled AI consent and configured a private key. It does not boot or save a user project. The offline Studio verification remains 104 checks.

For public download, package the complete Studio library, then use `tools/release_mac.sh /path/to/CRATE.app 'Developer ID Application: …' notary-profile /path/to/output`. This requires the team's Developer ID Application certificate and a Keychain notary profile. The current local ZIP uses an ad-hoc signature and is not notarized. Supported destination: Apple Silicon, macOS 26+. New users enable AI help and connect automatically through the deployed desktop backend; personal keys in Settings are optional. Do not embed a shared provider key.

## Hosted desktop AI (0.3)

The default Mac connection is now https://crate-desktop-api.pocketvet-ai.workers.dev. New installations enroll automatically after AI consent; users do not need provider keys. An expiring installation session lives in login Keychain. Jev and GPT provider keys are server secrets. Settings shows CRATE AI included and keeps personal connections behind an optional toggle. The worker enforces canonical musical contracts, fixed GPT-4.1 mini, output caps and transactional per-installation/IP/global quotas; see desktop-worker/README.md. The original iPhone worker is unchanged.
