"""Install a verified private LLL package into an existing Proton prefix.

Requires the game and LLL helper closed. Preserves settings/mods and records
exact per-file preimages for guarded rollback. Does not launch Steam or the game.
"""
from pathlib import Path
import argparse,hashlib,json,os,re,struct,uuid,zipfile
SHA=lambda b:hashlib.sha256(b).hexdigest()
PATCH='9ba626afa44a3aa3.patch_0'
ENTRY=0xf476df93691895fa
LUA_TYPE=0xa14e8dfa2cd117e2

def digest(path):
    return SHA(path.read_bytes()) if path.is_file() else None

def assert_closed():
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():continue
        try:name=(entry/'comm').read_text().strip()
        except OSError:continue
        if name=='helldivers2.exe' or name.startswith('lll_steam_servi') or name.startswith('lll_steam_launc'):
            raise ValueError('Close the game and LLL helper/launcher before installation: '+name)

def local_home(prefix):
    prefix=Path(prefix).resolve()
    if not (prefix/'drive_c/users/steamuser').is_dir() or (prefix/'dosdevices/z:').resolve()!=Path('/'):
        raise ValueError('Expected an existing Steam Proton prefix with Z: mapped to /')
    return prefix/'drive_c/users/steamuser/AppData/Local/LLL/Helldivers2'

def target(game,home,key):
    parts=key.split('/')
    if len(parts)!=2:raise ValueError('Invalid target path')
    group,name=parts
    if group=='data' and name in [PATCH,PATCH+'.stream',PATCH+'.gpu_resources']:return game/'data'/name
    if group=='service' and (re.fullmatch(r'lll_steam_(service|launcher)_[0-9a-f]{16}\.exe',name) or name in ['game-root.txt','installed-steam-preview.json']):return home/'Service'/name
    raise ValueError('Unexpected installation target: '+key)

def atomic(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    stage=path.with_name(path.name+'.lll-stage-'+uuid.uuid4().hex)
    try:
        with stage.open('xb') as f:f.write(data);f.flush();os.fsync(f.fileno())
        os.replace(stage,path)
    finally:
        if stage.exists():stage.unlink()

def check_slots(game):
    for p in (game/'data').glob('9ba626afa44a3aa3.patch_*'):
        if p.name==PATCH or not re.fullmatch(r'9ba626afa44a3aa3\.patch_[0-9]+',p.name):continue
        if p.stat().st_size>67108864:raise ValueError('Startup slot too large to verify')
        data=p.read_bytes()
        if len(data)<104 or struct.unpack_from('<I',data)[0]!=0xf0000011:raise ValueError('Unverifiable startup slot '+p.name)
        types,count=struct.unpack_from('<II',data,4);start=72+32*types
        if not 0<types<=100000 or count>100000 or start+80*count>len(data):raise ValueError('Invalid startup slot table')
        for i in range(count):
            name,kind=struct.unpack_from('<QQ',data,start+80*i)
            if name==ENTRY and kind==LUA_TYPE:raise ValueError('Competing startup resource: '+p.name)

def validate(package,game,home):
    info=json.loads((package/'package.json').read_text())
    if info.get('format')!='LLL-Steam-portable-v1':raise ValueError('Unsupported package format')
    if set(info.get('game',{}))!={'bin/helldivers2.exe','data/game/game.dll'}:raise ValueError('Incomplete game identity')
    for key,sha in info['game'].items():
        if not re.fullmatch('[0-9a-f]{64}',sha) or digest(game/key)!=sha:raise ValueError('Unsupported game file: '+key)
    check_slots(game)
    expected={'data/'+PATCH,'data/'+PATCH+'.stream','data/'+PATCH+'.gpu_resources'}
    for field,group,prefix,suffix in [('service','service','lll_steam_service_','.exe'),('launcher','service','lll_steam_launcher_','.exe')]:
        name=info.get(field)
        if name is None and field!='service':continue
        if not isinstance(name,str) or not re.fullmatch(re.escape(prefix)+'[0-9a-f]{16}'+re.escape(suffix),name):raise ValueError('Invalid '+field+' name')
        expected.add(group+'/'+name)
    if set(info.get('payloads',{}))!=expected:raise ValueError('Unexpected or incomplete payload manifest')
    desired={}
    for key,sha in info['payloads'].items():
        target(game,home,key)
        value=(package/key).read_bytes()
        if not re.fullmatch('[0-9a-f]{64}',sha) or SHA(value)!=sha:raise ValueError('Changed payload: '+key)
        if key.startswith('service/') and sha[:16] not in key:raise ValueError('Content-address mismatch: '+key)
        installed=target(game,home,key)
        if key.startswith('service/') and installed.exists() and digest(installed)!=sha:
            raise ValueError('Existing content-addressed payload differs: '+key)
        desired[key]=value
    for suffix in ['.stream','.gpu_resources']:
        if desired['data/'+PATCH+suffix]:raise ValueError('Unexpected startup sidecar payload')
        old=game/'data'/(PATCH+suffix)
        if old.exists() and old.stat().st_size:raise ValueError('Conflicting startup sidecar')
    patch=digest(game/'data'/PATCH)
    known=info.get('known_lll_patch_sha256',[])
    if not isinstance(known,list) or any(not isinstance(h,str) or not re.fullmatch('[0-9a-f]{64}',h) for h in known):raise ValueError('Invalid owned-patch manifest')
    state=home/'Service/installed-steam-preview.json'
    winroot='Z:'+str(game).replace('/','\\')
    owner=json.loads(state.read_text()) if state.exists() else None
    if owner and (owner.get('format')!='LLL-Steam-preview-owner-v1' or owner.get('game_root','').lower().rstrip('\\/')!=winroot.lower()):raise ValueError('LLL prefix is bound to another game root')
    if patch and patch!=SHA(desired['data/'+PATCH]) and patch not in known and not (owner and owner.get('patch_sha256')==patch):raise ValueError('Unknown startup patch ownership')
    binding=home/'Service/game-root.txt'
    if binding.exists() and binding.read_text().strip().lower().rstrip('\\/')!=winroot.lower():raise ValueError('Existing game binding differs')
    if not patch and any((game/'data'/(PATCH+s)).exists() for s in ['.stream','.gpu_resources']):raise ValueError('Orphan startup sidecars')
    desired['service/game-root.txt']=(winroot+'\n').encode()
    owner={'format':'LLL-Steam-preview-owner-v1','release':info['release'],'game_root':winroot,'patch_sha256':SHA(desired['data/'+PATCH]),'helper':info['service']}
    desired['service/installed-steam-preview.json']=(json.dumps(owner,sort_keys=True,indent=2)+'\n').encode()
    return info,desired

def install(package,game,prefix):
    package,game,prefix=Path(package).resolve(),Path(game).resolve(),Path(prefix).resolve()
    assert_closed();home=local_home(prefix);info,desired=validate(package,game,home)
    rows=[];preimages={}
    for key,data in sorted(desired.items()):
        path=target(game,home,key);before=digest(path);after=SHA(data)
        if before==after:continue
        if before is not None:preimages[key]=path.read_bytes()
        rows.append({'key':key,'before':before,'after':after})
    if not rows:return {'state':'already installed; no files changed','release':info['release']}
    backup=home/'Backups'/('proton-preview-'+uuid.uuid4().hex);backup.mkdir(parents=True)
    with zipfile.ZipFile(backup/'rollback.zip','w',zipfile.ZIP_DEFLATED) as z:
        for key,data in preimages.items():z.writestr(key,data)
    receipt={'format':'LLL-Proton-preview-install-v1','game_root':str(game),'prefix':str(prefix),'release':info['release'],'files':rows,'state':'prepared','live_validation':'pending'}
    receipt_path=backup/'receipt.json'
    atomic(receipt_path,(json.dumps(receipt,indent=2)+'\n').encode());done=[]
    try:
        assert_closed();validate(package,game,home)
        for row in rows:
            assert_closed();path=target(game,home,row['key'])
            if digest(path)!=row['before']:raise ValueError('Target changed before replacement: '+row['key'])
            atomic(path,desired[row['key']]);done.append(row)
            if digest(path)!=row['after']:raise ValueError('Installed bytes failed verification')
        (home/'Logs').mkdir(parents=True,exist_ok=True)
        receipt['state']='installed bytes verified; live validation pending'
    except BaseException:
        for row in reversed(done):
            path=target(game,home,row['key'])
            if digest(path)!=row['after']:continue
            if row['before'] is None:path.unlink()
            else:atomic(path,preimages[row['key']])
        receipt['state']='installation failed; owned writes restored'
        atomic(receipt_path,(json.dumps(receipt,indent=2)+'\n').encode())
        raise
    atomic(receipt_path,(json.dumps(receipt,indent=2)+'\n').encode())
    return {'state':receipt['state'],'release':info['release'],'receipt':str(receipt_path),'files':len(rows)}

def rollback(receipt_path):
    assert_closed();receipt_path=Path(receipt_path).resolve();r=json.loads(receipt_path.read_text())
    if r.get('format')!='LLL-Proton-preview-install-v1':raise ValueError('Unsupported receipt')
    game=Path(r['game_root']).resolve();home=local_home(r['prefix']);seen=set();restore={}
    with zipfile.ZipFile(receipt_path.parent/'rollback.zip') as z:
        for row in r['files']:
            path=target(game,home,row['key'])
            if path in seen:raise ValueError('Duplicate rollback target')
            seen.add(path)
            if digest(path) not in (row['before'],row['after']):raise ValueError('Installed bytes changed; refusing rollback')
            if row['before'] is not None:
                data=z.read(row['key'])
                if SHA(data)!=row['before']:raise ValueError('Rollback preimage changed')
                restore[row['key']]=data
    assert_closed()
    for row in reversed(r['files']):
        path=target(game,home,row['key']);current=digest(path)
        if current==row['before']:continue
        if current!=row['after']:raise ValueError('Target changed during rollback')
        if row['before'] is None:path.unlink()
        else:atomic(path,restore[row['key']])
        if digest(path)!=row['before']:raise ValueError('Rollback verification failed')
    r['state']='rolled back; original bytes verified';atomic(receipt_path,(json.dumps(r,indent=2)+'\n').encode())
    return {'state':r['state'],'receipt':str(receipt_path)}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--package');p.add_argument('--game');p.add_argument('--prefix');p.add_argument('--rollback');a=p.parse_args()
    if a.rollback:result=rollback(a.rollback)
    elif all([a.package,a.game,a.prefix]):result=install(a.package,a.game,a.prefix)
    else:p.error('Provide --package, --game and --prefix, or --rollback')
    print(json.dumps(result,indent=2))
