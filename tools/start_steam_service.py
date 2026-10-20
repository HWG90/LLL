"""Start the hash-verified external filesystem helper with no visible window."""
from pathlib import Path
import argparse
import json
import os
import subprocess
from build_steam_probe import GAME, digest

def start(game,candidate):
    game,candidate=Path(game).resolve(),Path(candidate).resolve()
    info=json.loads((candidate/'build.json').read_text())
    service=Path(os.environ['LOCALAPPDATA'])/'LLL/Helldivers2/Service'/info['service']
    if digest(service.read_bytes())!=info['service_sha256']:raise ValueError('Installed service changed')
    for path,expected in GAME.items():
        if digest((game/path).read_bytes())!=expected:raise ValueError('Installed game changed')
    child=subprocess.Popen([str(service),'--game',str(game),'--pipe',info['pipe']],creationflags=subprocess.CREATE_NO_WINDOW)
    receipt={'pid':child.pid,'executable':str(service),'pipe':info['pipe'],'purpose':'external filesystem and visible-menu pointer service; no game process access'}
    (candidate/'service-process.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps(receipt,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game',required=True,type=Path)
    parser.add_argument('--candidate',required=True,type=Path)
    args=parser.parse_args();start(args.game,args.candidate)
