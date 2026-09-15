#!/usr/bin/env python3
"""Run checksum-pinned upstream security tools without placing credentials in output."""

import argparse
import hashlib
import io
from pathlib import Path
import platform
import subprocess
import tarfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
TOOLS = {
    'actionlint': ('rhysd/actionlint', '1.7.12', {
        'Darwin-arm64': ('darwin_arm64', 'aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f'),
        'Linux-x86_64': ('linux_amd64', '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8'),
    }),
    'gitleaks': ('gitleaks/gitleaks', '8.30.1', {
        'Darwin-arm64': ('darwin_arm64', 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5'),
        'Linux-x86_64': ('linux_x64', '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'),
    }),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tool', choices=TOOLS)
    args = parser.parse_args()
    repository, version, builds = TOOLS[args.tool]
    target = platform.system() + '-' + platform.machine()
    if target not in builds:
        parser.error('Supported hosts: Apple silicon macOS or x86_64 Linux')
    suffix, expected = builds[target]
    filename = f'{args.tool}_{version}_{suffix}.tar.gz'
    cache = ROOT / '.build' / 'security-tools'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / filename
    if not archive.exists():
        with urlopen(f'https://github.com/{repository}/releases/download/v{version}/{filename}', timeout=60) as response:
            archive.write_bytes(response.read(50 * 1024 * 1024 + 1))
    data = archive.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('Security tool checksum mismatch; remove the cached archive and investigate')
    executable = cache / f'{args.tool}-{version}'
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as bundle:
        member = bundle.getmember(args.tool)
        if not member.isfile():
            raise ValueError('Expected a regular executable in the verified archive')
        executable.write_bytes(bundle.extractfile(member).read())
    executable.chmod(0o700)
    command = [str(executable)]
    if args.tool == 'actionlint':
        command += ['-color']
    else:
        command += ['git', '--redact=100', '--no-banner', '--log-opts=--all', str(ROOT)]
    return subprocess.run(command, cwd=ROOT).returncode


if __name__ == '__main__':
    raise SystemExit(main())
