-- vrmod/combat/sh_weaponadapter.lua
-- Weapon-base adapter registry.
--
-- Each weapon base (ArcCW, ArcVR, M9K, TFA, MW...) registers an adapter that
-- knows how to read that base's melee hit/swing sounds and classify its weapons
-- (melee / pistol / gun). VRMod's melee system uses this to play a weapon's OWN
-- hit sound on impact (melees only; everything else falls back to generic impact
-- sounds), and the two-hand grip system uses the classification to mark pistols
-- and melees visual-only.
--
-- Adding a base later is one WA.Register call. Start: ArcCW.

vrmod = vrmod or {}
vrmod.weaponadapter = vrmod.weaponadapter or {}
local WA = vrmod.weaponadapter

-- Category constants (compared by reference, no per-call string churn)
WA.MELEE  = "melee"
WA.PISTOL = "pistol"
WA.GUN    = "gun"

local IsValid          = IsValid
local isstring         = isstring
local istable          = istable
local isfunction       = isfunction
local math_random      = math.random
local weapons_GetStored = weapons.GetStored

local adapters = {}
WA.adapters = adapters

-- def: { Match(wep, def), HitSound(wep, def, isFlesh), SwingSound(wep, def), Classify(wep, def) }
function WA.Register(name, def)
    def.name = name
    for i = 1, #adapters do
        if adapters[i].name == name then adapters[i] = def return end
    end
    adapters[#adapters + 1] = def
end

-- Pick a sound: accepts a string or an ArcCW-style sound table.
local function pick(s)
    if isstring(s) then
        if s ~= "" then return s end
    elseif istable(s) then
        local n = #s
        if n > 0 then return s[math_random(n)] end
    end
end
WA.PickSound = pick

-- Walk a weapon def's Base inheritance chain looking for a base class name.
-- Used by bases (e.g. TFA) that lack a single inherited identifier flag.
local function baseChainHas(def, target, depth)
    if not def or (depth or 0) > 8 then return false end
    local b = def.Base
    if not b then return false end
    if b == target then return true end
    return baseChainHas(weapons_GetStored(b), target, (depth or 0) + 1)
end
WA.BaseChainHas = baseChainHas

-- Per-class cache. A FRESH table is created on every file load, so a Lua
-- autorefresh drops all stale entries automatically (the previous approach
-- wrote onto ArcCW's def tables and survived reloads, pinning bad results).
-- Weak keys so unregistered weapon defs can be collected.
local cache = setmetatable({}, {__mode = "k"})
WA._cache = cache

function WA.ClearCache()
    for k in pairs(cache) do cache[k] = nil end
end

-- Resolve the adapter + stored def for a weapon. O(1) after first lookup.
function WA.Get(wep)
    if not IsValid(wep) then return end
    local def = isfunction(wep.GetClass) and weapons_GetStored(wep:GetClass()) or wep
    if not def then def = wep end
    local e = cache[def]
    if e then return e.a or nil, def end
    for i = 1, #adapters do
        local a = adapters[i]
        if a.Match(wep, def) then cache[def] = {a = a} return a, def end
    end
    cache[def] = {a = false}
    return nil, def
end

-- Cached classification (per class def).
local function classify(a, def, wep)
    local e = cache[def]
    if not e then e = {a = a or false} cache[def] = e end
    local c = e.cat
    if c == nil then
        c = (a and a.Classify and a.Classify(wep, def)) or WA.GUN
        e.cat = c
    end
    return c
end

function WA.Classify(wep)
    local a, def = WA.Get(wep)
    if not def then return WA.GUN end
    return classify(a, def, wep)
end

-- Weapon hit sound — melee-classified weapons only (guns/pistols use fallbacks).
function WA.HitSound(wep, isFlesh)
    local a, def = WA.Get(wep)
    if not a or not a.HitSound or classify(a, def, wep) ~= WA.MELEE then return end
    return pick(a.HitSound(wep, def, isFlesh))
end

-- Weapon swing/whoosh sound — melee-classified weapons only.
function WA.SwingSound(wep)
    local a, def = WA.Get(wep)
    if not a or not a.SwingSound or classify(a, def, wep) ~= WA.MELEE then return end
    return pick(a.SwingSound(wep, def))
end

-- Pistols and melees are visual-only for two-hand grip (second hand shows but
-- doesn't drive aim).
function WA.IsVisualOnly(wep)
    local c = WA.Classify(wep)
    return c == WA.MELEE or c == WA.PISTOL
end

----------------------------------------------------------------------
-- ArcCW
----------------------------------------------------------------------
do
    local MELEE_HOLD  = {melee = true, melee2 = true, knife = true, fist = true}
    local PISTOL_HOLD = {pistol = true, revolver = true, duel = true}

    -- Read fields off the live entity first: GMod doesn't flatten base-class
    -- fields into weapons.GetStored(), so .ArcCW (defined on arccw_base) is
    -- absent from a derived SWEP's def table but present on the instance via
    -- metatable inheritance. def is the fallback for non-entity callers.
    WA.Register("arccw", {
        Match = function(wep, def)
            return (wep and wep.ArcCW == true) or (def and def.ArcCW == true)
        end,
        -- sh_bash.lua: MeleeHitNPCSound (flesh/NPC) / MeleeHitSound (world).
        -- pick() handles the table form ArcCW allows.
        HitSound = function(wep, def, isFlesh)
            if isFlesh then return wep.MeleeHitNPCSound or def.MeleeHitNPCSound end
            return wep.MeleeHitSound or def.MeleeHitSound
        end,
        -- sh_bash.lua: MeleeSwingSound.
        SwingSound = function(wep, def)
            return wep.MeleeSwingSound or def.MeleeSwingSound
        end,
        -- HoldtypeActive is stable per class (unlike live GetHoldType, which
        -- flips during sights/sprint). Melee bases set it to melee/knife.
        Classify = function(wep, def)
            local ht = wep.HoldtypeActive or def.HoldtypeActive
            if MELEE_HOLD[ht]  then return WA.MELEE  end
            if PISTOL_HOLD[ht] then return WA.PISTOL end
            return WA.GUN
        end,
    })
end

----------------------------------------------------------------------
-- TFA
----------------------------------------------------------------------
do
    local MELEE_HOLD  = {melee = true, melee2 = true, knife = true, fist = true}
    local PISTOL_HOLD = {pistol = true, revolver = true, duel = true}

    -- Bash/hit sounds live on tfa_bash_base (Secondary.Bash*), swing for
    -- dedicated melee weapons is per-attack (Primary.Attacks[i].snd). All TFA
    -- weapons root at tfa_gun_base, so detect via the Base chain.
    WA.Register("tfa", {
        Match = function(wep, def)
            if wep and wep.IsTFAWeapon then return true end
            return baseChainHas(def, "tfa_gun_base")
        end,
        -- Secondary.BashHitSound_Flesh / BashHitSound (tfa_bash_base, inherited).
        HitSound = function(wep, _, isFlesh)
            local s = wep.Secondary
            if not s then return end
            return isFlesh and s.BashHitSound_Flesh or s.BashHitSound
        end,
        -- Prefer the melee weapon's per-attack swing; fall back to the bash swing.
        SwingSound = function(wep)
            local atk = wep.Primary and wep.Primary.Attacks
            if istable(atk) and atk[1] then
                local snd = atk[1].snd
                if snd then return snd end
            end
            return wep.Secondary and wep.Secondary.BashSound
        end,
        -- HoldType is the authored holdtype (stable); DefaultHoldType is its
        -- runtime mirror.
        Classify = function(wep)
            local ht = wep.HoldType or wep.DefaultHoldType
            if MELEE_HOLD[ht]  then return WA.MELEE  end
            if PISTOL_HOLD[ht] then return WA.PISTOL end
            return WA.GUN
        end,
    })
end

----------------------------------------------------------------------
-- Debug
----------------------------------------------------------------------
local function fmt(v)
    if v == nil then return "nil" end
    if istable(v) then return ("table[%d]"):format(#v) end
    return tostring(v)
end

-- Dump the full decision chain for a weapon on the current realm.
function WA.Debug(wep)
    local realm = SERVER and "SV" or "CL"
    if not IsValid(wep) then
        print(("[WA:%s] no valid weapon"):format(realm))
        return
    end
    local def = isfunction(wep.GetClass) and weapons_GetStored(wep:GetClass()) or nil
    local a = WA.Get(wep)
    print(("[WA:%s] ===== %s ====="):format(realm, wep:GetClass()))
    print(("  adapters registered : %d"):format(#adapters))
    print(("  wep.ArcCW=%s   def.ArcCW=%s"):format(fmt(wep.ArcCW), def and fmt(def.ArcCW) or "<no def>"))
    print(("  wep.HoldtypeActive=%s   live GetHoldType=%s")
        :format(fmt(wep.HoldtypeActive), wep.GetHoldType and fmt(wep:GetHoldType()) or "n/a"))
    print(("  matched adapter     : %s"):format(a and a.name or "NONE"))
    print(("  classify            : %s   (visualOnly=%s)"):format(WA.Classify(wep), tostring(WA.IsVisualOnly(wep))))
    print(("  raw fields          : HitSound=%s  HitNPCSound=%s  SwingSound=%s")
        :format(fmt(wep.MeleeHitSound), fmt(wep.MeleeHitNPCSound), fmt(wep.MeleeSwingSound)))
    print(("  resolved HitSound   : world=%s"):format(fmt(WA.HitSound(wep, false))))
    print(("  resolved HitSound   : flesh=%s"):format(fmt(WA.HitSound(wep, true))))
    print(("  resolved SwingSound : %s"):format(fmt(WA.SwingSound(wep))))
end

if SERVER then
    util.AddNetworkString("vrmod_wa_debug")
    net.Receive("vrmod_wa_debug", function(_, ply)
        if not IsValid(ply) then return end
        WA.Debug(ply:GetActiveWeapon())
    end)

    -- Server console: vrmod_wa <player name fragment>, or first player if omitted
    concommand.Add("vrmod_wa", function(_, _, args)
        local target
        local frag = args[1] and string.lower(args[1])
        for _, p in ipairs(player.GetAll()) do
            if not frag or string.find(string.lower(p:Nick()), frag, 1, true) then target = p break end
        end
        WA.Debug(IsValid(target) and target:GetActiveWeapon() or nil)
    end)
else
    -- Client: dumps client-side chain, then asks the server to dump its own
    -- (server output appears in the server console).
    concommand.Add("vrmod_wa", function()
        WA.Debug(LocalPlayer():GetActiveWeapon())
        net.Start("vrmod_wa_debug")
        net.SendToServer()
        print("[WA:CL] requested server-side dump (see server console)")
    end)

    concommand.Add("vrmod_wa_clearcache", function()
        WA.ClearCache()
        print("[WA:CL] cache cleared")
    end)
end