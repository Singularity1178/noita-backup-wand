-- mods/backup_wand/files/lib/backup.lua
--
-- The actual mod.
--
-- Design notes
-- ------------
-- * The authoritative backup is a *string* (see snapshot.lua) kept in the global
--   cross-VM store. The clone entity in the world is a visual marker only.
--   That way a backup survives save/load, mod reloads, and the marker being
--   destroyed or streamed out of the world.
-- * The BACKUP spell runs inside the wand's own gun.lua VM, which shares no
--   state with this file, so it only raises a flag that is polled here.
-- * Death is intercepted with DamageModelComponent.wait_for_kill_flag_on_death,
--   which tells the engine not to finish off an entity whose hp reached zero.

local SNAP = dofile_once("mods/backup_wand/files/lib/snapshot.lua")

local M = {}

local MOD_DIR = "mods/backup_wand"
local CLONE_ENTITY = MOD_DIR .. "/files/entities/backup_clone.xml"
local WAND_ENTITY = MOD_DIR .. "/files/entities/backup_wand.xml"
local CLONE_NAME = "backup_wand_clone"
local CLONE_TAG = "bkup_clone"
local WAND_NAME = "backup_wand_item"
local WAND_TAG = "bkup_backup_wand"
local CAST_TAG = "bkup_cast_pending"

local G_BLOB = "backup_wand_blob" -- the serialised backup
local G_FRAME = "backup_wand_cast_frame" -- raised by the spell
local G_X = "backup_wand_clone_x"
local G_Y = "backup_wand_clone_y"

local CLONE_HP = 4
local CLONE_OFFSET = 14 -- how far to the side the copy stands
local WAND_CHECK_INTERVAL = 90 -- frames between "do I still have the wand?"
local GRACE_FRAMES = 120 -- post-rescue invulnerability
local HEAL_FRAMES = 180 -- post-rescue top-up healing
local TELEPORT_MATERIAL = "magic_gas_teleport"

local KEY_NAMES = {
	["6"] = "C", ["11"] = "H", ["13"] = "J", ["17"] = "N",
	["24"] = "U", ["25"] = "V", ["28"] = "Y",
	["58"] = "F1", ["59"] = "F2", ["60"] = "F3", ["61"] = "F4",
}

local g_player = nil
local g_clone = nil
local g_clone_x = -99999
local g_clone_y = -99999
local g_last_cast_frame = ""
local g_wand_check_frame = 0
local g_grace = 0
local g_heal = 0
local g_announced = false
local g_last_guard = nil
local g_cast_count = 0
local g_has_backup = false

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------

local function valid(e)
	return type(e) == "number" and e ~= 0 and EntityGetIsAlive(e) == true
end

-- ModSettingGet() returns bool|number|string|nil. For a boolean setting it
-- returns a real Lua boolean, NOT the string "1", so the value has to be
-- interpreted rather than compared. A nil means the settings have not been
-- initialised yet, in which case the documented default is used -- the mod
-- must never silently do nothing just because a setting is missing.
local function setting_raw(id, default)
	local ok, v = pcall(ModSettingGet, MOD_DIR .. "." .. id)
	if not ok or v == nil then return default end
	return v
end

local function setting_on(id, default)
	if default == nil then default = true end
	local v = setting_raw(id, default)
	if type(v) == "boolean" then return v end
	if type(v) == "number" then return v ~= 0 end
	local s = tostring(v)
	return s == "1" or s == "true" or s == "yes"
end

local function setting_str(id, default)
	local v = setting_raw(id, default)
	if v == nil then return default end
	if type(v) == "string" then
		if v == "" then return default end
		return v
	end
	return tostring(v)
end

-- The global store lives on the world state entity, which DOES NOT EXIST YET
-- during OnModInit and may still be missing on the first frames of a run.
-- GlobalsGetValue/GlobalsSetValue raise a hard Lua error in that case, and an
-- error aborts the whole function it happens in. Since these are called from
-- OnPlayerSpawned and from the per-frame tick, one unguarded call at the wrong
-- moment silently kills the entire mod. So every access is guarded, and while
-- the store is unavailable we back off instead of erroring 60 times a second.
local g_world_ready = false
local g_probe_frame = -9999
local PROBE_INTERVAL = 30

local function gget(key, default)
	default = default or ""

	if not g_world_ready then
		local now = GameGetFrameNum()
		if now - g_probe_frame < PROBE_INTERVAL then
			return default
		end
		g_probe_frame = now
	end

	local ok, v = pcall(GlobalsGetValue, key, default)
	if not ok then
		g_world_ready = false
		return default
	end
	g_world_ready = true
	if v == nil then return default end
	return v
end

local function gset(key, value)
	if not g_world_ready then
		local now = GameGetFrameNum()
		if now - g_probe_frame < PROBE_INTERVAL then
			return
		end
		g_probe_frame = now
	end

	local ok = pcall(GlobalsSetValue, key, value)
	if not ok then
		g_world_ready = false
	end
end

local function safe(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		print_error("backup_wand: " .. tostring(err))
	end
end

local function burst(x, y, how_many)
	safe(GameCreateCosmeticParticle,
		TELEPORT_MATERIAL, x, y, how_many,
		0, -20, -- xvel, yvel
		0xff9ce6ff, -- colour
		0.3, 0.9, -- lifetime min / max
		true, false, true, true, -- force_create, draw_front, collide, randomize vel
		0, 0) -- gravity x / y
end

-------------------------------------------------------------------------------
-- finding things
-------------------------------------------------------------------------------

local function get_player()
	if valid(g_player) then return g_player end

	local list = EntityGetWithTag("player_unit")
	if list ~= nil then
		for _, e in ipairs(list) do
			if valid(e) and IsPlayer(e) then
				g_player = e
				return e
			end
		end
		for _, e in ipairs(list) do
			if valid(e) then
				g_player = e
				return e
			end
		end
	end
	return nil
end

local function find_clone()
	if valid(g_clone) then return g_clone end
	g_clone = nil

	-- name first (any string is valid for a name), tag as a fallback
	local by_name = EntityGetWithName(CLONE_NAME)
	if by_name ~= nil then
		for _, e in ipairs(by_name) do
			if valid(e) then
				g_clone = e
				return e
			end
		end
	end

	local by_tag = EntityGetWithTag(CLONE_TAG)
	if by_tag ~= nil then
		for _, e in ipairs(by_tag) do
			if valid(e) then
				g_clone = e
				return e
			end
		end
	end

	return nil
end

-- Whether a backup currently exists. The in-memory flag is the primary source
-- because it is always correct within a session; the global store is the
-- fallback that carries the backup across save/load and mod reloads. If the
-- store is unusable the mod still works, it just will not persist.
local function has_backup()
	if g_has_backup then return true end
	return gget(G_BLOB, "") ~= ""
end

local function clear_backup()
	g_has_backup = false
	gset(G_BLOB, "")
end

-- Identify the backup wand by name first and only then by tag: a custom tag
-- coming from an entity XML is not guaranteed to be a registered tag, whereas
-- an entity name is always free-form.
local function is_backup_wand(e)
	if not valid(e) then return false end
	if EntityGetName(e) == WAND_NAME then return true end
	-- guarded: querying a tag the game does not know about is not guaranteed to
	-- be harmless, and this must never throw
	local ok, has = pcall(EntityHasTag, e, WAND_TAG)
	return ok and has == true
end

local function player_backup_wand(player)
	if not valid(player) then return nil end
	local items = GameGetAllInventoryItems(player)
	if items == nil then return nil end
	for _, it in ipairs(items) do
		if is_backup_wand(it) then
			return it
		end
	end
	return nil
end

local function drop_clone()
	local old = find_clone()
	if valid(old) then
		safe(EntityKill, old)
	end
	g_clone = nil
	g_clone_x, g_clone_y = -99999, -99999
end

-- The marker has just been placed at (x, y): remember it so the per-frame
-- position tracking in keep_clone_alive() does not immediately rewrite it.
local function remember_clone_pos(x, y)
	g_clone_x, g_clone_y = x, y
	gset(G_X, tostring(math.floor(x)))
	gset(G_Y, tostring(math.floor(y)))
end

-------------------------------------------------------------------------------
-- the backup wand
-------------------------------------------------------------------------------

local function make_backup_wand(x, y)
	local wand = EntityLoad(WAND_ENTITY, x, y)
	if not valid(wand) then
		print_error("backup_wand: could not load " .. WAND_ENTITY)
		return nil
	end

	EntitySetName(wand, WAND_NAME)
	EntityAddTag(wand, WAND_TAG)

	-- the one and only spell
	local card = CreateItemActionEntity("BACKUP", x, y)
	if not valid(card) then
		print_error("backup_wand: CreateItemActionEntity('BACKUP') failed - "
			.. "is files/actions.lua registered?")
	else
		EntityAddChild(wand, card)
		EntitySetComponentsWithTagEnabled(card, "enabled_in_world", false)

		local ic = EntityGetFirstComponentIncludingDisabled(card, "ItemComponent")
		if ic ~= nil then
			safe(ComponentSetValue2, ic, "uses_remaining", -1)
			safe(ComponentSetValue2, ic, "is_identified", true)
			safe(ComponentSetValue2, ic, "permanently_attached", true)
			safe(ComponentSetValue2, ic, "preferred_inventory", "QUICK")
		end
	end

	local ab = EntityGetFirstComponentIncludingDisabled(wand, "AbilityComponent")
	if ab ~= nil then
		safe(ComponentSetValue2, ab, "ui_name", "Backup Wand")
		-- mIsInitialized is a private field; if the engine ever refuses to write
		-- it that must not take the rest of the mod down with it
		safe(ComponentSetValue2, ab, "mIsInitialized", false)
	end

	return wand
end

-- Hand the player a backup wand if they do not have one. This is what makes the
-- feature impossible to permanently lose: drop the wand, burn it, kick it into
-- lava, whatever -- it comes back.
local function ensure_backup_wand(player, force)
	if not valid(player) then return nil end

	if not force then
		local existing = player_backup_wand(player)
		if existing ~= nil then return existing end
	end

	local x, y = EntityGetTransform(player)
	local wand = make_backup_wand(x + 6, y)
	if not valid(wand) then return nil end

	safe(GamePickUpInventoryItem, player, wand, false)
	return wand
end

-------------------------------------------------------------------------------
-- the copy
-------------------------------------------------------------------------------

local function free_spot(x, y)
	local ok, fx, fy = pcall(FindFreePositionForBody, x, y, 0, 0, 6)
	if ok and fx ~= nil then
		return fx, fy
	end
	return x, y
end

local function sanitize_clone(clone)
	-- never let the game think this is a second player
	EntityRemoveTag(clone, "player_unit")
	EntityRemoveTag(clone, "prey")
	EntityRemoveTag(clone, "hittable")
	EntityRemoveTag(clone, "mortal")
	EntityAddTag(clone, CLONE_TAG)
	EntitySetName(clone, CLONE_NAME)

	-- player_base.xml attaches a few scripts to the player. They either do
	-- nothing useful here or can reach into real player state, so switch them off.
	local luas = EntityGetComponentIncludingDisabled(clone, "LuaComponent")
	if luas ~= nil then
		for _, c in ipairs(luas) do
			EntitySetComponentIsEnabled(clone, c, false)
		end
	end

	-- the verlet-chain cape expects a moving body to hang off
	local kids = EntityGetAllChildren(clone)
	if kids ~= nil then
		for _, k in ipairs(kids) do
			if EntityGetName(k) == "cape" then
				EntityKill(k)
			end
		end
	end

	local dm = EntityGetFirstComponentIncludingDisabled(clone, "DamageModelComponent")
	if dm ~= nil then
		ComponentSetValue2(dm, "hp", CLONE_HP)
		ComponentSetValue2(dm, "max_hp", CLONE_HP)
		ComponentSetValue2(dm, "wait_for_kill_flag_on_death", true)
	end
end

local function keep_clone_alive()
	local clone = find_clone()
	if clone == nil then return nil end

	local frame = GameGetFrameNum()

	if frame % 5 == 0 then
		local dm = EntityGetFirstComponentIncludingDisabled(clone, "DamageModelComponent")
		if dm ~= nil then
			ComponentSetValue2(dm, "hp", CLONE_HP)
			ComponentSetValue2(dm, "wait_for_kill_flag_on_death", true)
		end
	end

	-- Remember where the marker is, so a recall still lands in the right place
	-- even if the entity itself got destroyed by the world. Only write when it
	-- actually moved -- this runs every frame and Globals writes are not free.
	local x, y = EntityGetTransform(clone)
	if math.abs(x - g_clone_x) > 4 or math.abs(y - g_clone_y) > 4 then
		g_clone_x, g_clone_y = x, y
		gset(G_X, tostring(math.floor(x)))
		gset(G_Y, tostring(math.floor(y)))
	end

	return clone
end

-- Create the copy, or bring the existing one to the player.
function M.cast_backup()
	if not setting_on("enabled", true) then return end

	local player = get_player()
	if not valid(player) then
		print_error("backup_wand: cast_backup with no valid player")
		return
	end

	local px, py = EntityGetTransform(player)
	local tx, ty = px + CLONE_OFFSET, py

	local clone = find_clone()

	if valid(clone) then
		-- exactly one copy may exist, and it already does: bring it to the player
		local cx, cy = EntityGetTransform(clone)
		if math.abs(cx - tx) > 2 or math.abs(cy - ty) > 2 then
			burst(cx, cy, 40)
		end
		safe(EntityApplyTransform, clone, tx, ty)
		remember_clone_pos(tx, ty)
		burst(tx, ty, 40)
		GamePrint("[Backup] Your copy is with you again.")
		print_error("backup_wand: recalled copy " .. tostring(clone)
			.. " to " .. tostring(tx) .. "," .. tostring(ty))

		if setting_on("refresh_on_recall", false) then
			g_has_backup = true
			gset(G_BLOB, SNAP.capture(player))
			GamePrint("[Backup] Backup refreshed.")
		end
	else
		-- no copy right now -> make one
		local blob = SNAP.capture(player)
		g_has_backup = true
		gset(G_BLOB, blob)
		print_error("backup_wand: captured snapshot, "
			.. (blob and #blob or 0) .. " chars, world_ready=" .. tostring(g_world_ready))

		if setting_on("clone_is_visible", true) then
			local sx, sy = free_spot(tx, ty)
			drop_clone()
			local marker = EntityLoad(CLONE_ENTITY, sx, sy)
			if valid(marker) then
				sanitize_clone(marker)
				g_clone = marker
				remember_clone_pos(sx, sy)
				print_error("backup_wand: clone entity " .. tostring(marker)
					.. " spawned at " .. tostring(sx) .. "," .. tostring(sy))
			else
				remember_clone_pos(tx, ty)
				print_error("backup_wand: EntityLoad(" .. CLONE_ENTITY .. ") FAILED")
			end
		else
			drop_clone()
			remember_clone_pos(tx, ty)
		end

		burst(tx, ty, 50)
		GamePrint("[Backup] Backup created.")
	end

	M.update_death_guard()
end

-------------------------------------------------------------------------------
-- death handling
-------------------------------------------------------------------------------

-- While a backup exists the player must not actually die: the kill is deferred
-- and they are revived into their copy instead. This runs every frame, so only
-- touch the component when the desired state actually changes.
function M.update_death_guard()
	local player = get_player()
	if not valid(player) then return end

	local dm = EntityGetFirstComponentIncludingDisabled(player, "DamageModelComponent")
	if dm == nil then return end

	local guard = has_backup() or g_grace > 0
	if guard == g_last_guard then return end
	g_last_guard = guard

	ComponentSetValue2(dm, "wait_for_kill_flag_on_death", guard)
	ComponentSetValue2(dm, "kill_now", false)
end

local function revive_into_copy()
	local player = get_player()
	if not valid(player) then return end

	local blob = gget(G_BLOB, "")
	if blob == "" then return end

	-- where the copy was standing
	local clone = find_clone()
	local cx, cy
	if valid(clone) then
		cx, cy = EntityGetTransform(clone)
	else
		cx = tonumber(gget(G_X, "0")) or 0
		cy = tonumber(gget(G_Y, "0")) or 0
	end
	if cx == nil or cy == nil then return end

	local px, py = EntityGetTransform(player)

	-- 1. what the dying player is carrying right now
	local dying = {}
	local items = GameGetAllInventoryItems(player)
	if items ~= nil then
		for _, it in ipairs(items) do
			table.insert(dying, it)
		end
	end

	-- 2. clear it out, so the copy's belongings are guaranteed to fit. Nothing is
	--    deleted from the game: the items merely stop being owned, and step 5
	--    deals with them depending on the setting.
	for _, it in ipairs(dying) do
		if valid(it) then
			safe(GameKillInventoryItem, player, it)
		end
	end

	-- 3. become the copy
	local perks, stats = SNAP.read_meta(blob)
	SNAP.restore_perks(player, perks)

	local built = SNAP.build_all(blob, px, py)
	for _, e in ipairs(built) do
		if valid(e) then
			safe(GamePickUpInventoryItem, player, e, false)
		end
	end

	SNAP.restore_stats(player, stats)

	-- 4. optionally also keep the post-backup items that still fit; whatever does
	--    not fit is dropped at the feet rather than destroyed
	if setting_on("keep_newer_items", false) then
		for _, it in ipairs(dying) do
			if valid(it) then
				safe(GamePickUpInventoryItem, player, it, false)
			end
		end
	end
	SNAP.scatter_leftovers(dying, px, py)

	-- 5. stand up where the copy stood
	if DoesWorldExistAt(math.floor(cx) - 8, math.floor(cy) - 8,
		math.floor(cx) + 8, math.floor(cy) + 8) then
		safe(EntityApplyTransform, player, cx, cy)
	end

	-- 6. heal
	local dm = EntityGetFirstComponentIncludingDisabled(player, "DamageModelComponent")
	if dm ~= nil then
		local max_hp = ComponentGetValue2(dm, "max_hp")
		if type(max_hp) ~= "number" or max_hp <= 0 then max_hp = CLONE_HP end
		ComponentSetValue2(dm, "hp", max_hp)
		ComponentSetValue2(dm, "wait_for_kill_flag_on_death", true)
		ComponentSetValue2(dm, "kill_now", false)
	end
	g_grace = GRACE_FRAMES
	g_heal = HEAL_FRAMES

	-- 7. the copy has become you, so it is spent
	drop_clone()
	clear_backup()

	burst(cx, cy, 60)
	safe(GameScreenshake, 300, cx, cy)
	print_error("backup_wand: rescued player into the copy at "
		.. tostring(cx) .. "," .. tostring(cy))
	GamePrint("===========================================")
	GamePrint("[Backup] You died, and took control of your copy.")
	GamePrint("[Backup] The copy has been spent - cast Backup again.")
	GamePrint("===========================================")
end

local function check_player_down()
	if not has_backup() then return end
	local player = get_player()
	if not valid(player) then return end

	local dm = EntityGetFirstComponentIncludingDisabled(player, "DamageModelComponent")
	if dm == nil then return end

	local hp = ComponentGetValue2(dm, "hp")
	if type(hp) == "number" and hp <= 0 then
		revive_into_copy()

		-- Safety net. If for any reason the rescue did not take, never leave the
		-- player pinned at 0 hp with death deferred: that would soft-lock the
		-- run. Put them back on their feet and drop the backup instead.
		local after = ComponentGetValue2(dm, "hp")
		if type(after) ~= "number" or after <= 0 then
			local max_hp = ComponentGetValue2(dm, "max_hp")
			if type(max_hp) ~= "number" or max_hp <= 0 then max_hp = CLONE_HP end
			ComponentSetValue2(dm, "hp", max_hp)
			g_grace = GRACE_FRAMES
			drop_clone()
			clear_backup()
			GamePrint("[Backup] Rescue failed - the backup was lost.")
		end
	end
end

local function top_up_heal()
	if g_heal <= 0 then return end
	g_heal = g_heal - 1

	local player = get_player()
	if not valid(player) then return end
	local dm = EntityGetFirstComponentIncludingDisabled(player, "DamageModelComponent")
	if dm == nil then return end

	local max_hp = ComponentGetValue2(dm, "max_hp")
	if type(max_hp) ~= "number" or max_hp <= 0 then max_hp = CLONE_HP end
	local hp = ComponentGetValue2(dm, "hp")
	if type(hp) ~= "number" or hp < max_hp then
		ComponentSetValue2(dm, "hp", max_hp)
	end
end

-------------------------------------------------------------------------------
-- hotkey
-------------------------------------------------------------------------------

local function check_hotkey()
	if GameIsInventoryOpen() then return end

	local code = tonumber(setting_str("cast_key", "0"))
	if code == nil or code <= 0 then return end

	if InputIsKeyJustDown(code) then
		M.cast_backup()
	end
end

local function announce()
	if g_announced then return end
	g_announced = true

	local code = setting_str("cast_key", "0")
	local name = KEY_NAMES[code]
	if name ~= nil then
		GamePrint("[Backup Wand] Active. Equip the Backup Wand and fire it, or press " .. name .. ".")
	else
		GamePrint("[Backup Wand] Active. Equip the Backup Wand and fire it to cast Backup.")
	end
end

-------------------------------------------------------------------------------
-- hooks
-------------------------------------------------------------------------------

function M.on_mod_init()
	-- Runs before the world state exists, so nothing here may touch the global
	-- store. Also deliberately does NOT clear the stored backup: mods are
	-- re-initialised when a save is loaded, and wiping here would throw the
	-- backup away. It is cleared only when the copy is spent.
	g_last_cast_frame = ""
	g_announced = false
	g_last_guard = nil
	g_world_ready = false
	g_probe_frame = -9999
	g_cast_count = 0
	g_has_backup = false
	g_clone_x, g_clone_y = -99999, -99999
end

function M.on_player_spawned(player)
	g_player = player
	g_clone = nil
	g_grace = 0
	g_heal = 0
	g_announced = false
	g_wand_check_frame = 0
	g_last_guard = nil
	-- a backup carried across a save/load lives only in the global store
	g_has_backup = gget(G_BLOB, "") ~= ""
	g_clone_x, g_clone_y = -99999, -99999

	-- Nothing below may throw: this hook fires very early, when parts of the
	-- world (including the world state the global store lives on) may still be
	-- missing, and an escaping error would skip the death guard entirely.
	pcall(function()
		-- pick a backup back up if one survived a save/load
		if has_backup() then
			local clone = find_clone()
			local x = tonumber(gget(G_X, "0")) or 0
			local y = tonumber(gget(G_Y, "0")) or 0
			if valid(clone) and (x ~= 0 or y ~= 0) then
				safe(EntityApplyTransform, clone, x, y)
				remember_clone_pos(x, y)
			end
		end
	end)

	local ok, wand = pcall(ensure_backup_wand, player, false)
	if not ok then
		print_error("backup_wand: ensure_backup_wand failed: " .. tostring(wand))
	end

	pcall(M.update_death_guard)

	print_error(string.format(
		"backup_wand: spawned. player=%s wand=%s has_backup=%s",
		tostring(player), tostring(wand), tostring(has_backup())))

	if not valid(wand) then
		GamePrint("[Backup Wand] could not create the wand - see logger.txt")
		GamePrint("===========================================")
	end
end

function M.on_player_died(player)
	-- Only reached when there was no backup to fall back on, or when a new run
	-- starts inside the same session.
	g_player = nil
	g_clone = nil
	g_grace = 0
	g_heal = 0
	g_last_guard = nil
	g_has_backup = false
	g_clone_x, g_clone_y = -99999, -99999
end

-- The spell signals a cast over two independent channels, because the global
-- store is not always available and a single dropped signal means the spell
-- silently does nothing:
--   * a bkup_cast_pending tag on the player entity (no world state needed)
--   * a frame number in the global store (edge triggered, survives save/load)
-- Returns true exactly once per cast.
local function consume_pending_cast()
	local player = get_player()
	if valid(player) then
		local ok, has = pcall(EntityHasTag, player, CAST_TAG)
		if ok and has == true then
			pcall(EntityRemoveTag, player, CAST_TAG)
			g_cast_count = g_cast_count + 1
			print_error("backup_wand: cast detected via tag (#" .. g_cast_count .. ")")
			return true
		end
	end

	local frame = gget(G_FRAME, "")
	if frame ~= "" and frame ~= g_last_cast_frame then
		g_last_cast_frame = frame
		g_cast_count = g_cast_count + 1
		print_error("backup_wand: cast detected via globals (#" .. g_cast_count .. ")")
		return true
	end

	return false
end

-- One bad frame must never be able to disable the mod, so every step of the
-- tick runs independently. The death guard and the wand are the two things that
-- must keep working no matter what else fails.
local function step(name, fn)
	local ok, err = pcall(fn)
	if not ok then
		print_error("backup_wand: step '" .. name .. "' failed: " .. tostring(err))
	end
	return ok
end

function M.on_world_post_update()
	if not setting_on("enabled", true) then return end

	local player = get_player()
	if not valid(player) then
		-- OnPlayerSpawned / OnPlayerDied will sort it out
		return
	end

	-- Periodic trace so logger.txt shows the loop is alive and what it can see.
	local fnum = GameGetFrameNum()
	if fnum > 30 and (fnum % 600) < 2 then
		print_error(string.format(
			"backup_wand: tick frame=%d player=%s world_ready=%s casts=%d "
			.. "has_backup=%s clone=%s",
			fnum, tostring(player), tostring(g_world_ready), g_cast_count,
			tostring(has_backup()), tostring(find_clone())))
	end

	if g_grace > 0 then g_grace = g_grace - 1 end

	-- 1. the spell was cast
	step("cast", function()
		if consume_pending_cast() then
			M.cast_backup()
		end
	end)

	-- 2. quick-cast hotkey (works even if the wand or spell is broken)
	step("hotkey", check_hotkey)

	-- 3. the backup wand itself must never be permanently lost
	if GameGetFrameNum() - g_wand_check_frame >= WAND_CHECK_INTERVAL then
		g_wand_check_frame = GameGetFrameNum()
		step("wand", function() ensure_backup_wand(player, false) end)
		step("announce", announce)
	end

	-- 4. keep the copy healthy and remember where it is
	step("clone", keep_clone_alive)

	-- 5. never let the player die while a backup exists
	step("guard", function() M.update_death_guard() end)
	step("down", check_player_down)
	step("heal", top_up_heal)
end

return M
