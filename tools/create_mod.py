"""Create an owned loose-script mod and per-mod JSON; never overwrite existing files."""
import argparse,json,re
from pathlib import Path

def create(output,mod_id,name=None,author='Goose'):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',mod_id):raise ValueError('Use a simple mod ID')
    if not isinstance(author,str) or not author.strip() or any(ord(ch)<32 for ch in author):raise ValueError('Printable author is required')
    root=Path(output).resolve();root.mkdir(parents=True,exist_ok=True)
    script=root/(mod_id+'.lua');metadata=root/(mod_id+'.json')
    if script.exists() or metadata.exists():raise FileExistsError('Refusing to overwrite a mod or its metadata')
    title=name or mod_id
    if not isinstance(title,str) or not title or any(ord(ch)<32 for ch in title):raise ValueError('Use a nonempty printable mod name')
    body='return {live_lua_api=1,name='+json.dumps(title,ensure_ascii=False)+',on_enable=function()end,on_disable=function()return true end}\n'
    with script.open('x',encoding='utf-8') as file:file.write(body)
    try:
        with metadata.open('x',encoding='utf-8') as file:file.write(json.dumps({'name':title,'author':author.strip()},ensure_ascii=False,indent=2)+'\n')
    except Exception:
        if script.read_text(encoding='utf-8')==body:script.unlink()
        raise
    return script,metadata

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('id');parser.add_argument('--output',required=True);parser.add_argument('--name');parser.add_argument('--author',default='Goose')
    args=parser.parse_args()
    for file in create(args.output,args.id,args.name,args.author):print(file)
