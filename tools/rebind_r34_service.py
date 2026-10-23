"""Derive the private 26088801 helper from exact unsigned R34 bytes.

Only the two fixed-size game hash literals change. This is NOT a source rebuild.
Use build_steam_service.py on Windows for a source-built release helper.
"""
from pathlib import Path
import argparse,hashlib,json,struct
GAME=json.loads((Path(__file__).resolve().parents[1]/'steam-build.json').read_text())['game']
ORIGINAL='b06b577092c40405c033398dd8195ff7be8d31d328f5f523b775ecda37528837'
OLD={'bin/helldivers2.exe':'2ce8b3d74c5573088e4211b060ced0963f1fc1e74526e2645399780b8fb13ff7',
'data/game/game.dll':'a457433f0eb766fbe15a6de5a16f0fbbb1fd3c840c5607a5f0b2ebf53b112949'}
def derive(source,output):
    source,output=Path(source),Path(output)
    data=source.read_bytes()
    if hashlib.sha256(data).hexdigest()!=ORIGINAL:raise ValueError('Not the exact published R34 helper')
    pe=struct.unpack_from('<I',data,0x3c)[0]
    if struct.unpack_from('<II',data,pe+24+112+4*8)!=(0,0):raise ValueError('Refuse signed helper derivation')
    derived=bytearray(data);ranges=[]
    for key,old in OLD.items():
        if data.count(old.encode())!=1:raise ValueError('Expected exactly one fixed hash literal')
        offset=data.index(old.encode());derived[offset:offset+64]=GAME[key].encode()
        ranges.append({'offset':offset,'length':64,'old':old,'new':GAME[key]})
    allowed={i for r in ranges for i in range(r['offset'],r['offset']+64)}
    if any(a!=b and i not in allowed for i,(a,b) in enumerate(zip(data,derived))):raise ValueError('Unexpected binary change')
    output.mkdir(parents=True,exist_ok=True)
    sha=hashlib.sha256(derived).hexdigest();name='lll_steam_service_'+sha[:16]+'.exe'
    (output/name).write_bytes(derived);(output/'service.txt').write_text(name+'\n')
    receipt={'derivation':'two fixed-size game fingerprint literals only; not source rebuilt',
       'source_sha256':ORIGINAL,'result_sha256':sha,'byte_length_unchanged':len(data)==len(derived),'changes':ranges,'validation':'pending'}
    (output/'derivation.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',required=True);p.add_argument('--output',required=True);a=p.parse_args();print(json.dumps(derive(a.source,a.output),indent=2))
