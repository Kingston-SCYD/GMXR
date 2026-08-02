----------------------------------------
-- VRMod Melee System (Trace-Based)
----------------------------------------
local cl_vrmod_melee = CreateClientConVar("cl_vrmod_melee", "1", true, FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE)
local sv_vrmod_melee = CreateConVar("sv_vrmod_melee", "1", FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE, "Enable or disable VRMod melee system")
local cv_meleeVelThreshold = CreateConVar("vrmod_melee_velthreshold", "1.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local cv_meleeDamage = CreateConVar("vrmod_melee_damage", "3", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local cv_meleeDelay = CreateConVar("vrmod_melee_delay", "0.45", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local cv_meleeSpeedScale = CreateConVar("vrmod_melee_speedscale", "0.05", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Multiplier for relative speed in melee damage calculation")
local cl_vrmod_kick = CreateClientConVar("cl_vrmod_kick", "1", true, FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE)
local sv_vrmod_kick = CreateConVar("sv_vrmod_kick", "1", FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE, "Enable or disable VRMod FBT kicking")
local cv_kickDamage = CreateConVar("vrmod_kick_damage", "8", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Flat damage dealt by FBT kicks (ignores weapon)")
local cv_kickVelThreshold = CreateConVar("vrmod_kick_velthreshold", "2.0", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Foot speed threshold to trigger a kick")
local cl_vrmod_headbutt = CreateClientConVar("cl_vrmod_headbutt", "1", true, FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE)
local sv_vrmod_headbutt = CreateConVar("sv_vrmod_headbutt", "1", FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE, "Enable or disable VRMod headbutting")
local cv_headbuttDamage = CreateConVar("vrmod_headbutt_damage", "5", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Flat damage dealt by headbutts (ignores weapon)")
local cv_headbuttVelThreshold = CreateConVar("vrmod_headbutt_velthreshold", "2.5", FCVAR_REPLICATED + FCVAR_ARCHIVE, "HMD speed threshold to trigger a headbutt")

local impactSounds = {
    fist = {"physics/body/body_medium_impact_hard1.wav", "physics/body/body_medium_impact_hard2.wav", "physics/body/body_medium_impact_hard3.wav", "physics/body/body_medium_impact_soft1.wav"},
    blunt = {"melee/rifle_swing_hit_world.wav"},
    stunstick = {"weapons/stunstick/stunstick_impact1.wav", "weapons/stunstick/stunstick_impact2.wav", "weapons/stunstick/stunstick_fleshhit1.wav", "weapons/stunstick/stunstick_fleshhit2.wav"},
    sharp = {"physics/flesh/flesh_squishy_impact_hard1.wav", "physics/flesh/flesh_squishy_impact_hard2.wav", "weapons/knife/knife_hit1.wav", "weapons/knife/knife_hit2.wav"},
    piercing = {"physics/flesh/flesh_bloody_impact_hard1.wav", "physics/flesh/flesh_bloody_impact_hard2.wav", "weapons/crossbow/hitbod1.wav", "weapons/crossbow/hitbod2.wav"},
    heavy = {"physics/metal/metal_barrel_impact_hard1.wav", "physics/metal/metal_barrel_impact_hard2.wav", "physics/concrete/concrete_impact_hard1.wav", "physics/concrete/concrete_impact_hard2.wav"},
    energy = {"weapons/physcannon/energy_bounce1.wav", "weapons/physcannon/energy_bounce2.wav", "weapons/physcannon/energy_sing_flyby1.wav", "weapons/physcannon/energy_sing_flyby2.wav"},
    explosive = {"weapons/explode3.wav", "weapons/explode4.wav", "ambient/explosions/explode_1.wav", "ambient/explosions/explode_2.wav"}
}

local impactMultipliers = {
    fist      = {1.0,  DMG_CLUB},
    blunt     = {1.25, DMG_CLUB},
    stunstick = {1.1,  bit.bor(DMG_CLUB, DMG_SHOCK)},
    sharp     = {1.5,  DMG_SLASH},
    piercing  = {1.3,  DMG_BULLET},
    heavy     = {2.0,  bit.bor(DMG_CLUB, DMG_CRUSH)},
    energy    = {1.4,  bit.bor(DMG_ENERGYBEAM, DMG_SHOCK)},
    explosive = {2.5,  bit.bor(DMG_BLAST, DMG_CLUB)},
}

local matDecals = {
    [MAT_METAL] = "Impact.Metal", [MAT_WOOD] = "Impact.Wood", [MAT_FLESH] = "Impact.Flesh",
    [MAT_DIRT] = "Impact.Dust", [MAT_SAND] = "Impact.Dust", [MAT_GLASS] = "GlassBreak",
}

local knownWeaponHitSounds = {
    weapon_crowbar       = {world = {"Weapon_Crowbar.Melee_Hit"}, flesh = {"Weapon_Crowbar.Melee_HitNPC"}},
    arcticvr_hl2_crowbar = {world = {"Weapon_Crowbar.Melee_Hit"}, flesh = {"Weapon_Crowbar.Melee_HitNPC"}},
}

local holdTypeImpact = {melee = "blunt", melee2 = "blunt", knife = "sharp", slam = "heavy"}
local meleeHoldTypes = {melee = true, melee2 = true, knife = true} -- set for isMeleeWep check

local impactTypeToID = {fist = 0, blunt = 1, stunstick = 2, sharp = 3, piercing = 4, heavy = 5, energy = 6, explosive = 7}
local idToImpactType = {}
for k, v in pairs(impactTypeToID) do idToImpactType[v] = k end

-- Kick trace constants (no weapon — feet are always the same shape)
local KICK_RADIUS = 3
local KICK_REACH = 14
local HEADBUTT_RADIUS = 2
local HEADBUTT_REACH = 8

-- Shared sound resolution: wepDef fields → knownWeaponHitSounds → nil
local function ResolveWepHitSound(wep, wepDef, wepClass, isFlesh)
    -- Weapon-base adapter (melee-classified weapons only); falls through otherwise
    local s = vrmod.weaponadapter and vrmod.weaponadapter.HitSound(wep, isFlesh)
    if s then return s end
    if wepDef then
        -- ArcVR MeleeHitSound / MeleeStrikeSound
        local s = isFlesh and wepDef.MeleeStrikeSound or wepDef.MeleeHitSound
        if isstring(s) and s ~= "" then return s end
        -- Common field names
        s = isFlesh
            and (wepDef.HitSoundBody or wepDef.HitBodySound or wepDef.HitFleshSound or wepDef.MeleeHitNPCSound)
            or (wepDef.HitSoundWorld or wepDef.HitSound or wepDef.MeleeHitWorldSound)
        if isstring(s) and s ~= "" then return s end
        -- Sound table pools
        local pool = isFlesh and (wepDef.PrimaryHitBodSounds or wepDef.PrimaryHitFleshSounds) or wepDef.PrimaryHitSounds or wepDef.HitSounds
        if istable(pool) and #pool > 0 then return pool[math.random(#pool)] end
    end
    -- Hardcoded fallback
    local known = knownWeaponHitSounds[wepClass]
    if known then
        local pool = isFlesh and known.flesh or known.world
        if pool then return Sound(pool[math.random(#pool)]) end
    end
end

-- CLIENTSIDE --------------------------
if CLIENT then
    local NextMeleeTime = 0
    local vec_zero = Vector(0, 0, 0)
    local ang_zero = Angle(0, 0, 0)
    local PreLeft = {radius = 0, reach = 0, mins = nil, maxs = nil, ang = nil, dir = nil, useWeapon = false, weapon = nil, isMelee = false, pos = nil}
    local PreRight = {radius = 0, reach = 0, mins = nil, maxs = nil, ang = nil, dir = nil, useWeapon = false, weapon = nil, isMelee = false, pos = nil}

    local function SendMeleeAttack(src, dir, radius, reach, mins, maxs, angles, impactType, hand)
        net.Start("VRMod_MeleeAttack")
        net.WriteVector(src)
        net.WriteVector(dir)
        net.WriteFloat(radius)
        net.WriteFloat(reach)
        net.WriteVector(mins or vec_zero)
        net.WriteVector(maxs or vec_zero)
        net.WriteAngle(angles or ang_zero)
        net.WriteUInt(impactTypeToID[impactType] or 0, 3)
        net.WriteBool(hand == "right")
        net.SendToServer()
    end

    local function TryMelee(ply, params, hand, curtime)
        if NextMeleeTime > curtime then return end
        local useWeapon = params.useWeapon and IsValid(params.weapon) and vrmod.utils.IsValidWep(params.weapon)
        local isMelee = params.isMelee
        local src = params.pos
        if (useWeapon or isMelee) then src = vrmod.utils.AdjustCollisionsBox(src, params.ang, isMelee) end
        local dir = params.dir
        local tr = vrmod.utils.TraceBoxOrSphere({
            start = src, endpos = src + dir * params.reach,
            radius = params.radius, mins = params.mins, maxs = params.maxs,
            filter = function(ent) return vrmod.utils.MeleeFilter(ent, ply, hand) end,
            mask = MASK_SHOT
        })
        if not tr.Hit then return end
        if IsValid(tr.Entity) and tr.Entity == g_VR.vehicle.current then return end
        NextMeleeTime = curtime + cv_meleeDelay:GetFloat()

        -- Swing sound (weapon hand only)
        if useWeapon then
            local swingSound = vrmod.weaponadapter and vrmod.weaponadapter.SwingSound(params.weapon)
            if not swingSound then
                local wepClass = params.weapon:GetClass()
                local wepDef = weapons.GetStored(wepClass)
                if wepDef and isstring(wepDef.MeleeStrikeSound) and wepDef.MeleeStrikeSound ~= "" then
                    swingSound = wepDef.MeleeStrikeSound
                elseif wepClass == "weapon_crowbar" or wepClass == "arcticvr_hl2_crowbar" then
                    swingSound = "Weapon_Crowbar.Single"
                end
            end
            hook.Run("VRMod_MeleeSwing", {Player = ply, Weapon = params.weapon, Hand = hand, Position = params.pos}, function(s) swingSound = s end)
            if swingSound then sound.Play(swingSound, params.pos, 75, 100, 1) end
        end

        -- Impact type from holdtype
        local impactType = "fist"
        if useWeapon then
            local ht = isfunction(params.weapon.GetHoldType) and params.weapon:GetHoldType() or ""
            impactType = holdTypeImpact[ht] or "blunt"
        end
        SendMeleeAttack(tr.HitPos, dir, params.radius, params.reach, params.mins, params.maxs, params.ang, impactType, hand)
    end

    local function SendKickAttack(src, dir, isRightFoot)
        net.Start("VRMod_KickAttack")
        net.WriteVector(src)
        net.WriteVector(dir)
        net.WriteBool(isRightFoot)
        net.SendToServer()
    end

    local function SendHeadbuttAttack(src, dir)
        net.Start("VRMod_HeadbuttAttack")
        net.WriteVector(src)
        net.WriteVector(dir)
        net.SendToServer()
    end

    local bodyFilterPly
    local function bodyTraceFilter(ent) return ent ~= bodyFilterPly and ent:IsValid() end
    local clKickTrace = {start = nil, endpos = nil, radius = KICK_RADIUS, filter = bodyTraceFilter, mask = MASK_SHOT}
    local clHeadbuttTrace = {start = nil, endpos = nil, radius = HEADBUTT_RADIUS, filter = bodyTraceFilter, mask = MASK_SHOT}

    hook.Add("VRMod_Tracking", "VRMeleeTrace", function()
        local meleeOn = cl_vrmod_melee:GetBool()
        local kickOn = cl_vrmod_kick:GetBool() and g_VR.sixPoints
        local headbuttOn = cl_vrmod_headbutt:GetBool()
        if not meleeOn and not kickOn and not headbuttOn then return end
        local ply = LocalPlayer()
        if not IsValid(ply) or not ply:Alive() or not vrmod.IsPlayerInVR(ply) then return end
        local curtime = CurTime()
        if NextMeleeTime > curtime then return end

        -- Hand melee
        if meleeOn then
            local leftVel = vrmod.GetLeftHandVelocityRelative() or vec_zero
            local rightVel = vrmod.GetRightHandVelocityRelative() or vec_zero
            local threshold = cv_meleeVelThreshold:GetFloat() * 50
            local threshSqr = threshold * threshold
            local leftFast = leftVel:LengthSqr() >= threshSqr
            local rightFast = rightVel:LengthSqr() >= threshSqr

            if leftFast or rightFast then
                local weaponLeft = false
                if leftFast and not g_VR.cooldownLeft then
                    local ang = vrmod.GetLeftHandAng(ply)
                    local fwd = ang:Forward()
                    local leftWep = weaponLeft and ply:GetActiveWeapon() or nil
                    local useWeapon = weaponLeft and IsValid(leftWep) and vrmod.utils.IsValidWep(leftWep)
                    local lR, lRe, lMn, lMx, lAng, lIsMelee = vrmod.utils.GetWeaponMeleeParams(useWeapon and leftWep or nil, ply, "left")
                    local L = PreLeft
                    L.radius = lR; L.reach = lRe; L.mins = lMn; L.maxs = lMx
                    L.ang = lAng; L.dir = fwd; L.useWeapon = useWeapon
                    L.weapon = leftWep; L.isMelee = lIsMelee; L.pos = vrmod.GetLeftHandPos(ply) + fwd * 5
                    TryMelee(ply, L, "left", curtime)
                end
                if rightFast and not g_VR.cooldownRight then
                    local ang = vrmod.GetRightHandAng(ply)
                    local fwd = ang:Forward()
                    local rightWep = not weaponLeft and ply:GetActiveWeapon() or nil
                    local useWeapon = not weaponLeft and IsValid(rightWep) and vrmod.utils.IsValidWep(rightWep)
                    local rR, rRe, rMn, rMx, rAng, rIsMelee = vrmod.utils.GetWeaponMeleeParams(useWeapon and rightWep or nil, ply, "right")
                    local R = PreRight
                    R.radius = rR; R.reach = rRe; R.mins = rMn; R.maxs = rMx
                    R.ang = rAng; R.dir = fwd; R.useWeapon = useWeapon
                    R.weapon = rightWep; R.isMelee = rIsMelee; R.pos = vrmod.GetRightHandPos(ply) + fwd * 5
                    TryMelee(ply, R, "right", curtime)
                end
            end
        end
-- FBT kick (requires calibrated FBT, this is mainly for people using standable in the background like me)
        local fbtA = g_VR.fbtActive
        if kickOn and fbtA and fbtA[ply:SteamID()] and NextMeleeTime <= curtime then
            local kickThresh = cv_kickVelThreshold:GetFloat() * 50
            local kickThreshSqr = kickThresh * kickThresh
            local lf = vrmod.GetLeftFootVelocityRelative()
            local rf = vrmod.GetRightFootVelocityRelative()
            local lfFast = lf:LengthSqr() >= kickThreshSqr
            local rfFast = rf:LengthSqr() >= kickThreshSqr
            if lfFast or rfFast then
                -- Pick the faster foot
                local isRight = rfFast and (not lfFast or rf:LengthSqr() > lf:LengthSqr())
                local pos = isRight and vrmod.GetRightFootPos(ply) or vrmod.GetLeftFootPos(ply)
                local ang = isRight and vrmod.GetRightFootAng(ply) or vrmod.GetLeftFootAng(ply)
                local dir = ang:Forward()
                bodyFilterPly = ply
                clKickTrace.start = pos
                clKickTrace.endpos = pos + dir * KICK_REACH
                local tr = vrmod.utils.TraceBoxOrSphere(clKickTrace)
                if tr.Hit and not (IsValid(tr.Entity) and tr.Entity == g_VR.vehicle.current) then
                    NextMeleeTime = curtime + cv_meleeDelay:GetFloat()
                    SendKickAttack(tr.HitPos, dir, isRight)
                end
            end
        end

        -- Headbutt
        if headbuttOn and NextMeleeTime <= curtime then
            local hmdVel = vrmod.GetHMDVelocity()
            local hbThresh = cv_headbuttVelThreshold:GetFloat() * 50
            if hmdVel:LengthSqr() >= hbThresh * hbThresh then
                local pos = vrmod.GetHMDPos(ply)
                local dir = vrmod.GetHMDAng(ply):Forward()
                bodyFilterPly = ply
                clHeadbuttTrace.start = pos
                clHeadbuttTrace.endpos = pos + dir * HEADBUTT_REACH
                local tr = vrmod.utils.TraceBoxOrSphere(clHeadbuttTrace)
                if tr.Hit and not (IsValid(tr.Entity) and tr.Entity == g_VR.vehicle.current) then
                    NextMeleeTime = curtime + cv_meleeDelay:GetFloat()
                    SendHeadbuttAttack(tr.HitPos, dir)
                end
            end
        end
    end)
end

-- SERVERSIDE --------------------------
if SERVER then
    util.AddNetworkString("VRMod_MeleeAttack")
    util.AddNetworkString("VRMod_KickAttack")
    util.AddNetworkString("VRMod_HeadbuttAttack")

    local filterPly, filterHand
    local function traceFilter(ent) return vrmod.utils.MeleeFilter(ent, filterPly, filterHand) end

    -- Pre-allocated tables — fields overwritten each call
    local svTrace = {start = nil, endpos = nil, radius = 0, mins = nil, max = nil, filter = traceFilter, mask = MASK_SHOT}
    local hitData = {
        Attacker = nil, HitEntity = nil, HitPos = nil, Damage = 0,
        ImpactType = "", Hand = "", RelativeSpeed = 0, MaterialType = 0,
        DecalName = "", DamageMultiplier = 0, DamageType = 0, Reach = 0, Radius = 0,
        -- Hook-writable overrides (read back after hook.Run)
        Sound = nil, DamageExplicit = false,
    }

    net.Receive("VRMod_MeleeAttack", function(_, ply)
        if not sv_vrmod_melee:GetBool() then return end
        if not IsValid(ply) or not ply:Alive() then return end
        local src = net.ReadVector()
        local dir = net.ReadVector()
        local radius = net.ReadFloat()
        local reach = net.ReadFloat()
        local mins = net.ReadVector()
        local maxs = net.ReadVector()
        local angles = net.ReadAngle()
        local impactType = idToImpactType[net.ReadUInt(3)] or "fist"
        local isRight = net.ReadBool()
        local hand = isRight and "right" or "left"

        local vel = isRight and vrmod.GetRightHandVelocityRelative(ply) or vrmod.GetLeftHandVelocityRelative(ply)
        local swingSpeed = vel and vel:Length() or 0

        filterPly = ply; filterHand = hand
        svTrace.start = src; svTrace.endpos = src + dir * reach
        svTrace.radius = radius; svTrace.mins = mins; svTrace.max = maxs

        local tr = vrmod.utils.TraceBoxOrSphere(svTrace)
        if not tr.Hit then return end

        local matType = tr.MatType
        local decalName = matDecals[matType] or "Impact.Concrete"

        -- Damage base
        local base = cv_meleeDamage:GetFloat()
        local weaponInHand = isRight ~= (false)
        local activeWep = weaponInHand and ply:GetActiveWeapon() or nil
        local wepClass, wepDef
        if IsValid(activeWep) then
            wepClass = activeWep:GetClass()
            wepDef = weapons.GetStored(wepClass)
            local ht = isfunction(activeWep.GetHoldType) and activeWep:GetHoldType() or ""
            local isMeleeWep = activeWep.NotAGun or (wepDef and wepDef.NotAGun)
                or (activeWep.MeleeDamageType and bit.band(activeWep.MeleeDamageType, DMG_SLASH) ~= 0)
                or meleeHoldTypes[ht]
            local swepDmg
            local pri = activeWep.Primary
            if pri and isnumber(pri.Damage) and pri.Damage > 0 then
                swepDmg = pri.Damage
            end
            if not swepDmg and wepDef then
                local mn, mx = wepDef.MinDamage or wepDef.DamageMin, wepDef.MaxDamage or wepDef.DamageMax
                if isnumber(mn) and isnumber(mx) and mn > 0 then swepDmg = math.random(mn, mx) end
            end
            if swepDmg then
                base = isMeleeWep and swepDmg or (base + swepDmg * 0.1)
            end
        end

        local relativeSpeed = math.max(0, swingSpeed)
        local impactInfo = impactMultipliers[impactType] or impactMultipliers.fist
        local speedFactor = math.min(5.0, 1.0 + relativeSpeed * cv_meleeSpeedScale:GetFloat())
        local dmgAmt = base * speedFactor * impactInfo[1]

        -- Populate hitData (pre-allocated, fields overwritten)
        local H = hitData
        H.Attacker = ply; H.HitEntity = tr.Entity; H.HitPos = tr.HitPos
        H.Damage = dmgAmt; H.ImpactType = impactType; H.Hand = hand
        H.RelativeSpeed = relativeSpeed; H.MaterialType = matType
        H.DecalName = decalName; H.DamageMultiplier = impactInfo[1]
        H.DamageType = impactInfo[2]; H.Reach = reach; H.Radius = radius
        H.Sound = nil; H.DamageExplicit = false

        hook.Run("VRMod_MeleeHit", H, function(soundPath, newDecal, newDamage, newMult, newDmgType, _, _, newImpactType)
            if not weaponInHand then return end
            if soundPath then H.Sound = soundPath end
            if newDecal then H.DecalName = newDecal end
            if newDamage then H.Damage = newDamage; H.DamageExplicit = true end
            if newMult then H.DamageMultiplier = newMult end
            if newDmgType then H.DamageType = newDmgType end
            if newImpactType then H.ImpactType = newImpactType end
        end)

        -- Re-resolve if hook changed impactType but cleared damageType
        if not H.DamageType and H.ImpactType then
            local info = impactMultipliers[H.ImpactType] or impactMultipliers.fist
            H.DamageMultiplier = H.DamageMultiplier or info[1]
            H.DamageType = info[2]
        end

        if not H.DamageExplicit then H.Damage = base * speedFactor * (H.DamageMultiplier or 1.0) end

        -- Glass / breakable surf → add DMG_BLAST
        if matType == MAT_GLASS or (IsValid(tr.Entity) and tr.Entity:GetClass() == "func_breakable_surf") then
            H.DamageType = bit.bor(H.DamageType, DMG_BLAST)
        end

        local dmgInfo = DamageInfo()
        dmgInfo:SetAttacker(ply)
        dmgInfo:SetInflictor(ply)
        dmgInfo:SetDamage(H.Damage)
        dmgInfo:SetDamageType(H.DamageType)
        dmgInfo:SetDamagePosition(tr.HitPos)
        tr.Entity:TakeDamageInfo(dmgInfo)
        local phys = tr.Entity:GetPhysicsObject()
        if IsValid(phys) then phys:ApplyForceCenter(dir * H.Damage * 10) end

        -- Sound
        local snd = H.Sound
        if not snd and IsValid(activeWep) then
            local isFlesh = IsValid(tr.Entity) and (tr.Entity:IsPlayer() or tr.Entity:IsNPC() or tr.Entity:IsNextBot())
            snd = ResolveWepHitSound(activeWep, wepDef, wepClass, isFlesh)
        end
        if not snd then
            local list = impactSounds[H.ImpactType] or impactSounds.fist
            snd = list[math.random(#list)]
        end

        local hitPos = tr.HitPos
        local decalOfs = tr.HitNormal * 2
        sound.Play(snd, hitPos, 75, 100, 1)
        util.Decal(H.DecalName, hitPos + decalOfs, hitPos - decalOfs)
        if IsValid(tr.Entity) and tr.Entity ~= game.GetWorld() then
            util.Decal(H.DecalName, hitPos + decalOfs, hitPos - decalOfs, tr.Entity)
        end

        if vrmod.logger.IsDebug and vrmod.logger.IsDebug() then
            vrmod.logger.Debug("%s smashed %s for %.1f dmg (impact:%s mult:%.2f type:%d speed:%.1f snd:%s)",
                ply:Nick(), IsValid(tr.Entity) and tr.Entity:GetClass() or "World",
                H.Damage, H.ImpactType, H.DamageMultiplier, H.DamageType, swingSpeed, snd)
        end
    end)

    -- Kick & headbutt handlers — flat damage, no weapon scaling
    local svBodyFilter
    local function svBodyTraceFilter(ent) return ent ~= svBodyFilter and ent:IsValid() end
    local svKickTrace = {start = nil, endpos = nil, radius = KICK_RADIUS, filter = svBodyTraceFilter, mask = MASK_SHOT}
    local svHeadbuttTrace = {start = nil, endpos = nil, radius = HEADBUTT_RADIUS, filter = svBodyTraceFilter, mask = MASK_SHOT}

    net.Receive("VRMod_KickAttack", function(_, ply)
        if not sv_vrmod_kick:GetBool() then return end
        if not IsValid(ply) or not ply:Alive() then return end
        local src = net.ReadVector()
        local dir = net.ReadVector()
        local isRight = net.ReadBool()

        -- Server-side validation trace
        local footPos = isRight and vrmod.GetRightFootPos(ply) or vrmod.GetLeftFootPos(ply)
        local footAng = isRight and vrmod.GetRightFootAng(ply) or vrmod.GetLeftFootAng(ply)
        local svDir = footAng:Forward()
        svBodyFilter = ply
        svKickTrace.start = footPos
        svKickTrace.endpos = footPos + svDir * KICK_REACH

        local tr = vrmod.utils.TraceBoxOrSphere(svKickTrace)
        if not tr.Hit then return end

        local dmg = cv_kickDamage:GetFloat()
        local matType = tr.MatType
        local decalName = matDecals[matType] or "Impact.Concrete"
        local dmgType = DMG_CLUB

        if matType == MAT_GLASS or (IsValid(tr.Entity) and tr.Entity:GetClass() == "func_breakable_surf") then
            dmgType = bit.bor(dmgType, DMG_BLAST)
        end

        local dmgInfo = DamageInfo()
        dmgInfo:SetAttacker(ply)
        dmgInfo:SetInflictor(ply)
        dmgInfo:SetDamage(dmg)
        dmgInfo:SetDamageType(dmgType)
        dmgInfo:SetDamagePosition(tr.HitPos)
        tr.Entity:TakeDamageInfo(dmgInfo)
        local phys = tr.Entity:GetPhysicsObject()
        if IsValid(phys) then phys:ApplyForceCenter(svDir * dmg * 15) end

        local list = impactSounds.fist
        local snd = list[math.random(#list)]
        local hitPos = tr.HitPos
        local decalOfs = tr.HitNormal * 2
        sound.Play(snd, hitPos, 80, 90, 1)
        util.Decal(decalName, hitPos + decalOfs, hitPos - decalOfs)
        if IsValid(tr.Entity) and tr.Entity ~= game.GetWorld() then
            util.Decal(decalName, hitPos + decalOfs, hitPos - decalOfs, tr.Entity)
        end

        if vrmod.logger.IsDebug and vrmod.logger.IsDebug() then
            vrmod.logger.Debug("%s kicked %s for %.1f dmg (foot:%s)",
                ply:Nick(), IsValid(tr.Entity) and tr.Entity:GetClass() or "World",
                dmg, isRight and "right" or "left")
        end
    end)

    net.Receive("VRMod_HeadbuttAttack", function(_, ply)
        if not sv_vrmod_headbutt:GetBool() then return end
        if not IsValid(ply) or not ply:Alive() then return end
        local src = net.ReadVector()
        local dir = net.ReadVector()

        local hmdPos = vrmod.GetHMDPos(ply)
        local hmdAng = vrmod.GetHMDAng(ply)
        local svDir = hmdAng:Forward()
        svBodyFilter = ply
        svHeadbuttTrace.start = hmdPos
        svHeadbuttTrace.endpos = hmdPos + svDir * HEADBUTT_REACH

        local tr = vrmod.utils.TraceBoxOrSphere(svHeadbuttTrace)
        if not tr.Hit then return end

        local dmg = cv_headbuttDamage:GetFloat()
        local matType = tr.MatType
        local decalName = matDecals[matType] or "Impact.Concrete"
        local dmgType = DMG_CLUB

        if matType == MAT_GLASS or (IsValid(tr.Entity) and tr.Entity:GetClass() == "func_breakable_surf") then
            dmgType = bit.bor(dmgType, DMG_BLAST)
        end

        local dmgInfo = DamageInfo()
        dmgInfo:SetAttacker(ply)
        dmgInfo:SetInflictor(ply)
        dmgInfo:SetDamage(dmg)
        dmgInfo:SetDamageType(dmgType)
        dmgInfo:SetDamagePosition(tr.HitPos)
        tr.Entity:TakeDamageInfo(dmgInfo)
        local phys = tr.Entity:GetPhysicsObject()
        if IsValid(phys) then phys:ApplyForceCenter(svDir * dmg * 8) end

        local list = impactSounds.fist
        local snd = list[math.random(#list)]
        local hitPos = tr.HitPos
        local decalOfs = tr.HitNormal * 2
        sound.Play(snd, hitPos, 75, 110, 1)
        util.Decal(decalName, hitPos + decalOfs, hitPos - decalOfs)
        if IsValid(tr.Entity) and tr.Entity ~= game.GetWorld() then
            util.Decal(decalName, hitPos + decalOfs, hitPos - decalOfs, tr.Entity)
        end

        if vrmod.logger.IsDebug and vrmod.logger.IsDebug() then
            vrmod.logger.Debug("%s headbutted %s for %.1f dmg",
                ply:Nick(), IsValid(tr.Entity) and tr.Entity:GetClass() or "World", dmg)
        end
    end)
end