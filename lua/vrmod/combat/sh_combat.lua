----------------------------------------
-- VRMod Melee System (Trace-Based)
----------------------------------------
local sv_vrmod_melee = CreateConVar("sv_vrmod_melee", "1", FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE, "Enable or disable VRMod melee system")
local cv_meleeVelThreshold = CreateConVar("vrmod_melee_velthreshold", "2.4", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local cv_meleeDamage = CreateConVar("vrmod_melee_damage", "4", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local cv_meleeDelay = CreateConVar("vrmod_melee_delay", "0.01", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local cv_meleeSpeedScale = CreateConVar("vrmod_melee_speedscale", "0.01", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Multiplier for relative speed in melee damage calculation")
local sv_vrmod_kick = CreateConVar("sv_vrmod_kick", "1", FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE, "Enable or disable VRMod FBT kicking")
local cv_kickDamage = CreateConVar("vrmod_kick_damage", "14", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Flat damage dealt by FBT kicks (ignores weapon)")
local cv_kickVelThreshold = CreateConVar("vrmod_kick_velthreshold", "3.9", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Foot speed threshold to trigger a kick")
local sv_vrmod_headbutt = CreateConVar("sv_vrmod_headbutt", "1", FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE, "Enable or disable VRMod headbutting")
local cv_headbuttDamage = CreateConVar("vrmod_headbutt_damage", "5", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Flat damage dealt by headbutts (ignores weapon)")
local cv_headbuttVelThreshold = CreateConVar("vrmod_headbutt_velthreshold", "2.5", FCVAR_REPLICATED + FCVAR_ARCHIVE, "HMD speed threshold to trigger a headbutt")

local util_TraceHull = util.TraceHull

-- Feet and head are always the same shape, no weapon involved
local KICK_RADIUS, KICK_REACH = 3, 14
local HEADBUTT_RADIUS, HEADBUTT_REACH = 2, 8

local math_random = math.random

local impactNames = {[0] = "fist", "blunt", "stunstick", "sharp", "piercing", "heavy", "energy", "explosive"}

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

-- What the C++ crowbar plays on any hit (Single is its miss sound). Same
-- script as desktop, so sound.Add replacements of it apply in VR too.
local CROWBAR_HIT = "Weapon_Crowbar.Melee_Hit"
local knownHit = {weapon_crowbar = CROWBAR_HIT, arcticvr_hl2_crowbar = CROWBAR_HIT, weapon_stunstick = "Weapon_StunStick.Melee_Hit"}

-- Swing push multiplier (sh_collisions): also scales each segment hit's
-- force (props, ragdolls, what an NPC's death ragdoll inherits)
local cv_pmForce = GetConVar("vrmod_physmelee_force")

-- Physical melee replaces the C++ swing (an eye trace) on the HL2 melee
-- weapons, so the trigger can't fire one on top of the real hit.
hook.Add("StartCommand", "VRMod_PhysMelee", function(ply, cmd)
    if not cmd:KeyDown(IN_ATTACK) then return end
    local w = ply:GetActiveWeapon()
    local d = w:IsValid() and vrmod.PhysMeleeDef(w)
    if d and d.strip and vrmod.IsPlayerInVR(ply) then cmd:RemoveKey(IN_ATTACK) end
end)

-- The server played these through sound.Play without ever precaching them,
-- which plays nothing. Precache once here. The client also drops files it
-- can't find so a missing pool falls back to fists instead of going silent.
do
    local fist = impactSounds.fist
    for name, list in pairs(impactSounds) do
        local n, len = 0, #list
        for i = 1, len do
            local f = list[i]
            if SERVER or file.Exists("sound/" .. f, "GAME") then
                n = n + 1
                list[n] = f
                util.PrecacheSound(f)
            else
                MsgN("[VRMod Melee] missing sound: ", f)
            end
        end
        for i = n + 1, len do list[i] = nil end
        if n == 0 then impactSounds[name] = fist end
    end
    for _, s in pairs(knownHit) do util.PrecacheSound(s) end
end

local function pick(t) return t[math_random(#t)] end

-- Weapon's own hit sound: base adapter (melee-classified only), common SWEP
-- fields, sound pools, then the known crowbars. Read off the live entity so
-- base-class fields resolve through inheritance (weapons.GetStored doesn't).
local function WepHitSound(wep, isFlesh)
    local WA = vrmod.weaponadapter
    local s = WA and WA.HitSound(wep, isFlesh)
    if s then return s end
    -- ArcVR MeleeHitSound / MeleeStrikeSound
    s = isFlesh and wep.MeleeStrikeSound or wep.MeleeHitSound
    if isstring(s) and s ~= "" then return s end
    s = isFlesh and (wep.HitSoundBody or wep.HitBodySound or wep.HitFleshSound or wep.MeleeHitNPCSound)
        or (wep.HitSoundWorld or wep.HitSound or wep.MeleeHitWorldSound)
    if isstring(s) and s ~= "" then return s end
    local pool = isFlesh and (wep.PrimaryHitBodSounds or wep.PrimaryHitFleshSounds) or wep.PrimaryHitSounds or wep.HitSounds
    if istable(pool) and #pool > 0 then return pick(pool) end
    return knownHit[wep:GetClass()]
end

local function IsFlesh(ent) return ent:IsValid() and (ent:IsNPC() or ent:IsPlayer() or ent:IsNextBot()) end

-- Hull sweep written into t.output: the given box, else a cube of half-size r.
-- Both realms run the identical shape, so the server re-trace can't disagree.
local cubeMins, cubeMaxs = Vector(), Vector()
local function Hull(t, a, b, r, mins, maxs)
    if not mins then
        cubeMins:SetUnpacked(-r, -r, -r)
        cubeMaxs:SetUnpacked(r, r, r)
        mins, maxs = cubeMins, cubeMaxs
    end
    t.start, t.endpos, t.mins, t.maxs = a, b, mins, maxs
    util_TraceHull(t)
    return t.output
end

-- CLIENTSIDE --------------------------
if CLIENT then
    local cl_melee = CreateClientConVar("cl_vrmod_melee", "1", true, true)
    local cl_kick = CreateClientConVar("cl_vrmod_kick", "1", true, true)
    local cl_headbutt = CreateClientConVar("cl_vrmod_headbutt", "1", true, true)

    -- Holdtype -> impact id (see impactNames); unknown weapon holdtypes are blunt
    local holdImpact = {melee = 1, melee2 = 1, knife = 3, slam = 5}
    local vec_zero = Vector()
    local NextMeleeTime, mySID = 0
    local fPly, fHand
    local out = {}
    local meleeTr = {mask = MASK_SHOT, output = out, filter = function(e) return vrmod.utils.MeleeFilter(e, fPly, fHand) end}
    local bodyTr = {mask = MASK_SHOT, output = out, filter = function(e) return e ~= fPly and e:IsValid() end}
    local swingInfo, swingSnd = {}
    local function SetSwing(s) swingSnd = s end
    local _pa, _pb, _hit = Vector(), Vector(), Vector()

    -- Send a hit, then its cosmetics: nothing a swing listener does can cost
    -- the hit. The server re-sweeps from just short of contact (_hit). spd > 0
    -- marks a physical-melee hit and carries its contact speed (u/s).
    local function Strike(ply, wep, isRight, ent, r, impact, dx, dy, dz, spd, pos)
        _pa:SetUnpacked(_hit.x - dx * 2, _hit.y - dy * 2, _hit.z - dz * 2)
        _pb:SetUnpacked(dx, dy, dz)
        net.Start("VRMod_MeleeAttack")
        net.WriteVector(_pa)
        net.WriteNormal(_pb)
        net.WriteFloat(r)
        net.WriteFloat(4)
        net.WriteBool(false)
        net.WriteUInt(impact, 3)
        net.WriteBool(isRight)
        net.WriteUInt(spd, 13)
        net.SendToServer()

        local hand = isRight and "right" or "left"
        local hitSnd = wep and WepHitSound(wep, IsFlesh(ent)) or pick(impactSounds[impactNames[impact]])
        if hitSnd then sound.Play(hitSnd, _hit, 75, 100, 1) end
        if not wep then
            -- Weapons get theirs through the VRMod_MeleeSwing listener below
            if vrmod.Haptic then vrmod.Haptic(hand, "impact") end
            return
        end
        local WA = vrmod.weaponadapter
        local snd = WA and WA.SwingSound(wep)
        if not snd then
            local s = wep.MeleeStrikeSound
            if isstring(s) and s ~= "" then snd = s end
        end
        swingSnd = snd
        swingInfo.Player, swingInfo.Weapon, swingInfo.Hand, swingInfo.Position = ply, wep, hand, pos
        hook.Run("VRMod_MeleeSwing", swingInfo, SetSwing)
        -- From the weapon: scripts force their own channel, so a world-sourced
        -- swing on the hit's channel would replace the hit.
        if swingSnd then wep:EmitSound(swingSnd, 75, 100, 1, CHAN_AUTO) end
    end

    -- The weapon box is hand-space (from the model: "vertical" = blade along
    -- the hand's up, "horizontal" = along its forward), but it went to
    -- TraceHull as is, and TraceHull boxes are world-aligned: a blade column
    -- up to ~25u tall stood upright whatever the weapon's angle, and it was
    -- swept along the hand's forward instead of the swing. A swing then hit
    -- whatever sat that far above or below the blade, and HitPos (the box
    -- centre) put the impact half a column off. Now up to three cubes along
    -- the box's long axis, turned with the hand, each swept along the swing
    -- from where it was last frame to just past where it is now. Earliest
    -- contact wins. v* is the hand's velocity relative to the head.
    local function TryMelee(ply, pose, isRight, curtime, vx, vy, vz)
        local ang = pose.ang
        local fwd = ang:Forward()
        local wep = isRight ~= vrmod.utils.GunInLeftHand() and ply:GetActiveWeapon()
        local useWep = wep and vrmod.utils.IsValidWep(wep)
        local hand = isRight and "right" or "left"
        local radius, _, mins, maxs, _, isMelee = vrmod.utils.GetWeaponMeleeParams(useWep and wep or nil, ply, hand)
        local pos = pose.pos + fwd * 5
        local src = (useWep or isMelee) and vrmod.utils.AdjustCollisionsBox(pos, ang, isMelee) or pos
        fPly, fHand = ply, hand

        local sp = (vx * vx + vy * vy + vz * vz) ^ 0.5
        if sp < 0.001 then return end -- threshold convar at 0
        local dx, dy, dz = vx / sp, vy / sp, vz / sp
        local back = sp * FrameTime()
        local look = back + 2
        -- Long axis (hand-space x/y/z = forward/left/up), its extent, and the
        -- cross-section as the probe size
        local ax, lo, hi, r = nil, 0, 0, radius
        if mins then
            local ex, ey, ez = maxs.x - mins.x, maxs.y - mins.y, maxs.z - mins.z
            if ez >= ex and ez >= ey then
                ax, lo, hi, r = ang:Up(), mins.z, maxs.z, (ex > ey and ex or ey) * 0.5
            elseif ex >= ey then
                ax, lo, hi, r = fwd, mins.x, maxs.x, (ey > ez and ey or ez) * 0.5
            else
                ax, lo, hi, r = -ang:Right(), mins.y, maxs.y, (ex > ez and ex or ez) * 0.5
            end
        end
        if r < 2 then r = 2 end
        local n = ax and hi - lo > r * 4 and 3 or 1
        local bestF, bestEnt = 2
        for i = 1, n do
            local t = n == 1 and (ax and (lo + hi) * 0.5 or 0) or lo + (hi - lo) * (i - 1) * 0.5
            local px, py, pz = src.x, src.y, src.z
            if ax then px, py, pz = px + ax.x * t, py + ax.y * t, pz + ax.z * t end
            _pa:SetUnpacked(px - dx * back, py - dy * back, pz - dz * back)
            _pb:SetUnpacked(px + dx * look, py + dy * look, pz + dz * look)
            local o = Hull(meleeTr, _pa, _pb, r)
            if o.Hit and not o.StartSolid and o.Fraction < bestF then
                bestF, bestEnt = o.Fraction, o.Entity
                _hit:Set(o.HitPos)
            end
        end
        if not bestEnt or bestEnt == g_VR.vehicle.current then return end
        NextMeleeTime = curtime + cv_meleeDelay:GetFloat()

        local impact = 0
        if useWep then
            local f = wep.GetHoldType
            impact = holdImpact[f and f(wep) or ""] or 1
        end
        Strike(ply, useWep and wep, isRight, bestEnt, r, impact, dx, dy, dz, 0, pos)
    end

    -- PHYSICAL MELEE (vrmod.PhysMeleeDef, right hand) -------------------------
    -- Points along the weapon's grip->tip segment, each swept from where it
    -- was last frame to where it is now: tip speed, so wrist flicks count, and
    -- shaft hits too. Runs on the FINAL pose (vrmod.PhysMeleeStep, after the
    -- wall and body bends), so hits land where you see the weapon; the frame
    -- the bend catches it is the impact. Lines, so bodies are hit by hitbox.
    -- A point's speed is the higher of this frame's and last frame's: the
    -- impact frame is cut short by the stop, and shouldn't read as slower.
    -- Only points over the def's speed trace.
    local SysTime, math_ceil = SysTime, math.ceil
    local util_TraceLine = util.TraceLine
    local ANG0 = Angle()
    local pmPts, pmSpd = {}, {}
    for i = 1, 5 do pmPts[i], pmSpd[i] = Vector(), 0 end
    local pmN, pmT, pmR, pmNext, pmCls, pmSent, pmStable, pmActive, pmLeft = 0, 0, 0, 0, nil, false, 0, false, false
    local pmHit = setmetatable({}, {__mode = "k"})
    local _cur, _cand, _sent, _sentG = Vector(), Vector(), Vector(), Vector()
    local cvClear

    -- Hand-local tip and grip: a melee weapon's as drawn (MeleeTip), else
    -- the muzzle carried back through the viewmodel pose that built it
    -- (g_VR.viewModelPos = hand * vmi offset) from the def's grip.
    -- A gun's muzzle is held while a hull contact moves the hand: the drawn
    -- muzzle doesn't carry this frame's lift, so measured against the lifted
    -- pose it read as a longer gun, which went to the server hull, whose
    -- longer contact lifted further -- stretching until it sank in.
    local gunTip, gunCls = Vector(), nil
    local function PMTip(wep, def, pose, left)
        if def.tip then return vrmod.utils.MeleeTip(wep, def) end
        local cls = wep:GetClass()
        if gunCls == cls and vrmod.utils.HullContact(left) then return gunTip, def.grip end
        local muz = g_VR.viewModelMuzzle
        if not muz then return end
        gunTip:Set((WorldToLocal(muz.Pos, ANG0, pose.pos, pose.ang)))
        gunCls = cls
        return gunTip, def.grip
    end

    -- True while the right hand swings a weapon with a segment (its hand
    -- melee is then skipped); a weapon with no tip and no muzzle keeps the
    -- hand melee.
    local function PMStep(ply)
        local wep = ply:GetActiveWeapon()
        local def = wep:IsValid() and vrmod.PhysMeleeDef(wep)
        local left = vrmod.utils.GunInLeftHand()
        local tr = g_VR.tracking
        local pose = def and ply:Alive() and (left and tr.pose_lefthand or tr.pose_righthand)
        if pose and def.tip then vrmod.utils.SampleMeleeTip(wep, pose, left) end
        local tip, grip
        if pose then tip, grip = PMTip(wep, def, pose, left) end
        if not tip then
            pmN = 0
            return false
        end

        -- The server hull and gun segment come from this tip: sent once per
        -- weapon after it has held still (deploy anims), again if retuned.
        local cls = wep:GetClass()
        if cls ~= pmCls or left ~= pmLeft then pmCls, pmLeft, pmSent, pmStable, pmN = cls, left, false, 0, 0 end
        if _cand:DistToSqr(tip) < 0.0025 then
            pmStable = pmStable + 1
            local g = grip or vec_zero
            if pmStable == 15 and not (pmSent and _sent:DistToSqr(_cand) < 0.25 and _sentG:DistToSqr(g) < 0.25) then
                pmSent = true
                _sent:Set(_cand)
                _sentG:Set(g)
                net.Start("vrmod_physmelee_tip")
                net.WriteVector(_cand)
                net.WriteVector(g)
                net.SendToServer()
            end
        else
            _cand:Set(tip)
            pmStable = 0
        end

        local g = grip or vec_zero
        local gx, gy, gz = g.x, g.y, g.z
        local sx, sy, sz = tip.x - gx, tip.y - gy, tip.z - gz
        local n = math_ceil((sx * sx + sy * sy + sz * sz) ^ 0.5 / 6)
        if n < 1 then n = 1 elseif n > 5 then n = 5 end
        local now = SysTime()
        local dt = now - pmT
        local live = n == pmN and dt > 0 and dt < 0.1
        pmT, pmN, pmR = now, n, def.r
        local pos, ang = pose.pos, pose.ang
        local F, R, U = ang:Forward(), ang:Right(), ang:Up()
        local px, py, pz = pos.x, pos.y, pos.z
        local vmin = def.min
        -- Past the point along its motion by the gap the bend leaves (the
        -- weapon's half-thickness + vrmod_gunwall_clearance) and 1u more:
        -- reaches the face it was parked on, not one it slides along
        cvClear = cvClear or GetConVar("vrmod_gunwall_clearance")
        local look = 1 + def.r + (cvClear and cvClear:GetFloat() or 0)
        local bestF, bestEnt, bx, by, bz, bs = 2
        fPly, fHand = ply, left and "left" or "right"
        for i = 1, n do
            local f = i / n
            local lx, ly, lz = gx + sx * f, gy + sy * f, gz + sz * f
            -- hand-local y is left = -Right
            local wx = px + F.x * lx - R.x * ly + U.x * lz
            local wy = py + F.y * lx - R.y * ly + U.y * lz
            local wz = pz + F.z * lx - R.z * ly + U.z * lz
            local last = pmPts[i]
            if live then
                local dx, dy, dz = wx - last.x, wy - last.y, wz - last.z
                local d2 = dx * dx + dy * dy + dz * dz
                local d = d2 ^ 0.5
                local sp, lsp = d / dt, pmSpd[i]
                pmSpd[i] = sp
                if lsp > sp then sp = lsp end
                if sp >= vmin and d2 > 1e-6 then
                    dx, dy, dz = dx / d, dy / d, dz / d
                    _cur:SetUnpacked(wx + dx * look, wy + dy * look, wz + dz * look)
                    meleeTr.start, meleeTr.endpos = last, _cur
                    util_TraceLine(meleeTr)
                    local o = meleeTr.output
                    if o.Hit and not o.StartSolid and o.Fraction < bestF then
                        bestF, bestEnt, bx, by, bz, bs = o.Fraction, o.Entity, dx, dy, dz, sp
                        _hit:Set(o.HitPos)
                    end
                end
            else
                pmSpd[i] = 0
            end
            last:SetUnpacked(wx, wy, wz)
        end

        -- One hit per 80ms, each entity at most every 300ms
        if bestEnt and now >= pmNext and not g_VR.cooldownRight and (pmHit[bestEnt] or 0) <= now and bestEnt ~= g_VR.vehicle.current then
            pmNext, pmHit[bestEnt] = now + 0.08, now + 0.3
            if bs > 8191 then bs = 8191 end
            Strike(ply, wep, not left, bestEnt, def.r, def.impact, bx, by, bz, bs - bs % 1, pos)
        end
        return true
    end

    -- Runs once the frame's hand poses are final (cl_vrmod, after the wall
    -- and body bends), so the sweep follows the weapon you see. The hand
    -- melee next frame reads pmActive to leave a weapon hand to it.
    function vrmod.PhysMeleeStep()
        pmActive = g_VR.threePoints and cl_melee:GetBool() and PMStep(LocalPlayer()) or false
    end

    -- Tuning: segment points (white, tip red) and the last contact (yellow)
    local cv_pmdbg = CreateClientConVar("vrmod_physmelee_debug", "0", false, false, "Draw the physical melee sweep points", 0, 1)
    local COL_PT, COL_TIP, COL_HIT = Color(255, 255, 255), Color(255, 40, 40), Color(255, 220, 0)
    hook.Add("PostDrawTranslucentRenderables", "VRMod_PhysMeleeDebug", function(depth, sky)
        if depth or sky or pmN == 0 or not cv_pmdbg:GetBool() then return end
        render.SetColorMaterial()
        for i = 1, pmN do
            render.DrawWireframeSphere(pmPts[i], pmR, 6, 6, i == pmN and COL_TIP or COL_PT)
            if i > 1 then render.DrawLine(pmPts[i - 1], pmPts[i], COL_PT) end
        end
        render.DrawWireframeSphere(_hit, 1, 4, 4, COL_HIT)
    end)

    concommand.Add("vrmod_physmelee_tip", function(_, _, a)
        local w = LocalPlayer():GetActiveWeapon()
        local d = w:IsValid() and vrmod.PhysMeleeDef(w)
        if not (d and d.tip) then
            print("[PhysMelee] Active weapon has no tunable tip (guns use their muzzle)")
            return
        end
        if a[3] then d.tip = Vector(tonumber(a[1]) or 0, tonumber(a[2]) or 0, tonumber(a[3]) or 0) end
        if a[6] then d.grip = Vector(tonumber(a[4]) or 0, tonumber(a[5]) or 0, tonumber(a[6]) or 0) end
        local t, g = d.tip, d.grip or vec_zero
        print(string.format("[PhysMelee] %s tip = Vector(%.2f, %.2f, %.2f), grip = Vector(%.2f, %.2f, %.2f)", w:GetClass(), t.x, t.y, t.z, g.x, g.y, g.z))
    end, nil, "vrmod_physmelee_tip [x y z [gx gy gz]]: show or set the held melee weapon's hand-local tip (and grip)")

    hook.Add("VRMod_Tracking", "VRMeleeTrace", function()
        local three = g_VR.threePoints
        local meleeOn = three and cl_melee:GetBool()
        local ply = LocalPlayer()
        local pmOn = meleeOn and pmActive
        local curtime = CurTime()
        if NextMeleeTime > curtime then return end
        local kickOn = g_VR.sixPoints and cl_kick:GetBool()
        local hbOn = three and cl_headbutt:GetBool()
        if not (meleeOn or kickOn or hbOn) then return end
        if not ply:Alive() then return end
        local t = g_VR.tracking
        local hmd = t.hmd
        if not hmd then return end
        local hv = hmd.vel or vec_zero

        -- Hand melee: speed relative to the head, compared squared, no allocation
        if meleeOn then
            local thr = cv_meleeVelThreshold:GetFloat() * 50
            thr = thr * thr
            local hx, hy, hz = hv.x, hv.y, hv.z
            -- The hand swinging a segment weapon is the sweep's (pmActive)
            local pmL = pmOn and vrmod.utils.GunInLeftHand()
            local p = t.pose_lefthand
            local v = p and p.vel
            if v and not pmL and not g_VR.cooldownLeft then
                local x, y, z = v.x - hx, v.y - hy, v.z - hz
                if x * x + y * y + z * z >= thr then TryMelee(ply, p, false, curtime, x, y, z) end
            end
            p = t.pose_righthand
            v = p and p.vel
            if v and not (pmOn and not pmL) and NextMeleeTime <= curtime and not g_VR.cooldownRight then
                local x, y, z = v.x - hx, v.y - hy, v.z - hz
                if x * x + y * y + z * z >= thr then TryMelee(ply, p, true, curtime, x, y, z) end
            end
        end

        -- FBT kick (requires calibrated FBT, this is mainly for people using standable in the background like me)
        if kickOn and NextMeleeTime <= curtime then
            mySID = mySID or ply:SteamID()
            local fa = g_VR.fbtActive
            if fa and fa[mySID] then
                local thr = cv_kickVelThreshold:GetFloat() * 50
                thr = thr * thr
                local ls = vrmod.GetLeftFootVelocityRelative():LengthSqr()
                local rs = vrmod.GetRightFootVelocityRelative():LengthSqr()
                if ls >= thr or rs >= thr then
                    local isRight = rs > ls -- faster foot; ties go left
                    local pos, ang = (isRight and vrmod.GetRightFootPose or vrmod.GetLeftFootPose)(ply)
                    local dir = ang:Forward()
                    fPly = ply
                    local tr = Hull(bodyTr, pos, pos + dir * KICK_REACH, KICK_RADIUS)
                    if tr.Hit and tr.Entity ~= g_VR.vehicle.current then
                        NextMeleeTime = curtime + cv_meleeDelay:GetFloat()
                        net.Start("VRMod_KickAttack")
                        net.WriteBool(isRight)
                        net.SendToServer()
                        sound.Play(pick(impactSounds.fist), tr.HitPos, 80, 90, 1)
                    end
                end
            end
        end

        -- Headbutt
        if hbOn and NextMeleeTime <= curtime then
            local thr = cv_headbuttVelThreshold:GetFloat() * 50
            if hv:LengthSqr() >= thr * thr then
                local pos = hmd.pos
                fPly = ply
                local tr = Hull(bodyTr, pos, pos + hmd.ang:Forward() * HEADBUTT_REACH, HEADBUTT_RADIUS)
                if tr.Hit and tr.Entity ~= g_VR.vehicle.current then
                    NextMeleeTime = curtime + cv_meleeDelay:GetFloat()
                    net.Start("VRMod_HeadbuttAttack")
                    net.SendToServer()
                    sound.Play(pick(impactSounds.fist), tr.HitPos, 75, 110, 1)
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

    local IsValid, util_Effect = IsValid, util.Effect
    local GetRightHandPos, GetLeftHandPos = vrmod.GetRightHandPos, vrmod.GetLeftHandPos
    local math_min, bor, band = math.min, bit.bor, bit.band
    local others = RecipientFilter()
    local ed, _c, _s, _f = EffectData(), Vector(), Vector(), Vector()

    local impactMultipliers = {
        fist      = {1.0,  DMG_CLUB},
        blunt     = {1.25, DMG_CLUB},
        stunstick = {1.1,  bor(DMG_CLUB, DMG_SHOCK)},
        sharp     = {1.5,  DMG_SLASH},
        piercing  = {1.3,  DMG_BULLET},
        heavy     = {2.0,  bor(DMG_CLUB, DMG_CRUSH)},
        energy    = {1.4,  bor(DMG_ENERGYBEAM, DMG_SHOCK)},
        explosive = {2.5,  bor(DMG_BLAST, DMG_CLUB)},
    }

    local meleeHoldTypes = {melee = true, melee2 = true, knife = true}
    local cv_pmDmg, cv_pmSpeed = GetConVar("vrmod_physmelee_damage"), GetConVar("vrmod_physmelee_speed")

    -- A weapon's melee damage: melee weapons their own, guns 10% of theirs
    -- on top of the fist damage; no weapon (or none found), the fist damage
    local function WeaponBase(wep)
        local base = cv_meleeDamage:GetFloat()
        if not wep:IsValid() then return base end
        local f, mdt = wep.GetHoldType, wep.MeleeDamageType
        local isMeleeWep = wep.NotAGun or (isnumber(mdt) and band(mdt, DMG_SLASH) ~= 0) or meleeHoldTypes[f and f(wep) or ""]
        local pri = wep.Primary
        local d = pri and pri.Damage
        if not (isnumber(d) and d > 0) then
            local mn, mx = wep.MinDamage or wep.DamageMin, wep.MaxDamage or wep.DamageMax
            d = isnumber(mn) and isnumber(mx) and mn > 0 and math_random(mn, mx) or nil
        end
        if d then base = isMeleeWep and d or base + d * 0.1 end
        return base
    end

    local fPly, fHand
    local out = {}
    local meleeTr = {mask = MASK_SHOT, output = out, filter = function(e) return vrmod.utils.MeleeFilter(e, fPly, fHand) end}
    local bodyTr = {mask = MASK_SHOT, output = out, filter = function(e) return e ~= fPly and e:IsValid() end}

    -- Damage, push, sound and effects shared by every attack kind. Glass and
    -- breakable surfaces take DMG_BLAST on top so they actually shatter.
    -- t is the trace input table; its hull box locates the contact point.
    -- force is the push along dir. It rides the damage as its force, which
    -- the engine applies itself: props and ragdolls at the hit point, and an
    -- NPC this kills hands it to its ragdoll.
    local function Impact(ply, t, dir, dmg, dmgType, force, snd, level, pitch, decal, inf)
        local tr = t.output
        local ent, hp, n = tr.Entity, tr.HitPos, tr.HitNormal
        if tr.MatType == MAT_GLASS or ent:GetClass() == "func_breakable_surf" then dmgType = bor(dmgType, DMG_BLAST) end
        local bc = ent:GetBloodColor() -- before the damage can remove it
        local di = DamageInfo()
        di:SetAttacker(ply)
        di:SetInflictor(inf or ply)
        di:SetDamage(dmg)
        di:SetDamageType(dmgType)
        di:SetDamagePosition(hp)
        _f:SetUnpacked(dir.x * force, dir.y * force, dir.z * force)
        di:SetDamageForce(_f)
        ent:TakeDamageInfo(di)
        if snd then
            others:RemoveAllPlayers()
            others:AddPAS(hp)
            others:RemovePlayer(ply)
            EmitSound(snd, hp, 0, CHAN_AUTO, 1, level, 0, pitch, 0, others)
        end

        -- HitPos is the hull centre; the surface is the box's support
        -- distance d (<= 0) along n from it.
        local mn, mx, nx, ny, nz = t.mins, t.maxs, n.x, n.y, n.z
        local a, b = nx * mn.x, nx * mx.x
        local d = a < b and a or b
        a, b = ny * mn.y, ny * mx.y
        d = a < b and d + a or d + b
        a, b = nz * mn.z, nz * mx.z
        d = a < b and d + a or d + b
        _c.x, _c.y, _c.z = hp.x + nx * d, hp.y + ny * d, hp.z + nz * d
        ed:SetOrigin(_c)
        -- HL2 bludgeon UTIL_ImpactTrace: material particles, decal, sound
        _s.x, _s.y, _s.z = hp.x + nx * 4, hp.y + ny * 4, hp.z + nz * 4
        ed:SetStart(_s)
        ed:SetSurfaceProp(tr.SurfaceProps)
        ed:SetDamageType(dmgType)
        ed:SetHitBox(tr.HitBox)
        ed:SetEntity(ent)
        util_Effect("Impact", ed)
        -- plus the blood its TraceAttack spawns. GetBloodColor can return nil.
        if bc and bc >= 0 and bc ~= BLOOD_COLOR_MECH then
            ed:SetNormal(dir)
            ed:SetColor(bc)
            util_Effect("BloodImpact", ed)
        end
        -- VRMod_MeleeHit listener decal, on top of the engine's own
        if decal then
            _c.x, _c.y, _c.z = _c.x - nx * 8, _c.y - ny * 8, _c.z - nz * 8
            util.Decal(decal, hp, _c)
        end
        return ent, dmgType
    end

    -- Pre-allocated hit payload + persistent override setter for VRMod_MeleeHit
    local H, hookRight = {}
    local function Override(snd, decal, dmg, mult, dmgType, _, _, impact)
        if not hookRight then return end
        if snd then H.Sound = snd end
        if decal then H.DecalName = decal end
        if dmg then H.Damage = dmg H.DamageExplicit = true end
        if mult then H.DamageMultiplier = mult end
        if dmgType then H.DamageType = dmgType end
        if impact then H.ImpactType = impact end
    end

    local function Debug() return vrmod.logger.IsDebug and vrmod.logger.IsDebug() end

    vrmod.NetReceiveLimited("VRMod_MeleeAttack", 20, 512, function(_, ply)
        if not sv_vrmod_melee:GetBool() or not IsValid(ply) or not ply:Alive() then return end
        local src = net.ReadVector()
        local dir = net.ReadNormal()
        local radius = net.ReadFloat()
        local reach = net.ReadFloat()
        local mins, maxs
        if net.ReadBool() then
            mins = net.ReadVector()
            maxs = net.ReadVector()
        end
        local impactType = impactNames[net.ReadUInt(3)]
        local isRight = net.ReadBool()
        local pmSpeed = net.ReadUInt(13)
        -- NaN fails every comparison, so malformed floats are rejected too
        if not (reach > 0 and reach <= 128 and radius >= 0 and radius <= 128) then return end
        -- The swing has to start at the hand that made it (a crowbar tip sits
        -- ~30u out; the rest is latency headroom)
        if not (src:DistToSqr((isRight and GetRightHandPos or GetLeftHandPos)(ply)) <= 16384) then return end

        -- Physical melee: the client's contact speed, for a weapon with a
        -- segment actually in the right hand
        local wep = isRight ~= (ply.vrGunLeft == true) and ply:GetActiveWeapon() or NULL
        local hasWep = wep:IsValid()
        local def = pmSpeed > 0 and hasWep and vrmod.PhysMeleeDef(wep)
        if pmSpeed > 0 and not def then return end

        local hand = isRight and "right" or "left"
        fPly, fHand = ply, hand
        local tr = Hull(meleeTr, src, src + dir * reach, radius, mins, maxs)
        if not tr.Hit then return end

        -- Physical: the weapon's own damage at the reference tip speed, up to
        -- double for faster swings; it's already the weapon's number, so no
        -- impact-type multiplier on top. Hand melee: the fist formula.
        local info = impactMultipliers[impactType]
        local speed, scale, mult
        if def then
            speed = pmSpeed
            local f = speed / cv_pmSpeed:GetFloat()
            if f > 2 then f = 2 end
            scale, mult = (def.dmg or WeaponBase(wep)) * f * cv_pmDmg:GetFloat(), 1
        else
            local vel = isRight and vrmod.GetRightHandVelocityRelative(ply) or vrmod.GetLeftHandVelocityRelative(ply)
            speed = vel and vel:Length() or 0
            scale, mult = WeaponBase(wep) * math_min(5, 1 + speed * cv_meleeSpeedScale:GetFloat()), info[1]
        end

        local ent, mat = tr.Entity, tr.MatType
        H.Attacker, H.HitEntity, H.HitPos, H.Hand = ply, ent, tr.HitPos, hand
        H.ImpactType, H.DamageMultiplier, H.DamageType = impactType, mult, info[2]
        H.Damage, H.Physical = scale * mult, def and true or false
        H.RelativeSpeed, H.MaterialType = speed, mat
        H.Reach, H.Radius = reach, radius
        H.Sound, H.DamageExplicit, H.DecalName = nil, false, nil
        hookRight = isRight
        hook.Run("VRMod_MeleeHit", H, Override)

        -- Re-resolve if a listener changed the impact type and cleared the damage type
        if not H.DamageType and H.ImpactType then
            local i2 = impactMultipliers[H.ImpactType] or impactMultipliers.fist
            H.DamageMultiplier = H.DamageMultiplier or i2[1]
            H.DamageType = i2[2]
        end
        if not H.DamageExplicit then H.Damage = scale * (H.DamageMultiplier or 1) end

        local snd = H.Sound
        if not snd and hasWep then snd = WepHitSound(wep, IsFlesh(ent)) end
        snd = snd or pick(impactSounds[H.ImpactType] or impactSounds.fist)
        local _, dmgType = Impact(ply, meleeTr, dir, H.Damage, H.DamageType, def and speed * def.f * cv_pmForce:GetFloat() or H.Damage * 10, snd, 75, 100, H.DecalName, def and wep)

        if Debug() then
            vrmod.logger.Debug("%s smashed %s for %.1f dmg (impact:%s mult:%.2f type:%d speed:%.1f snd:%s)",
                ply:Nick(), ent:IsValid() and ent:GetClass() or "World",
                H.Damage, H.ImpactType, H.DamageMultiplier or 1, dmgType, speed, tostring(snd))
        end
    end)

    -- Kick & headbutt: flat damage, no weapon scaling. The server re-traces from
    -- its own tracker pose, so the client only says which foot.
    net.Receive("VRMod_KickAttack", function(_, ply)
        if not sv_vrmod_kick:GetBool() or not IsValid(ply) or not ply:Alive() then return end
        local isRight = net.ReadBool()
        local pos, ang = (isRight and vrmod.GetRightFootPose or vrmod.GetLeftFootPose)(ply)
        local dir = ang:Forward()
        fPly = ply
        local tr = Hull(bodyTr, pos, pos + dir * KICK_REACH, KICK_RADIUS)
        if not tr.Hit then return end
        local dmg = cv_kickDamage:GetFloat()
        local ent = Impact(ply, bodyTr, dir, dmg, DMG_CLUB, dmg * 15, pick(impactSounds.fist), 80, 90)
        if Debug() then
            vrmod.logger.Debug("%s kicked %s for %.1f dmg (foot:%s)", ply:Nick(), ent:IsValid() and ent:GetClass() or "World", dmg, isRight and "right" or "left")
        end
    end)

    net.Receive("VRMod_HeadbuttAttack", function(_, ply)
        if not sv_vrmod_headbutt:GetBool() or not IsValid(ply) or not ply:Alive() then return end
        local pos, ang = vrmod.GetHMDPose(ply)
        local dir = ang:Forward()
        fPly = ply
        local tr = Hull(bodyTr, pos, pos + dir * HEADBUTT_REACH, HEADBUTT_RADIUS)
        if not tr.Hit then return end
        local dmg = cv_headbuttDamage:GetFloat()
        local ent = Impact(ply, bodyTr, dir, dmg, DMG_CLUB, dmg * 8, pick(impactSounds.fist), 75, 110)
        if Debug() then
            vrmod.logger.Debug("%s headbutted %s for %.1f dmg", ply:Nick(), ent:IsValid() and ent:GetClass() or "World", dmg)
        end
    end)
end