"""Cross-build the small PowerShell-free launcher with Zig, no installation."""
from pathlib import Path
import argparse,hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[1]
def build(zig,service,output):
    service,output=Path(service),Path(output);output.mkdir(parents=True,exist_ok=True)
    name=(service/'service.txt').read_text().strip();sha=hashlib.sha256((service/name).read_bytes()).hexdigest()
    if name!='lll_steam_service_'+sha[:16]+'.exe':raise ValueError('Helper name/hash mismatch')
    exe=output/'launcher.exe'
    cmd=[str(zig),'cc','-target','x86_64-windows-gnu','-O2','-municode','-DLLL_HELPER_NAME=L"'+name+'"','-DLLL_HELPER_SHA256="'+sha+'"',str(ROOT/'native/steam_launch.c'),'-lbcrypt','-lshell32','-o',str(exe)]
    subprocess.run(cmd,check=True)
    data=exe.read_bytes();digest=hashlib.sha256(data).hexdigest();name='lll_steam_launcher_'+digest[:16]+'.exe'
    (output/name).write_bytes(data);(output/'launcher.txt').write_text(name+'\n')
    (output/'launcher-build.json').write_text(json.dumps({'launcher':name,'sha256':digest,'helper_sha256':sha,'timeout_ms':8000,'source':'native/steam_launch.c'},indent=2)+'\n')
    return output/name
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--zig',required=True);p.add_argument('--service',required=True);p.add_argument('--output',required=True);a=p.parse_args();print(build(a.zig,a.service,a.output))
