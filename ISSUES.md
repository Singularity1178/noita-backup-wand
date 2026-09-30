# Known issues

Open bug list for the Backup Wand mod. **Nothing here is fixed yet** — this file
is a record of what has been observed in game so the issues can be reproduced and
chased down.

Last updated: initial report from the author.

## Environment

| | |
| --- | --- |
| Noita version | v2024.08.12 (Aug 12 2024) |
| Commit reported against | `1b117e1` ("Fix blocking cast bug, plus six follow-ups") |
| Platform | Windows |
| Installed as | `mods/backup_wand` |

## Confirmed working

So that regressions are obvious, these were observed working:

- Casting **BACKUP** creates a copy.
- Casting it again while a copy exists recalls that copy.
- A lethal hit while a copy exists does not end the run; the player is
  resurrected into the copy and the backup is consumed.
- The Backup Wand appears in the quickslots on spawn and can be equipped and
  fired like a normal wand.
- Post-backup items are not destroyed: they are dropped on the floor where the
  player fell.

---

## BUG-01 — The copy follows the player around

**Severity:** high — it undermines the whole point of the copy being a separate
body you can walk away from.

The copy is expected to stand still where it was left. Instead it moves in
step with the player, so it is never actually "somewhere else" to be rescued to.

**Reproduction:** cast BACKUP, then walk away. The copy comes with you.

**Notes / likely suspects (unverified):** the copy is built from
`data/entities/player_base.xml` with `CharacterPlatformingComponent` and
`ControlsComponent` disabled, so it should not self-move. That it tracks the
player suggests it is being treated as a child of the player, or a transform is
being re-applied to it every frame. Worth checking:

- `files/entities/backup_clone.xml` — whether any inherited component pulls its
  transform from a parent. `player_base.xml` attaches an `arm_r` child with an
  `InheritTransformComponent` referencing the `right_arm_root` hotspot, and a
  verlet-chain `cape`.
- Whether the copy is in fact parented to the player, rather than being a free
  world entity.
- `keep_clone_alive()` runs every frame and writes the marker's position back
  to the global store. It only *reads* the transform, so it should be innocent,
  but it is the only per-frame code touching the copy.

## BUG-02 — Row of blue dots rising to the right of the copy

**Severity:** low — cosmetic, but it is very visible and constant.

A row of small blue dots appears consistently to the right of the copy, travels
upwards, dissipates, and then more appear.

**Reproduction:** cast BACKUP and stand still.

**Likely cause (high confidence):** this is our own effect, not a game bug.
`files/entities/backup_clone.xml` adds a `SpriteParticleEmitterComponent` using
`data/particles/smoke_ghostly.png` with a blue tint, `velocity.y = -5`,
`emission_interval_min_frames = 5` and `randomize_position.max_x = 8`. That
describes the observed behaviour exactly: a band of particles to one side,
rising, fading out via `color_change.a = -0.30`, repeating on the interval.

The intent was a soft ghost aura. It reads as a line of discrete dots rather
than a haze, and the horizontal offset makes it lopsided. Options: drop the
emitter, widen and randomise it properly, or replace it with a subtler effect.

## BUG-03 — Second, larger crosshair over the copy

**Severity:** low — cosmetic.

A second crosshair is drawn over/near the copy. It is larger than the player's
reticle and has a black outline.

**Likely cause (high confidence):** this is inherited, not added. The copy is
built from `data/entities/player_base.xml`, which contains the player's aiming
reticle:

```xml
<SpriteComponent
  _tags="aiming_reticle"
  image_file="data/ui_gfx/mouse_cursor.png"
  offset_x="6" offset_y="35"
  has_special_scale="1" special_scale_x="1" special_scale_y="1"
  emissive="1" />
```

The copy overrides the `character` sprite in `backup_clone.xml` but leaves the
`aiming_reticle` sprite inherited and enabled, so every copy draws its own
mouse cursor 35px below itself. The fix would be to disable that component in
`backup_clone.xml` (it is not a player, so it has no cursor to show).

## BUG-04 — Occasionally more than one copy exists (3 bodies with the original)

**Severity:** high — breaks the "only one copy" rule, which is a core promise of
the mod.

Sometimes three characters are visible at once, including the original player.
Not yet reproducible on demand.

**Notes / likely suspects (unverified):** this is probably orphaned copy
markers that nothing ever cleans up. Two structural weaknesses make it likely:

1. **`EntityGetWithName` returns a single entity id, not a list.** This is
   already a known trap in this codebase — it caused BUG-05's predecessor, a
   blocking crash. `find_clone()` can therefore only ever track *one* marker.
   `drop_clone()` kills only the one `find_clone()` returns, so if two copies
   ever exist, the other is invisible to the mod and is never killed.

2. **`CameraBoundComponent` on the copy has `freeze_on_distance_kill="1"` and
   `freeze_on_max_count_kill="1"`.** Per the component docs, a frozen entity is
   *stored* and later **respawned** where it was destroyed. A marker that
   wandered out of range and got frozen can come back later as a duplicate, and
   nothing in the mod accounts for that.

Worth checking whether `place_marker()` should sweep *all* `bkup_clone`-tagged
entities rather than trusting a single lookup, and whether `CameraBoundComponent`
is even wanted on something that is a bookmark, not a live actor.

## BUG-05 — The copy does not retain the same wands

**Severity:** high — this is the headline feature.

After taking control of the copy, the wands are not the ones it was carrying.
Perks were not tested, so it is unknown whether they suffer the same problem.

**Reproduction:** pick up and modify a wand, cast BACKUP, then die and take
control of the copy. The wands are wrong or missing.

**Reproduction status:** not reproduced in the offline round-trip harness —
`files/lib/snapshot.lua` passes 12/12 mocked tests, including a case that
restores two wands with exact decks, gun configuration, mana, and the backup
wand itself holding only `BACKUP` with unlimited uses. So the discrepancy is
something the mock does not model. Useful angles to investigate:

- **`EntityGetFilename` is the weak link in the serializer.** The API docs warn
  it returns an *incorrect* value "if the entity has passed through the world
  streaming system". A wand picked up from a chest in a streamed chunk may
  report a stale path, and `record_for()` silently returns `nil` for an item
  with no usable file, so the wand is quietly dropped from the snapshot. This
  would produce exactly the reported symptom, and it would be intermittent and
  hard to notice.
- **Capacity.** The rescue drops the dying player's items first, then restores
  the snapshot, so capacity should not be the issue — but
  `GameDropPlayerInventoryItems` failing silently would leave the inventory
  full and every subsequent `GamePickUpInventoryItem` to overflow onto the
  floor. Worth logging how many items `build_all` actually produced versus how
  many were successfully picked up.
- **`mIsInitialized`** is written on the `AbilityComponent` in both
  `make_backup_wand` and the snapshot restore, and it is a *private* field. If
  the engine refuses to write it, the rebuilt wand's deck may never be built.
- **`EntityLoad` of a wand data file** runs that wand's own procedural script
  (e.g. `wand_level_03.lua` → `generate_gun(...)`). The restore path disables
  the wand's `LuaComponent`s and kills the `card_action` children first, but
  those `LuaComponent`s have `execute_on_added="1"`, so there is a race: if the
  engine runs them before the disabling takes effect, `generate_gun` will have
  already added random spells and possibly reset the gun configuration.
- **Useful next step:** log every record the snapshot produces, and every
  `EntityLoad` that returns 0, so it is visible how many wands went in and how
  many came out.

---

## Deliberate behaviour that may look like a bug

Listed so they are not "fixed" by mistake:

- Dying with **no** backup ends the run normally. The backup has to cost
  something.
- Items picked up **after** the last cast are left where the player fell, unless
  *Keep items found after the backup* is enabled. Overflow is dropped, never
  destroyed.
- Taking control of the copy **consumes** it; BACKUP must be cast again.
- Recalling the copy relocates it but does **not** re-snapshot it, unless
  *Recalling also refreshes the backup* is enabled.
- Turning off *Show the copy in the world* hides the marker but leaves the
  backup fully functional.
