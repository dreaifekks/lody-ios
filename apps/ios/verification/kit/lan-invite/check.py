#!/usr/bin/env python3
"""Small offline Swift checks; no Xcode build, simulator, Keychain or real hub."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[5]
LOCK = Path('/tmp/lody-ios-mac-heavy.lock')


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    try:
        LOCK.mkdir()
    except FileExistsError:
        raise SystemExit('LOCK_BUSY: leave the current native job alone')
    try:
        (LOCK / 'owner').write_text(f'lan-data-p0-lightweight {os.getpid()}\n')
        load = os.getloadavg()[0]
        if load > 30:
            raise SystemExit(f'LOAD_HIGH: {load:.2f}; no compilation run')
        with tempfile.TemporaryDirectory(prefix='lody-lan-p0-') as temp:
            output = Path(temp)
            swift = ['swiftc', '-swift-version', '6', '-module-cache-path', '/tmp/lody-lan-p0-cache']
            kit = ROOT / 'packages/LodyKit/Sources/LodyKit'
            auth = kit / 'Auth'
            cloud = kit / 'Cloud'
            sources = [auth / f'{name}.swift' for name in ['LanInvite', 'AuthKeychain', 'LanHub', 'LanHubFollower']]
            sources += [cloud / 'BackendEnvironment.swift']
            sources += [kit / f'LAN/{name}.swift' for name in ['LanMemberProtocol', 'LanMemberChannel']]
            for case in ['lan-invite', 'lan-hub-follow']:
                binary = output / case
                run(*swift, *sources, ROOT / f'apps/ios/verification/kit/{case}/main.swift', '-o', binary)
                run(binary)
            binary = output / 'scheme'
            run(*swift, '-parse-as-library', auth / 'LanInvite.swift', cloud / 'LanHubSchemeHandler.swift',
                ROOT / 'apps/ios/verification/kit/lan-invite/scheme/main.swift', '-o', binary)
            run(binary)
            core = sorted((ROOT / 'packages/lody-core/Sources/LodyCore').rglob('*.swift'))
            run(*swift, '-emit-library', '-emit-module', '-module-name', 'LodyCore',
                '-emit-module-path', output / 'LodyCore.swiftmodule', *core, '-o', output / 'libLodyCore.dylib')
            outbox = [kit / f'Outbox/{name}.swift'
                      for name in ['OutboxRecord', 'OutboxStore', 'OutboxForeground', 'OutboxDispatcher']]
            binary = output / 'outbox'
            run(*swift, '-parse-as-library', '-I', output, '-L', output, '-lLodyCore', *outbox,
                ROOT / 'apps/ios/verification/kit/lan-invite/outbox/Support.swift',
                ROOT / 'apps/ios/verification/kit/lan-invite/outbox/main.swift', '-o', binary)
            run(binary)
            run(*swift, '-typecheck', ROOT / 'packages/lody-core/Sources/LodyRuntime/RuntimeDocument.swift')
            print('PASS: lightweight LAN checks; no system credentials, network or app build used')
    finally:
        (LOCK / 'owner').unlink()
        LOCK.rmdir()


if __name__ == '__main__':
    main()
