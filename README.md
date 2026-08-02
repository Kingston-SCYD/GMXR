MAINTAINER NOTE: STABLE

THIS IS INDEV SANDBOX FOR STABLE TESTING, not worth tainting nighty for this.

DO NOT PUSH FRESH FEATURES TO STABLE UNTIL YOU HAVE COMPLETED A FULL TEST LOOP, WITH WAYNE, WITHOUT MAJOR ISSUES.

Module: 0.2.0a (Linux/Proton uses vrmod_linux 1 with hardcoded Quest 2 dims)

---

## Linux/Proton Setup

Linux users running GMod through Proton with WiVRn/OpenXR need the **64-bit** `openxr_loader.dll`.
The one in `Modules/` is 32-bit (for native Windows). The 64-bit version is in `Modules/linux_loader/`.

**Install:**
1. Copy `Modules/linux_loader/openxr_loader.dll` to `GarrysMod/bin/win64/openxr_loader.dll`
2. Set `vrmod_linux 1` in GMod console
3. The module DLL (`gmcl_vrmod_win64.dll`) goes in `garrysmod/lua/bin/` as usual

---

## Changelog

### 2026-06-17 - NEVER CRY (LAV)
- Fixed: Playermodels breaking when using worldmodel weapons
- Fix: Dynamic Flashlight Support
- Added: Toggle Overrides Per Override
- Fix: Small Hull
- Added: Small Hull Scale
- Added: Hull Menu by server (might move into server)

### 2026-06-16 - Melee Hand Grip Fix (Kingston)
- Fixed: player model hand stays flat when holding melee weapons (crowbar, stunstick)
- Root cause: finger tracking validation zeroed closedHandAngles at startup
- Fix: restore closedHandAngles from defaults on melee weapon equip
- Disabled the zeroing code in cl_character.lua
- All 5 finger curls forced to 1 when holding NotAGun weapons
- ArcVR melee damage blocked (avr_meleeattack) - only VRMod fling system does damage
- Melee physics bat visibility now uses vrmod_visual_debug
### 2026-06-16 - Foregrip Changes (Lav)

Added:
- Foregrip SPHERE mode
- Foregrip SPHERE slider

### 2026-06-14 - Stock ArcVR Rewrite (Kingston)

**Architecture Change**
- ArcVR (workshop 3680991679) handles its own entities: magazine pickup/positioning, shell ejection, slide/bolt, mag insertion, dual wield, left-hand weapons
- x64 handles: props, ragdolls, non-ArcVR weapons, holster system
- Pouch spawns mags using ArcVR's native heldItems + vrutil_net_pickup system (EntityPose positioning)
- Stock avr_spawnmag disabled server-side to prevent double mag spawns from bone-based pouch
- Old mag in hand cleared before new mag spawns (prevents ghost mags from previous weapon)
- sh_pickup_arcvr.lua restored from original workshop 3442302711

**Ammo Pouch**
- HMD-relative sphere (14 units below head, offset 3 units back)
- Left grip in sphere spawns mag into left hand
- Disables when looking down (vrmod_pouch_fix_lookdown cvar, default 55 degrees)
- Crouching halves the drop distance
- 0.5s cooldown prevents double spawns
- Debug sphere: green idle, yellow hand-in, red gripping, gray disabled

**X Button (Mag Eject + Flick Reload)**
- Pressing X calls EjectMagazine(false) on ArcVR weapons (drops mag to floor)
- X also signals boolean_reload for flick reload detection
- Hold X + flick gun hand downward for instant full reload

**Smooth Finger Animations**
- Thumb, trigger, and grip fingers all use math_Approach for smooth 0.1s transitions
- No more snapping between open/closed

**Valve Index Bindings**
- Full Index controller profile added to cl_input.lua
- Squeeze force for grip, A/B buttons per hand

**Linux/Proton Startup**
- vrmod_linux 1 for Proton/WiVRn users
- Bypasses GetDisplayInfo (fails under 0.2.0a Proton), uses hardcoded Quest 2 dims
- Deferred first-frame setup gets correct FOV/IPD after session starts

### 2026-06-10 - Weapon Pickup Rework (Kingston, fix/weapon-pickup-rework)

**Root Cause: hands locking up after weapon grab/drop**
- `rightBusy` check in client-side pickup scanning blocked right hand from finding targets whenever a weapon was equipped
- Stale `heldEntityLeft/Right` references (entity removed but ref not cleared) permanently blocked hand scanning
- ArcVR's `GrabAndPose` wrote to `heldItems` in array format, corrupting x64's index-1/2 format

**Fixes**
- Removed `rightBusy` flag entirely - weapons don't block hand scanning, only physics-held entities do
- Added per-tick `IsValid` cleanup: stale entity refs in `heldEntityLeft/Right` are cleared to nil automatically
- ArcVR `sv_arcticvr.lua` patched: `GrabAndPose` now calls `vrmod.Pickup()` instead of managing heldItems directly
- `avr_pose` net handler disabled (x64 PhysicsSimulate handles entity positioning)
- `avr_spawnmag` disabled (vrmod_pouch_spawnmag handles mag spawning)
- `MagPickupIntercept` removed (x64 handles all pickup validation)
- All `heldItems` manipulation in ArcVR neutralized
- Magazine positioning uses ArcVR's per-mag `Pose` data via custom RenderOverride matching original EntityPose logic
- Ground magazine pickup: same ammo type = picks up directly into hand, different ammo type = absorbs rounds + pickup sound
- Magazine physics reinit on drop (restores correct collision hull after motion controller)
- Magazine debug: white wireframe OBB box in vrmod_visual_debug mode
- Pouch disables when looking down past 65 degrees (gray sphere in debug) so you can grab through it
- Pouch spawned mags marked with `_pouch_spawned` to avoid double-absorption
- Magazine shadows disabled (physics position doesn't match visual)
- On mag drop, entity snaps to visual hand position (EntityPose) before physics release
- Holster weapon draw: direct Give+SelectWeapon, no entity spawn roundtrip
- Fixed `vrmod_lefthand_flag` unpooled net message crash that blocked holster draws

### 2026-06-10 - Left Hand & Pouch (Kingston)

- Removed x64 left-hand weapon system (`sh_lefthand.lua` deleted)
- Purged all `g_VR.gunInLeftHand` and `_avr_gunInLeftHand` references (hardcoded to right-hand)
- Left hand pickup of weapons blocked at `IsValidPickupTarget` level
- Weapons are right-hand only until left-hand support is rewritten from scratch
- `vrmod_pouch_lefthandwep_enable` default changed to 0
- Ammo pouch: left hand grabs mags only, right hand is weapon hand

### 2026-06-10 - Sound Update and clean up (PlagueEMT)
- Added unuploaded sounds
- Removed lua/lua folder
- Removed office images in autorun folder
- Removed lua.ink, which would prevent a workshop upload

### 2026-06-10 - Debug System & Pouch Tuning (Kingston)

**vrmod_visual_debug - Master Debug Toggle**
- Added `vrmod.DebugVisible()` API function in `sh_api.lua` for all future debug visuals
- `vrmod_visual_debug 0/1` is the single cvar that controls all debug rendering (pouch sphere, melee trace, etc.)
- Future debug visuals should use `if not vrmod.DebugVisible() then return end`

**Ammo Pouch Tuning**
- Sphere offset 3 units backward (toward body) using yaw-only direction, so it sits closer to hips
- Crouching moves sphere to 50% of cvar drop value (scales with whatever `vrmod_pouch_fix_drop` is set to)

**Melee System**
- Projectile weapons (ArcVR guns) now track right hand position directly instead of viewmodel offset - no more floating trace line above the weapon
- Debug trace controlled exclusively by `vrmod_visual_debug`

**ArcVR Mag Eject**
- X button now calls `EjectMagazine(false)` directly - mag drops to floor instead of being placed in left hand

### 2026-06-09 - ArcVR Reload & Input Fixes (Kingston)

**ArcVR Hip Pouch (Magazine Grab)**
- ArcVR's bone-based hip pouch (`Bip01_L_Thigh`) fails on player models missing that bone
- Replaced with HMD-relative sphere: 14 units below head, 14 unit radius, world-space (straight down regardless of head tilt)
- Magazine spawns directly into left hand via `vrmod.Pickup` server-side - no visible world pop-in
- Sphere renders as wireframe: green (idle), yellow (hand inside), red (gripping)
- Pickup target check removed - was false-positiving and blocking mag spawns
- 0.5s cooldown prevents double spawns
- Uses own `vrmod_pouch_spawnmag` net message to bypass ArcVR's `GrabAndPose` which put mags in the wrong hand due to heldItems format mismatch with x64

**ArcVR Mag Eject (X Button)**
- `boolean_reload` was never bound in the active Oculus Touch profile (`cl_input.lua`), X was bound to `boolean_use`
- Added VRInput forwarding: when holding an ArcVR weapon, `boolean_use` (X) is translated to `boolean_reload` and passed to `SWEP:VRInput`
- Default `+use` command is suppressed when holding ArcVR weapons so it doesn't fire alongside mag eject
- Also forwards all other non-grip inputs to `wpn:VRInput` so ArcVR's foregrip, slide lock, etc. all work

**Dead Input Systems Removed**
- Removed ~50 lines of old inline action set + 4 hardcoded controller profiles from `cl_vrmod.lua` (was dead code behind `if vrmod.SetupXRActions then return end`)
- Removed orphaned `cl_steamvr_bindings.lua` (SteamVR JSON manifest, never loaded by anything)
- Single input system remains: `cl_input.lua` using OpenXR action sets (works for all runtimes including SteamVR)

**Default Input**
- `boolean_reload` no longer sends `+reload` to engine when holding ArcVR weapons (ArcVR handles reload internally via VRInput)

### 2026-06-09 - Pickup System Fixes (from Welp111 nighty)

**Two-Hand Prop Grab**
- If `vrmod_twohand` state was lost (hot-reload, mixed-generation grab), rebuilt from `heldItems` so second-hand grab doesn't silently fail

**Prop Falling After Two-Hand Release**
- Fixed typo `eg_VR` to `g_VR` (broken global reference in sh_pickup_util)
- `_FinalizePickupRemoval` now only clears `vrmod_pickup_info` if the entry still owns the entity - previously clobbered the surviving hand's reference, causing PhysicsSimulate to bail and props to fall server-side
- `AttachPhysicsToController` deduplicates physics objects - prevents adding same phys to motion controller twice on second-hand grab
- Clears `_vrmod_onmc` flag on release so re-grabs work correctly

**NPC Weapon Grab Leak**
- Blocks grabbing NPC-owned weapons (live weapons on NPCs) - grabbing these leaked pickupCount permanently, which breaks ALL future grips globally
- Blocks grabbing `vrmod_is_ragdoll_weapon` (decorative fake weapons welded to ragdolls)
- Added `PurgePickupByEntity()` - auto-cleanup via `CallOnRemove` when a held entity is removed unexpectedly
- Re-grabbing a dropped NPC ragdoll cancels despawn timer and clears drop flags - prevents ragdoll from Remove()'ing mid-hold

**Debug VR Mode**
- Hands now track full view (pitch + yaw) so you can aim at props during desktop testing
- Added mouse1/mouse2 as left/right grip inputs for full grab pipeline testing
- Fires `VRMod_Exit` hook on stop so spawnmenu and other VR-only UI restores properly
- Grips release cleanly on debug stop

---

## Current Quest 2 Bindings (cl_input.lua)

| Button | Action |
|--------|--------|
| Left Trigger | Secondary Fire |
| Right Trigger | Primary Fire |
| Left Grip | Left Pickup |
| Right Grip | Right Pickup |
| X (click) | Use (Mag Eject when holding ArcVR weapon) |
| Y (touch) | Radial Weapon Menu |
| Y (click) | Spawn Menu |
| A | Jump |
| B | Crouch |
| Left Stick | Walk |
| Right Stick | Smooth Turn |
| Left Stick Click | Sprint |
| Right Stick Click | Change Weapon |

---

## Console Variables

| Cvar | Default | Description |
|------|---------|-------------|
| vrmod_visual_debug | 0 | Master toggle for all debug visuals |
| vrmod_pouch_fix_drop | 14 | Units below HMD for ammo pouch sphere |
| vrmod_pouch_fix_radius | 14 | Radius of ammo pouch sphere |
| vrmod_pouch_enabled | 1 | Enable/disable holster system |
| vrmod_pouch_visiblename | 1 | Show holster slot spheres and labels |
| vrmod_pouch_lefthandwep_enable | 0 | Allow left hand to hold weapons from holster |

---

## Remaining Tasks

- Fix PAC3 Bugs.
- Climbing: visual debug traces, write toggleable wall-grip system
- Player scale: reverted for stability, re-add after core is stable
- Sticky Grab for Props (Toggle Grab)
- Gravity Gloves tuning
- Gravity Gloves sounds
- FBT hands on foregrip for NonVR/ArcVR SWEPs
- VR Player Hitboxes
- Edge Culling
- Per-hand vehicle wheel grabbing
- Left Hand Foregripping
- Settings Menu Polish

---

## RTVS Server Commands & CVars Reference

### VRMod / ArcVR
```
arcticvr_flickreload 1
arcticvr_flickreload_dw 0
arcticvr_shootsys 1
arcticvr_physical_bullets 0
arcticvr_defaultammo_normalize 0
arcticvr_net_magtimertime 0.11
arcticvr_grenade_pin_enable 1
arcticvr_dmgmul_assault_rifle 1
arcticvr_dmgmul_smg 1
arcticvr_dmgmul_shotgun 1
arcticvr_dmgmul_pistol 1
arcticvr_dmgmul_sniper_rifle 1
arcticvr_dmgmul_melee 1
arcticvr_dmgmul_rocket_launcher 1
```

### Misc Binds
```
physgun_nocollide_key
+voicethrow, +voicethrow_target
+alyx_radial_menu
pv_delay 150
lad_btl_fast_switching 1
89 fov
stacker_improved_force_stayinworld 0
```

### Combine Mech
```
sv_combinemech_disablemodifiers
sv_combinemech_maxhealth 400
sv_combinemech_maxshield 100
sv_combinemech_maxhoverheight 1000
sv_combinemech_allowwepswhileflying
```

### VFire
```
Client:
  vfire_lod 1
  vfire_enable_glows 1
  vfire_enable_lights 1
  vfire_light_brightness 1
  vfire_default_visual_settings

Server:
  vfire_spread_boost
  vfire_enable_damage 1
  vfire_enable_damage_in_vehicles 0
  vfire_damage_multiplier 1
  vfire_enable_explosion_fires 1
  vfire_enable_explosion_effects 1
  vfire_enable_decals 1
  vfire_decal_probability 1
  vfire_enable_spread 1
  vfire_spread_delay
  vfire_decay_rate
  vfire_affect_npcs 1
  vfire_remove_all
  vfire_default_settings
```

### Screen Message / Arm HUD

Chat Commands:
```
HUDT,PlayerName: text            - Send text to screen
HUDT: text                       - Send to default player
HUDT,*: text                     - Broadcast to all
HUDT,PlayerName: text, X, Y      - With position offset

HUDH,PlayerName: Label, Value    - Update HUD bar label + number
HUDH: Label, Value               - Default player
HUDH,*: Label, Value             - Broadcast

HUDBAR,PlayerName: Label, Value, Percent
HUDBAR: Label, Value, Percent, AnimFlag

HUDE,PlayerName: URL             - Send image/video to forearm HUD
HUDE: URL, Duration              - With duration (default 5s)
HUDE,*: URL                      - Broadcast

HUDTCLEAR                        - Clear text for default player
HUDTCLEAR,PlayerName             - Clear for specific player
HUDTCLEAR,*                      - Clear for all

HUDFHUD,PlayerName: 1/0          - Toggle forearm HUD
HUDFHUD: on/off                  - Default player
HUDFHUD,*: off                   - All players
```

Console Commands:
```
sm_clear                         - Clear text messages
sm_clear PlayerName              - Clear for a player
sm_clear *                       - Clear all
sm_clear PlayerName SenderName   - Clear from specific sender

sm_forearmhud PlayerName 1       - Enable forearm HUD
sm_forearmhud * 0                - Disable for all

sm_setdefault PlayerName         - Set default player
sm_setdefault                    - Show current default

sm_listplayers                   - List connected players
sm_debug 1/0                     - Toggle debug output

screenmessage_clearlocal         - Clear own screen (bind as safety net)
```
