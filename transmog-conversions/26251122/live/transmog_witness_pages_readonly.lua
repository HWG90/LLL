-- Read-only LLtM probe: which of Transmog's 26 witness locations (Addon d42a76efa2beb2e3.lua CompatSpec and
-- CatalogCompat, build 26251122) are readable now. Reports R (readable) or C (cold: unreadable) per witness. No writes.
-- Generated from the installed package; compare readable bytes with the capture offline if needed.
local W={{'manager',0xBB1D94,96},{'session',0x12FD4D7,102},{'font',0x121E994,96},{'atlas',0x121E9A4,98},{'material',0x121E980,102},{'loadout_registration',0x12FDBFD,98},{'loadout_flags',0x12FD4E1,99},{'loadout_state',0x12FD6D0,97},{'local_slot',0x1307A2F,117},{'record_peer',0x1307C3A,115},{'loadout_payload',0x11F7A01,99},{'player_card_address',0x130810C,98},{'player_card_payload',0x171DC64,99},{'loadout_view_setter',0x13089D3,98},{'loadout_view_stratagems',0x1303F96,101},{'equipment_button_owner',0x171C5F9,105},{'equipment_button_size',0x17121D8,96},{'equipment_button_top_attachment',0x171C67F,99},{'extra_booster_host',0x882D40,744},{'extra_player_state',0x881990,200},{'deployment_picker_grid',0x130A1E0,29},{'loadout_state',0x12FD6D0,97},{'gear_payload',0x1307D6E,129},{'gear_catalog_categories',0x17EF5BA,122},{'progression_owned_layout',0x1205CD0,150},{'extra_localized_text',0x15F4620,99}}
local out={}
for _,w in ipairs(W) do
    local s=read(game+w[2],w[3])
    out[#out+1]=w[1]..'='..(s and 'R' or 'C')
end
return table.concat(out,' ')
