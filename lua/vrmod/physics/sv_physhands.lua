if CLIENT then return end
-- Server-side VR hand physics props, one per hand. Each is pulled onto the
-- player's networked hand pose by its own motion controller: ComputeShadowControl
-- runs inside PhysicsSimulate with the physics step's real delta time. (It used
-- to run from PlayerTick -- per usercmd, deltatime 0, a closure per call.)
--
-- The right hand reshapes per weapon: its grip->tip segment
-- (vrmod.PhysMeleeDef) as a heavy, silent convex. The pose is the same
-- network frame every other client draws the weapon from, wall bend included,
-- so the hull sits where everyone sees the weapon with no traffic of its own.
local IsValid = IsValid
local vrHands = {}
local SIDES = {"right", "left"} -- hoisted: no per-call table alloc in spawn/repair loops
local OFF = vrmod.DEFAULT_OFFSET
local TICK = engine.TickInterval()
local SIM_NOTHING = SIM_NOTHING
local LocalToWorld, WorldToLocal, CurTime, ANG0 = LocalToWorld, WorldToLocal, CurTime, Angle()
local ENT = FindMetaTable("Entity")
local InitSphere, InitBox, InitConvex = ENT.PhysicsInitSphere, ENT.PhysicsInitBox, ENT.PhysicsInitConvex
local PARK = Vector(0, 0, -10000)
local cv_pmForce = GetConVar("vrmod_physmelee_force")
local RMIN, RMAX = Vector(-2, -2, -2), Vector(2, 2, 2)
local ORIGIN = Vector()
-- Interpolated client hand poses (sh_pickup_util, loaded first)
local HandPoseNow, HandPoseIn = vrmod.utils.HandPoseNow, vrmod.utils.HandPoseIn
-- Master switch for the server-side hand physics props. On (default): solid vphysics
-- hands that push objects. Off: nothing spawns, so nothing can block bullets/movement.
-- Replicated so the settings menu checkbox can bind to it and show the live
-- server value; without that flag the client has no such convar at all.
local cv_handphysics = CreateConVar("vrmod_hand_physics", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED, "Enable server-side VR hand physics props. Disable to stop hands interacting with the world.")
-- Utility to get cached physics data from weapon
local function GetCachedWeaponParams(wep, ply, side)
    local radius, reach, mins, maxs, angles = vrmod.utils.GetWeaponMeleeParams(wep, ply, side)
    if radius == vrmod.DEFAULT_RADIUS and reach == vrmod.DEFAULT_REACH then return nil end
    return radius, reach, mins, maxs, angles
end

-- Motion-controller step: pull the hand prop onto its hand pose, OFF
-- forward of the controller. Parked hands are left asleep. The pose is the
-- one the client sends each tick (vrmod_hand_pose: where its collision put
-- the hand, world space), else the network frame's.
--
-- vrRP/vrRA: the hand pose this step chased; Tick measures the prop
-- against it once the step has run (vrmod_hull_error, below).
local function Sim(self, phys, dt)
    if self.vrParked then return SIM_NOTHING end
    local pt = g_VR[self.vrSID]
    local lf = pt and pt.latestFrame
    if not lf then return SIM_NOTHING end
    local ply = self.vrOwner
    if not IsValid(ply) then return SIM_NOTHING end
    local pos, ang
    if CurTime() < (ply.vrHT or 0) then
        HandPoseNow(ply)
        if self.vrRight then pos, ang = ply.vrHRP, ply.vrHRA else pos, ang = ply.vrHLP, ply.vrHLA end
        self.vrSeq = ply.vrHS -- the client pose this step chases (echoed in its hull error)
    else
        self.vrSeq = 0
        local p, a
        if self.vrRight then p, a = lf.righthandPos, lf.righthandAng else p, a = lf.lefthandPos, lf.lefthandAng end
        if not (p and a) then return SIM_NOTHING end
        pos, ang = LocalToWorld(p, a, ply:GetPos(), ANG0)
    end

    self.vrRP:Set(pos)
    self.vrRA:Set(ang)
    self.vrHasR = true

    -- Stuck last tick: the shadow drives the hull at its target, which is
    -- deep in whatever stopped it, at whatever speed reaches it in a tick --
    -- vphysics then lets the hull sink in proportion, so harder slams sat
    -- deeper. Capped while stuck, it rests on the surface; free, uncapped.
    local p, stuck = self.vrSC, self.vrErrSent
    p.maxspeed, p.maxangular = stuck and 300 or 2000000, stuck and 720 or 20000
    local t = p.pos
    t:Set(ang:Forward())
    t:Mul(OFF)
    t:Add(pos)
    p.angle, p.deltatime = ang, dt
    phys:Wake()
    phys:ComputeShadowControl(p)
    return SIM_NOTHING
end

-- Rebuild a hand's physics object with init(ent, a, b) and put the new one
-- on the motion controller in place of the old.
local function Reshape(d, mass, pm, init, a, b)
    local e = d.ent
    if IsValid(d.phys) then e:RemoveFromMotionController(d.phys) end
    init(e, a, b)
    local phys = e:GetPhysicsObject()
    d.phys, e.vrPM = phys, pm
    if not IsValid(phys) then return end
    phys:SetMass(mass)
    phys:EnableGravity(false)
    if pm then phys:SetMaterial("default_silent") end -- the hit sweep owns impact audio
    e:AddToMotionController(phys)
    if e.vrParked then phys:EnableMotion(false) else phys:Wake() end
end

-- What the prop is, for vrmod_debug_hull on clients (only on reshape).
-- vrGun: a weapon's hull (box or segment), not a bare hand's sphere -- Held.
local function Tag(e, kind, a, b, r)
    e.vrGun = kind ~= 1
    e:SetNWInt("vrShape", kind)
    if a then e:SetNWVector("vrA", a) end
    if b then e:SetNWVector("vrB", b) end
    e:SetNWFloat("vrR", r or 0)
end

local function Sphere(d)
    Reshape(d, 20, false, InitSphere, vrmod.DEFAULT_RADIUS, "metal_bouncy")
    Tag(d.ent, 1, nil, nil, vrmod.DEFAULT_RADIUS)
end

-- Segment hull for wep. The tip is the player's measured one (sent by the
-- client, the only way a gun's muzzle reaches here), else the def's. False
-- when there's no def or no tip yet: the caller keeps the generic shape.
local function PMShape(ply, d, wep)
    local def = vrmod.PhysMeleeDef(wep)
    if not def then return false end
    local cls = wep:GetClass()
    -- measured per class and hand: a left-hand segment isn't the right's
    local sent = ply.vrpmTips and ply.vrpmTips[cls .. (ply.vrGunLeft and "L" or "R")]
    local tip = sent and sent[1] or def.tip
    if not tip then return false end
    local grip = sent and sent[2] or def.grip or ORIGIN
    if d.ent.vrPM and d.pmCls == cls and d.pmTip:DistToSqr(tip) < 0.25 and d.pmGrip:DistToSqr(grip) < 0.25 then return true end
    local verts = vrmod.utils.SegBox(grip, tip, def.r, OFF)
    if not verts then return false end
    Reshape(d, def.m * cv_pmForce:GetFloat(), true, InitConvex, verts)
    Tag(d.ent, 3, grip, tip, def.r)
    d.pmCls, d.pmTip, d.pmGrip, d.pmMass = cls, tip, grip, def.m
    return true
end

-- The hand holding the weapon gets its shape; the other is always a bare
-- hand (sphere). Which hand holds it the client says with every pose
-- (ply.vrGunLeft, from vrmod_hand_pose).
local function GunSide(ply) return ply.vrGunLeft and "left" or "right" end
local function UpdateWeaponCollisionShape(ply, wep)
    if not cv_handphysics:GetBool() then return end
    local hands = vrHands[ply]
    if not hands then return end
    local side = GunSide(ply)
    local gun, bare = hands[side], hands[side == "left" and "right" or "left"]
    if bare and IsValid(bare.ent) and bare.ent:GetNWInt("vrShape", 1) ~= 1 then Sphere(bare) end
    if not (gun and IsValid(gun.ent)) then return end
    if IsValid(wep) and PMShape(ply, gun, wep) then return end
    if gun.ent.vrPM then Sphere(gun) end
    timer.Simple(0.1, function()
        -- A later switch, a hand swap, or the client's tip for a gun
        -- supersedes this
        if not IsValid(ply) or not vrmod.IsPlayerInVR(ply) or not IsValid(gun.ent) or gun.ent.vrPM or ply:GetActiveWeapon() ~= wep or GunSide(ply) ~= side then return end
        if not vrmod.utils.IsValidWep(wep) then
            vrmod.logger.Debug("UpdateWeaponCollisionShape: Invalid weapon %s, applying default sphere", tostring(wep))
            Sphere(gun)
            return
        end

        local radius, reach, mins, maxs, angles = GetCachedWeaponParams(wep, ply, side)
        if not radius or not mins or not maxs or not angles or radius == vrmod.DEFAULT_RADIUS and reach == vrmod.DEFAULT_REACH and mins == vrmod.DEFAULT_MINS and maxs == vrmod.DEFAULT_MAXS then
            vrmod.logger.Debug("UpdateWeaponCollisionShape: Invalid or default params for %s, retrying", wep:GetClass())
            timer.Simple(0.5, function() UpdateWeaponCollisionShape(ply, wep) end)
            return
        end

        vrmod.logger.Debug("UpdateWeaponCollisionShape: Applying box for %s, mins=%s, maxs=%s", wep:GetClass(), tostring(mins), tostring(maxs))
        Reshape(gun, 20, false, InitBox, mins, maxs)
        Tag(gun.ent, 2, mins, maxs)
    end)
end

-- Triggers on weapon switch
hook.Add("PlayerSwitchWeapon", "VRHand_UpdateCollisionOnWeaponSwitch", function(ply, oldWep, newWep) UpdateWeaponCollisionShape(ply, newWep) end)

local function NewHand(ply, right)
    local e = ents.Create("base_anim")
    if not IsValid(e) then return end
    e:SetPos(ply:GetPos())
    e:SetModel("models/props_junk/PopCan01a.mdl")
    e:Spawn()
    e:SetPersistent(true)
    e:SetNoDraw(true)
    e:DrawShadow(false)
    e:SetNWBool("isVRHand", true)
    e.vrOwner, e.vrSID, e.vrRight = ply, ply:SteamID(), right
    -- teleportdistance: past it the prop is lost (wedged, or unparking),
    -- not stuck, so it snaps home rather than drag the hand there. 48: a
    -- hard slam is ~20u in by the time the pin lands; at 24 it went through
    e.vrSC = {secondstoarrive = TICK, pos = Vector(), maxangular = 20000, maxangulardamp = 20000, maxspeed = 2000000, maxspeeddamp = 20000, dampfactor = 0.3, teleportdistance = 48}
    e.vrRP, e.vrRA, e.vrHasR = Vector(), Angle(), false
    e.PhysicsSimulate = Sim
    e:SetCustomCollisionCheck(true) -- VRHand_NoWorld
    e:StartMotionController()
    -- no model, just physics sphere
    local d = {ent = e}
    Reshape(d, 20, false, InitSphere, 2, "metal_bouncy")
    if not IsValid(d.phys) then
        e:Remove()
        return
    end
    Tag(e, 1, nil, nil, 2)
    e:SetCollisionBounds(RMIN, RMAX)
    e:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    e:Activate()
    return d
end

-- Out of play (death, vehicle, cleanup): parked far below the map,
-- frozen and asleep. Unpark puts it back; the shadow teleports it home.
local function Park(d)
    local e = d and d.ent
    if not IsValid(e) or e.vrParked then return end
    e.vrParked = true
    e:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    e:SetPos(PARK)
    local p = d.phys
    if IsValid(p) then
        p:EnableMotion(false)
        p:Sleep()
    end
end

local function Unpark(d)
    local e = d.ent
    e.vrParked, e.vrHasR, e.vrMine = false, false, false -- false: Tick re-syncs the held rules
    e:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    local p = d.phys
    if IsValid(p) then
        p:EnableMotion(true)
        p:Wake()
    end
end

local function SpawnVRHands(ply)
    if not cv_handphysics:GetBool() or not IsValid(ply) or ply.vrHandsOff or not ply:Alive() or ply:InVehicle() or not vrmod.IsPlayerInVR(ply) then return end
    local hands = vrHands[ply]
    if not hands then
        hands = {}
        vrHands[ply] = hands
    end
    for i = 1, 2 do
        local side = SIDES[i]
        local d = hands[side]
        if not (d and IsValid(d.ent)) then
            hands[side] = NewHand(ply, i == 1)
        elseif d.ent.vrParked then
            Unpark(d)
        end
    end

    local wep = ply:GetActiveWeapon()
    if vrmod.utils.IsValidWep(wep) then UpdateWeaponCollisionShape(ply, wep) end
end

local function RemoveVRHands(ply)
    local hands = vrHands[ply]
    if not hands then return end
    Park(hands.right)
    Park(hands.left)
end

-- Held as a ragdoll (sh_playergrab): the hands sit the carry out parked,
-- and SpawnVRHands won't bring them back until it's over.
function vrmod.utils.ParkVRHands(ply, park)
    ply.vrHandsOff = park or nil
    if park then RemoveVRHands(ply) else SpawnVRHands(ply) end
end

-- Full teardown (VR exit, hand physics off, disconnect): delete props +
-- clear state so the next start rebuilds fresh.
local function DestroyVRHands(ply)
    local hands = vrHands[ply]
    if not hands then return end
    for _, side in pairs(hands) do
        if IsValid(side.ent) then side.ent:Remove() end
    end

    vrHands[ply] = nil
end

-- Any VR hand, anyone's: never something to grab
hook.Add("VRMod_Pickup", "VRHand_BlockPickup", function(ply, ent) if ent.vrOwner then return false end end)

-- Client-measured physical-melee tip (hand-local) for the weapon in hand. The
-- client sends it once per weapon after it settles, so this is rare.
util.AddNetworkString("vrmod_physmelee_tip")
vrmod.NetReceiveLimited("vrmod_physmelee_tip", 4, 256, function(_, ply)
    local tip, grip = net.ReadVector(), net.ReadVector()
    local wep = ply:GetActiveWeapon()
    -- NaN fails the comparison, so it's rejected too
    if not (wep:IsValid() and vrmod.PhysMeleeDef(wep) and tip:LengthSqr() <= 6400 and grip:LengthSqr() <= 6400) then return end
    local cls = wep:GetClass()
    local tips = ply.vrpmTips
    if not tips then
        tips = {}
        ply.vrpmTips = tips
    end
    tips[cls .. (ply.vrGunLeft and "L" or "R")] = {tip, grip}
    local h = vrHands[ply]
    local gun = h and h[GunSide(ply)]
    if gun and IsValid(gun.ent) and cv_handphysics:GetBool() then PMShape(ply, gun, wep) end
end)

-- Both hands' poses from the client (vrmod.utils.SendHandPose), and which
-- hand holds the weapon; a swap re-shapes both. Kept on the player: the hand
-- props (Sim) and the pickup controller (GetHandTransform) both drive from
-- it, so a held thing and the hand holding it chase the same pose. Fresh
-- for a quarter second, after that both fall back to the frame.
util.AddNetworkString("vrmod_hand_pose")
vrmod.NetReceiveLimited("vrmod_hand_pose", 200, 512, function(_, ply)
    local lp, la, rp, ra = net.ReadVector(), net.ReadAngle(), net.ReadVector(), net.ReadAngle()
    local gunLeft, seq, ms = net.ReadBool(), net.ReadUInt(16), net.ReadUInt(16)
    if gunLeft ~= (ply.vrGunLeft == true) then
        ply.vrGunLeft = gunLeft
        UpdateWeaponCollisionShape(ply, ply:GetActiveWeapon())
    end
    -- Near the player (NaN fails the comparison too)
    local o = ply:GetPos()
    if not (lp:DistToSqr(o) <= 40000 and rp:DistToSqr(o) <= 40000) then return end
    local now = CurTime()
    HandPoseIn(ply, lp, la, rp, ra, seq, ms, now < (ply.vrHT or 0))
    ply.vrHT = now + 0.25
end)

-- Each tick, after the step: a prop off the pose it chased (past 1u /
-- ~6 degrees, squared sums; lost past 48u, its teleportdistance) AND held
-- back by a contact is stuck -- one trailing a swing in free air isn't.
-- The owner gets that contact as a plane in the touched prop's own space
-- and the touching hull point in hand space: the client lifts its live
-- hand out of the prop as drawn, so it keeps sliding and turning at frame
-- rate instead of sitting a round trip back on the hull's pose. Ragdolls
-- (many bones) get that pose, world space. Contact only between steps
-- (Contact, below), never from Sim.
local ERR_P, ERR_A, ERR_MAX = 1, 36, 48 * 48
-- Stuck needs something holding the hull back: a contact that is frozen or
-- barely moving. A prop the hull is knocking away moves off fast; reporting
-- the hull's lag on it pinned the hand back to the impact a round trip
-- later, after the prop had already gone (MP; SP clears inside a tick).
local SLOW2 = 50 * 50
local function Contact(phys)
    local s = phys:GetFrictionSnapshot()
    for k = 1, #s do
        local c = s[k]
        local o = c.Other
        if IsValid(o) and (not o:IsMotionEnabled() or o:GetVelocity():LengthSqr() < SLOW2) then return c end
    end
end
util.AddNetworkString("vrmod_hull_plane")
util.AddNetworkString("vrmod_hull_error") -- held props (sh_pickup_util SendHullError)
local WriteContactPlane = vrmod.utils.WriteContactPlane
local function SendStuck(ply, right, phys, c, cp, ca, rp, seq)
    net.Start("vrmod_hull_plane", true)
    net.WriteBool(right)
    net.WriteBool(true)
    net.WriteUInt(seq or 0, 16)
    -- Normal out of the prop: toward the hull's mass centre
    local pt, n = c.ContactPoint, c.Normal
    local m = phys:LocalToWorld(phys:GetMassCenter())
    if (m.x - pt.x) * n.x + (m.y - pt.y) * n.y + (m.z - pt.z) * n.z < 0 then n = -n end
    if not WriteContactPlane(c.Other:GetEntity(), pt, n, cp, ca) then
        net.WriteBool(false)
        net.WriteVector(cp)
        net.WriteAngle(ca)
        local d = rp - cp
        local has = d:LengthSqr() > ERR_P
        net.WriteBool(has)
        if has then
            d:Normalize()
            net.WriteNormal(d)
        end
    end
    net.Send(ply)
end
local function SendClear(ply, right)
    net.Start("vrmod_hull_plane")
    net.WriteBool(right)
    net.WriteBool(false)
    net.Send(ply)
end
hook.Add("Tick", "VRHand_HullError", function()
    for ply, hands in pairs(vrHands) do
        if IsValid(ply) then
            for i = 1, 2 do
                local d = hands[SIDES[i]]
                local e = d and d.ent
                if e and IsValid(e) then
                    -- What this hand and the other hold, against last tick. A
                    -- hand holding a prop: the prop is its hull now, so its own
                    -- goes inert (collides with nothing; still chases, never
                    -- reports); holding a ragdoll it stays a hand. Any change
                    -- resets the pair cache (Held). Polled, not hooked: a
                    -- two-hand hold's first release fires no VRMod_Drop, and
                    -- left that hand inert -- through everything -- until the
                    -- next full drop.
                    local t = g_VR[e.vrSID]
                    t = t and t.heldItems
                    local mine, other = t and t[i == 1 and 2 or 1], t and t[i == 1 and 1 or 2]
                    mine, other = mine and mine.ent, other and other.ent
                    if mine ~= e.vrMine or other ~= e.vrOther then
                        e.vrMine, e.vrOther = mine, other
                        if not e.vrParked then
                            e:SetCollisionGroup(mine and IsValid(mine) and mine:GetClass() ~= "prop_ragdoll" and COLLISION_GROUP_IN_VEHICLE or COLLISION_GROUP_WEAPON)
                        end
                        e:CollisionRulesChanged()
                    end
                    local phys, c = d.phys, nil
                    if e.vrHasR and not e.vrParked and IsValid(phys) then
                        local cp, ca = phys:GetPos(), phys:GetAngles()
                        local f = ca:Forward()
                        cp.x, cp.y, cp.z = cp.x - f.x * OFF, cp.y - f.y * OFF, cp.z - f.z * OFF
                        local rp = e.vrRP
                        local ep, ea = WorldToLocal(cp, ca, rp, e.vrRA)
                        local d2 = ep:LengthSqr()
                        c = d2 < ERR_MAX and (d2 > ERR_P or ea.p * ea.p + ea.y * ea.y + ea.r * ea.r > ERR_A) and Contact(phys) or nil
                        if c then SendStuck(ply, i == 1, phys, c, cp, ca, rp, e.vrSeq) end
                    end
                    if not c and e.vrErrSent then SendClear(ply, i == 1) end
                    e.vrErrSent = c ~= nil
                end
            end
        end
    end
end)

-- What hand props don't touch. The world, brushes (doors, func_*) and
-- bodies: the client keeps hands and weapons out of those itself, exactly,
-- and a prop also catching on them would report error the client already
-- resolved. What that hand holds, and the weapon welded to a ragdoll it
-- holds (a hand on the arm pushed the gun, dragging the arm off the grip).
-- A prop the OTHER hand holds, when that hand is bare: a second hand
-- reaching in for a two-hand grab knocked the prop aside before its grab
-- landed. A weapon hull hits it (blocks, knocks, gets stopped by it), as
-- any other player's hands do; so is a ragdoll the other hand holds. This
-- is the one rule for hands against held things: sh_pickup_util's leaves
-- hands to it. Held changes on pickup/drop, and the hull with every
-- reshape (a new physics object); Tick resets the pair cache for the first.
local function Static(e) return e:IsWorld() or vrmod.utils.IsStaticBrush(e) or e:IsNPC() or e:IsPlayer() or e:IsNextBot() end
local function Held(hand, e)
    local t = g_VR[hand.vrSID]
    t = t and t.heldItems
    if not t then return false end
    local r = hand.vrRight
    local mine, other = t[r and 2 or 1], t[r and 1 or 2]
    if mine and (mine.ent == e or mine.ent == e.vrmod_source_ragdoll) then return true end
    return other and other.ent == e and not hand.vrGun and e:GetClass() ~= "prop_ragdoll" or false
end
hook.Add("ShouldCollide", "VRHand_NoWorld", function(a, b)
    if a.vrOwner then
        if Static(b) or Held(a, b) or b.vrOwner == a.vrOwner then return false end
    elseif b.vrOwner and (Static(a) or Held(b, a)) then
        return false
    end
end)

-- The physical-melee hull hits through the sweep only: its vphysics impact
-- (crush) damage would land a second hit on whatever it touches.
hook.Add("EntityTakeDamage", "VRHand_PMNoCrush", function(_, dmg)
    local inf = dmg:GetInflictor()
    if inf:IsValid() and inf.vrPM then return true end
end)

hook.Add("VRMod_Start", "VRHand_VRStart", function(ply) SpawnVRHands(ply) end)
hook.Add("PlayerSpawn", "VRHand_PlayerSpawn", function(ply) if vrmod.IsPlayerInVR(ply) then timer.Simple(0.1, function() if IsValid(ply) then SpawnVRHands(ply) end end) end end)
hook.Add("PlayerDeath", "VRHand_PlayerDeath", RemoveVRHands)
-- VR exit tears down fully, so a restart builds fresh hands exactly as the
-- first start does: reusing parked ones across sessions left the right
-- (weapon) hand, reshaped per weapon, passing through props
hook.Add("VRMod_Exit", "VRHand_VREnd", function(ply)
    DestroyVRHands(ply)
    ply.vrHT, ply.vrHB = nil, nil -- last session's hand pose is not this one's
end)
hook.Add("PlayerEnteredVehicle", "VRHand_Vehicle", RemoveVRHands)
-- Still seated while this runs; respawn once out
hook.Add("PlayerLeaveVehicle", "VRHand_Vehicle", function(ply) timer.Simple(0, function() SpawnVRHands(ply) end) end)
hook.Add("PlayerDisconnected", "VRHand_Disconnect", DestroyVRHands)

hook.Add("PreCleanupMap", "VRHand_PreCleanup", function()
    for ply, _ in pairs(vrHands) do
        RemoveVRHands(ply)
    end
end)

hook.Add("PostCleanupMap", "VRHand_PostCleanup", function()
    for _, ply in ipairs(player.GetHumans()) do
        if IsValid(ply) and vrmod.IsPlayerInVR(ply) then SpawnVRHands(ply) end
    end
end)

-- 5/s: frozen props in reach get vrFz, so client prediction (PropMass)
-- stops a hand or weapon on them at contact instead of a round trip later;
-- weapon hulls are 40-200kg and no mass check passes on a frozen 20kg prop.
-- Only changes are networked. Once a second: rebuild hands something else removed.
local MOVETYPE_VPHYSICS, FindInSphere, scanN = MOVETYPE_VPHYSICS, ents.FindInSphere, 0
timer.Create("VRHand_Repair", 0.2, 0, function()
    scanN = scanN % 5 + 1
    for ply, hands in pairs(vrHands) do
        if not IsValid(ply) then
            vrHands[ply] = nil
        else
            local r, l = hands.right, hands.left
            if scanN == 1 and not (r and IsValid(r.ent) and l and IsValid(l.ent)) then SpawnVRHands(ply) end
            if ply:Alive() then
                local t = FindInSphere(ply:WorldSpaceCenter(), 110)
                for k = 1, #t do
                    local e = t[k]
                    if not e.vrOwner and e:GetMoveType() == MOVETYPE_VPHYSICS then
                        local p = e:GetPhysicsObject()
                        local fz = IsValid(p) and not p:IsMotionEnabled()
                        if fz ~= (e.vrFz or false) then
                            e.vrFz = fz
                            e:SetNWBool("vrFz", fz)
                        end
                    end
                end
            end
        end
    end
end)

-- Fix: hands eating the player's own gunfire. FireBullets traces at COLLISION_GROUP_NONE,
-- which collides with the weapon group, and the muzzle Src sits inside the right-hand box
-- (StartSolid -> dead round point-blank). No stock group passes bullets while still pushing
-- props, so lift solidity on that shooter's own hands for the single trace and restore next
-- tick. Fires per-shot (not per-frame); nil-returns instantly for anything without hands.
hook.Add("EntityFireBullets", "VRHand_PassBullets", function(ent)
    local hands = vrHands[ent]
    if not hands then return end
    local re = hands.right and hands.right.ent
    local le = hands.left and hands.left.ent
    if IsValid(re) then re:SetNotSolid(true) end
    if IsValid(le) then le:SetNotSolid(true) end
    timer.Simple(0, function()
        if IsValid(re) then re:SetNotSolid(false) end
        if IsValid(le) then le:SetNotSolid(false) end
    end)
end)

-- Swing push is mostly the hull's own momentum: re-weigh live hulls
cvars.AddChangeCallback("vrmod_physmelee_force", function(_, _, new)
    local k = tonumber(new) or 1
    for _, hands in pairs(vrHands) do
        for i = 1, 2 do
            local d = hands[SIDES[i]]
            if d and d.pmMass and IsValid(d.ent) and d.ent.vrPM and IsValid(d.phys) then d.phys:SetMass(math.max(d.pmMass * k, 1)) end
        end
    end
end, "vrmod_physmelee_force")

-- Live toggle for vrmod_hand_physics: spawn/destroy props on change, no rejoin needed.
cvars.AddChangeCallback("vrmod_hand_physics", function(_, _, new)
    local on = tonumber(new) ~= 0
    for _, ply in ipairs(player.GetHumans()) do
        if on then
            if vrmod.IsPlayerInVR(ply) then SpawnVRHands(ply) end
        else
            DestroyVRHands(ply)
        end
    end
end, "vrmod_hand_physics")

-- ==========================================================================
-- FEET. Exactly the hand props, one per foot: NewHand builds them, Sim steps
-- them, Reshape / Park / Unpark handle them -- none of it changed. They're
-- driven by a second pose stream, vrmod_foot_pose (cl_character sends where
-- the body solve wants each foot, laid out like vrmod_hand_pose), played
-- back through the same HandPoseIn / HandPoseNow -- on a per-player stand-in
-- (FootSrc) that answers to what those and NewHand / Sim ask of a player
-- (IsValid, SteamID, GetPos, the vrH* pose fields), so the hand path itself
-- never sees a foot. The only foot-specific bits: a bigger sphere, a stale
-- stream parks the step (Sim would fall back to the frame's HANDS), and they
-- skip your own hands and whatever you're standing on.
-- ==========================================================================
local cv_footphysics = CreateConVar("vrmod_foot_physics", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED, "Enable server-side VR foot physics props (the hand props, on the feet).")
-- Kick strength: scales the foot props' mass (the hands' 20kg x this). A
-- shadow-driven prop pushes with its momentum, so this is how hard feet
-- shove and kick things -- and, heavier, how few props stop them.
local cv_footforce = CreateConVar("vrmod_foot_force", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED, "VR foot physics push/kick strength (scales the foot props' mass)", 0.05, 20)
local FOOT_MASS = 20
local function FootMass() return math.max(FOOT_MASS * cv_footforce:GetFloat(), 1) end
local FOOT_R = 3
local FMIN, FMAX = Vector(-FOOT_R, -FOOT_R, -FOOT_R), Vector(FOOT_R, FOOT_R, FOOT_R)
local vrFeet = {}

local FOOTSRC = {}
FOOTSRC.__index = FOOTSRC
function FOOTSRC:IsValid() return IsValid(self.ply) end
function FOOTSRC:SteamID() return self.ply:SteamID() end
function FOOTSRC:GetPos() return self.ply:GetPos() end
local function FootSrc(ply)
    local s = ply.vrFootSrc
    if not s then
        s = setmetatable({ply = ply}, FOOTSRC)
        ply.vrFootSrc = s
    end
    return s
end

util.AddNetworkString("vrmod_foot_pose")
vrmod.NetReceiveLimited("vrmod_foot_pose", 200, 512, function(_, ply)
    local lp, la, rp, ra = net.ReadVector(), net.ReadAngle(), net.ReadVector(), net.ReadAngle()
    local seq, ms = net.ReadUInt(16), net.ReadUInt(16)
    -- Near the player (NaN fails the comparison too)
    local o = ply:GetPos()
    if not (lp:DistToSqr(o) <= 40000 and rp:DistToSqr(o) <= 40000) then return end
    local s, now = FootSrc(ply), CurTime()
    HandPoseIn(s, lp, la, rp, ra, seq, ms, now < (s.vrHT or 0))
    s.vrHT = now + 0.25
end)

-- The hands' step, only while the foot stream is fresh
local function FootSim(self, phys, dt)
    local s = self.vrOwner
    if self.vrParked or CurTime() >= (s.vrHT or 0) then return SIM_NOTHING end
    return Sim(self, phys, dt)
end

local function NewFoot(ply, right)
    local d = NewHand(FootSrc(ply), right)
    if not d then return end
    local e = d.ent
    e.PhysicsSimulate = FootSim
    e.vrFootOf = ply
    Reshape(d, FootMass(), false, InitSphere, FOOT_R, "metal_bouncy")
    Tag(e, 1, nil, nil, FOOT_R)
    e:SetCollisionBounds(FMIN, FMAX)
    return d
end

local function SpawnVRFeet(ply)
    if not cv_footphysics:GetBool() or not IsValid(ply) or ply.vrHandsOff or not ply:Alive() or ply:InVehicle() or not vrmod.IsPlayerInVR(ply) then return end
    local feet = vrFeet[ply]
    if not feet then
        feet = {}
        vrFeet[ply] = feet
    end
    for i = 1, 2 do
        local d = feet[i]
        if not (d and IsValid(d.ent)) then
            feet[i] = NewFoot(ply, i == 1)
        elseif d.ent.vrParked then
            Unpark(d)
        end
    end
end

local function ParkVRFeet(ply)
    local feet = vrFeet[ply]
    if feet then Park(feet[1]) Park(feet[2]) end
end

local function DestroyVRFeet(ply)
    local feet = vrFeet[ply]
    if feet then
        for i = 1, 2 do
            local d = feet[i]
            if d and IsValid(d.ent) then d.ent:Remove() end
        end
        vrFeet[ply] = nil
    end
    if IsValid(ply) then ply.vrFootSrc = nil end -- last session's stream is not this one's
end

-- On top of the hands' rules (which already keep feet off the world, brushes,
-- bodies, each other and what's held): not your own hands, not your ground.
hook.Add("ShouldCollide", "VRFoot_Rules", function(a, b)
    local pa, pb = a.vrFootOf, b.vrFootOf
    if pa then
        if b.vrOwner == pa or b == a.vrGround then return false end
    elseif pb then
        if a.vrOwner == pb or a == b.vrGround then return false end
    end
end)

-- Per tick: the ground under the player (pair rules are cached, so a change
-- has to reset them), and a stale stream or a ragdoll carry parks the feet.
hook.Add("Tick", "VRFoot_Tick", function()
    local now = CurTime()
    for ply, feet in pairs(vrFeet) do
        if not IsValid(ply) then
            vrFeet[ply] = nil
        else
            local g = ply:GetGroundEntity()
            g = IsValid(g) and g or nil
            local off = ply.vrHandsOff
            for i = 1, 2 do
                local d = feet[i]
                local e = d and d.ent
                if e and IsValid(e) then
                    if off and not e.vrParked then Park(d) end
                    if e.vrGround ~= g then
                        e.vrGround = g
                        e:CollisionRulesChanged()
                    end
                    local fresh = now < (FootSrc(ply).vrHT or 0)
                    if fresh ~= e.vrFresh then
                        e.vrFresh = fresh
                        e:SetNotSolid(not fresh)
                        -- asleep, it gets no PhysicsSimulate to wake itself
                        if fresh and IsValid(d.phys) then d.phys:Wake() end
                    end
                end
            end
        end
    end
end)

-- Your own gunfire passes your feet, as it does your hands
hook.Add("EntityFireBullets", "VRFoot_PassBullets", function(ent)
    local feet = vrFeet[ent]
    if not feet then return end
    local a, b = feet[1] and feet[1].ent, feet[2] and feet[2].ent
    if IsValid(a) then a:SetNotSolid(true) end
    if IsValid(b) then b:SetNotSolid(true) end
    timer.Simple(0, function()
        if IsValid(a) and a.vrFresh then a:SetNotSolid(false) end
        if IsValid(b) and b.vrFresh then b:SetNotSolid(false) end
    end)
end)

hook.Add("VRMod_Start", "VRFoot_VRStart", SpawnVRFeet)
hook.Add("PlayerSpawn", "VRFoot_PlayerSpawn", function(ply) if vrmod.IsPlayerInVR(ply) then timer.Simple(0.1, function() if IsValid(ply) then SpawnVRFeet(ply) end end) end end)
hook.Add("PlayerDeath", "VRFoot_PlayerDeath", ParkVRFeet)
hook.Add("PlayerEnteredVehicle", "VRFoot_Vehicle", ParkVRFeet)
hook.Add("PlayerLeaveVehicle", "VRFoot_Vehicle", function(ply) timer.Simple(0, function() SpawnVRFeet(ply) end) end)
hook.Add("VRMod_Exit", "VRFoot_VREnd", DestroyVRFeet)
hook.Add("PlayerDisconnected", "VRFoot_Disconnect", DestroyVRFeet)
hook.Add("PreCleanupMap", "VRFoot_PreCleanup", function()
    for ply in pairs(vrFeet) do ParkVRFeet(ply) end
end)
hook.Add("PostCleanupMap", "VRFoot_PostCleanup", function()
    for _, ply in ipairs(player.GetHumans()) do
        if IsValid(ply) and vrmod.IsPlayerInVR(ply) then SpawnVRFeet(ply) end
    end
end)
timer.Create("VRFoot_Repair", 1, 0, function()
    for ply, feet in pairs(vrFeet) do
        if IsValid(ply) and not ply.vrHandsOff and ply:Alive() and not ply:InVehicle() and not (feet[1] and IsValid(feet[1].ent) and feet[2] and IsValid(feet[2].ent)) then SpawnVRFeet(ply) end
    end
end)
cvars.AddChangeCallback("vrmod_foot_physics", function(_, _, new)
    local on = tonumber(new) ~= 0
    for _, ply in ipairs(player.GetHumans()) do
        if on then
            if vrmod.IsPlayerInVR(ply) then SpawnVRFeet(ply) end
        else
            DestroyVRFeet(ply)
        end
    end
end, "vrmod_foot_physics")
-- Re-weigh live feet
cvars.AddChangeCallback("vrmod_foot_force", function()
    local m = FootMass()
    for _, feet in pairs(vrFeet) do
        for i = 1, 2 do
            local d = feet[i]
            if d and IsValid(d.ent) and IsValid(d.phys) then d.phys:SetMass(m) end
        end
    end
end, "vrmod_foot_force")
