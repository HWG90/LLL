"""Install/remove only the recorded current-Steam startup probe; game must be closed."""
from pathlib import Path
import argparse
import json
import os
import subprocess

from build_steam_probe import GAME, digest


def closed():
    result = subprocess.check_output(['tasklist', '/FI', 'IMAGENAME eq helldivers2.exe', '/FO', 'CSV', '/NH'])
    if b'"helldivers2.exe"' in result.lower():
        raise RuntimeError('Close Helldivers 2 before changing its resource archives')


def deploy(game, candidate, rollback=False):
    closed()
    game, candidate = Path(game).resolve(), Path(candidate).resolve()
    receipt = candidate / 'deployment.json'
    if rollback:
        rows = json.loads(receipt.read_text())['files']
        for row in rows:
            target = game / 'data' / row['name']
            if target.parent != game / 'data' or digest(target.read_bytes()) != row['sha256']:
                raise ValueError('Probe target changed; refusing removal')
        closed()
        for row in rows:
            (game / 'data' / row['name']).unlink()
        (candidate / 'rollback-completed.json').write_text(json.dumps({'removed':rows}, indent=2))
        return
    if receipt.exists():
        raise ValueError('Probe already deployed; inspect existing receipt')
    for name, expected in GAME.items():
        if digest((game / name).read_bytes()) != expected:
            raise ValueError('Installed game changed: ' + name)
    info = json.loads((candidate / 'probe.json').read_text())
    names = ['9ba626afa44a3aa3.patch_101' + suffix for suffix in ('', '.stream', '.gpu_resources')]
    rows = []
    for name in names:
        target = game / 'data' / name
        payload = (candidate / name).read_bytes()
        if target.exists() or target.with_name(name + '.lll-probe.tmp').exists():
            raise ValueError('Probe slot is already occupied: ' + name)
        expected = info['probe_sha256'] if name == names[0] else digest(b'')
        if digest(payload) != expected:
            raise ValueError('Candidate payload changed')
        rows.append({'name':name, 'sha256':expected, 'previously_present':False})
    receipt.write_text(json.dumps({'game':str(game), 'purpose':info['purpose'], 'files':rows,
                                   'state':'prepared'}, indent=2))
    closed()
    for row in rows:
        target = game / 'data' / row['name']
        temporary = target.with_name(target.name + '.lll-probe.tmp')
        with temporary.open('xb') as stream:
            stream.write((candidate / row['name']).read_bytes())
        # Windows rename refuses an existing destination rather than replacing it.
        os.rename(temporary, target)
    for row in rows:
        if digest((game / 'data' / row['name']).read_bytes()) != row['sha256']:
            raise ValueError('Installed verification failed')
    result = json.loads(receipt.read_text())
    result['state'] = 'installed-hashes-verified; live startup pending'
    receipt.write_text(json.dumps(result, indent=2))
    print(result['state'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--rollback', action='store_true')
    args = parser.parse_args()
    deploy(args.game, args.candidate, args.rollback)
