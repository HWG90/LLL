local Console=dofile('src/ui/diagnostics.lua')
local old_global,old_loaded=DBFDiagnostics,package.loaded['dbf.diagnostics.v1']
DBFDiagnostics=nil;package.loaded['dbf.diagnostics.v1']=nil
local a=Console.shared();local b=Console.shared();assert(a==b)
local left=a.attach('LLL','loader.log');local right=b.attach('MCM','mcm.log')
a.record('LLL','Loaded');b.record('MCM','Callback failed')
assert(a.count==2 and b.read()[2].severity=='error')
local surface=Console.surface(a);local held=false
local input={down=function(code)return code==192 and held end,mouse=function()return 0,0 end,wheel=function()return 0 end}
surface.filter(input,false);held=true;surface.filter(input,true);assert(not a.window.visible)
held=false;surface.filter(input,true);held=true;surface.filter(input,true);assert(a.window.visible)
local commands=surface.compose(1920,1080,{x=0,y=400,w=1100,h=660},true)
assert(#commands>0)
for _,c in ipairs(commands)do assert(c.popup and c.diagnostic_console)end
surface.release();assert(a.window.visible)
a.detach(left);assert(a.window.visible);a.detach(right);assert(not a.window.visible)
DBFDiagnostics=old_global;package.loaded['dbf.diagnostics.v1']=old_loaded
print('PASS shared console stream, log locations, grave parent gating/held suppression, high-layer commands and handoff cleanup')
