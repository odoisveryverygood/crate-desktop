#!/usr/bin/env python3
"""Package a built CRATE.app with a complete original library, then sign and ZIP it."""
import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path
from import_mac_library import inspect

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('app',type=Path);p.add_argument('library',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();app=a.app.resolve();lib=a.library.resolve();out=a.output.resolve()
    if not app.is_dir() or app.suffix!='.app':raise ValueError('A built .app is required')
    _,refs,_,missing=inspect(lib)
    if missing:raise ValueError(f'The library is incomplete: {len(missing)} missing audio files')
    if app==out/'CRATE.app':raise ValueError('Build input must differ from the output app')
    out.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='crate-package-') as tmp:
        stage=Path(tmp)/'CRATE.app'
        subprocess.run(['ditto',str(app),str(stage)],check=True)
        bundled=stage/'Contents/Resources/StudioLibrary';bundled.mkdir(parents=True,exist_ok=True)
        for relative in refs:
            dest=bundled/relative;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(lib/relative,dest)
        for name in ['oneshots.json','loops.json','grooves.json','vibes.json','PROVENANCE.md']:
            if (lib/name).is_file():shutil.copy2(lib/name,bundled/name)
        entitlements=Path(__file__).resolve().parents[1]/'Resources/Mac.entitlements'
        subprocess.run(['codesign','--force','--sign','-','--options','runtime','--entitlements',str(entitlements),str(stage)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(stage)],check=True)
        subprocess.run(['ditto',str(stage),str(out/'CRATE.app')],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(out/'CRATE.app')],check=True)
        subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(out/'CRATE.app'),str(out/'CRATE-Mac.zip')],check=True)
    print(f'Packaged {len(refs)} audio files in {out / "CRATE-Mac.zip"}')

if __name__=='__main__':main()
