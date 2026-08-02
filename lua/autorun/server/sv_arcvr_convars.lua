-- sv_arcvr_convars.lua
-- Registers ONLY cvars that ArcVR doesn't create itself
-- ArcVR handles: arcticvr_flickreload, arcticvr_flickreload_dw, arcticvr_net_magtimertime,
--   arcticvr_defaultammo_normalize, arcticvr_shootsys, arcticvr_physical_bullets, arcticvr_grenade_pin_enable

if not SERVER then return end

-- Damage multipliers (not in stock ArcVR)
CreateConVar("arcticvr_dmgmul_assault_rifle", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Damage multiplier: assault rifles")
CreateConVar("arcticvr_dmgmul_smg", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Damage multiplier: SMGs")
CreateConVar("arcticvr_dmgmul_shotgun", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Damage multiplier: shotguns")
CreateConVar("arcticvr_dmgmul_pistol", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Damage multiplier: pistols")
CreateConVar("arcticvr_dmgmul_sniper_rifle", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Damage multiplier: sniper rifles")
CreateConVar("arcticvr_dmgmul_melee", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Damage multiplier: melee")
CreateConVar("arcticvr_dmgmul_rocket_launcher", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Damage multiplier: rocket launchers")
