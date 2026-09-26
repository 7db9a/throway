#!/usr/bin/env python3
"""Create placeholder release downloads for rehearsing the release job.

The Linux archive is a runnable stand-in whose commands only exit 0. The
Windows zip holds a stand-in install-windows.ps1 that records its arguments.
Neither contains product code.
"""
import argparse
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import zipfile

spec = importlib.util.spec_from_file_location('download', Path(__file__).with_name('prepare-standard-download.py'))
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)

COMMANDS = ('dearmachine', 'machtiani', 'machtiani-installer', 'machtiani-model-host', 'agent-manager', 'git-lfs', 'python3')
WINDOWS_INSTALLER = '''param([string]$Bundle, [string]$Destination, [switch]$Update)
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
Set-Content -LiteralPath (Join-Path $Destination 'rehearsal-install.txt') -Value "bundle=$Bundle update=$Update"
Write-Output "Rehearsal install recorded in $Destination"
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True, choices=('linux-x64', 'windows-x64'))
    parser.add_argument('--tag', required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir()
    prefix = f'dearmachine-{args.tag}-{args.target}'
    if args.target == 'windows-x64':
        with zipfile.ZipFile(args.output / (prefix + '.zip'), 'w', zipfile.ZIP_DEFLATED) as bundle:
            bundle.writestr('source/scripts/install-windows.ps1', WINDOWS_INSTALLER)
        return
    archive = args.output / (prefix + '.tar.gz')
    with tarfile.open(archive, 'w:gz') as tar:
        for name in ('bootstrap-runtime.sh', *('bin/' + command for command in COMMANDS)):
            content = b'#!/bin/sh\nexit 0\n'
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(content), 0o755
            tar.addfile(info, io.BytesIO(content))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    base_url = f'https://github.com/{args.repository}/releases/download/{args.tag}'
    (args.output / (prefix + '.bootstrap.sh')).write_text(
        download.render_bootstrap(base_url, digest, 'rehearsal-' + digest[:12], archive.name))


if __name__ == '__main__':
    main()
