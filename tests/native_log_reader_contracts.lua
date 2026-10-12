local platform=dofile('tests/tmp/speed-native.lua')
local path='tests/tmp/log-reader-native.log'
local function replace(text)local f=assert(io.open(path,'wb'));f:write(text);f:close()end
replace('prior session\n')
local text,position=platform.read_log(path,nil,0)
assert(text=='' and position==14)
local writer=assert(io.open(path,'ab'));writer:write('ERROR appended\n');writer:flush()
text,position=platform.read_log(path,position,8192)
assert(text=='ERROR appended\n' and position==29,'shared native reader must read while writer remains open')
writer:close()
replace('ERROR rotated\n')
local reset
text,position,reset=platform.read_log(path,position,8192)
assert(reset and text=='ERROR rotated\n' and position==14)
replace('ERROR changed\n')
text,position,reset=platform.read_log(path,position,8192,true)
assert(reset and text=='ERROR changed\n','same-length replacement must rewind on changed stamp')
replace(string.rep('x',100000)..'\nERROR tail\n')
local skipped,total
text,position,reset,skipped,total=platform.read_log(path,-65536,8192)
assert(skipped and #text==8192 and position<total,'large launch tail is bounded and can drain incrementally')
os.remove(path)
print('PASS real Windows log sharing, append, truncation, equal-size replacement and bounded launch tail')
