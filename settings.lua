-- mods/backup_wand/settings.lua

dofile("data/scripts/lib/mod_settings.lua")

local mod_id = "backup_wand" -- must match the mod folder name
mod_settings_version = 1

-- Key codes are SDL scancodes, the same values the game itself uses for
-- InputIsKeyDown / InputIsKeyJustDown (see data/scripts/debug/generate_lua_documentation.lua).
--   a=4  c=6  h=11 j=13 n=17 u=24 v=25 y=28  F1=58 F2=59 F3=60
-- Letters that Noita binds by default (wasd, e, f, q, r, tab, space, shift, m, esc ...)
-- are deliberately not offered here so the hotkey can never fight the game controls.
mod_settings = {
	{
		id = "enabled",
		ui_name = "Backup Wand enabled",
		ui_description = "Turn the whole mod on or off without restarting.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "cast_key",
		ui_name = "Quick-cast key",
		ui_description = "Casts the BACKUP spell without having to equip the backup wand. Set to Disabled if you only want to fire it from the wand itself.",
		value_default = "6", -- C
		values = {
			{ "0", "Disabled" },
			{ "6", "C" },
			{ "11", "H" },
			{ "13", "J" },
			{ "17", "N" },
			{ "24", "U" },
			{ "25", "V" },
			{ "28", "Y" },
			{ "58", "F1" },
			{ "59", "F2" },
			{ "60", "F3" },
			{ "61", "F4" },
		},
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "refresh_on_recall",
		ui_name = "Recalling also refreshes the backup",
		ui_description = "Off: casting again only moves your existing copy to you, leaving the stored copy exactly as it was when you first made it.\nOn: casting again also overwrites the stored copy with your current belongings.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "keep_newer_items",
		ui_name = "Keep items found after the backup",
		ui_description = "Off (default): taking control of your copy gives you exactly what the copy was carrying; anything you picked up after the backup is left behind at the spot where you fell.\nOn: you also keep the post-backup items that fit in your inventory. Anything that does not fit is dropped at your feet instead of being destroyed.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "clone_is_visible",
		ui_name = "Show the copy in the world",
		ui_description = "On (default): a ghost copy of you stands where you last cast the spell, so you can see where your backup is.\nOff: the backup is invisible. It still works and is still recalled to you.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
}

function ModSettingsUpdate(init_scope)
	local old_version = mod_settings_get_version(mod_id)
	mod_settings_update(mod_id, mod_settings, init_scope)
end

function ModSettingsGuiCount()
	return mod_settings_gui_count(mod_id, mod_settings)
end

function ModSettingsGui(gui, in_main_menu)
	mod_settings_gui(mod_id, mod_settings, gui, in_main_menu)
end
