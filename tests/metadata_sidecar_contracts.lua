local M=dofile('src/metadata.lua')
local files={['root/one.json']='{"name":"One","author":"Goose"}',['root/two.json']='{"name":"Two","author":"External Author"}',['root/manifest.json']='{"name":"Root","author":"Do not inherit this"}'}
local platform={read=function(path)return files[path]end}
assert(M.read(platform,'root','one').author=='Goose')
assert(M.read(platform,'root','two').author=='External Author')
assert(M.read(platform,'root','missing').author==nil,'Root metadata must not relabel loose external mods')
assert(M.read(platform,'root','../one').author==nil)
files['folder/manifest.json']='{"Name":"Folder mod"}';files['folder/metadata.json']='{"author":"Folder author"}'
local mixed=M.read(platform,'folder');assert(mixed.name=='Folder mod' and mixed.author=='Folder author')
print('PASS per-mod JSON author/name, external author preservation, missing metadata isolation, safe IDs and conventional manifest merging')
