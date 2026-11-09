g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}
local U = vrmod.utils
-- Native methods as upvalues. Vector/Angle __index is native, so v.x, v.y,
-- v.z is three calls into C, v:Unpack() two (index + call), VUnpack(v) one.
local VEC, ANG = FindMetaTable("Vector"), FindMetaTable("Angle")
local VUnpack, VSetU, VSet, VDistToSqr = VEC.Unpack, VEC.SetUnpacked, VEC.Set, VEC.DistToSqr
local AUnpack, ASetU, ASet, AForward, ARight, AUp = ANG.Unpack, ANG.SetUnpacked, ANG.Set, ANG.Forward, ANG.Right, ANG.Up
local eIsValid = FindMetaTable("Entity").IsValid
local util_TraceLine, util_TraceHull = util.TraceLine, util.TraceHull
local cl_effectmodel = CreateClientConVar("vrmod_melee_fist_collisionmodel", "models/props_junk/PopCan01a.mdl", true, FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE)
--GLOBALS
vrmod.DEFAULT_RADIUS = 1.69
vrmod.DEFAULT_REACH = 3.0
vrmod.DEFAULT_MINS = Vector(-0.75, -0.75, -1.25)
vrmod.DEFAULT_MAXS = Vector(0.75, 0.75, 11)
vrmod.DEFAULT_ANGLES = Angle(0, 0, 0)
vrmod.DEFAULT_OFFSET = 3
vrmod.MODEL_OVERRIDES = {
    weapon_physgun = "models/weapons/w_physics.mdl",
    weapon_physcannon = "models/weapons/w_physics.mdl",
}

-- Physical melee (right hand), every weapon. The weapon is the segment grip ->
-- tip in the tracked right-hand pose's space. The viewmodel (vmi offset) and
-- the worldmodel (hand-bone merge) both hang rigidly off that pose, so one
-- segment serves both modes and drives the wall bend (GunWallPivot), the hit
-- sweep (sh_combat) and the server hand hull (sv_physhands).
--   tip/grip  hand-local; guns have no tip and use their live muzzle
--   r  half-thickness   m  hull mass   impact  sh_combat impact id
--   dmg  damage of a full-speed hit (vrmod_physmelee_speed); without it,
--        the weapon's own (SWEP Primary.Damage), or a gun's 10% plus fists'
--   min  contact speed (u/s) a hit needs   f  push per u/s
--   strip  the trigger's own swing is removed (C++ eye-trace melee)
-- Tune a tip live with vrmod_physmelee_tip + vrmod_physmelee_debug 1.
-- Entries here are overrides; vrmod.PhysMeleeDef covers everything else.
vrmod.PHYSMELEE = {
    weapon_crowbar   = {tip = Vector(5.53, 1, 27.63), grip = Vector(3, 1, -3), r = 1.5, m = 200, dmg = 10, min = 250, f = 5, impact = 1, strip = true},
    weapon_stunstick = {tip = Vector(5, 1, 24), grip = Vector(3, 1, -3), r = 1.5, m = 150, dmg = 10, min = 250, f = 4, impact = 2, strip = true},
}
local PHYSMELEE = vrmod.PHYSMELEE
-- Swing push: scales the server hull's mass (what really throws things on a
-- swing) and each hit's damage force. Live; sv_physhands re-weighs hulls.
CreateConVar("vrmod_physmelee_force", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Physical melee swing push multiplier (hull mass and hit force)", 0.05, 20)
-- Swing damage: the weapon's damage at vrmod_physmelee_speed tip speed,
-- scaled by speed up to double, times this
CreateConVar("vrmod_physmelee_damage", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Physical melee damage multiplier", 0, 10)
CreateConVar("vrmod_physmelee_speed", "400", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Tip speed (units/s) for a physical melee hit's full damage; faster hits up to double", 50, 3000)

-- Def for any weapon, cached per class. Overrides first; then melee (NotAGun,
-- a melee holdtype, or its base adapter says so) gets a tip up the hand's
-- axis, as long as its worldmodel; everything else is a gun (grip -> live
-- muzzle). Tools whose beam or screen sits at the muzzle are left out.
local PM_GUN = {r = 1.5, m = 40, min = 300, f = 2, impact = 1}
local PM_SKIP = {weapon_physgun = true, weapon_physcannon = true, gmod_tool = true, gmod_camera = true}
local PM_MELEE = {melee = 1, melee2 = 1, knife = 3}
local pmAuto = {}
function vrmod.PhysMeleeDef(wep)
    local cls = wep:GetClass()
    local d = PHYSMELEE[cls] or pmAuto[cls]
    if d ~= nil then return d end
    if PM_SKIP[cls] or not U.IsValidWep(wep) then
        d = false
    else
        local f, WA = wep.GetHoldType, vrmod.weaponadapter
        local hi = PM_MELEE[f and f(wep) or ""]
        if hi or wep.NotAGun or WA and WA.Classify(wep) == WA.MELEE then
            local mn, mx = wep:GetModelBounds()
            local L = mx.x - mn.x
            if mx.y - mn.y > L then L = mx.y - mn.y end
            if mx.z - mn.z > L then L = mx.z - mn.z end
            L = L - 4
            if L < 8 then L = 8 elseif L > 60 then L = 60 end
            d = {tip = Vector(4, 1, L), grip = Vector(3, 1, -3), r = 1.5, m = 120, min = 250, f = 4, impact = hi or 1}
        else
            d = PM_GUN
        end
    end
    pmAuto[cls] = d
    return d
end

vrmod.modelCache = {}
vrmod.collisionSpheres = {}
vrmod.collisionBoxes = {}
vrmod._collisionShapeByHand = { left = nil, right = nil }

-- Pre-allocated hand iterator — avoids creating {"left","right"} table every frame
local HANDS = {"left", "right"}
local pending = {}

local function DebugEnabled()
    local cv = GetConVar("vrmod_debug_physics")
    return cv and cv:GetBool() or false
end

local function GetWeaponCollisionBox(phys, isVertical)
    local mins, maxs = phys:GetAABB()
    if not mins or not maxs then
        if DebugEnabled() then vrmod.logger.Debug("GetWeaponCollisionBox: Invalid AABB, returning defaults") end
        return vrmod.DEFAULT_MINS, vrmod.DEFAULT_MAXS, isVertical, vrmod.DEFAULT_MINS, vrmod.DEFAULT_MAXS
    end

    local amin, amax = mins, maxs -- Store raw AABB for return
    -- Calculate the extents of the AABB
    local extents = (maxs - mins) * 0.5
    if isVertical then
        -- Vertical alignment: prioritize z-axis, swap x and z extents
        mins = Vector(-extents.z * 0.35, -extents.y * 0.35, -extents.x)
        maxs = Vector(extents.z * 0.35, extents.y * 0.35, extents.x)
        if DebugEnabled() then vrmod.logger.Debug("GetWeaponCollisionBox: Vertical-aligned (z-axis) | Mins: %s, Maxs: %s", tostring(mins), tostring(maxs)) end
    else
        -- Forward alignment: prioritize x-axis
        mins = Vector(-extents.x * 0.8, -extents.y * 0.35, -extents.z * 0.35)
        maxs = Vector(extents.x * 0.8, extents.y * 0.35, extents.z * 0.35)
        if DebugEnabled() then vrmod.logger.Debug("GetWeaponCollisionBox: Forward-aligned (x-axis) | Mins: %s, Maxs: %s", tostring(mins), tostring(maxs)) end
    end

    -- Ensure the box isn't too small by enforcing minimum dimensions
    local minSize = vrmod.DEFAULT_RADIUS * 0.5
    mins.x = math.min(mins.x, -minSize)
    mins.y = math.min(mins.y, -minSize)
    mins.z = math.min(mins.z, -minSize)
    maxs.x = math.max(maxs.x, minSize)
    maxs.y = math.max(maxs.y, minSize)
    maxs.z = math.max(maxs.z, minSize)
    return mins, maxs, isVertical, amin, amax
end

local function DetectMeleeFromModel(modelPath, phys, offsetAng)
    if not IsValid(phys) then return false end
    -- 1. Filename hints
    local lowerPath = string.lower(modelPath)
    if lowerPath:find("crowbar") or lowerPath:find("knife") or lowerPath:find("melee") or lowerPath:find("bat") or lowerPath:find("katana") or lowerPath:find("sword") then return true end
    -- 2. Get raw bounding box verts
    local mins, maxs = phys:GetAABB()
    local verts = {Vector(mins.x, mins.y, mins.z), Vector(mins.x, mins.y, maxs.z), Vector(mins.x, maxs.y, mins.z), Vector(mins.x, maxs.y, maxs.z), Vector(maxs.x, mins.y, mins.z), Vector(maxs.x, mins.y, maxs.z), Vector(maxs.x, maxs.y, mins.z), Vector(maxs.x, maxs.y, maxs.z)}
    -- 3. Apply VRMod offsetAng if provided (align model to hand space)
    local ang = offsetAng or Angle(0, 0, 0)
    for i = 1, #verts do
        verts[i]:Rotate(ang)
    end

    -- 4. Measure extents in aligned space
    local minAligned = Vector(verts[1].x, verts[1].y, verts[1].z)
    local maxAligned = Vector(verts[1].x, verts[1].y, verts[1].z)
    for i = 2, #verts do
        minAligned.x = math.min(minAligned.x, verts[i].x)
        minAligned.y = math.min(minAligned.y, verts[i].y)
        minAligned.z = math.min(minAligned.z, verts[i].z)
        maxAligned.x = math.max(maxAligned.x, verts[i].x)
        maxAligned.y = math.max(maxAligned.y, verts[i].y)
        maxAligned.z = math.max(maxAligned.z, verts[i].z)
    end

    local sizeX = maxAligned.x - minAligned.x
    local sizeY = maxAligned.y - minAligned.y
    local sizeZ = maxAligned.z - minAligned.z
    local longest = math.max(sizeX, sizeY, sizeZ)
    local shortest = math.min(sizeX, sizeY, sizeZ)
    if shortest < 0.01 then return false end
    local aspect = longest / shortest
    -- 5. Melee = longest axis is aligned Z (up in hand space) + long/thin shape
    if sizeZ == longest and aspect >= 4.5 then return true end
    return false
end

-- COLLISIONS
-- Params for a model that couldn't be measured (a fresh table each: the sync marks it sent)
local function DefaultParams()
    return {radius = vrmod.DEFAULT_RADIUS, reach = vrmod.DEFAULT_REACH, mins_horizontal = vrmod.DEFAULT_MINS, maxs_horizontal = vrmod.DEFAULT_MAXS, mins_vertical = vrmod.DEFAULT_MINS, maxs_vertical = vrmod.DEFAULT_MAXS, angles = vrmod.DEFAULT_ANGLES, computed = true, isMelee = false}
end

function U.ComputePhysicsParams(modelPath)
    if not modelPath or modelPath == "" then
        if DebugEnabled() then vrmod.logger.Warn("Invalid or empty model path, caching defaults") end
        vrmod.modelCache[modelPath] = DefaultParams()
        return
    end

    local originalModelPath = modelPath
    -- Fallback for c_models to w_models
    if modelPath:match("^models/weapons/c_") then
        local baseName = modelPath:match("models/weapons/c_(.-)%.mdl")
        if baseName then
            local fallback = "models/weapons/w_" .. baseName .. ".mdl"
            if file.Exists(fallback, "GAME") then
                if DebugEnabled() then vrmod.logger.Debug("Replacing %s with valid worldmodel %s", modelPath, fallback) end
                modelPath = fallback
            else
                if DebugEnabled() then vrmod.logger.Debug("No valid fallback for %s, caching defaults", modelPath) end
                vrmod.modelCache[originalModelPath] = DefaultParams()
                return
            end
        end
    end

    -- Already computed?
    if vrmod.modelCache[originalModelPath] and vrmod.modelCache[originalModelPath].computed then return end
    -- Retry protection
    pending[originalModelPath] = pending[originalModelPath] or {
        attempts = 0
    }

    if pending[originalModelPath].attempts >= 2 then
        if DebugEnabled() then vrmod.logger.Warn("Max retries (2) reached for %s, caching defaults", originalModelPath) end
        vrmod.modelCache[originalModelPath] = DefaultParams()

        pending[originalModelPath] = nil
        return
    end

    pending[originalModelPath].attempts = pending[originalModelPath].attempts + 1
    util.PrecacheModel(modelPath)
    local ent = CLIENT and ents.CreateClientProp(modelPath) or ents.Create("prop_physics")
    if not IsValid(ent) then
        if DebugEnabled() then vrmod.logger.Err("Failed to spawn %s (attempt %d)", modelPath, pending[originalModelPath].attempts) end
        pending[originalModelPath].lastAttempt = CurTime()
        return
    end

    ent:SetModel(modelPath)
    ent:SetNoDraw(true)
    ent:PhysicsInit(SOLID_VPHYSICS)
    ent:SetMoveType(MOVETYPE_NONE)
    ent:Spawn()
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        local ang = Angle(0, 0, 0)
        local currentvmi = g_VR.currentvmi
        if currentvmi then ang = currentvmi.offsetAng end
        local isMelee = DetectMeleeFromModel(modelPath, phys, ang)
        local mins_horizontal, maxs_horizontal, mins_vertical, maxs_vertical
        if isMelee then
            mins_vertical, maxs_vertical = GetWeaponCollisionBox(phys, true)
            mins_horizontal, maxs_horizontal = vrmod.DEFAULT_MINS, vrmod.DEFAULT_MAXS
        else
            mins_horizontal, maxs_horizontal = GetWeaponCollisionBox(phys, false)
            mins_vertical, maxs_vertical = GetWeaponCollisionBox(phys, true)
        end

        local mins, maxs = phys:GetAABB()
        local reach = math.max(maxs.x - mins.x, maxs.y - mins.y, maxs.z - mins.z) * 0.5
        reach = math.Clamp(reach * 1.5, 6.6, 50)
        vrmod.modelCache[originalModelPath] = {
            radius = reach,
            reach = reach,
            mins_horizontal = mins_horizontal or vrmod.DEFAULT_MINS,
            maxs_horizontal = maxs_horizontal or vrmod.DEFAULT_MAXS,
            mins_vertical = mins_vertical or vrmod.DEFAULT_MINS,
            maxs_vertical = maxs_vertical or vrmod.DEFAULT_MAXS,
            angles = vrmod.DEFAULT_ANGLES,
            computed = true,
            isMelee = isMelee
        }

        if DebugEnabled() then vrmod.logger.Info("Computed collision boxes for %s → reach: %.2f units, melee: %s", modelPath, reach, tostring(isMelee)) end
    else
        if DebugEnabled() then vrmod.logger.Warn("No valid physobj for %s, attempt %d", modelPath, pending[originalModelPath].attempts) end
    end

    ent:Remove()
    pending[originalModelPath].lastAttempt = CurTime()
    if pending[originalModelPath].attempts >= 2 then pending[originalModelPath] = nil end
end

function U.GetModelParams(modelPath, ply, offsetAng)
    if vrmod.modelCache[modelPath] and vrmod.modelCache[modelPath].computed then
        local cache = vrmod.modelCache[modelPath]
        local ang = vrmod.GetRightHandAng(ply)
        local mins = cache.isMelee and cache.mins_vertical or cache.mins_horizontal
        local maxs = cache.isMelee and cache.maxs_vertical or cache.maxs_horizontal
        -- Validate that parameters aren't just defaults
        local isDefault = mins == vrmod.DEFAULT_MINS and maxs == vrmod.DEFAULT_MAXS and cache.radius == vrmod.DEFAULT_RADIUS and cache.reach == vrmod.DEFAULT_REACH
        if not isDefault then
            -- Only send once per model
            if not cache.sent then
                net.Start("vrmod_sync_model_params")
                net.WriteString(modelPath)
                net.WriteFloat(cache.radius)
                net.WriteFloat(cache.reach)
                net.WriteVector(mins)
                net.WriteVector(maxs)
                net.WriteVector(cache.mins_vertical)
                net.WriteVector(cache.maxs_vertical)
                net.WriteAngle(cache.angles)
                if CLIENT then net.SendToServer() else net.Broadcast() end
                if DebugEnabled() then vrmod.logger.Info("GetModelParams: Sent computed params for %s to %s", modelPath, CLIENT and "server" or "clients") end

                -- mark as sent
                cache.sent = true
            end
        else
            if DebugEnabled() then vrmod.logger.Info("GetModelParams: Skipping sync for %s due to default parameters", modelPath) end
        end
        return cache.radius, cache.reach, mins, maxs, ang, cache.isMelee
    end

    -- Schedule computation if needed
    if not pending[modelPath] then
        pending[modelPath] = {
            attempts = 0
        }

        timer.Simple(0, function()
            U.ComputePhysicsParams(modelPath)
            -- Optionally re-call GetModelParams to trigger sync after computation
            if vrmod.modelCache[modelPath] and vrmod.modelCache[modelPath].computed then U.GetModelParams(modelPath, ply, offsetAng) end
        end)

        if DebugEnabled() then vrmod.logger.Debug("GetModelParams: Scheduled computation for %s", modelPath) end
    end
    return vrmod.DEFAULT_RADIUS, vrmod.DEFAULT_REACH, vrmod.DEFAULT_MINS, vrmod.DEFAULT_MAXS, vrmod.GetRightHandAng(ply), false
end

function U.GetWeaponMeleeParams(wep, ply, hand)
    local model = cl_effectmodel:GetString()
    local offsetAng = vrmod.DEFAULT_ANGLES
    if hand == "right" then
        local class, vm = U.WepInfo(wep)
        if not class then return vrmod.DEFAULT_RADIUS, vrmod.DEFAULT_REACH end
        if CLIENT then
            local vmInfo = g_VR.viewModelInfo[class]
            offsetAng = vmInfo and vmInfo.offsetAng or vrmod.DEFAULT_ANGLES
            model = vm
        else
            model = vrmod.MODEL_OVERRIDES[class] or wep:GetModel()
        end
        return U.GetModelParams(model, ply, offsetAng)
    else
        return U.GetModelParams(model, ply, offsetAng)
    end
end

function U.AdjustCollisionsBox(pos, ang, isMelee)
    local f, l = isMelee and 3 or 10, isMelee and 1 or 1.5
    local fx, fy, fz = VUnpack(AForward(ang))
    local rx, ry, rz = VUnpack(ARight(ang))
    local ux, uy, uz = VUnpack(AUp(ang))
    local px, py, pz = VUnpack(pos)
    return Vector(px + fx * f - rx * l + ux * 4, py + fy * f - ry * l + uy * 4, pz + fz * f - rz * l + uz * 4)
end

local function GetClimbingGripState()
    local climb = vrmod.climbing
    if not climb then return false, false end
    return climb.gripLeft or false, climb.gripRight or false
end
U.GetClimbingGripState = GetClimbingGripState

-- Which hand holds the gun: VRMod's flag, ArcVR's as fallback
local function GunLeft() return g_VR.gunInLeftHand or (ArcticVR and ArcticVR.GunInLeftHand) or false end
U.GunInLeftHand = GunLeft

-- What the client keeps hands and weapons out of: the world (static props
-- included), brush entities like doors, and bodies (NPCs, players) by
-- hitbox -- weapons bend off them through this filter (_bodies, line traces
-- hit hitboxes), hands resolve against the hitboxes directly (BodyPush), as
-- a hull trace would only see a body's coarse box. These are exact on the
-- client. Props and ragdolls are not: the server simulates them, and the
-- client only sees them interpolated, ~100ms late. They belong to the
-- server hand props, whose error the client takes on (ApplyHullError) --
-- if a prop gets stuck, the hand and weapon do.
local function Body(e) return e:IsNPC() or e:IsPlayer() or e:IsNextBot() end
-- Brush entities by their model ("*N"), not GetSolid: func_brush and doors
-- are SOLID_VPHYSICS, so a SOLID_BSP test let hands through them here while
-- the server hull caught on them. Physics brushes (func_physbox) move, so
-- they stay props.
local MOVETYPE_VPHYSICS = MOVETYPE_VPHYSICS
local function Brush(e)
    if e:GetSolid() == SOLID_BSP then return true end
    local m = e:GetModel()
    return m ~= nil and m:byte(1) == 42 and e:GetMoveType() ~= MOVETYPE_VPHYSICS
end
-- Both are fixed for an entity's life, and the trace filters ask them of
-- every entity every trace passes: cached per entity (weak keys). 1 static
-- brush, 2 body, 0 anything else.
local kind = setmetatable({}, {__mode = "k"})
local function Kind(e)
    local k = kind[e]
    if k == nil then
        k = Brush(e) and 1 or Body(e) and 2 or 0
        kind[e] = k
    end
    return k
end
U.IsStaticBrush = function(e) return Kind(e) == 1 end
local _me, _bodies = nil, false
local function CollideFilter(e)
    local k = kind[e]
    if k == nil then
        if not eIsValid(e) then return true end
        k = Kind(e)
    end
    if k == 1 then return true end
    return k == 2 and _bodies and e ~= _me
end

-- Broad phase: anything solid within r of a hand
local _nOut, _nMin, _nMax = {}, Vector(), Vector()
local _nTr = {mins = _nMin, maxs = _nMax, mask = MASK_SHOT_HULL, filter = CollideFilter, output = _nOut}
local function Nearby(pos, r)
    VSetU(_nMin, -r, -r, -r)
    VSetU(_nMax, r, r, r)
    _nTr.start, _nTr.endpos = pos, pos
    util_TraceHull(_nTr)
    return _nOut.Hit
end

local cvCollisions = CreateClientConVar("vrmod_collisions", "1", true, false, "Enable VR hand/weapon wall collisions", 0, 1)
local collOn = cvCollisions:GetBool()
cvars.AddChangeCallback("vrmod_collisions", function() collOn = cvCollisions:GetBool() end, "vrmod_collisions_cache")
function U.CollisionsPreCheck(leftPos, rightPos)
    local ply = LocalPlayer()
    -- cvCollisions: the settings checkbox existed but was never read — the
    -- broad-phase is the one place that gates both hand clip and weapon pushout.
    if not collOn or not g_VR.active or not IsValid(ply) or not ply:GetNWBool("vrmod_server_enforce_collision", true) or ply:GetMoveType() == MOVETYPE_NOCLIP or not ply:Alive() or not vrmod.IsPlayerInVR(ply) or ply:InVehicle() then
        vrmod._collisionNearby = false
        return
    end

    local leftGrip, rightGrip = GetClimbingGripState()
    -- The gun hand gets the long reach, whichever hand that is
    local big = U.IsValidWep(ply:GetActiveWeapon()) and 69 or 30
    local gl = big == 69 and GunLeft()
    _me, _bodies = ply, true
    vrmod._collisionNearby = not leftGrip and Nearby(leftPos, gl and big or 30)
        or not rightGrip and Nearby(rightPos, gl and 30 or big) or false
end

-- Gun/wall pivot: the gun is the segment grip -> muzzle. Entering the world,
-- it rotates about the grip until the muzzle rests a clearance off the
-- surface, swinging the way the barrel already leaned. cl_vrmod runs it on
-- the gun hand's tracked pose and writes the result back, so everything built
-- from that pose follows: the viewmodel in either hand, worldmodels through
-- the body IK, the network frame and the server's aim.
local cv_gunClear = CLIENT and CreateClientConVar("vrmod_gunwall_clearance", "0", true, false, "Gap kept between the muzzle and walls, in units", 0, 8)
local gunClear = cv_gunClear and cv_gunClear:GetFloat() or 0
if CLIENT then cvars.AddChangeCallback("vrmod_gunwall_clearance", function() gunClear = cv_gunClear:GetFloat() end, "vrmod_gunwall_clearance") end
local math_atan2, math_deg, math_cos, math_sin = math.atan2, math.deg, math.cos, math.sin
-- ROUNDED EDGES (hands and weapons). A hand lays its palm on the face it
-- touches and a barrel bends off it, and map brushes are flat faces meeting
-- at sharp edges: sliding from a wall over a 45deg bevel onto a floor turned
-- both face by face, 45deg at a time. Here the touched face's neighbours are
-- found by probing, and the normal used is the one the surface would have
-- if every edge between them were filleted (radius vrmod_collision_round):
-- for a convex edge exactly -- the nearest point on the pair shrunk by the
-- radius -- and a polynomial smooth union for a concave one. A function of
-- where the point is, not a transition: standing still on a bevel's edge
-- the hand rests half-turned, as on a rounded edge. The distance to that
-- rounded surface comes with it, so a hand also MOVES over the rounding:
-- the box hull's own path has corners at every edge (and sits further off
-- a slope than a wall), which the palm used to follow. World and brushes.
local cv_round = CLIENT and CreateClientConVar("vrmod_collision_round", "2", true, false, "Rounds map brush edges for hand and weapon contact: fillet radius in units (0 = sharp edges)", 0, 16)
local roundRho = cv_round and cv_round:GetFloat() or 0
if CLIENT then cvars.AddChangeCallback("vrmod_collision_round", function() roundRho = cv_round:GetFloat() end, "vrmod_collision_round") end
local function RoundFilter(e)
    local k = kind[e]
    if k == nil then
        if not eIsValid(e) then return true end
        k = Kind(e)
    end
    return k == 1
end
local R_EPS = 0.05
local _rOut, _rS, _rE = {}, Vector(), Vector()
local _rTr = {start = _rS, endpos = _rE, mask = MASK_SHOT_HULL, filter = RoundFilter, output = _rOut}
-- Line from (x, y, z) along unit (dx, dy, dz); true on a clean hit (_rOut)
local function RRay(x, y, z, dx, dy, dz, len)
    VSetU(_rS, x, y, z)
    VSetU(_rE, x + dx * len, y + dy * len, z + dz * len)
    util_TraceLine(_rTr)
    return _rOut.Hit and not _rOut.StartSolid
end
-- Down onto the surface from s out along t, off face (p, n), 1.25 s deep:
-- a 45deg face lands inside it, not on its end (where float noise decided
-- hit or miss); deeper reached past thin trims. 0: face n again; 1: another
-- face (in _rOut); 2: it drops clean away. A drop looks back under the edge
-- for the face below it (convex).
local function Under(px, py, pz, nx, ny, nz, tx, ty, tz, s)
    local ex, ey, ez = px + nx * R_EPS + tx * s, py + ny * R_EPS + ty * s, pz + nz * R_EPS + tz * s
    local d = s * 1.25 + R_EPS
    if RRay(ex, ey, ez, -nx, -ny, -nz, d) then
        local hx, hy, hz = VUnpack(_rOut.HitNormal)
        if hx * nx + hy * ny + hz * nz > 0.999 then
            hx, hy, hz = VUnpack(_rOut.HitPos)
            local o = (hx - px) * nx + (hy - py) * ny + (hz - pz) * nz
            if o < 0.1 and o > -0.1 then return 0 end
        end
        return 1
    end
    return RRay(ex - nx * d, ey - ny * d, ez - nz * d, -tx, -ty, -tz, 1.5 * s + R_EPS) and 1 or 2
end
local function HitOut(convex)
    local hx, hy, hz = VUnpack(_rOut.HitPos)
    local nx, ny, nz = VUnpack(_rOut.HitNormal)
    return hx, hy, hz, nx, ny, nz, convex
end
-- The nearest face along t off face (p, n) within rp that isn't it: point,
-- normal and whether the edge to it is convex -- or nothing. Along the
-- surface first (a face rising: concave), then down from out along t -- far
-- first, so a flat run costs two rays -- nearest first after that, so a
-- short face isn't skipped for the one past it. Found below the face's plane
-- means convex: how it was found says so, where a test on the two hit points
-- can't (both on the edge itself, it's a coin toss).
local function Probe(px, py, pz, nx, ny, nz, tx, ty, tz, rp)
    local lim, ax, ay, az, anx, any, anz = rp
    if RRay(px + nx * R_EPS, py + ny * R_EPS, pz + nz * R_EPS, tx, ty, tz, rp) then
        ax, ay, az, anx, any, anz = HitOut(false)
        lim = rp * _rOut.Fraction
    end
    local r = Under(px, py, pz, nx, ny, nz, tx, ty, tz, lim)
    if r ~= 0 then
        local fx, fy, fz, fnx, fny, fnz
        if r == 1 then fx, fy, fz, fnx, fny, fnz = HitOut(true) end
        for k = 1, 2 do
            if Under(px, py, pz, nx, ny, nz, tx, ty, tz, lim * k / 3) == 1 then return HitOut(true) end
        end
        if fx then return fx, fy, fz, fnx, fny, fnz, true end
    end
    if ax then return ax, ay, az, anx, any, anz, false end
end
-- Normal and distance at x off the pair face a (p, n) / face b (q, m),
-- filleted to rho. Convex: x against the pair shrunk by rho -- off face a,
-- off face b, or round the edge, where the offset from the edge is
-- al*n + be*m (al, be solving it against both faces) -- less rho. Concave:
-- a polynomial smooth union (distance and its gradient). Unit normal.
local function Pair(xx, xy, xz, px, py, pz, nx, ny, nz, qx, qy, qz, mx, my, mz, rho, convex)
    local c = nx * mx + ny * my + nz * mz
    local a = (xx - px) * nx + (xy - py) * ny + (xz - pz) * nz
    local b = (xx - qx) * mx + (xy - qy) * my + (xz - qz) * mz
    local al, be, d
    if convex then
        local k = 1 - c * c
        if k < 1e-3 then return nx, ny, nz, a end -- (near) parallel: no edge
        a, b = a + rho, b + rho
        al, be = (a - b * c) / k, (b - a * c) / k
        if be <= 0 then return nx, ny, nz, a - rho end
        if al <= 0 then return mx, my, mz, b - rho end
        d = (al * al + be * be + 2 * al * be * c) ^ 0.5
        local l = 1 / d
        return (nx * al + mx * be) * l, (ny * al + my * be) * l, (nz * al + mz * be) * l, d - rho
    end
    al = 0.5 + 0.5 * (b - a) / rho
    if al < 0 then al = 0 elseif al > 1 then al = 1 end
    be = 1 - al
    d = b + (a - b) * al - rho * al * be
    local ox, oy, oz = nx * al + mx * be, ny * al + my * be, nz * al + mz * be
    local l = ox * ox + oy * oy + oz * oz
    if l < 1e-8 then return nx, ny, nz, a end
    l = l ^ -0.5
    return ox * l, oy * l, oz * l, d
end
-- Rounded normal at x for contact with face (p, n) -- n a true face normal --
-- (slot 1 left hand, 2 right hand, 3 barrel), as numbers, with x's distance
-- off the rounded surface. The neighbour that turns it most wins (one edge
-- at a time).
-- Probed along the face's axes (brush edges mostly run along them), out to
-- half again the fillet's reach. Cached while x and the face don't move.
local _rSlot = {}
for i = 1, 3 do _rSlot[i] = {x = 0, y = 0, z = 0, ox = 0, oy = 0, oz = 0, nx = 0, ny = 0, nz = 0, d = 0, ok = false} end
local function RoundNormal(slot, xx, xy, xz, px, py, pz, nx, ny, nz, rho)
    local sc = _rSlot[slot]
    if sc.ok and sc.nx == nx and sc.ny == ny and sc.nz == nz then
        local dx, dy, dz = sc.x - xx, sc.y - xy, sc.z - xz
        if dx * dx + dy * dy + dz * dz < 1e-6 then return sc.ox, sc.oy, sc.oz, sc.d end
    end
    local t1x, t1y, t1z
    if nz < 0.9 and nz > -0.9 then
        local l = (nx * nx + ny * ny) ^ -0.5
        t1x, t1y, t1z = ny * l, -nx * l, 0
    else
        local l = (ny * ny + nz * nz) ^ -0.5
        t1x, t1y, t1z = 0, nz * l, -ny * l
    end
    local t2x, t2y, t2z = ny * t1z - nz * t1y, nz * t1x - nx * t1z, nx * t1y - ny * t1x
    local dist = (xx - px) * nx + (xy - py) * ny + (xz - pz) * nz
    local rp = 1.5 * (dist + rho) + 0.5
    local bx, by, bz, bd = nx, ny, nz, 1
    for k = 1, 4 do
        local s = k % 2 == 1 and 1 or -1
        local tx, ty, tz
        if k <= 2 then tx, ty, tz = t1x * s, t1y * s, t1z * s else tx, ty, tz = t2x * s, t2y * s, t2z * s end
        local qx, qy, qz, mx, my, mz, cv = Probe(px, py, pz, nx, ny, nz, tx, ty, tz, rp)
        if qx and mx * nx + my * ny + mz * nz < 0.9999 then
            local ox, oy, oz, od = Pair(xx, xy, xz, px, py, pz, nx, ny, nz, qx, qy, qz, mx, my, mz, rho, cv)
            local d = ox * nx + oy * ny + oz * nz
            if d < bd then bx, by, bz, bd, dist = ox, oy, oz, d, od end
        end
    end
    sc.x, sc.y, sc.z, sc.ox, sc.oy, sc.oz = xx, xy, xz, bx, by, bz
    sc.nx, sc.ny, sc.nz, sc.d, sc.ok = nx, ny, nz, dist, true
    return bx, by, bz, dist
end

-- Barrel traces hit hitboxes (bodies), and fences stay solid
local _gOut, _gStart, _gEnd, _gAx, ANG0 = {}, Vector(), Vector(), Vector(), Angle()
local _gTr = {endpos = _gEnd, mask = bit.bor(MASK_SHOT, CONTENTS_GRATE), filter = CollideFilter, output = _gOut}
-- Each hand's FINAL pose last frame [1 left, 2 right], set by ApplyHullError:
-- the pose the muzzle now in g_VR.viewModelMuzzle was drawn from
local prevP, prevA, hasPrev = {Vector(), Vector()}, {Angle(), Angle()}, {false, false}
local _hasLast, _hasT, _lastLeft = false, false, false
local ltx, lty, ltz = 0, 0, 0 -- last frame's slide direction (_hasT)
local _gBox = {mins = Vector(), maxs = Vector()}
-- vrmod_debug_collisions (physics/sh_collisions): read on first use, again after a change
local dbgColl
cvars.AddChangeCallback("vrmod_debug_collisions", function() dbgColl = nil end, "vrmod_debug_collisions_cache")

-- Swing unit d until d.n == c, keeping its slide along the plane. Within
-- ~10deg of square-on that slide flips with tremor, so f (last frame's
-- slide, else the hand's right) picks the side.
local function Project(dx, dy, dz, nx, ny, nz, c, fx, fy, fz)
    local dn = dx * nx + dy * ny + dz * nz
    if dn >= c then return dx, dy, dz, false end
    local tx, ty, tz = dx - nx * dn, dy - ny * dn, dz - nz * dn
    local tl = tx * tx + ty * ty + tz * tz
    if tl < 0.03 then
        dn = fx * nx + fy * ny + fz * nz
        tx, ty, tz = fx - nx * dn, fy - ny * dn, fz - nz * dn
        tl = tx * tx + ty * ty + tz * tz
        if tl < 1e-6 then return dx, dy, dz, false end
    end
    local s = ((1 - c * c) / tl) ^ 0.5
    return nx * c + tx * s, ny * c + ty * s, nz * c + tz * s, true
end

local function Solid(tr) return tr.Hit and not tr.StartSolid end

-- vrmod_debug_collisions: the grip->muzzle box, yellow while deflected
local function DebugBarrel(pos, ang, tl, hit)
    if dbgColl == nil then
        local cv = GetConVar("vrmod_debug_collisions")
        dbgColl = cv and cv:GetBool() or false
    end
    if not dbgColl then return end
    local x, y, z = VUnpack(tl)
    VSetU(_gBox.mins, (x < 0 and x or 0) - 0.5, (y < 0 and y or 0) - 0.5, (z < 0 and z or 0) - 0.5)
    VSetU(_gBox.maxs, (x > 0 and x or 0) + 0.5, (y > 0 and y or 0) + 0.5, (z > 0 and z or 0) + 0.5)
    _gBox.pos, _gBox.angles, _gBox.hit = pos, ang, hit
    vrmod.collisionBoxes[1] = _gBox
end

local function Pivot(pos, ang, left)
    vrmod.collisionBoxes[1] = nil
    -- VRMod_AllowWeaponPushout returning false keeps the tracked pose
    if not vrmod._collisionNearby or hook.Call("VRMod_AllowWeaponPushout", nil, pos, ang) == false then
        _hasLast = false
        return pos, ang
    end
    local wep = LocalPlayer():GetActiveWeapon()
    if not U.IsValidWep(wep) then
        _hasLast = false
        return pos, ang
    end
    -- Physical melee weapons have no muzzle; they bend about their fixed
    -- hand-local tip.
    local pm = vrmod.PhysMeleeDef(wep)
    local tl = pm and pm.tip and (U.MeleeTip(wep, pm))
    _bodies = true
    if not tl then
        local muz = g_VR.viewModelMuzzle
        if not muz then
            _hasLast = false
            return pos, ang
        end
        -- Muzzle in grip space, measured against the pose that drew it: last
        -- frame's final gun-hand pose (this bend, hand collision and hull lift
        -- included). Measured on this function's own input, which lacks the
        -- lift, a gun pressed on a prop read longer by however far it was
        -- lifted. Follows grip edits, weapon swaps and hand swaps, no cache.
        local k = left and 1 or 2
        if not (_hasLast and _lastLeft == left and hasPrev[k]) then
            _hasLast, _lastLeft = true, left
            return pos, ang
        end
        tl = WorldToLocal(muz.Pos, ANG0, prevP[k], prevA[k])
    end
    local px, py, pz = VUnpack(pos)
    local dx, dy, dz = VUnpack((LocalToWorld(tl, ANG0, pos, ang)))
    dx, dy, dz = dx - px, dy - py, dz - pz
    local L = (dx * dx + dy * dy + dz * dz) ^ 0.5
    if L < 2 or L > 80 then return pos, ang end -- no rigid muzzle on this hand
    dx, dy, dz = dx / L, dy / L, dz / L

    -- The weapon's own half-thickness too: the segment is its centre line,
    -- and the server hull is that line padded by r
    local m = gunClear + (pm and pm.r or 0)
    local reach = L + m
    VSetU(_gEnd, px + dx * reach, py + dy * reach, pz + dz * reach)
    _gTr.start = pos
    util_TraceLine(_gTr)
    if not Solid(_gOut) then
        _hasT = false
        DebugBarrel(pos, ang, tl, false)
        return pos, ang
    end
    local hitEnt = _gOut.Entity

    -- d.n = c puts the muzzle m*|d.n| off the plane; at first contact (hit
    -- exactly at reach) c == d.n, so the swing starts from zero, no pop.
    local hx, hy, hz = VUnpack(_gOut.HitPos)
    local n1x, n1y, n1z = VUnpack(_gOut.HitNormal)
    -- A body's hitboxes animate: that bend gets smoothed (GunWallPivot).
    -- The world bends off the face with its edges rounded (RoundNormal)
    local entBend = eIsValid(hitEnt) and Kind(hitEnt) == 2
    if not entBend and roundRho > 0 then n1x, n1y, n1z = RoundNormal(3, hx, hy, hz, hx, hy, hz, n1x, n1y, n1z, roundRho) end
    local dn = dx * n1x + dy * n1y + dz * n1z
    if dn >= 0 then return pos, ang end
    local c1 = (-m * dn - ((px - hx) * n1x + (py - hy) * n1y + (pz - hz) * n1z)) / L
    if c1 > 1 then c1 = 1 end
    local fx, fy, fz
    if _hasT then
        fx, fy, fz = ltx, lty, ltz
    else
        local sg = left and -1 or 1
        fx, fy, fz = VUnpack(ARight(ang))
        fx, fy, fz = fx * sg, fy * sg, fz * sg
    end
    local ex, ey, ez, moved = Project(dx, dy, dz, n1x, n1y, n1z, c1, fx, fy, fz)
    if not moved then return pos, ang end
    local en = ex * n1x + ey * n1y + ez * n1z
    local tx, ty, tz = ex - n1x * en, ey - n1y * en, ez - n1z * en
    local t2 = tx * tx + ty * ty + tz * tz
    if t2 > 1e-6 then
        t2 = t2 ^ -0.5
        ltx, lty, ltz, _hasT = tx * t2, ty * t2, tz * t2, true
    end

    -- Corner: the swung barrel can meet a second face; alternating the two
    -- constraints settles it along the edge.
    VSetU(_gEnd, px + ex * reach, py + ey * reach, pz + ez * reach)
    util_TraceLine(_gTr)
    if Solid(_gOut) then
        local n2x, n2y, n2z = VUnpack(_gOut.HitNormal)
        local dn2 = ex * n2x + ey * n2y + ez * n2z
        if dn2 < 0 and n2x * n1x + n2y * n1y + n2z * n1z < 0.99 then
            local qx, qy, qz = VUnpack(_gOut.HitPos)
            local c2 = (-m * dn2 - ((px - qx) * n2x + (py - qy) * n2y + (pz - qz) * n2z)) / L
            if c2 > 1 then c2 = 1 end
            for _ = 1, 3 do
                ex, ey, ez = Project(ex, ey, ez, n2x, n2y, n2z, c2, fx, fy, fz)
                ex, ey, ez = Project(ex, ey, ez, n1x, n1y, n1z, c1, fx, fy, fz)
            end
        end
    end

    -- Outside edge: the plane solution assumes face 1 runs on under the
    -- muzzle. Where it ends first that over-swings, then pops back the moment
    -- the raw barrel clears the edge. Probe under the tip; with no face there,
    -- bisect the swing for the smallest one that clears, so the barrel rests
    -- on the edge. Both answers meet where the face ends: no pop either way.
    local tipX, tipY, tipZ = px + ex * L, py + ey * L, pz + ez * L
    local md = m + 2
    VSetU(_gStart, tipX + n1x, tipY + n1y, tipZ + n1z)
    VSetU(_gEnd, tipX - n1x * md, tipY - n1y * md, tipZ - n1z * md)
    _gTr.start = _gStart
    util_TraceLine(_gTr)
    _gTr.start = pos
    if not _gOut.Hit then
        local cs = dx * ex + dy * ey + dz * ez
        local wx, wy, wz = ex - dx * cs, ey - dy * cs, ez - dz * cs
        local wl = (wx * wx + wy * wy + wz * wz) ^ 0.5
        if wl > 1e-5 then
            wx, wy, wz = wx / wl, wy / wl, wz / wl
            local th, lo, hi = math_atan2(wl, cs), 0, 1
            for _ = 1, 7 do
                local mid = (lo + hi) * 0.5
                local ca, sa = math_cos(th * mid), math_sin(th * mid)
                VSetU(_gEnd, px + (dx * ca + wx * sa) * reach, py + (dy * ca + wy * sa) * reach, pz + (dz * ca + wz * sa) * reach)
                util_TraceLine(_gTr)
                if Solid(_gOut) then lo = mid else hi = mid end
            end
            local ca, sa = math_cos(th * hi), math_sin(th * hi)
            ex, ey, ez = dx * ca + wx * sa, dy * ca + wy * sa, dz * ca + wz * sa
        end
    end

    -- One rotation about the grip, d -> e
    local ax, ay, az = dy * ez - dz * ey, dz * ex - dx * ez, dx * ey - dy * ex
    local s = (ax * ax + ay * ay + az * az) ^ 0.5
    if s < 1e-5 then return pos, ang end
    VSetU(_gAx, ax / s, ay / s, az / s)
    local out = Angle(ang)
    out:RotateAroundAxis(_gAx, math_deg(math_atan2(s, dx * ex + dy * ey + dz * ez)))
    DebugBarrel(pos, out, tl, true)
    return pos, out, entBend
end

-- A body bend follows animated hitboxes, so it's smoothed in
-- hand space (~40ms) and blends back out after contact. World bends stay
-- exact unless one is blending out.
local math_exp, RealFrameTime, LerpAngle = math.exp, RealFrameTime, LerpAngle
local _bendL, _bendOn, _zp = Angle(), false, Vector()
function U.GunWallPivot(pos, ang, left)
    local p, a, ent = Pivot(pos, ang, left)
    if not (ent or _bendOn) then return p, a end
    if not _bendOn then _bendL:SetUnpacked(0, 0, 0) end
    local _, lt = WorldToLocal(_zp, a, _zp, ang)
    _bendL = LerpAngle(1 - math_exp(-RealFrameTime() * 25), _bendL, lt)
    local ep, ey, er = _bendL.p - lt.p, _bendL.y - lt.y, _bendL.r - lt.r
    if not ent and ep * ep + ey * ey + er * er < 0.01 then
        _bendOn = false
        return p, a
    end
    _bendOn = true
    local _, out = LocalToWorld(_zp, _bendL, p, ang)
    return p, out
end

-- Swept hands: each hand travels from where collision left it last frame to
-- its tracked pose, stopping at and sliding along the world, so only the path
-- it actually moves through is tested. The old HMD->hand ray dropped a blocked
-- hand on whichever face the line from your HEAD crossed: working round an
-- outside corner teleported the hand, and the gun with it, onto the other face.
-- MELEE TIP AS DRAWN. A melee def's tip is hand-local and tuned against one
-- model; in worldmodel mode the weapon drawn is its w_ model bone-merged on
-- the IK hand, which can sit at a different angle entirely -- then the bend,
-- sweep and server hull all follow a crowbar nobody sees. So in worldmodel
-- mode the segment is measured off the drawn weapon: the model's long axis
-- (bind pose, bone-0 space, once per model) carried on its drawn bone 0,
-- taken into the space of the hand pose that drew it, and smoothed (the IK
-- hand trails the tracked pose a little). Viewmodel mode keeps the def's,
-- since c_ viewmodels' bounds include the arms.
local axisEnds = {} -- [model] = {Vector, Vector} in bone-0 space | false
local function ModelEnds(mdl)
    local c = axisEnds[mdl]
    if c ~= nil then return c end
    c = false
    local cm = ClientsideModel(mdl, RENDERGROUP_OTHER)
    if IsValid(cm) then
        cm:SetupBones()
        local m = cm:GetBoneMatrix(0)
        local mn, mx = cm:GetModelBounds()
        if m and mn then
            local cx, cy, cz = (mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, (mn.z + mx.z) * 0.5
            local ex, ey, ez = mx.x - mn.x, mx.y - mn.y, mx.z - mn.z
            local a, b
            if ex >= ey and ex >= ez then
                a, b = Vector(mn.x, cy, cz), Vector(mx.x, cy, cz)
            elseif ey >= ez then
                a, b = Vector(cx, mn.y, cz), Vector(cx, mx.y, cz)
            else
                a, b = Vector(cx, cy, mn.z), Vector(cx, cy, mx.z)
            end
            local bp, ba = m:GetTranslation(), m:GetAngles()
            c = {(WorldToLocal(a, angle_zero, bp, ba)), (WorldToLocal(b, angle_zero, bp, ba))}
        end
        cm:Remove()
    end
    axisEnds[mdl] = c
    return c
end

local mTip, mGrip, mCls, mOK = Vector(), Vector(), nil, false
local lastP, lastA, hasLast, lastLeft = Vector(), Angle(), false, false
-- Once per frame with the weapon hand's final pose (vrmod.PhysMeleeStep).
-- The drawn bone is last frame's, so it's measured against last frame's
-- final pose -- of the same hand: a swap starts over.
function U.SampleMeleeTip(wep, pose, left)
    if left ~= lastLeft then hasLast, mOK, lastLeft = false, false, left end
    local ok = false
    if hasLast and g_VR.viewModel == wep then
        local e = ModelEnds(wep:GetModel())
        local m = e and wep:GetBoneMatrix(0)
        if m then
            local bp, ba = m:GetTranslation(), m:GetAngles()
            local ax, ay, az = VUnpack((WorldToLocal(LocalToWorld(e[1], angle_zero, bp, ba), angle_zero, lastP, lastA)))
            local bx, by, bz = VUnpack((WorldToLocal(LocalToWorld(e[2], angle_zero, bp, ba), angle_zero, lastP, lastA)))
            local A2, B2 = ax * ax + ay * ay + az * az, bx * bx + by * by + bz * bz
            -- tip: the end away from the hand
            if A2 > B2 then ax, ay, az, bx, by, bz, B2 = bx, by, bz, ax, ay, az, A2 end
            if B2 > 16 and B2 < 6400 then
                local cls = wep:GetClass()
                if cls ~= mCls or not mOK then
                    VSetU(mGrip, ax, ay, az)
                    VSetU(mTip, bx, by, bz)
                    mCls = cls
                else
                    local gx, gy, gz = VUnpack(mGrip)
                    VSetU(mGrip, gx + (ax - gx) * 0.15, gy + (ay - gy) * 0.15, gz + (az - gz) * 0.15)
                    gx, gy, gz = VUnpack(mTip)
                    VSetU(mTip, gx + (bx - gx) * 0.15, gy + (by - gy) * 0.15, gz + (bz - gz) * 0.15)
                end
                ok = true
            end
        end
    end
    mOK = ok
    VSet(lastP, pose.pos)
    ASet(lastA, pose.ang)
    hasLast = true
end

-- Hand-local tip and grip of a melee def's weapon as drawn
function U.MeleeTip(wep, def)
    if mOK and mCls == wep:GetClass() and g_VR.viewModel == wep then return mTip, mGrip end
    return def.tip, def.grip
end

-- 8 corners of the box around hand-space segment g -> t, padded r every way,
-- moved back off along x: sv_physhands' hand prop rides off forward of the
-- hand. Shared so the hull debug draws exactly what the server built.
local SB_UP, SB_FWD = Vector(0, 0, 1), Vector(1, 0, 0)
function U.SegBox(g, t, r, off)
    local d = t - g
    local L = d:Length()
    if L < 0.1 then return end
    d:Div(L)
    local u = d:Cross(d.z * d.z < 0.81 and SB_UP or SB_FWD)
    u:Normalize()
    u:Mul(r)
    local v = d:Cross(u) -- d unit and u perpendicular to it, so |v| = r
    local a, b = g - d * r, t + d * r
    a.x, b.x = a.x - off, b.x - off
    local verts = {}
    for i = 0, 7 do
        local p = Vector(i < 4 and a or b)
        if i % 2 == 0 then p:Add(u) else p:Sub(u) end
        if i % 4 < 2 then p:Add(v) else p:Sub(v) end
        verts[i + 1] = p
    end
    return verts
end

-- vrmod_debug_hull: every VR hand prop where the SERVER has it, from the
-- shape it tags on the prop (vrShape: 1 sphere, 2 box, 3 weapon segment).
-- Networked entities draw interpolated, so judge it against props and NPCs
-- (they lag the same), not against your own hand.
if CLIENT then
    local cv_dbgHull = CreateClientConVar("vrmod_debug_hull", "0", false, false, "Draw the server's physics hand props (red)", 0, 1)
    local COL_HULL = Color(255, 60, 60)
    local BITS = {1, 2, 4}
    local function DrawHulls(depth, sky)
        if depth or sky then return end
        render.SetColorMaterial()
        local list = ents.FindByClass("base_anim")
        for i = 1, #list do
            local e = list[i]
            local shp = e:GetNWInt("vrShape", 0)
            if shp == 1 then
                render.DrawWireframeSphere(e:GetPos(), e:GetNWFloat("vrR", 2), 8, 8, COL_HULL)
            elseif shp == 2 then
                render.DrawWireframeBox(e:GetPos(), e:GetAngles(), e:GetNWVector("vrA"), e:GetNWVector("vrB"), COL_HULL, true)
            elseif shp == 3 then
                local v = U.SegBox(e:GetNWVector("vrA"), e:GetNWVector("vrB"), e:GetNWFloat("vrR", 1.5), vrmod.DEFAULT_OFFSET)
                if v then
                    local pos, ang = e:GetPos(), e:GetAngles()
                    for k = 1, 8 do v[k] = LocalToWorld(v[k], ANG0, pos, ang) end
                    -- corners differing in one bit share an edge
                    for k = 0, 7 do
                        for b = 1, 3 do
                            local w = BITS[b]
                            if math.floor(k / w) % 2 == 0 then render.DrawLine(v[k + 1], v[k + w + 1], COL_HULL, true) end
                        end
                    end
                end
            end
        end
    end
    -- Only hooked while on: PostDrawTranslucentRenderables runs several times a frame
    local function SyncHull()
        if cv_dbgHull:GetBool() then
            hook.Add("PostDrawTranslucentRenderables", "vrmod_debug_hull", DrawHulls)
        else
            hook.Remove("PostDrawTranslucentRenderables", "vrmod_debug_hull")
        end
    end
    cvars.AddChangeCallback("vrmod_debug_hull", SyncHull, "vrmod_debug_hull")
    SyncHull()
end

local HAND_R = vrmod.DEFAULT_RADIUS
local SEED_OFF = HAND_R * 1.75 -- clears the hull's corner off any plane
local RESEED_SQR = 48 * 48     -- teleport, respawn: start again from the head
local _hOut, _hEnd, _palm = {}, Vector(), Vector()
local _hHull = {endpos = _hEnd, mins = Vector(-HAND_R, -HAND_R, -HAND_R), maxs = Vector(HAND_R, HAND_R, HAND_R), mask = MASK_SHOT_HULL, filter = CollideFilter, output = _hOut}
local _hLine = {mask = MASK_SHOT_HULL, filter = CollideFilter, output = _hOut}
-- The sweep runs at the palm, OFF forward of the hand pose (the wrist):
-- the same point the server hull and the contact prediction use
local OFF = vrmod.DEFAULT_OFFSET

-- BODY HITBOXES (hands). A line pass loses the hand the moment it starts
-- inside one -- arm boxes overlap the chest's, idle anims drift them -- and
-- then it passes through. So each hitbox near the hands is an OBB on its
-- bone, grown by the hand radius; BodyPush puts a point out along the
-- shallowest face of any it's in, which also makes the hand slide. A body
-- that moves onto the hand pushes it out. Bounds cached per model; bone
-- frames gathered once per frame (last drawn pose).
local math_ceil, RAD = math.ceil, math.pi / 180
local GetBoneMatrix = FindMetaTable("Entity").GetBoneMatrix
local MAT = FindMetaTable("VMatrix")
local MGetTranslation, MGetAngles = MAT.GetTranslation, MAT.GetAngles
local hbDefs = {} -- [model] = {{bone, x0..z1, cx..cz, hr}, ...} | false
local function HitboxDefs(e)
    local mdl = e:GetModel()
    if not mdl then return false end
    local d = hbDefs[mdl]
    if d ~= nil then return d end
    d = false
    local set = e:GetHitboxSet()
    local n = set and e:GetHitBoxCount(set) or 0
    for i = 0, n - 1 do
        local mn, mx = e:GetHitBoxBounds(i, set)
        local bone = e:GetHitBoxBone(i, set)
        if mn and bone then
            local ex, ey, ez = (mx.x - mn.x) * 0.5, (mx.y - mn.y) * 0.5, (mx.z - mn.z) * 0.5
            d = d or {}
            d[#d + 1] = {bone = bone, x0 = mn.x, y0 = mn.y, z0 = mn.z, x1 = mx.x, y1 = mx.y, z1 = mx.z,
                cx = mn.x + ex, cy = mn.y + ey, cz = mn.z + ez, hr = (ex * ex + ey * ey + ez * ez) ^ 0.5}
        end
    end
    hbDefs[mdl] = d
    return d
end

local boxes, nBox = {}, 0 -- this frame's hitbox frames near the hands, pooled
local function GatherBodies(center)
    nBox = 0
    local list = ents.FindInSphere(center, 96)
    for i = 1, #list do
        local e = list[i]
        -- A player this hand carries (sh_playergrab) rides it, drawn a round
        -- trip behind: pushing out of its hitboxes shook the grip loose
        local d = Kind(e) == 2 and e ~= _me and e:IsSolid() and not e:IsDormant() and e:GetNW2Entity("vrmod_grabber") ~= _me and HitboxDefs(e)
        if d then
            for j = 1, #d do
                local h = d[j]
                local m = GetBoneMatrix(e, h.bone)
                if m then
                    -- The bone's axes as Angle:Forward/Left/Up of its angles
                    -- (scale dropped, as before): one GetAngles, the trig in Lua
                    local ox, oy, oz = VUnpack(MGetTranslation(m))
                    local p, yw, r = AUnpack(MGetAngles(m))
                    p, yw, r = p * RAD, yw * RAD, r * RAD
                    local sp, cp, sy, cy, sr, cr = math_sin(p), math_cos(p), math_sin(yw), math_cos(yw), math_sin(r), math_cos(r)
                    local fx, fy, fz = cp * cy, cp * sy, -sp
                    local lx, ly, lz = sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, sr * cp -- bone-local y is left
                    local ux, uy, uz = cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp
                    nBox = nBox + 1
                    local b = boxes[nBox]
                    if not b then b = {} boxes[nBox] = b end
                    b.ox, b.oy, b.oz = ox, oy, oz
                    b.fx, b.fy, b.fz = fx, fy, fz
                    b.lx, b.ly, b.lz = lx, ly, lz
                    b.ux, b.uy, b.uz = ux, uy, uz
                    b.x0, b.y0, b.z0 = h.x0 - HAND_R, h.y0 - HAND_R, h.z0 - HAND_R
                    b.x1, b.y1, b.z1 = h.x1 + HAND_R, h.y1 + HAND_R, h.z1 + HAND_R
                    -- world centre and reach, for a cheap reject
                    local hx, hy, hz = h.cx, h.cy, h.cz
                    b.cx = ox + fx * hx + lx * hy + ux * hz
                    b.cy = oy + fy * hx + ly * hy + uy * hz
                    b.cz = oz + fz * hx + lz * hy + uz * hz
                    local rr = h.hr + HAND_R
                    b.r2 = rr * rr
                end
            end
        end
    end
end

-- Point out of every grown hitbox it's in, along the shallowest face; two
-- passes settle overlapping boxes. Returns the point and the last push axis.
local function BodyPush(px, py, pz)
    local hit, hx, hy, hz = false, 0, 0, 0
    for _ = 1, 2 do
        local any = false
        for k = 1, nBox do
            local b = boxes[k]
            local dx, dy, dz = px - b.cx, py - b.cy, pz - b.cz
            if dx * dx + dy * dy + dz * dz < b.r2 then
                local rx, ry, rz = px - b.ox, py - b.oy, pz - b.oz
                local lx = rx * b.fx + ry * b.fy + rz * b.fz
                local ly = rx * b.lx + ry * b.ly + rz * b.lz
                local lz = rx * b.ux + ry * b.uy + rz * b.uz
                if lx > b.x0 and lx < b.x1 and ly > b.y0 and ly < b.y1 and lz > b.z0 and lz < b.z1 then
                    local best, wx, wy, wz = lx - b.x0, -b.fx, -b.fy, -b.fz
                    local v = b.x1 - lx
                    if v < best then best, wx, wy, wz = v, b.fx, b.fy, b.fz end
                    v = ly - b.y0
                    if v < best then best, wx, wy, wz = v, -b.lx, -b.ly, -b.lz end
                    v = b.y1 - ly
                    if v < best then best, wx, wy, wz = v, b.lx, b.ly, b.lz end
                    v = lz - b.z0
                    if v < best then best, wx, wy, wz = v, -b.ux, -b.uy, -b.uz end
                    v = b.z1 - lz
                    if v < best then best, wx, wy, wz = v, b.ux, b.uy, b.uz end
                    best = best + 0.01
                    px, py, pz = px + wx * best, py + wy * best, pz + wz * best
                    any, hx, hy, hz = true, wx, wy, wz
                end
            end
        end
        if not any then break end
        hit = true
    end
    return px, py, pz, hit, hx, hy, hz
end
local handFree = {left = Vector(), right = Vector()}
local handSeeded = {left = false, right = false}
local handShape = {}
for i = 1, 2 do
    handShape[HANDS[i]] = {radius = HAND_R, mins = _hHull.mins, maxs = _hHull.maxs, hitNormal = Vector()}
end

-- Moves free toward (tx, ty, tz), sliding along up to three faces. Returns
-- clipped (first normal written to nOut) and stuck (started in solid).
local function Sweep(free, tx, ty, tz, nOut)
    local clipped = false
    for _ = 1, 3 do
        VSetU(_hEnd, tx, ty, tz)
        _hHull.start = free
        util_TraceHull(_hHull)
        if _hOut.StartSolid then return clipped, true end
        local hx, hy, hz = VUnpack(_hOut.HitPos)
        if not _hOut.Hit then
            VSetU(free, hx, hy, hz)
            break
        end
        local nx, ny, nz = VUnpack(_hOut.HitNormal)
        if not clipped then
            clipped = true
            VSetU(nOut, nx, ny, nz)
        end
        -- Keep the rest of the move, minus its push into this face
        local d = (tx - hx) * nx + (ty - hy) * ny + (tz - hz) * nz - 0.05
        tx, ty, tz = tx - nx * d, ty - ny * d, tz - nz * d
        VSetU(free, hx + nx * 0.05, hy + ny * 0.05, hz + nz * 0.05)
    end
    return clipped, false
end

-- Palm flat on the surface with normal n: fingers along it (the hand's
-- forward projected onto the plane), palm axis on the normal
local _pf, VNormalize, VAngle = Vector(), VEC.Normalize, VEC.Angle
local function PalmFlat(ang, nx, ny, nz, left)
    local fx, fy, fz = VUnpack(AForward(ang))
    local d = fx * nx + fy * ny + fz * nz
    fx, fy, fz = fx - nx * d, fy - ny * d, fz - nz * d
    if fx * fx + fy * fy + fz * fz < 0.001 then
        local rx, ry, rz = VUnpack(ARight(ang))
        fx, fy, fz = ry * nz - rz * ny, rz * nx - rx * nz, rx * ny - ry * nx -- Right x n
    end
    VSetU(_pf, fx, fy, fz)
    VNormalize(_pf)
    local a = VAngle(_pf)
    -- Roll so the palm axis lies on the normal: Right = +normal for the
    -- right hand, -normal for the left. At roll r, Source gives
    -- Right(r) = cos(r)*R0 - sin(r)*U0 with R0/U0 the roll-0 axes, and
    -- the normal lies in that plane (F was projected onto the
    -- surface), so r = atan2(-s*n.U0, s*n.R0) for every surface.
    local s = left and -1 or 1
    local ux, uy, uz = VUnpack(AUp(a))
    local rx, ry, rz = VUnpack(ARight(a))
    a.roll = math_deg(math_atan2(-s * (nx * ux + ny * uy + nz * uz), s * (nx * rx + ny * ry + nz * rz)))
    return a
end
-- The palm's face is found by a line down the contact normal: the hull's
-- own normal can be a brush bevel plane (Source adds those for box traces),
-- not a face. Reaches the hull's farthest corner, plus slack. PALM_D: how
-- far off the rounded surface the palm rests (the hull on a flat wall).
local PALM_PROBE, PALM_D = HAND_R * 1.8 + 1, HAND_R + 0.05
-- Corner signs on the contact side, per axis: one sign where the normal has
-- a component, both where it has none (i: 1 or 2; nil: skip)
local function CSign(v, i)
    if v > 0.01 then return i == 1 and -1 or nil end
    if v < -0.01 then return i == 1 and 1 or nil end
    return i == 1 and -1 or 1
end
-- The face the hull rests on: straight down the contact normal, else -- the
-- hull caught on an edge by a corner, its centre already past the face --
-- the nearest hit of lines to its corners on the contact side. Point and
-- normal, or nothing.
local function PalmFace(x, y, z, nx, ny, nz)
    if RRay(x, y, z, -nx, -ny, -nz, PALM_PROBE) then return HitOut() end
    local bf, hx, hy, hz, hnx, hny, hnz = 2
    for ix = 1, 2 do
        local sx = CSign(nx, ix)
        if sx then
            for iy = 1, 2 do
                local sy = CSign(ny, iy)
                if sy then
                    for iz = 1, 2 do
                        local sz = CSign(nz, iz)
                        if sz and RRay(x, y, z, sx * 0.57735, sy * 0.57735, sz * 0.57735, PALM_PROBE) and _rOut.Fraction < bf then
                            bf = _rOut.Fraction
                            hx, hy, hz, hnx, hny, hnz = HitOut()
                        end
                    end
                end
            end
        end
    end
    return hx, hy, hz, hnx, hny, hnz
end

function U.UpdateHandCollisions(lefthandPos, lefthandAng, righthandPos, righthandAng)
    local spheres, byHand = vrmod.collisionSpheres, vrmod._collisionShapeByHand
    _bodies, nBox = false, 0
    if not vrmod._collisionNearby then
        if spheres[1] then table.Empty(spheres) end
        byHand.left, byHand.right = nil, nil
        handSeeded.left, handSeeded.right = false, false
        return lefthandPos, lefthandAng, righthandPos, righthandAng
    end

    local ply = LocalPlayer()
    if not IsValid(ply) then return lefthandPos, lefthandAng, righthandPos, righthandAng end
    local gunHand = U.IsValidWep(ply:GetActiveWeapon()) and (GunLeft() and "left" or "right")
    if not gunHand then table.Empty(vrmod.collisionBoxes) end

    table.Empty(spheres)
    byHand.left, byHand.right = nil, nil

    local hmdPos = g_VR.tracking.hmd.pos
    if not hmdPos then return lefthandPos, lefthandAng, righthandPos, righthandAng end
    GatherBodies(hmdPos)

    local leftGrip, rightGrip = GetClimbingGripState()

    for i = 1, 2 do
        local hand, left = HANDS[i], i == 1
        local handPos = left and lefthandPos or righthandPos
        local ang = left and lefthandAng or righthandAng
        local isGun = hand == gunHand

        -- Climbing grip, or VRMod_AllowHandCollision returning false, skips
        -- this hand this frame
        if (left and leftGrip or not left and rightGrip) or hook.Call("VRMod_AllowHandCollision", nil, hand, handPos, ang) == false then
            handSeeded[hand] = false
            continue
        end

        local fx, fy, fz = VUnpack(AForward(ang))
        local hx, hy, hz = VUnpack(handPos)
        local tx, ty, tz = hx + fx * OFF, hy + fy * OFF, hz + fz * OFF -- the palm
        VSetU(_palm, tx, ty, tz)
        local free = handFree[hand]
        if not handSeeded[hand] or VDistToSqr(free, _palm) > RESEED_SQR then
            -- Seed on your side of any wall, from the head
            _hLine.start, _hLine.endpos = hmdPos, _palm
            util_TraceLine(_hLine)
            if _hOut.Hit and not _hOut.StartSolid then
                local px, py, pz = VUnpack(_hOut.HitPos)
                local nx, ny, nz = VUnpack(_hOut.HitNormal)
                VSetU(free, px + nx * SEED_OFF, py + ny * SEED_OFF, pz + nz * SEED_OFF)
            else
                VSet(free, _palm)
            end
            handSeeded[hand] = true
        end

        local shape = handShape[hand]
        local normal = shape.hitNormal
        local px, py, pz = VUnpack(free) -- where this frame's move starts
        local clipped, stuck = Sweep(free, tx, ty, tz, normal)
        local ent = false -- a body did the stopping (set below)
        if stuck then handSeeded[hand] = false end
        -- Bodies: the move sub-stepped (no tunnelling through an arm), each
        -- step pushed out of the hitboxes (BodyPush), so the hand stops on
        -- and slides along them. Stop only: bodies can't be shoved.
        if nBox > 0 and not stuck then
            local qx, qy, qz = VUnpack(free)
            local mx, my, mz = qx - px, qy - py, qz - pz
            local steps = math_ceil((mx * mx + my * my + mz * mz) ^ 0.5 / HAND_R)
            if steps < 1 then steps = 1 elseif steps > 8 then steps = 8 end
            mx, my, mz = mx / steps, my / steps, mz / steps
            local hit = false
            for _ = 1, steps do
                local h, nx, ny, nz
                px, py, pz, h, nx, ny, nz = BodyPush(px + mx, py + my, pz + mz)
                if h then
                    hit = true
                    VSetU(normal, nx, ny, nz)
                end
            end
            if hit then
                VSetU(free, px, py, pz)
                clipped, ent = true, true
            end
        end
        -- isClipped feeds climbing's grab fallback: world only, never a prop
        shape.pos, shape.pushOutPos, shape.angles = free, free, ang
        shape.hit, shape.isClipped, shape.hitWorld = clipped, clipped and not ent, clipped and not ent
        spheres[#spheres + 1] = shape
        byHand[hand] = shape

        if clipped then
            g_VR._cachedFrameRelative = nil
            g_VR._cachedFrameAbsolute = nil
            -- On entities the hand only stops: their normals change every
            -- frame, so reorienting to them shakes the hand. The gun hand only
            -- stops too, fingers closed round the grip; GunWallPivot swings
            -- the barrel clear from this pose. On the world both hands rest
            -- PALM_D off the rounded surface (RoundNormal), and a bare hand
            -- lays its palm flat on it. The sweep keeps free as it found it:
            -- that's where next frame's move starts from.
            local a, ppx, ppy, ppz = ang, VUnpack(free)
            if not ent then
                local nx, ny, nz = VUnpack(normal)
                if roundRho > 0 then
                    local qx, qy, qz, qnx, qny, qnz = PalmFace(ppx, ppy, ppz, nx, ny, nz)
                    if qx then
                        local d
                        nx, ny, nz, d = RoundNormal(i, ppx, ppy, ppz, qx, qy, qz, qnx, qny, qnz, roundRho)
                        d = PALM_D - d
                        ppx, ppy, ppz = ppx + nx * d, ppy + ny * d, ppz + nz * d
                    end
                end
                if not isGun then
                    a = PalmFlat(ang, nx, ny, nz, left)
                    local sk = g_VR.input and (left and g_VR.input.skeleton_lefthand or g_VR.input.skeleton_righthand)
                    local fc = sk and sk.fingerCurls
                    if fc then for j = 1, 5 do fc[j] = 0 end end
                end
            end
            -- The palm, less OFF back along the final forward, is the wrist.
            -- A new vector: the caller stores it into the pose.
            fx, fy, fz = VUnpack(AForward(a))
            local corrected = Vector(ppx - fx * OFF, ppy - fy * OFF, ppz - fz * OFF)
            if left then lefthandPos, lefthandAng = corrected, a else righthandPos, righthandAng = corrected, a end
        end
    end
    return lefthandPos, lefthandAng, righthandPos, righthandAng
end

-- HULL ERROR. Collision is the client's: hands and weapons go where this
-- file puts them. The server hand props chase that pose (SendHandPose) and
-- do the pushing; only when one is pressed against something and can't get
-- there -- the server checks its contacts -- does it send the WORLD hand
-- pose the stuck prop implies. ApplyHullError pins the hand there, measured
-- against this frame's hand, so a weapon sticks where its prop is stuck --
-- in the frame and so for everyone -- however far the real hand has pushed
-- on during the round trip. Pulled back out along the push, it lets go at
-- once, ahead of the server's clear. Free movement never involves the
-- server. Once per frame from cl_vrmod.
local ZV, _raA = Vector(), Angle()
local WorldToLocal, SysTime = WorldToLocal, SysTime
-- Every hand pose sent carries a sequence; a stuck pose echoes the one its
-- step chased, so its age is the real round trip (poseT ring, ~0.4s deep).
-- latEst rises at once, decays slowly: the prediction window is built on it.
-- predDelay: contact -> server pin, learned from pins after predictions
-- (the server may push a few ticks before it calls a prop stuck).
local poseSeq, poseT, poseS, latEst, predDelay = 0, {}, {}, 0.08, 0.06
local cvDbgHE, cvPred, dbgHE, predOn
if CLIENT then
    cvDbgHE = CreateClientConVar("vrmod_debug_hullerr", "0", false, false, "Print hull error / contact prediction timing", 0, 1)
    cvPred = CreateClientConVar("vrmod_hull_predict", "1", true, false, "Client predicts hand stops on heavy props ahead of the server", 0, 1)
    dbgHE, predOn = cvDbgHE:GetBool(), cvPred:GetBool()
    cvars.AddChangeCallback("vrmod_debug_hullerr", function() dbgHE = cvDbgHE:GetBool() end, "vrmod_debug_hullerr")
    cvars.AddChangeCallback("vrmod_hull_predict", function() predOn = cvPred:GetBool() end, "vrmod_hull_predict")
end
local errIn, errUse = {}, {}
for i = 1, 2 do
    -- cP/cN/plane: the surface touched (world, rebuilt each frame from
    -- cLP/cLN on the prop it belongs to, cEnt), cL the hand-local hull point
    -- touching it (see Pen, ApplyHullError). p/a/n: a server pose pin, for
    -- contacts that come without a plane (held props, ragdolls).
    -- errUse: w the plane's world lift, p/a the pose pin's hand-local offset
    errIn[HANDS[i]] = {p = Vector(), a = Angle(), n = Vector(), hasN = false, on = false, pred = false, t = 0, ignore = 0, cP = Vector(), cN = Vector(), plane = false, cL = Vector(), cLP = Vector(), cLN = Vector(), cEnt = nil, held = false, ra = Angle()}
    errUse[HANDS[i]] = {p = Vector(), a = Angle(), on = false, w = Vector(), wOn = false, rp = 0, ry = 0, rr = 0, pen = 0}
end
-- A hull contact is moving this hand's final pose (lift or pin, easing included)
function U.HullContact(left)
    local u = errUse[left and "left" or "right"]
    return u.on or u.wOn
end
-- Stuck messages, one layout: vrmod_hull_plane (hand hulls) and
-- vrmod_hull_error (held props). The contact as a plane -- in the touched
-- prop's space, or world space -- plus the touching point in hand space;
-- else (a many-bone ragdoll) a pose. Held props used to get a pose pin
-- always: pressed on a floor or wall the hand froze on the prop and only let
-- go pulled back out, so dragging it along the surface stuck. A held
-- prop's plane also carries ra, the turn the server's prop has taken against
-- the surface relative to the hand pose it chased (ApplyHullError turns the
-- hand by it). Each stuck message echoes the hand pose sequence its step
-- chased (round-trip timing).
local function ReadPose(e)
    e.p:Set(net.ReadVector())
    e.a:Set(net.ReadAngle())
    e.hasN = net.ReadBool()
    if e.hasN then e.n:Set(net.ReadNormal()) end
end
local function HullIn(held)
    local right = net.ReadBool()
    local e, now = errIn[right and "right" or "left"], SysTime()
    local was, pT = e.on and now - e.t < 0.3, e.pred and e.predT or e.predExp
    e.on, e.t, e.pred, e.predT, e.predExp = net.ReadBool(), now, false, nil, nil
    if not e.on then
        e.plane = false
        if dbgHE then print(string.format("[HullErr] %s server clear", right and "R" or "L")) end
        return
    end
    -- Confirms a prediction, live or just expired: how long that took
    local pd = pT and now - pT < 0.3 and now - pT
    if pd then predDelay = pd > predDelay and pd or predDelay + (pd - predDelay) * 0.1 end
    local seq = net.ReadUInt(16)
    if net.ReadBool() then
        local world = net.ReadBool()
        local ent = not world and net.ReadEntity() or nil
        e.cLP:Set(net.ReadVector())
        e.cLN:Set(net.ReadNormal())
        e.cL:Set(net.ReadVector())
        if world then
            e.cP:Set(e.cLP)
            e.cN:Set(e.cLN)
        end
        e.cEnt, e.cWorld, e.plane, e.held = ent, world, world or IsValid(ent), held
        if held then e.ra:Set(net.ReadAngle()) end
        e.on = e.plane
    else
        e.plane = false
        ReadPose(e)
    end
    local age, j = -1, seq % 64
    if seq ~= 0 and poseS[j] == seq then
        age = now - poseT[j]
        latEst = age > latEst and age or latEst + (age - latEst) * 0.05
    end
    if (not was or pd) and dbgHE then
        e.dbg = string.format("[HullErr] %s server %s: pose age %.0fms (est %.0fms)%s", right and "R" or "L", e.plane and "plane" or "pin", age * 1000, latEst * 1000, pd and string.format(", %.0fms after prediction (learned %.0fms)", pd * 1000, predDelay * 1000) or "")
    end
end
if CLIENT then
    net.Receive("vrmod_hull_error", function() HullIn(true) end)
    net.Receive("vrmod_hull_plane", function() HullIn(false) end)
end

-- CONTACT PREDICTION. The server's verdict is a round trip plus a step
-- away; a hard slam covers inches in that. So the frame a hand's hull would
-- sweep into a prop heavy enough to stop it (PRED_RATIO x the hull's
-- server mass), it pins right there itself -- as if the server had said so
-- -- for about one round trip. The server's stuck pose takes over when it
-- lands; if none comes (the prop gave), the pin expires and eases off.
-- Props at rest draw where the server has them, so their surface is exact;
-- anything lighter, ragdolls, bodies and held things stay the server's.
-- Only on the transition (no pin live), and only past a small move.
-- Lighter props are left to the server: stopping on them would hitch every push.
local PRED_RATIO = 1 -- the server stops a hull on props about its own mass (floor friction helps)
local _pOut, _pW = {}, {Vector(), Vector()}
local _pTr = {mins = Vector(), maxs = Vector(), mask = MASK_SOLID, output = _pOut}
local _pPt, _pBare = {Vector(), Vector(), Vector()}, Vector(vrmod.DEFAULT_OFFSET, 0, 0)
local predMin, predH1, predH2, cvPredHP, cvPredF, predEnt, predDbg, predRej = 0, nil, nil
local predStat = {"", ""} -- [HullErr] the last real sweep's outcome per hand
-- Mass as the client can know it: server props have no client physobj. The
-- weight system's server stamp (sh_weight) if the prop has been held, else
-- the model's own (studiohdr, or the .phy solids summed), cached per model.
local mdlMass = {}
local HUGE = math.huge
local function PropMass(e)
    -- Nothing a hull can move: not simulated here (prop_dynamic, doors,
    -- parented), or frozen (stamped by sv_physhands)
    if e:GetMoveType() ~= MOVETYPE_VPHYSICS or e:GetNWBool("vrFz") then return HUGE end
    local m = e:GetNWFloat("vrw_m", 0)
    if m > 0 then return m end
    local mdl = e:GetModel()
    if not mdl then return 0 end
    m = mdlMass[mdl]
    if m then return m end
    local info = util.GetModelInfo(mdl)
    m = info and info.ModelMass or 0
    if m <= 0 and info and info.KeyValues then
        for v in info.KeyValues:gmatch('"mass"%s*"([%d%.]+)"') do m = m + tonumber(v) end
    end
    mdlMass[mdl] = m
    return m
end
_pTr.filter = function(e)
    if not eIsValid(e) or e == predH1 or e == predH2 or Kind(e) ~= 0 or e:IsWeapon() or e:IsRagdoll() or e:GetNWBool("isVRHand") then return false end
    local m = PropMass(e)
    if m >= predMin then return true end
    if predDbg then predRej = string.format("rejected %s %s (%.1fkg, need %.1fkg)", e:GetClass(), e:GetModel(), m, predMin) end
    return false
end
local function AngD(a, b) return (a - b + 180) % 360 - 180 end
local function Predict(i, e, pose, now)
    local pp, pa, cp, ca = prevP[i], prevA[i], pose.pos, pose.ang
    local d2 = VDistToSqr(pp, cp)
    if d2 > 2304 then return end -- teleport, respawn
    local p0, y0, r0 = AUnpack(pa)
    local p1, y1, r1 = AUnpack(ca)
    local dp, dy, dr = AngD(p1, p0), AngD(y1, y0), AngD(r1, r0)
    if d2 < 0.25 and dp * dp + dy * dy + dr * dr < 2.25 then return end -- 0.5u / 1.5deg a frame
    local ply = LocalPlayer()
    -- The hull the server built: the gun hand's grip->tip segment, else a sphere OFF forward
    local n, r, mass = 1, HAND_R, 20
    local wep = ply:GetActiveWeapon()
    if wep:IsValid() and (i == 2) ~= GunLeft() then
        local def = vrmod.PhysMeleeDef(wep)
        if def then
            local tip, grip
            if def.tip then
                tip, grip = U.MeleeTip(wep, def)
            else
                local muz = g_VR.viewModelMuzzle
                if muz then tip, grip = WorldToLocal(muz.Pos, ANG0, pp, pa), def.grip end -- the pose that drew it
            end
            if tip then
                grip = grip or ZV
                local tx, ty, tz = VUnpack(tip)
                local gx, gy, gz = VUnpack(grip)
                VSetU(_pPt[2], (tx + gx) * 0.5, (ty + gy) * 0.5, (tz + gz) * 0.5)
                VSet(_pPt[1], grip)
                VSet(_pPt[3], tip)
                cvPredF = cvPredF or GetConVar("vrmod_physmelee_force")
                n, r, mass = 3, def.r, def.m * cvPredF:GetFloat()
            end
        end
    end
    if n == 1 then VSet(_pPt[1], _pBare) end
    predMin = mass * PRED_RATIO
    predH1, predH2 = g_VR.heldEntityLeft, g_VR.heldEntityRight
    VSetU(_pTr.mins, -r, -r, -r)
    VSetU(_pTr.maxs, r, r, r)
    -- Hand-local hull points carried on both poses (y is left: -R); the
    -- poses unpacked once, each point once
    local ax, ay, az = VUnpack(pp)
    local bx, by, bz = VUnpack(cp)
    local f0x, f0y, f0z = VUnpack(AForward(pa))
    local r0x, r0y, r0z = VUnpack(ARight(pa))
    local u0x, u0y, u0z = VUnpack(AUp(pa))
    local f1x, f1y, f1z = VUnpack(AForward(ca))
    local r1x, r1y, r1z = VUnpack(ARight(ca))
    local u1x, u1y, u1z = VUnpack(AUp(ca))
    local s, w, t, ss = _pW[1], _pW[2], 2, 0
    _pTr.start, _pTr.endpos = s, w
    predDbg, predRej = dbgHE, nil
    for k = 1, n do
        local l = _pPt[k]
        local x, y, z = VUnpack(l)
        VSetU(s, ax + f0x * x - r0x * y + u0x * z, ay + f0y * x - r0y * y + u0y * z, az + f0z * x - r0z * y + u0z * z)
        VSetU(w, bx + f1x * x - r1x * y + u1x * z, by + f1y * x - r1y * y + u1y * z, bz + f1z * x - r1z * y + u1z * z)
        util_TraceHull(_pTr)
        if _pOut.StartSolid then
            ss = ss + 1
        elseif _pOut.Hit and _pOut.Fraction < t and _pOut.Entity:IsValid() then
            t, predEnt = _pOut.Fraction, _pOut.Entity
            VSet(e.cP, _pOut.HitPos)
            VSet(e.cN, _pOut.HitNormal)
            VSet(e.cL, l)
        end
    end
    if t > 1 then
        -- Kept from the entry frame: once inside, every sweep starts solid
        if predDbg and ss < n then predStat[i] = predRej or string.format("swept %d pt(s) r%.1f, %.1fu, no hit", n, r, d2 ^ 0.5) end
        return
    end
    -- The surface it touched: through the touching point's hull centre,
    -- along the hit normal; that point stays on its side. Kept in the prop's
    -- space, so it moves with the prop as drawn (pushed, sliding).
    local ea = predEnt:GetAngles()
    e.cLP:Set((WorldToLocal(e.cP, ANG0, predEnt:GetPos(), ea)))
    e.cLN:Set((WorldToLocal(e.cN, ANG0, ZV, ea)))
    e.cEnt, e.plane, e.cWorld = predEnt, true, false
    -- Held for the measured round trip plus two ticks' slack
    local W, W2 = latEst + 0.03, predDelay * 1.25 + 0.015
    if W2 > W then W = W2 end
    W = W < 0.05 and 0.05 or W > 0.3 and 0.3 or W
    e.on, e.pred, e.t, e.predT = true, true, now - 0.3 + W, now
    if dbgHE then print(string.format("[HullErr] %s predict: hit %s (%.1fkg >= %.1f), hold %.0fms", i == 2 and "R" or "L", tostring(predEnt), PropMass(predEnt), predMin, W * 1000)) end
    return true
end

-- How far the touching hull point, on pose (pos, ang), is past e's surface
-- (<= 0: clear of it). That point only: the plane is flat and endless, a
-- prop isn't -- on a drum's rim the rest of the gun sat "behind" it while
-- nowhere near it, and got shoved far off.
-- Past this the plane no longer fits. A prediction's is a guess (12). The
-- server's is a real held contact, on a prop drawn ~a round trip behind the
-- server's: pushing one that slides, the hand ends up its error PLUS that
-- lag past the drawn face -- over 12 in MP, which let the weapon in. It
-- holds as far as the server calls the hull stuck at all (ERR_MAX, 48).
local PEN_MAX, PEN_SRV = 12, 48
local function Pen(e, pos, ang)
    local wx, wy, wz = VUnpack((LocalToWorld(e.cL, ANG0, pos, ang)))
    local cx, cy, cz = VUnpack(e.cP)
    local nx, ny, nz = VUnpack(e.cN)
    return (cx - wx) * nx + (cy - wy) * ny + (cz - wz) * nz
end
-- The plane in world space, on the prop as drawn: pushed or sliding, the
-- surface moves with it. False once the prop is gone.
local function Plane(e)
    if e.cWorld then return true end -- cP/cN: world space, set on arrival
    local ent = e.cEnt
    if not IsValid(ent) then
        e.plane = false
        return false
    end
    local a = ent:GetAngles()
    e.cP:Set((LocalToWorld(e.cLP, ANG0, ent:GetPos(), a)))
    e.cN:Set((LocalToWorld(e.cLN, ANG0, ZV, a)))
    return true
end

-- CONTACT. With a plane (every prediction, every hand-hull contact) the
-- hand stays live -- slides, turns, at frame rate -- and is only lifted
-- back out along the surface normal by however far its touching point is
-- past it. Pulled out, the lift is zero that frame: no wait for the
-- server's clear. Pinning the whole pose to the server's hull put the
-- weapon a round trip behind and stepped it at tick rate while pressed.
-- When the contact ends with the hand still in (the prop gave), the lift
-- eases off. Contacts without a plane keep the pose pin: snaps on, eases off.
function U.ApplyHullError(lh, rh)
    local dt = RealFrameTime()
    local now, kOn, kOff, kRot, right = SysTime(), 1 - math_exp(-dt * 150), 1 - math_exp(-dt * 80), 1 - math_exp(-dt * 30), false
    local kIn = 1 - math_exp(-dt * 90)
    cvPredHP = cvPredHP or GetConVar("vrmod_hand_physics")
    local predOK = predOn and cvPredHP and cvPredHP:GetBool()
    for i = 1, 2 do
        local hand = HANDS[i]
        local e, u = errIn[hand], errUse[hand]
        local pose = i == 1 and lh or rh
        local hp, ha = pose.pos, pose.ang
        local live = e.on and now - e.t < 0.3 and now >= e.ignore -- a lost clear expires
        if e.pred and e.predT and not live then
            if dbgHE then print(string.format("[HullErr] %s prediction expired after %.0fms, no server pin", i == 2 and "R" or "L", (now - e.predT) * 1000)) end
            e.predT, e.predExp = nil, e.predT
        end
        if not (live or u.on) and predOK and hasPrev[i] and now >= e.ignore and not IsValid(i == 1 and g_VR.heldEntityLeft or g_VR.heldEntityRight) then
            live = Predict(i, e, pose, now) or false
        end
        if e.dbg then
            print(e.dbg .. "\n    prediction: " .. (predStat[i] ~= "" and predStat[i] or "never ran (contact live, slow, held, or off)"))
            e.dbg, predStat[i] = nil, ""
        end
        -- A held prop pressed on a surface turns against it on the server
        -- (tipped flat on a floor, say). The lift only moves the hand, so
        -- the prop drawn on it stayed upright and sank in. The hand turns
        -- with the server's prop instead -- eased, as that turn arrives a
        -- tick at a time -- so the prop drawn on it matches, and the lift
        -- below is measured on that pose, as the server measured it.
        local rp, ry, rr = u.rp, u.ry, u.rr
        local gp, gy, gr = 0, 0, 0
        if live and e.plane and e.held then gp, gy, gr = AUnpack(e.ra) end
        if rp ~= gp or ry ~= gy or rr ~= gr then
            rp, ry, rr = rp + AngD(gp, rp) * kRot, ry + AngD(gy, ry) * kRot, rr + AngD(gr, rr) * kRot
            if gp == 0 and gy == 0 and gr == 0 and rp * rp + ry * ry + rr * rr < 0.01 then rp, ry, rr = 0, 0, 0 end
            u.rp, u.ry, u.rr = rp, ry, rr
        end
        if rp ~= 0 or ry ~= 0 or rr ~= 0 then
            ASetU(_raA, rp, ry, rr)
            local _, a = LocalToWorld(ZV, _raA, ZV, ha)
            ha = a
            pose.ang = a
            right = right or i == 2
        end
        local w = u.w
        local pen = live and e.plane and Plane(e) and Pen(e, hp, ha)
        if pen and pen < (e.pred and PEN_MAX or PEN_SRV) then
            if pen < 0 then pen = 0 end
            -- A held prop's contact is never predicted: it lands a round
            -- trip after the prop met the surface, already that deep, and
            -- lifting all of it in one frame jerked the hand. Deepening
            -- eases in (~11ms); backing out stays instant.
            if e.held and pen > u.pen then pen = u.pen + (pen - u.pen) * kIn end
            u.pen = pen
            local nx, ny, nz = VUnpack(e.cN)
            VSetU(w, nx * pen, ny * pen, nz * pen)
            u.wOn = true
            if u.on then
                u.on = false
                u.p:SetUnpacked(0, 0, 0)
                u.a:SetUnpacked(0, 0, 0)
            end
        else
            if u.wOn then
                w:Mul(1 - kOff)
                u.pen = u.pen * (1 - kOff)
                if w:LengthSqr() < 0.0001 then
                    w:SetUnpacked(0, 0, 0)
                    u.wOn, u.pen = false, 0
                end
            end
            -- Pose pin: released once the hand is back past it along the push
            local on = live and not e.plane
            if on and e.hasN then
                local q, n = e.p, e.n
                on = (hp.x - q.x) * n.x + (hp.y - q.y) * n.y + (hp.z - q.z) * n.z > 0
            end
            if on or u.on then
                local tp, ta = ZV, ANG0
                if on then tp, ta = WorldToLocal(e.p, e.a, hp, ha) end
                local k = on and kOn or kOff
                local p = u.p
                p.x, p.y, p.z = p.x + (tp.x - p.x) * k, p.y + (tp.y - p.y) * k, p.z + (tp.z - p.z) * k
                u.a = LerpAngle(k, u.a, ta)
                local a = u.a
                u.on = on or p:LengthSqr() >= 0.01 or a.p * a.p + a.y * a.y + a.r * a.r >= 0.01
                if not u.on then
                    p:SetUnpacked(0, 0, 0)
                    a:SetUnpacked(0, 0, 0)
                end
            end
        end
        if u.on then
            pose.pos, pose.ang = LocalToWorld(u.p, u.a, hp, ha)
            right = right or i == 2
        end
        if u.wOn and (w.x ~= 0 or w.y ~= 0 or w.z ~= 0) then
            pose.pos = pose.pos + w
            right = right or i == 2
        end
        VSet(prevP[i], pose.pos)
        ASet(prevA[i], pose.ang)
        hasPrev[i] = true
    end
    return right
end

-- GRAB POSE. A grab is anchored to the RAW controller pose, captured here
-- before any collision: sh_pickup measures the grip offset on it and sends
-- it to the server, which anchors bones and props to it too. Anchoring to
-- the corrected pose, then freezing that correction for the whole hold,
-- held whatever you took off your real hand by however far a wall, an NPC's
-- hitbox or a stuck hand prop had pushed the hand at that moment -- off to
-- the side, and orbiting it as the wrist turned. Now the object stays put
-- and the hand settles into the grip. Hull error is dropped when a hold
-- starts or ends: the hand's error source switches (hand prop <-> held
-- prop, sh_pickup_util), and stale errors from the old one are in flight.
-- At the start it's zeroed (the hand settles with the object); at the end
-- it eases off.
local rawP, rawA, wasHeld, hasRaw = {}, {}, {}, false
for i = 1, 2 do
    local h = HANDS[i]
    rawP[h], rawA[h], wasHeld[h] = Vector(), Angle(), false
end
function U.CaptureRawPose(lh, rh)
    for i = 1, 2 do
        local hand, pose = HANDS[i], i == 1 and lh or rh
        local held = IsValid(i == 1 and g_VR.heldEntityLeft or g_VR.heldEntityRight)
        if held ~= wasHeld[hand] then
            local e = errIn[hand]
            e.on, e.ignore = false, SysTime() + (held and 0.25 or 0.15)
            if held then
                local u = errUse[hand]
                u.on, u.wOn, u.pen, u.rp, u.ry, u.rr = false, false, 0, 0, 0, 0
                u.p:SetUnpacked(0, 0, 0)
                u.a:SetUnpacked(0, 0, 0)
                u.w:SetUnpacked(0, 0, 0)
            end
        end
        wasHeld[hand] = held
        VSet(rawP[hand], pose.pos)
        ASet(rawA[hand], pose.ang)
    end
    hasRaw = true
end
-- Live references: copy to keep. Nil until the first VR frame.
function U.RawHandPose(left)
    if not hasRaw then return end
    local h = left and "left" or "right"
    return rawP[h], rawA[h]
end

-- The hand poses the server props chase: after the world and body
-- collisions, before ApplyHullError (the props are where that comes from,
-- so no feedback). World space as this client has it -- the network frame
-- is relative to the player's position, which the server has a step behind
-- while you move, so props driven off it trailed you. Unreliable, every
-- rendered frame up to 150/s (the prop chases the freshest pose at each
-- physics step), both hands in one message. The pickup controller drives
-- held things from it too, so it also flows while holding with hand physics off.
local POSE_MIN, nextPose, cvHandPhys = 1 / 150, 0
function U.SendHandPose(lh, rh)
    if cvHandPhys == nil then cvHandPhys = GetConVar("vrmod_hand_physics") or false end
    if cvHandPhys and not cvHandPhys:GetBool() and not (g_VR.heldEntityLeft or g_VR.heldEntityRight) then return end
    local now = SysTime()
    if now < nextPose then return end
    nextPose = now + POSE_MIN
    net.Start("vrmod_hand_pose", true)
    net.WriteVector(lh.pos)
    net.WriteAngle(lh.ang)
    net.WriteVector(rh.pos)
    net.WriteAngle(rh.ang)
    net.WriteBool(GunLeft()) -- which hand gets the weapon's physics
    poseSeq = poseSeq % 65535 + 1 -- 0 is "none"
    local j = poseSeq % 64
    poseT[j], poseS[j] = now, poseSeq
    net.WriteUInt(poseSeq, 16)
    net.WriteUInt(now * 1000 % 65536, 16) -- send clock (ms): the server plays poses back on it
    net.SendToServer()
end