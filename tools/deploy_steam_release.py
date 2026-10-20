"""Deploy the reviewed Steam port with exact preimages, rollback and hash checks."""
from pathlib import Path
import argparse
import json
import os
import zipfile

from archive import read
from build_steam_probe import GAME, digest
from deploy_steam_probe import closed


def deploy(game, candidate, expected, rollback=False):
    closed()
    game, candidate = Path(game).resolve(), Path(candidate).resolve()
    settings = Path(os.environ['LOCALAPPDATA']) / 'LLL/Helldivers2/Settings'
    record = candidate / 'deployment.json'
    cfg = settings.parent / 'LLL.cfg'
    def target(group, name):
        root = game / 'data' if group == 'game' else (settings.parent / 'Service' if group == 'service' else settings)
        if Path(name).name != name:
            raise ValueError('Unsafe deployment filename')
        return root / name
    if rollback:
        receipt = json.loads(record.read_text())
        for row in receipt['files']:
            if digest(target(row['group'],row['name']).read_bytes()) != row['after']:
                raise ValueError('Installed candidate changed; refusing rollback')
        with zipfile.ZipFile(candidate / 'rollback.zip') as backup:
            for row in reversed(receipt['files']):
                path = target(row['group'],row['name'])
                if row['before'] is None: path.unlink()
                else:
                    value = backup.read(row['group']+'/'+row['name'])
                    if digest(value) != row['before']: raise ValueError('Rollback bytes changed')
                    temporary = path.with_name(path.name+'.lll-rollback.tmp')
                    with temporary.open('xb') as stream: stream.write(value)
                    os.replace(temporary,path)
        print('Restored reviewed pre-deployment bytes')
        return
    if record.exists(): raise ValueError('Deployment already recorded')
    for name, value in GAME.items():
        if digest((game/name).read_bytes()) != value: raise ValueError('Installed game changed: '+name)
    info = json.loads((candidate/'build.json').read_text())
    old = (game/'data/9ba626afa44a3aa3.patch_0').read_bytes()
    if digest(old) != expected: raise ValueError('Startup patch changed since review')
    if set(read(old)) not in ({0x7251fdd9bb62480a,0xf476df93691895fa},{0xf476df93691895fa}):
        raise ValueError('Existing patch contains unreviewed resources')
    changes=[]
    for suffix in ('','.stream','.gpu_resources'):
        name='9ba626afa44a3aa3.patch_0'+suffix
        value=(candidate/'data'/name).read_bytes()
        if digest(value) != (info['patch_sha256'] if not suffix else digest(b'')):
            raise ValueError('Candidate archive changed')
        changes.append(('game',name,value))
    if 'service' in info:
        helper=(candidate/info['service']).read_bytes()
        if digest(helper)!=info['service_sha256']:raise ValueError('Service changed')
        changes.append(('service',info['service'],helper))
        (settings.parent/'Service').mkdir(parents=True,exist_ok=True)
    else:
        helper=(candidate/info['helper']).read_bytes()
        if digest(helper) != info['helper_sha256']: raise ValueError('Helper changed')
        changes.append(('settings',info['helper'],helper))
    settings.mkdir(parents=True,exist_ok=True)
    config_hash=digest(cfg.read_bytes()) if cfg.is_file() else None
    rows=[]
    with zipfile.ZipFile(candidate/'rollback.zip','x',zipfile.ZIP_DEFLATED) as backup:
        for group,name,value in changes:
            path=target(group,name); before=path.read_bytes() if path.exists() else None
            if before == value: continue
            if before is not None: backup.writestr(group+'/'+name,before)
            rows.append({'group':group,'name':name,'before':digest(before) if before is not None else None,'after':digest(value)})
    receipt={'game':str(game),'files':rows,'configuration_sha256':config_hash,'state':'prepared','live':'pending'}
    record.write_text(json.dumps(receipt,indent=2))
    values={(group,name):value for group,name,value in changes}
    closed()
    for row in rows:
        path=target(row['group'],row['name'])
        if (digest(path.read_bytes()) if path.exists() else None) != row['before']:
            raise ValueError('Target changed before replacement')
        temporary=path.with_name(path.name+'.lll-steam.tmp')
        with temporary.open('xb') as stream: stream.write(values[row['group'],row['name']])
        os.replace(temporary,path)
    for row in rows:
        if digest(target(row['group'],row['name']).read_bytes()) != row['after']:
            raise ValueError('Installed hash mismatch')
    if (digest(cfg.read_bytes()) if cfg.exists() else None) != config_hash:
        raise ValueError('User configuration changed during deployment')
    receipt['state']='installed hashes verified; configuration preserved'
    record.write_text(json.dumps(receipt,indent=2))
    print(receipt['state'])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game',required=True,type=Path)
    parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--expected-patch',required=True)
    parser.add_argument('--rollback',action='store_true')
    args=parser.parse_args()
    deploy(args.game,args.candidate,args.expected_patch,args.rollback)
