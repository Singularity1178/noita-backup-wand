-- mods/backup_wand/files/lib/snapshot.lua
--
-- Serialises everything that makes up "the player" into a plain string, and
-- rebuilds it later.
--
-- What gets captured:
--   * the carried inventory (wands with their exact decks, spell cards,
--     potions, perks items, ...)
--   * the perk list, both the modern ones (game effects, custom funcs, UI
--     icons) and the classic stat ones (PERK_* run flags)
--   * the aggregated player stats, as a safety net
--   * hp / max_hp and the inventory size
--
-- Why a string rather than "just walk the inventory of the clone entity"?
--   * the backup must survive save/load and mod reloads
--   * an entity parked in a world chunk that later streams out is not a
--     reliable place to keep a player's entire life savings
-- The string lives in the global cross-VM store, which is part of the world
-- state and is therefore written into the save file. The clone entity is only
-- a visual marker.
--
-- Encoding: one record per line, fields separated by "|", nested lists by
-- ";", "~" and ",". No game string (entity file, action id, field name)
-- contains those characters; strings are sanitised anyway for safety.
--
--   H|hp|max_hp|quick_slots|full_x|full_y                    header, first line
--   K|id,id,id,...                                         perk ids
--   S|field=value,field=value,...                          player stats
--   C|action_id|uses_remaining|is_identified|preferred      loose spell card
--   I|file|uses_remaining|is_identified|preferred|          ordinary item /
--     frozen|permanent                                       perk / potion / ...
--   W|file|gun_level|mana|mana_max|mana_charge_speed|         wand
--    actions_per_round|shuffle|reload_time|deck_capacity|
--    fire_rate_wait|<child>;<child>
--       <child> = action_id~uses_remaining~is_identified
--
-- The first line of the blob is a format version number.

local M = {}

local SEP = "|"
local LSEP = ";"
local CSEP = "~"
local CSSEP = ","
local KVSEP = "="
local VERSION = "2"

-------------------------------------------------------------------------------
-- small string helpers
-------------------------------------------------------------------------------

local function clean(s)
	if s == nil then return "" end
	s = tostring(s)
	s = s:gsub("[|%;\n\r~,]", "")
	return s
end

local function b2s(v)
	if v == nil then return "" end
	if v == true then return "1" end
	if v == false then return "0" end
	return tostring(v)
end

local function s2b(s)
	return s == "1" or s == "true"
end

local function s2n(s, default)
	local n = tonumber(s)
	if n == nil then return default end
	return n
end

-- split on a literal separator
local function split(s, sep)
	local out = {}
	if s == nil or s == "" then return out end
	local pos = 1
	while true do
		local a, b = string.find(s, sep, pos, true)
		if a == nil then
			table.insert(out, string.sub(s, pos))
			break
		end
		table.insert(out, string.sub(s, pos, a - 1))
		pos = b + 1
	end
	return out
end

M.split = split
M.clean = clean

-------------------------------------------------------------------------------
-- component helpers
-------------------------------------------------------------------------------

-- Enums come back from ComponentGetValue2 as their string name. Be tolerant:
-- if we ever get a number or nothing, return nil so the caller can fall back to
-- a safe default instead of writing garbage into an entity.
local function str_field(entity, type_name, field)
	local c = EntityGetFirstComponentIncludingDisabled(entity, type_name)
	if c == nil then return nil end
	local v = ComponentGetValue2(c, field)
	if type(v) == "string" then return v end
	return nil
end

local function num_field(entity, type_name, field, default)
	local c = EntityGetFirstComponentIncludingDisabled(entity, type_name)
	if c == nil then return default end
	local v = ComponentGetValue2(c, field)
	if type(v) == "number" then return v end
	return default
end

local function bool_field(entity, type_name, field)
	local c = EntityGetFirstComponentIncludingDisabled(entity, type_name)
	if c == nil then return nil end
	local v = ComponentGetValue2(c, field)
	if v == nil then return nil end
	return v == true or v == 1
end

local function obj_field(entity, object_name, field, default)
	local c = EntityGetFirstComponentIncludingDisabled(entity, "AbilityComponent")
	if c == nil then return default end
	local v = ComponentObjectGetValue2(c, object_name, field)
	if v == nil then return default end
	return v
end

local function set_if(comp_id, field, value)
	if comp_id == nil or value == nil then return end
	ComponentSetValue2(comp_id, field, value)
end

-- Disable every LuaComponent on an entity and clear the AbilityComponent's
-- add_these_child_actions. A wand loaded from a data file runs a procedural
-- script that fills it with random spells; we want none of that.
local function strip_wand_generation(wand)
	local comps = EntityGetComponentIncludingDisabled(wand, "LuaComponent")
	if comps ~= nil then
		for _, c in ipairs(comps) do
			EntitySetComponentIsEnabled(wand, c, false)
		end
	end

	local ab = EntityGetFirstComponentIncludingDisabled(wand, "AbilityComponent")
	if ab ~= nil then
		ComponentSetValue2(ab, "add_these_child_actions", "")
		-- deck not built yet, force a rebuild from the cards we add
		ComponentSetValue2(ab, "mIsInitialized", false)
	end
end

local function kill_all_cards(wand)
	local kids = EntityGetAllChildren(wand)
	if kids == nil then return end
	for _, k in ipairs(kids) do
		if EntityHasTag(k, "card_action") then
			EntityKill(k)
		end
	end
end

local function cards_of(wand)
	local out = {}
	local kids = EntityGetAllChildren(wand)
	if kids == nil then return out end
	for _, k in ipairs(kids) do
		if EntityHasTag(k, "card_action") then
			local ac = EntityGetFirstComponentIncludingDisabled(k, "ItemActionComponent")
			if ac ~= nil then
				local aid = ComponentGetValue2(ac, "action_id")
				if type(aid) == "string" and aid ~= "" then
					local ic = EntityGetFirstComponentIncludingDisabled(k, "ItemComponent")
					local uses, ided = -1, true
					if ic ~= nil then
						uses = ComponentGetValue2(ic, "uses_remaining")
						ided = ComponentGetValue2(ic, "is_identified")
					end
					table.insert(out, { action_id = aid, uses = uses, identified = ided })
				end
			end
		end
	end
	return out
end

-------------------------------------------------------------------------------
-- perks
-------------------------------------------------------------------------------

-- Every perk the player owns, whether classic or modern. A perk always leaves a
-- UIIconComponent child behind (that is what draws its icon in the perk bar),
-- whose "name" is the ui_name, e.g. "$perk_extra_hp" -> id EXTRA_HP.
local function perk_ids_of(entity)
	local ids, seen = {}, {}

	local function add(id)
		if type(id) == "string" and id ~= "" and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end

	local kids = EntityGetAllChildren(entity)
	if kids ~= nil then
		for _, k in ipairs(kids) do
			local ui = EntityGetFirstComponentIncludingDisabled(k, "UIIconComponent")
			if ui ~= nil then
				local nm = ComponentGetValue2(ui, "name")
				if type(nm) == "string" then
					local suffix = string.match(nm, "^%$perk_(.+)$")
					if suffix ~= nil then
						add(string.upper(suffix))
					end
				end
			end
		end
	end

	-- belt and braces: also trust the PERK_* run flags for every known perk
	pcall(function()
		dofile_once("data/scripts/perks/perk_list.lua")
		if perk_list ~= nil then
			for _, pd in ipairs(perk_list) do
				if pd ~= nil and type(pd.id) == "string" then
					if GameHasFlagRun("PERK_" .. pd.id) then
						add(pd.id)
					end
				end
			end
		end
	end)

	return ids
end

-- Only the interesting scalar stats, as a name -> number table. These are
-- recomputed by the engine from perks and effects, so restoring them is a
-- safety net rather than the primary mechanism.
local function stats_of(entity)
	local out = {}
	local comp = EntityGetFirstComponentIncludingDisabled(entity, "PlayerStatsComponent")
	if comp == nil then return out end

	local members = ComponentGetMembers(comp)
	if members == nil then return out end

	for field, _ in pairs(members) do
		local keep = string.sub(field, 1, 5) == "stat_"
			or field == "max_hp" or field == "speed" or field == "lives"
		if keep then
			local v = ComponentGetValue2(comp, field)
			if type(v) == "number" then
				out[field] = v
			end
		end
	end

	return out
end

-------------------------------------------------------------------------------
-- capture
-------------------------------------------------------------------------------

local function record_for(item)
	if item == nil or item == 0 or not EntityGetIsAlive(item) then return nil end
	local ic = EntityGetFirstComponentIncludingDisabled(item, "ItemComponent")
	if ic == nil then return nil end

	local uses = ComponentGetValue2(ic, "uses_remaining")
	local identified = ComponentGetValue2(ic, "is_identified")
	local preferred = str_field(item, "ItemComponent", "preferred_inventory")

	-- spell card: fully described by its action id
	local ac = EntityGetFirstComponentIncludingDisabled(item, "ItemActionComponent")
	if ac ~= nil then
		local aid = ComponentGetValue2(ac, "action_id")
		if type(aid) == "string" and aid ~= "" then
			return table.concat({
				"C", clean(aid), b2s(uses), b2s(identified), clean(preferred),
			}, SEP)
		end
	end

	-- everything else needs its source file
	local file = EntityGetFilename(item)
	if type(file) ~= "string" or file == "" or file == "nil" then return nil end
	if not string.find(file, "%.xml$") then return nil end
	file = clean(file)

	if EntityHasTag(item, "wand") then
		local cards = cards_of(item)
		local child_strs = {}
		for _, c in ipairs(cards) do
			table.insert(child_strs, table.concat({
				clean(c.action_id), b2s(c.uses), b2s(c.identified),
			}, CSEP))
		end

		return table.concat({
			"W",
			file,
			b2s(num_field(item, "AbilityComponent", "gun_level", 1)),
			b2s(num_field(item, "AbilityComponent", "mana", 0)),
			b2s(num_field(item, "AbilityComponent", "mana_max", 100)),
			b2s(num_field(item, "AbilityComponent", "mana_charge_speed", 10)),
			b2s(obj_field(item, "gun_config", "actions_per_round", 1)),
			b2s(obj_field(item, "gun_config", "shuffle_deck_when_empty", false)),
			b2s(obj_field(item, "gun_config", "reload_time", 40)),
			b2s(obj_field(item, "gun_config", "deck_capacity", 2)),
			b2s(obj_field(item, "gunaction_config", "fire_rate_wait", 5)),
			table.concat(child_strs, LSEP),
		}, SEP)
	end

	return table.concat({
		"I",
		file,
		b2s(uses),
		b2s(identified),
		clean(preferred),
		b2s(bool_field(item, "ItemComponent", "is_frozen")),
		b2s(bool_field(item, "ItemComponent", "permanently_attached")),
	}, SEP)
end

-- entity -> blob string
function M.capture(entity)
	if entity == nil or entity == 0 or not EntityGetIsAlive(entity) then return "" end

	local lines = {}

	local inv2 = EntityGetFirstComponentIncludingDisabled(entity, "Inventory2Component")
	local quick, fx, fy = 10, 16, 8
	if inv2 ~= nil then
		quick = ComponentGetValue2(inv2, "quick_inventory_slots")
		fx = ComponentGetValue2(inv2, "full_inventory_slots_x")
		fy = ComponentGetValue2(inv2, "full_inventory_slots_y")
	end
	if type(quick) ~= "number" then quick = 10 end
	if type(fx) ~= "number" then fx = 16 end
	if type(fy) ~= "number" then fy = 8 end

	table.insert(lines, table.concat({
		"H",
		b2s(num_field(entity, "DamageModelComponent", "hp", 0)),
		b2s(num_field(entity, "DamageModelComponent", "max_hp", 0)),
		b2s(quick), b2s(fx), b2s(fy),
	}, SEP))

	local perks = perk_ids_of(entity)
	if #perks > 0 then
		local ids = {}
		for i, id in ipairs(perks) do ids[i] = clean(id) end
		table.insert(lines, "K" .. SEP .. table.concat(ids, CSSEP))
	end

	local stats = stats_of(entity)
	local stat_parts, stat_n = {}, 0
	for field, v in pairs(stats) do
		stat_n = stat_n + 1
		table.insert(stat_parts, clean(field) .. KVSEP .. b2s(v))
	end
	if stat_n > 0 then
		table.insert(lines, "S" .. SEP .. table.concat(stat_parts, CSSEP))
	end

	local items = GameGetAllInventoryItems(entity)
	if items ~= nil then
		for _, item in ipairs(items) do
			local rec = record_for(item)
			if rec ~= nil then table.insert(lines, rec) end
		end
	end

	return VERSION .. "\n" .. table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- restore
-------------------------------------------------------------------------------

-- Entities this mod creates are recognised at runtime by name and tag, so that
-- identity has to be re-applied whenever one is rebuilt from a record.
local OWNED_FILES = {
	["mods/backup_wand/files/entities/backup_wand.xml"] = {
		name = "backup_wand_item", tag = "bkup_backup_wand",
	},
}

local function reapply_identity(e, file)
	local o = OWNED_FILES[file]
	if o == nil then return end
	EntitySetName(e, o.name)
	EntityAddTag(e, o.tag)
end

-- Rebuild one entity from a record. Does NOT put it in anybody's inventory.
local function build(fields, x, y)
	local kind = fields[1]
	local e

	if kind == "C" then
		local aid = fields[2]
		if aid == nil or aid == "" then return nil end
		e = CreateItemActionEntity(aid, x, y)
		if e == nil or e == 0 or not EntityGetIsAlive(e) then return nil end
		local ic = EntityGetFirstComponentIncludingDisabled(e, "ItemComponent")
		set_if(ic, "uses_remaining", s2n(fields[3], -1))
		set_if(ic, "is_identified", s2b(fields[4]))
		if fields[5] ~= nil and fields[5] ~= "" then
			set_if(ic, "preferred_inventory", fields[5])
		end
		return e

	elseif kind == "I" then
		local file = fields[2]
		if file == nil or file == "" then return nil end
		e = EntityLoad(file, x, y)
		if e == nil or e == 0 or not EntityGetIsAlive(e) then return nil end
		reapply_identity(e, file)
		local ic = EntityGetFirstComponentIncludingDisabled(e, "ItemComponent")
		set_if(ic, "uses_remaining", s2n(fields[3], -1))
		set_if(ic, "is_identified", s2b(fields[4]))
		if fields[5] ~= nil and fields[5] ~= "" then
			set_if(ic, "preferred_inventory", fields[5])
		end
		set_if(ic, "is_frozen", s2b(fields[6]))
		set_if(ic, "permanently_attached", s2b(fields[7]))
		return e

	elseif kind == "W" then
		local file = fields[2]
		if file == nil or file == "" then return nil end
		e = EntityLoad(file, x, y)
		if e == nil or e == 0 or not EntityGetIsAlive(e) then return nil end
		reapply_identity(e, file)

		-- kill the wand's own generator and any cards it already made
		strip_wand_generation(e)
		kill_all_cards(e)

		local ab = EntityGetFirstComponentIncludingDisabled(e, "AbilityComponent")
		if ab == nil then return e end

		set_if(ab, "gun_level", s2n(fields[3]))
		set_if(ab, "mana", s2n(fields[4]))
		set_if(ab, "mana_max", s2n(fields[5]))
		set_if(ab, "mana_charge_speed", s2n(fields[6]))
		ComponentObjectSetValue2(ab, "gun_config", "actions_per_round", s2n(fields[7], 1))
		ComponentObjectSetValue2(ab, "gun_config", "shuffle_deck_when_empty", s2b(fields[8]))
		ComponentObjectSetValue2(ab, "gun_config", "reload_time", s2n(fields[9]))
		ComponentObjectSetValue2(ab, "gun_config", "deck_capacity", s2n(fields[10], 1))
		ComponentObjectSetValue2(ab, "gunaction_config", "fire_rate_wait", s2n(fields[11], 5))

		-- re-insert the recorded deck, in the recorded order
		local added = 0
		for _, cs in ipairs(split(fields[12] or "", LSEP)) do
			if cs ~= "" then
				local cf = split(cs, CSEP)
				local aid = cf[1]
				if aid ~= nil and aid ~= "" then
					local card = CreateItemActionEntity(aid, x, y)
					if card ~= nil and card ~= 0 then
						EntityAddChild(e, card)
						EntitySetComponentsWithTagEnabled(card, "enabled_in_world", false)
						local cic = EntityGetFirstComponentIncludingDisabled(card, "ItemComponent")
						set_if(cic, "uses_remaining", s2n(cf[2], -1))
						set_if(cic, "is_identified", s2b(cf[3]))
						added = added + 1
					end
				end
			end
		end

		local cap = s2n(fields[10], 0)
		if cap < added then
			ComponentObjectSetValue2(ab, "gun_config", "deck_capacity", added)
		end
		return e
	end

	return nil
end

-- blob -> a list of freshly built entities sitting loose in the world
function M.build_all(blob, x, y)
	local out = {}
	if blob == nil or blob == "" then return out end

	local lines = split(blob, "\n")
	if lines[1] == VERSION then table.remove(lines, 1) end

	-- wands first, so their decks are complete before anything is picked up
	for _, line in ipairs(lines) do
		if line ~= "" then
			local fields = split(line, SEP)
			if fields[1] == "W" then
				local e = build(fields, x, y)
				if e ~= nil then table.insert(out, e) end
			end
		end
	end

	for _, line in ipairs(lines) do
		if line ~= "" then
			local fields = split(line, SEP)
			if fields[1] == "I" or fields[1] == "C" then
				local e = build(fields, x, y)
				if e ~= nil then table.insert(out, e) end
			end
		end
	end

	return out
end

-- Re-apply the perk list. Two mechanisms are needed:
--   * the PERK_* run flag, which is what the engine (and the classic stat
--     perks) actually reads
--   * the game's own perk_pickup(), for every perk that lives in perk_list.lua,
--     so that game effects, custom funcs and the perk-bar icons come back
function M.restore_perks(entity, ids)
	if entity == nil or entity == 0 or not EntityGetIsAlive(entity) then return end
	if ids == nil or #ids == 0 then return end

	local known = {}
	pcall(function()
		dofile_once("data/scripts/perks/perk_list.lua")
		if perk_list ~= nil then
			for _, pd in ipairs(perk_list) do
				if pd ~= nil and type(pd.id) == "string" then
					known[pd.id] = true
				end
			end
		end
	end)

	-- This is exactly what data/scripts/perks/give_all_perks.lua does, i.e. the
	-- game's own supported way of granting a perk by id with no perk item.
	local have_perk_pickup = false
	if next(known) ~= nil then
		local ok = pcall(dofile, "data/scripts/game_helpers.lua")
		ok = pcall(dofile_once, "data/scripts/lib/utilities.lua") and ok
		ok = pcall(dofile_once, "data/scripts/perks/perk_list.lua") and ok
		ok = pcall(dofile, "data/scripts/perks/perk.lua") and ok
		have_perk_pickup = ok
	end

	for _, id in ipairs(ids) do
		if type(id) == "string" and id ~= "" then
			pcall(GameAddFlagRun, "PERK_" .. id)
			if known[id] and have_perk_pickup and perk_pickup ~= nil then
				pcall(perk_pickup, 0, entity, id, false, false, true)
			end
		end
	end
end

-- Safety net: put the recorded aggregate stats back.
function M.restore_stats(entity, pairs_list)
	if entity == nil or entity == 0 or not EntityGetIsAlive(entity) then return end
	if pairs_list == nil or #pairs_list == 0 then return end

	local comp = EntityGetFirstComponentIncludingDisabled(entity, "PlayerStatsComponent")
	if comp == nil then return end

	for _, kv in ipairs(pairs_list) do
		local f, v = string.match(kv, "^(.-)=([^=]*)$")
		if f ~= nil and f ~= "" then
			local n = tonumber(v)
			if n ~= nil then
				pcall(ComponentSetValue2, comp, f, n)
			end
		end
	end
end

-- Pull the K and S records out of a blob.
function M.read_meta(blob)
	local perks, stats = {}, {}
	if blob == nil or blob == "" then
		return perks, stats
	end

	local lines = split(blob, "\n")
	for _, line in ipairs(lines) do
		if line ~= "" then
			local fields = split(line, SEP)
			if fields[1] == "K" and fields[2] ~= nil and fields[2] ~= "" then
				for _, id in ipairs(split(fields[2], CSSEP)) do
					if id ~= "" then table.insert(perks, id) end
				end
			elseif fields[1] == "S" and fields[2] ~= nil and fields[2] ~= "" then
				for _, kv in ipairs(split(fields[2], CSSEP)) do
					if kv ~= "" then table.insert(stats, kv) end
				end
			end
		end
	end

	return perks, stats
end

-- Everything that still has no parent ended up on the floor rather than in an
-- inventory; nudge those next to `x, y` so nothing is lost off-screen.
function M.scatter_leftovers(entities, x, y)
	for i, e in ipairs(entities) do
		if e ~= nil and e ~= 0 and EntityGetIsAlive(e) and EntityGetParent(e) == 0 then
			local a = i * 2.399963 -- golden angle, spreads them in a ring
			local r = 8 + (i % 5) * 3
			EntitySetTransform(e, x + math.cos(a) * r, y + math.sin(a) * r)
		end
	end
end

return M
