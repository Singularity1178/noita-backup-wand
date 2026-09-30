-- mods/backup_wand/init.lua
--
-- Entry point. Deliberately thin: all the real logic lives in
-- files/lib/backup.lua so that it can be reloaded cleanly.

dofile_once("data/scripts/lib/utilities.lua")

-- Register the custom BACKUP spell. The Mod* API is only available while the
-- mod is initialising, which is exactly what the top level of init.lua is.
ModLuaFileAppend("data/scripts/gun/gun_actions.lua", "mods/backup_wand/files/actions.lua")

BACKUP_WAND = dofile_once("mods/backup_wand/files/lib/backup.lua")

function OnModInit()
	BACKUP_WAND.on_mod_init()
end

function OnPlayerSpawned(player_entity)
	BACKUP_WAND.on_player_spawned(player_entity)
end

function OnPlayerDied(player_entity)
	BACKUP_WAND.on_player_died(player_entity)
end

function OnWorldPostUpdate()
	BACKUP_WAND.on_world_post_update()
end
