#!/usr/bin/env python3
"""Rebuild using a locally supplied Cherri 2.3.0; NEVER invoke a signing server."""
import os, pathlib, re, shutil, subprocess, sys
ROOT=pathlib.Path(__file__).parent
compiler=os.environ.get('CHERRI',str(ROOT/'bin/cherri'))
version=subprocess.check_output([compiler,'--version'],text=True)
if 'v2.3.0' not in version:raise SystemExit('Use pinned Cherri v2.3.0')
for source,output in [('SSClip-send.cherri','SSClip发送_unsigned.shortcut')]:
 dest=ROOT/output
 if dest.exists():dest.unlink()
 result=subprocess.run([compiler,str(ROOT/source),'--skip-sign','--no-ansi'],cwd=ROOT,text=True,capture_output=True)
 if result.returncode or 'Error:' in result.stdout+result.stderr or not dest.exists():
  raise SystemExit('Compilation failed: '+result.stdout+result.stderr)
subprocess.run([sys.executable,str(ROOT/'normalize_shortcuts.py')],check=True)
subprocess.run([sys.executable,str(ROOT/'validate_shortcuts.py')],check=True)
for source,output in [('SSClip发送_unsigned.shortcut','SSClip-Send.unsigned.shortcut')]:
 shutil.copyfile(ROOT/source,ROOT/output)
 resources=ROOT.parent/"Resources"
 if resources.is_dir(): shutil.copyfile(ROOT/source,resources/output)
print('Unsigned resources generated. Apple signing and iOS runtime remain separate required checks.')
