-- mods/backup_wand/files/actions.lua
--
-- This file is APPENDED to data/scripts/gun/gun_actions.lua by
-- ModLuaFileAppend() in init.lua, so it runs inside gun.lua's Lua VM where the
-- `actions` table and the ACTION_TYPE_* constants already exist.

table.insert(actions,
	{
		id           = "BACKUP",
		name         = "Backup",
		description  = "Create a copy of yourself, holding everything you are carrying right now. Only one copy can exist: casting this again brings your existing copy to you. If you die while a copy exists, you wake up as that copy instead of dying.",
		sprite       = "data/ui_gfx/gun_actions/summon_wandghost.png",
		sprite_unidentified = "data/ui_gfx/gun_actions/summon_wandghost.png",
		type         = ACTION_TYPE_UTILITY,

		-- never show up in shops, chests or the world on their own
		spawn_level        = "",
		spawn_probability = "",
		price              = 0,

		-- zero mana + unlimited uses == the spell can be cast forever
		mana     = 0,
		max_uses = -1,

		action = function()
			-- data/scripts/gun/gun_collect_metadata.lua invokes every action once
			-- while a wand is initialised, purely to collect each spell's metadata
			-- (projectiles, damage, ...) for the wand UI. That is not a cast, and
			-- gun.lua sets the `reflecting` flag while it does this. Bail out or
			-- every wand init would silently create a backup.
			if reflecting then
				return
			end

			-- This runs inside the wand's gun.lua VM, which shares no state with
			-- the mod's init.lua VM, so all it can do is raise a signal for the
			-- mod's OnWorldPostUpdate to pick up.
			--
			-- It MUST NOT raise. That same metadata pass runs before the world
			-- state entity exists, and an error here aborts the whole pass and
			-- leaves the wand unable to fire. Everything below is pcall'd.
			local frame = tostring(GameGetFrameNum())

			-- channel 1: the global store, which also survives save/load
			pcall(GlobalsSetValue, "backup_wand_cast_frame", frame)

			-- channel 2: a tag on the player entity. Costs nothing, needs no world
			-- state, and is consumed by the mod's tick.
			pcall(function()
				local players = EntityGetWithTag("player_unit")
				if players ~= nil then
					for _, e in ipairs(players) do
						pcall(EntityAddTag, e, "bkup_cast_pending")
					end
				end
			end)
		end,
	}
)
