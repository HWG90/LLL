"""Create an owned loose-script mod and per-mod JSON; never overwrite existing files."""
import argparse,json,re
from pathlib import Path

def create(output,mod_id,name=None,author='Goose',layout='folder'):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',mod_id):raise ValueError('Use a simple mod ID')
    if not isinstance(author,str) or not author.strip() or any(ord(ch)<32 for ch in author):raise ValueError('Printable author is required')
    root=Path(output).resolve();root.mkdir(parents=True,exist_ok=True)
    title=name or mod_id
    if not isinstance(title,str) or not title or any(ord(ch)<32 for ch in title):raise ValueError('Use a printable nonempty mod name')
    if layout=='folder':
        folder=root/mod_id
        if folder.exists() or (root/(mod_id+'.lua')).exists():raise FileExistsError('Refusing to overwrite an existing mod')
        folder.mkdir();(folder/'src').mkdir();(folder/'config').mkdir()
        manifest={'id':mod_id,'name':title,'author':author.strip(),'version':'0.1.0','lll':{'entry':'main.lua','defaults':'config/defaults.cfg','modules':['src/runtime.lua']}}
        (folder/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
        (folder/'main.lua').write_text('return mod.require("src.runtime")\n',encoding='utf-8')
        (folder/'src/runtime.lua').write_text('return {live_lua_api=1,name=mod.name,on_enable=function()mod.log("Enabled")end,on_update=function(dt)end,on_disable=function()return true end}\n',encoding='utf-8')
        (folder/'config/defaults.cfg').write_text(json.dumps({'enabled':True,'interval':0.5},indent=2)+'\n',encoding='utf-8')
        return tuple(folder/name for name in ('manifest.json','main.lua','src/runtime.lua','config/defaults.cfg'))
    if layout!='loose':raise ValueError('Unknown layout')
    script=root/(mod_id+'.lua');metadata=root/(mod_id+'.json')
    if script.exists() or metadata.exists() or (root/mod_id).exists():raise FileExistsError('Refusing to overwrite a mod or its metadata')
    body='return {live_lua_api=1,name='+json.dumps(title,ensure_ascii=False)+',on_enable=function()end,on_disable=function()return true end}\n'
    with script.open('x',encoding='utf-8') as file:file.write(body)
    try:
        with metadata.open('x',encoding='utf-8') as file:file.write(json.dumps({'name':title,'author':author.strip()},ensure_ascii=False,indent=2)+'\n')
    except Exception:
        if script.read_text(encoding='utf-8')==body:script.unlink()
        raise
    return script,metadata

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('id');parser.add_argument('--output',required=True);parser.add_argument('--name');parser.add_argument('--author',default='Goose');parser.add_argument('--layout',choices=['folder','loose'],default='folder')
    args=parser.parse_args()
    for file in create(args.output,args.id,args.name,args.author,args.layout):print(file)
