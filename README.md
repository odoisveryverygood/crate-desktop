# CRATE Desktop

CRATE is an AI-assisted music sampler with a native Mac app and a Windows desktop beta. Build a beat from a prompt, browse and chop sounds, play pad banks and keys, add independent instrument layers, save projects, and export WAV audio. Jev prepares fast plans while GPT refines arrangements in the background.

This repository contains the desktop source and a separate Cloudflare AI gateway. Provider credentials belong in server secrets or each user's private OS storage; none are included in the repository. The apps support the existing hosted beta after AI consent, so testers do not need personal provider keys. Hosted usage has per-installation and shared quotas.

## Platforms

| App | Requirements | Implementation |
| --- | --- | --- |
| Native Mac | Apple Silicon, macOS 26+; Xcode 27 SDK to build | Swift / SwiftUI / AVFoundation |
| Windows beta | Windows x64; Node.js 24 and Python 3 to build | Electron / Web Audio |

The Windows port includes the core sampler and AI workflow. Advanced native Mac song arrangement, per-bar performance, audience display, speech transcription and the complete Mac effects stack have not all been ported. Windows and Mac projects currently use separate formats. Linux packaging is experimental and has not been verified on Linux hardware.

## Original sounds

The repository includes a small original synthesized starter kit for the native Mac app. Generate the full Studio library locally: **1,176 one-shots and 520 loops**. The scripts use NumPy and procedural synthesis; they do not download commercial sample packs. Instrument names describe synthesized timbres.

### Native Mac

Install Xcode 27 and its command-line tools, plus XcodeGen. From the repository root:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install numpy
python tools/generate_sampler_library.py build/studio-library
# Install XcodeGen if needed: brew install xcodegen
bash tools/build_mac.sh
python tools/package_mac_studio.py build/mac/Build/Products/Release/CRATE.app build/studio-library build/package
open build/package/CRATE.app
```

The packaged app has the full Studio library. `build_mac.sh` uses an ad-hoc signature. Public Mac distribution still needs Developer ID signing and notarization; `tools/release_mac.sh` supplies that workflow when the required certificate and notary profile are available.

### Windows

In PowerShell, from the repository root:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install numpy
.\.venv\Scripts\python.exe tools/generate_sampler_library.py build/studio-library
cd desktop
npm ci
node scripts/prepare-assets.mjs ../build/studio-library
npm test
npm start
```

Run `npm run build:windows` from `desktop/` on Windows to create an x64 installer and portable ZIP. The current configuration produces unsigned beta packages. See [Windows details](desktop/README.md) for controls and limits.

## Verification

After preparing the Studio library and installing the desktop dependencies:

```sh
cd desktop
npm test
npm run verify
```

`verify` exercises the real renderer, audio export and project save/load in isolated storage. `verify:hosted` explicitly adds live hosted Jev/GPT calls. It consumes beta quota. The gateway's security and quota checks run with:

```sh
node --test desktop-worker/test/gateway.test.js
```

This public snapshot passed a native Mac Release build and all 27 sampler/gateway tests on October 14, 2026.

Historical implementation checks passed on the original development checkout: 14 Windows core tests, 13 installed Windows checks, 15 Windows checks including hosted AI, and 104 native Mac Studio checks. These do not establish signing, physical microphone/speaker compatibility or latency on every computer. See [Mac details](docs/MAC.md) for native verification flags.

## Repository layout

- `Sources/`, `Resources/`, `mac-project.yml`: native Mac target and shared sampler code.
- `desktop/`: Windows Electron application, renderer, tests and packaging.
- `desktop-worker/`: hosted-session, Jev/GPT contract and quota gateway.
- `tools/`: original sound generation, native builds and packaging.
- `library/grooves.json`: groove templates used by the sound generator.

Based on CRATE Duo by Shuhan Zhang and contributors, with desktop work by Aradhya Mishra. See [attribution](ATTRIBUTION.md) and the bundled font notices. No new project-wide software license has been added.
