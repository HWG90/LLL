local M={}
function M.install(api,loader,controls,get_menu)
    function api.open_metadata(resource)
        if loader.get_loader_option and loader.get_loader_option("metadata_editing")==false then return false,"Metadata editing is locked" end
        local rows=loader.provenance_snapshot();local row
        for _,candidate in ipairs(rows) do if candidate.name==resource then row=candidate end end
        if not row then return false,"Mod is no longer available" end
        local saved=loader.get_loader_option("metadata_overrides") or {};local current=saved[resource] or {}
        local editor=api.mods.lll_metadata_editor
        if editor then editor.handle.unregister() end
        local handle=api.register({id="lll_metadata_editor",name="Edit metadata",pages={{id="metadata",name=row.display_name or resource,controls={
            {type="input",id="name",label="Name",default=current.name or row.display_name or resource,free_text=true,max_length=128},
            {type="input",id="author",label="Author",default=current.author or row.author,free_text=true,max_length=128},
            {type="input",id="description",label="Description",default=current.description or row.description or "",free_text=true,max_length=512},
            {type="text",label="Changes stay local; original mod files are preserved."}
        }}}})
        local confirm=handle.confirm
        handle.confirm=function(page_id)
            if loader.get_loader_option("metadata_editing")==false then return false,"Metadata editing is locked" end
            local values={};for _,key in ipairs({"name","author","description"}) do values[key]=handle.preview(key) end
            if values.name:match("^%s*$") or values.author:match("^%s*$") then return false,"Name and Author cannot be empty" end
            local existing=loader.get_loader_option("metadata_overrides") or {};local next_values={}
            for key,value in pairs(existing) do next_values[key]=value end;next_values[resource]=values
            local ok,why=loader.save_loader_option("metadata_overrides",next_values)
            if not ok then return false,why end
            local accepted,message=confirm(page_id);controls.refresh();return accepted,message
        end
        local menu=get_menu()
        for index,mod in ipairs(api.list()) do if mod.id=="lll_metadata_editor" then menu.selected,menu.page,menu.row,menu.scroll=index,1,1,0 end end
        menu.focus="settings";menu.context_menu=nil;return true
    end
    api.can_edit_metadata=function()return loader.save_loader_option and (not loader.get_loader_option or loader.get_loader_option("metadata_editing")~=false)end
end
return M
