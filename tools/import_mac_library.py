#!/usr/bin/env python3
"""Validate and privately install a complete CRATE Duo library folder on this Mac."""
import argparse
import json
import shutil
import subprocess
import sys
import uuid
from pathlib import Path


def inspect(root):
    metadata = {}
    refs = set()
    counts = {}
    for name, key in [('oneshots.json', 'samples'), ('loops.json', 'loops')]:
        data = json.loads((root / name).read_text())
        entries = data[key]
        if not isinstance(entries, list) or not entries:
            raise ValueError(f'{name} has no {key}')
        counts[key] = len(entries)
        for entry in entries:
            relative = entry['file']
            if not isinstance(relative, str) or Path(relative).is_absolute():
                raise ValueError(f'{name} contains a non-relative audio path')
            media = (root / relative).resolve()
            if not media.is_relative_to(root):
                raise ValueError(f'{name} contains an audio path outside the library')
            refs.add(relative)
        metadata[name] = data
    grooves = json.loads((root / 'grooves.json').read_text())
    if not grooves.get('grooves'):
        raise ValueError('grooves.json has no grooves')
    metadata['grooves.json'] = grooves
    missing = [r for r in sorted(refs) if not (root / r).is_file() or (root / r).stat().st_size == 0]
    return metadata, refs, counts, missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='The complete library folder, usually duo-hack/build/library')
    parser.add_argument('--dry-run', action='store_true', help='Check completeness without copying or changing app settings')
    parser.add_argument('--verify-audio', action='store_true', help='Also check that afinfo can read each referenced audio file')
    args = parser.parse_args()
    root = args.source.expanduser().resolve(strict=True)
    metadata, refs, counts, missing = inspect(root)
    report = {'one_shots': counts['samples'], 'loops': counts['loops'], 'referenced_audio_files': len(refs),
              'missing_audio_files': len(missing), 'missing_examples': missing[:5]}
    if missing:
        print(json.dumps(report, indent=2))
        return 2
    if args.verify_audio:
        unreadable = [r for r in sorted(refs) if subprocess.run(['afinfo', str(root / r)],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0]
        report['unreadable_audio_files'] = len(unreadable)
        if unreadable:
            print(json.dumps(report, indent=2))
            return 2
    if args.dry_run:
        report['complete'] = True
        print(json.dumps(report, indent=2))
        return 0
    parent = Path.home() / 'Library/Application Support/CRATE/libraries'
    parent.mkdir(parents=True, exist_ok=True)
    destination = parent / ('duo-' + uuid.uuid4().hex[:12])
    stage = parent / ('.staging-' + uuid.uuid4().hex)
    stage.mkdir()
    try:
        for relative in refs:
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / relative, target)
        for name in metadata:
            shutil.copy2(root / name, stage / name)
        for name in ['vibes.json', 'demo_samples.json']:
            if (root / name).is_file():
                json.loads((root / name).read_text())
                shutil.copy2(root / name, stage / name)
        stage.rename(destination)
        subprocess.run(['defaults', 'write', 'com.shuhan.crate.mac', 'crateMacLibraryPath', '-string', str(destination)], check=True)
    except Exception:
        if stage.exists():
            shutil.rmtree(stage)
        raise
    report.update(complete=True, installed_path=str(destination), next_step='Restart CRATE to load the verified library.')
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'Library not installed: {error}', file=sys.stderr)
        sys.exit(2)
