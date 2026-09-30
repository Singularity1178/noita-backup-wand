# Backup Wand

A Noita mod. You get a **second wand** that holds a single spell called
**BACKUP**.

* Cast **BACKUP** and a full copy of you is created.
* Only **one** copy can exist at a time. Cast it again and the copy you already
  have is brought to you.
* If you **die** while a copy exists, you do not die. You wake up **as your
  copy**, standing where it was, carrying exactly what it was carrying.
* The spell costs **no mana** and has **unlimited uses** — cast it forever.

---

## Status

Confirmed working in game on **Noita v2024.08.12** — creating a copy, recalling
it, and being rescued into it on death all function. The rough edges are still
being smoothed out, so please [open an issue](https://github.com/Singularity1178/noita-backup-wand/issues)
if something behaves oddly rather than assuming it is intended.

## Installing

Copy the `backup_wand` folder into your Noita `mods` directory, then enable
**Backup Wand** in the mod list. It needs no other mods and no unsafe-API
permission.

---

## How to use it

1. Enable **Backup Wand** in the mod list (Noita → main menu → Mods).
2. Start a run. A **Backup Wand** appears in your quickslots.
3. Cast the spell either way:
   * **equip the Backup Wand** and click, exactly like any other wand, or
   * press the **quick-cast key** (default **C**) without switching wands.

The copy remembers everything you were carrying at the moment you cast:
every wand with its exact deck and gun settings, every loose spell card,
potions, perks (both the classic stat perks and the modern ones, including
their game effects and perk-bar icons), and your aggregate player stats.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Backup Wand enabled | on | Master switch, applies immediately. |
| Quick-cast key | C | Casts BACKUP without equipping the wand. `Disabled` forces you to use the wand. |
| Recalling also refreshes the backup | off | Off: casting again only moves your existing copy, leaving it exactly as first created. On: casting again also re-snapshots your current belongings. |
| Keep items found after the backup | off | Off: taking control of your copy gives you exactly the copy's loadout and the rest is left where you fell. On: you also keep what you picked up since, and anything that does not fit is dropped at your feet rather than destroyed. |
| Show the copy in the world | on | The ghostly double that marks where your backup is. Turn it off and the backup still works, it is just invisible. |

## What happens when you take a lethal hit

Yes — a hit that would kill you does exactly that, it triggers the transfer.

The mod sets `DamageModelComponent.wait_for_kill_flag_on_death` on the player for
as long as a copy exists. That tells the engine *not* to finish off an entity
whose HP has reached zero. Your HP still hits zero, but the actual death (death
FX, ragdoll, game over) is held back. The mod then notices HP is zero on that
same frame and swaps you into the copy:

1. your current belongings are cleared,
2. your copy's belongings are rebuilt onto you, together with its perks,
3. you are moved to where the copy was standing,
4. you are healed to full,
5. the copy is spent — **the backup is consumed**, so cast Backup again to make a
   new one.

Because the rescue happens in the same frame, the death state is not really
visible. What you get instead is a burst of particles, a screen shake, and an
on-screen message.

If there is **no** copy, nothing is intercepted and you die completely normally.
This is deliberately not a general immortality cheat: dying costs you the backup.

## Behaviour notes

* **The backup survives saving and loading.** The snapshot lives in the global
  cross-VM store, which is part of the world state and is written into the save
  file.
* **The copy in the world is only a marker.** The authoritative backup is the
  serialised snapshot, not the entity, so the backup keeps working even if the
  marker is destroyed, kicked around or streamed out of the world.
* **You cannot lose the wand.** If the Backup Wand ever leaves your inventory
  for good, the mod gives you a new one within a couple of seconds.
* **Without a backup you still die normally.** Death is only intercepted while a
  copy exists; the mod is not a general immortality cheat, and there is a
  safety net that prevents it from ever pinning you at 0 hp.

## Files

```
mod.xml                                 mod metadata
init.lua                                hooks; registers the spell
settings.lua                            mod settings UI
files/actions.lua                       the BACKUP spell
files/lib/backup.lua                    main logic (cast, recall, rescue)
files/lib/snapshot.lua                  serialise / rebuild a whole loadout
files/entities/backup_wand.xml          the second wand
files/entities/backup_clone.xml         the visible copy
```

## If something looks wrong

The mod writes a line to `logger.txt` (in the Noita folder) every time the
player spawns, a backup is created, or a rescue happens, and calls
`print_error` with the specific reason if the wand or the spell fails to
initialise. Look for lines starting with `backup_wand:`.

`[Backup Wand] Active.` on spawn means the mod loaded and the settings were
read correctly. If you never see it, the mod is disabled or errored.
