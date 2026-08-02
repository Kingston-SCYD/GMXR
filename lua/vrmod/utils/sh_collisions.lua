g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}
local cl_effectmodel = CreateClientConVar("vrmod_melee_fist_collisionmodel", "models/props_junk/PopCan01a.mdl", true, FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE)
--GLOBALS
vrmod.SMOOTHING_FACTOR = 0.98
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

vrmod.modelCache = {}
vrmod.collisionSpheres = {}
vrmod.collisionBoxes = {}
vrmod._collisionShapeByHand = { left = nil, right = nil }
vrmod._lastRelFrame = {}

-- Pre-allocated hand iterator — avoids creating {"left","right"} table every frame
local HANDS = {"left", "right"}

-- Collision detection thresholds — hoisted as upvalues for faster access
local HAND_POS_TOLERANCE = 0.05
local HAND_ANG_TOLERANCE = 1.0

local pending = {}
local lastLeftPos = Vector(0, 0, 0)
local lastRightPos = Vector(0, 0, 0)
local lastRightAng = Angle(0, 0, 0)
local lastNonClippedPos = {
    left = nil,
    right = nil
}

local lastNonClippedNormal = {
    left = nil,
    right = nil
}

local cachedPushOutPos = {
    left = nil,
    right = nil
}

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

local function SphereCollidesWithWorld(pos, radius)
    local hullSize = Vector(radius, radius, radius)
    local tr = util.TraceHull({
        start = pos,
        endpos = pos,
        mins = -hullSize,
        maxs = hullSize,
        mask = MASK_SOLID_BRUSHONLY
    })
    if not tr.Hit or not tr.HitWorld then return false, Vector(0, 0, 1) end
    local hitNormal = tr.HitNormal
    if hitNormal:LengthSqr() < 0.01 then hitNormal = Vector(0, 0, 1) end
    return true, hitNormal
end

local function BoxCollidesWithWorld(pos, ang, mins, maxs, reach)
    ang = ang or Angle()
    ang:Normalize()
    local hullMins, hullMaxs
    local tr
    if not reach then
        hullMins = Vector(mins.x, mins.y, mins.z)
        hullMaxs = Vector(maxs.x, maxs.y, maxs.z)
        tr = util.TraceHull({
            start = pos,
            endpos = pos,
            angles = ang,
            mins = hullMins,
            maxs = hullMaxs,
            mask = MASK_SOLID_BRUSHONLY
        })
    else
        hullMins = Vector(mins.x, mins.y, mins.z)
        hullMaxs = Vector(maxs.x, maxs.y, maxs.z)
        local sweepEnd = pos + ang:Forward() * reach
        tr = util.TraceHull({
            start = pos,
            endpos = sweepEnd,
            angles = ang,
            mins = hullMins,
            maxs = hullMaxs,
            mask = MASK_SOLID_BRUSHONLY
        })
    end

    if not tr.Hit or not tr.HitWorld then return false, Vector(0, 0, 1), pos end
    local hitNormal = tr.HitNormal
    local pushPos
    if not tr.StartSolid then
        -- Started free, hit during movement/sweep: back off slightly from contact center pos
        if tr.StartPos and tr.EndPos and tr.Fraction then
            local contactCenter = tr.StartPos + (tr.EndPos - tr.StartPos) * tr.Fraction
            pushPos = contactCenter - tr.HitNormal * 0.1
        else
            -- Fallback if trace data is invalid
            pushPos = pos - (hitNormal:IsZero() and Vector(0, 0, 1) or hitNormal) * 0.1
        end
    else
        -- Started in solid: iterative resolution to find free pos
        if hitNormal:LengthSqr() < 0.1 then
            hitNormal = Vector(0, 0, 1) -- Default to up if no valid initial normal
        end

        local boxSize = math.max(hullMaxs.x - hullMins.x, hullMaxs.y - hullMins.y, hullMaxs.z - hullMins.z) / 2
        pushPos = pos
        local maxIterations = 5
        for _ = 1, maxIterations do
            local pushTrace = util.TraceHull({
                start = pushPos,
                endpos = pushPos + hitNormal * boxSize * 1.1,
                angles = ang,
                mins = hullMins,
                maxs = hullMaxs,
                mask = MASK_SOLID_BRUSHONLY
            })

            if not pushTrace.Hit then
                pushPos = pushTrace.EndPos
                break
            else
                pushPos = pushTrace.HitPos + pushTrace.HitNormal * 0.1
                hitNormal = pushTrace.HitNormal
            end
        end
    end
    return true, hitNormal, pushPos
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
function vrmod.utils.ComputePhysicsParams(modelPath)
    if not modelPath or modelPath == "" then
        if DebugEnabled() then vrmod.logger.Warn("Invalid or empty model path, caching defaults") end
        vrmod.modelCache[modelPath] = {
            radius = vrmod.DEFAULT_RADIUS,
            reach = vrmod.DEFAULT_REACH,
            mins_horizontal = vrmod.DEFAULT_MINS,
            maxs_horizontal = vrmod.DEFAULT_MAXS,
            mins_vertical = vrmod.DEFAULT_MINS,
            maxs_vertical = vrmod.DEFAULT_MAXS,
            angles = vrmod.DEFAULT_ANGLES,
            computed = true,
            isMelee = false
        }
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
                vrmod.modelCache[originalModelPath] = {
                    radius = vrmod.DEFAULT_RADIUS,
                    reach = vrmod.DEFAULT_REACH,
                    mins_horizontal = vrmod.DEFAULT_MINS,
                    maxs_horizontal = vrmod.DEFAULT_MAXS,
                    mins_vertical = vrmod.DEFAULT_MINS,
                    maxs_vertical = vrmod.DEFAULT_MAXS,
                    angles = vrmod.DEFAULT_ANGLES,
                    computed = true,
                    isMelee = false
                }
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
        vrmod.modelCache[originalModelPath] = {
            radius = vrmod.DEFAULT_RADIUS,
            reach = vrmod.DEFAULT_REACH,
            mins_horizontal = vrmod.DEFAULT_MINS,
            maxs_horizontal = vrmod.DEFAULT_MAXS,
            mins_vertical = vrmod.DEFAULT_MINS,
            maxs_vertical = vrmod.DEFAULT_MAXS,
            angles = vrmod.DEFAULT_ANGLES,
            computed = true,
            isMelee = false
        }

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
            mins_horizontal, maxs_horizontal, _, amin, amax = GetWeaponCollisionBox(phys, false)
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

function vrmod.utils.GetModelParams(modelPath, ply, offsetAng)
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
                if CLIENT then
                    net.Start("vrmod_sync_model_params")
                    net.WriteString(modelPath)
                    net.WriteFloat(cache.radius)
                    net.WriteFloat(cache.reach)
                    net.WriteVector(mins)
                    net.WriteVector(maxs)
                    net.WriteVector(cache.mins_vertical)
                    net.WriteVector(cache.maxs_vertical)
                    net.WriteAngle(cache.angles)
                    net.SendToServer()
                    if DebugEnabled() then vrmod.logger.Info("GetModelParams: Sent computed params for %s to server", modelPath) end
                elseif SERVER then
                    net.Start("vrmod_sync_model_params")
                    net.WriteString(modelPath)
                    net.WriteFloat(cache.radius)
                    net.WriteFloat(cache.reach)
                    net.WriteVector(mins)
                    net.WriteVector(maxs)
                    net.WriteVector(cache.mins_vertical)
                    net.WriteVector(cache.maxs_vertical)
                    net.WriteAngle(cache.angles)
                    net.Broadcast()
                    if DebugEnabled() then vrmod.logger.Info("GetModelParams: Sent computed params for %s to clients", modelPath) end
                end

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
            vrmod.utils.ComputePhysicsParams(modelPath)
            -- Optionally re-call GetModelParams to trigger sync after computation
            if vrmod.modelCache[modelPath] and vrmod.modelCache[modelPath].computed then vrmod.utils.GetModelParams(modelPath, ply, offsetAng) end
        end)

        if DebugEnabled() then vrmod.logger.Debug("GetModelParams: Scheduled computation for %s", modelPath) end
    end
    return vrmod.DEFAULT_RADIUS, vrmod.DEFAULT_REACH, vrmod.DEFAULT_MINS, vrmod.DEFAULT_MAXS, vrmod.GetRightHandAng(ply), false
end

function vrmod.utils.GetWeaponMeleeParams(wep, ply, hand)
    local model = cl_effectmodel:GetString()
    local offsetAng = vrmod.DEFAULT_ANGLES
    if hand == "right" then
        local class, vm = vrmod.utils.WepInfo(wep)
        if not class then return vrmod.DEFAULT_RADIUS, vrmod.DEFAULT_REACH end
        if CLIENT then
            local vmInfo = g_VR.viewModelInfo[class]
            offsetAng = vmInfo and vmInfo.offsetAng or vrmod.DEFAULT_ANGLES
            model = vm
        else
            model = vrmod.MODEL_OVERRIDES[class] or wep:GetModel()
        end
        return vrmod.utils.GetModelParams(model, ply, offsetAng)
    else
        return vrmod.utils.GetModelParams(model, ply, offsetAng)
    end
end

function vrmod.utils.GetCachedWeaponParams(wep, ply, side)
    if not vrmod.utils.IsValidWep(wep) then return nil end
    local radius, reach, mins, maxs, angles, isMelee = vrmod.utils.GetWeaponMeleeParams(wep, ply, side)
    local model = vrmod.utils.WepInfo(wep)
    if SERVER and vrmod.modelCache[model] and vrmod.modelCache[model].computed then
        local c = vrmod.modelCache[model]
        if DebugEnabled() then vrmod.logger.Info("GetCachedWeaponParams: Using server-side synced params for %s", model) end
        return c.radius, c.reach, c.mins_horizontal, c.maxs_horizontal, c.angles, c.isMelee
    end

    if pending[model] and CurTime() - (pending[model].lastAttempt or 0) < 2 then
        if DebugEnabled() then vrmod.logger.Debug("GetCachedWeaponParams: Computation pending for %s, waiting", model) end
        return nil
    end

    if radius ~= vrmod.DEFAULT_RADIUS or reach ~= vrmod.DEFAULT_REACH or mins ~= vrmod.DEFAULT_MINS then return radius, reach, mins, maxs, angles, isMelee end
    if not pending[model] then
        if DebugEnabled() then
            vrmod.logger.Debug("GetCachedWeaponParams: Scheduling computation for %s", model)
            timer.Simple(0, function() vrmod.utils.ComputePhysicsParams(model) end)
        end
    end
    return nil
end

function vrmod.utils.AdjustCollisionsBox(pos, ang, isMelee)
    local forwardOffset = isMelee and 3 or 10
    local leftOffset = isMelee and 1 or 1.5
    local upOffset = 4
    local adjustedPos = pos + ang:Forward() * forwardOffset - ang:Right() * leftOffset + ang:Up() * upOffset
    return adjustedPos
end

function vrmod.utils.GetClimbingGripState()
    local climb = vrmod and vrmod.climbing
    if not climb then return false, false end
    return climb.gripLeft or false, climb.gripRight or false
end

local cvCollisions = CreateClientConVar("vrmod_collisions", "1", true, false, "Enable VR hand/weapon wall collisions", 0, 1)
function vrmod.utils.CollisionsPreCheck(leftPos, rightPos)
    local ply = LocalPlayer()
    -- cvCollisions: the settings checkbox existed but was never read — the
    -- broad-phase is the one place that gates both hand clip and weapon pushout.
    if not cvCollisions:GetBool() or not IsValid(ply) or not g_VR.active or not ply:GetNWBool("vrmod_server_enforce_collision", true) or ply:GetMoveType() == MOVETYPE_NOCLIP or not ply:Alive() or not vrmod.IsPlayerInVR(ply) or ply:InVehicle() then
        vrmod._collisionNearby = false
        return
    end

    local leftGrip, rightGrip = vrmod.utils.GetClimbingGripState()
    local bigRadius = vrmod.utils.IsValidWep(ply:GetActiveWeapon()) and 69 or 30
    local leftNearby = not leftGrip and SphereCollidesWithWorld(leftPos, 30)
    local rightNearby = not rightGrip and SphereCollidesWithWorld(rightPos, bigRadius)
    vrmod._collisionNearby = leftNearby or rightNearby
end

function vrmod.utils.CheckWorldCollisions(pos, radius, mins, maxs, ang, hand, reach)
    local leftGrip, rightGrip = vrmod.utils.GetClimbingGripState()
    local gripping = hand == "left" and leftGrip or hand == "right" and rightGrip
    local shapeMins = mins or Vector(-radius, -radius, -radius)
    local shapeMaxs = maxs or Vector(radius, radius, radius)
    ang = ang or Angle(0, 0, 0) -- Fallback to zero angle
    ang:Normalize()
    local isClipped, hitNormal
    if mins and maxs then
        -- Clipping check: full box, no reach
        --isClipped, hitNormal = SphereCollidesWithWorld(pos, reach)
        isClipped, hitNormal = BoxCollidesWithWorld(pos, ang, shapeMins, shapeMaxs)
        if DebugEnabled() then if isClipped then vrmod.logger.Debug("Box collision for:", hand, "Pos:", pos, "Angles:", ang, "Mins:", shapeMins, "Maxs:", shapeMaxs, "Hit:", isClipped) end end
    else
        if not radius then radius = vrmod.DEFAULT_RADIUS end
        isClipped, hitNormal = SphereCollidesWithWorld(pos, radius)
        if DebugEnabled() then if isClipped then vrmod.logger.Debug("Sphere collision for:", hand, "Pos:", pos, "Radius:", radius, "Hit:", isClipped) end end
    end

    local pushOutPos = pos
    if isClipped and not gripping then
        -- Use last free position as the surface plane anchor
        pushOutPos = lastNonClippedPos[hand] or (pos + hitNormal)
        cachedPushOutPos[hand] = pushOutPos
    else
        lastNonClippedPos[hand] = pos
        cachedPushOutPos[hand] = nil
    end

    local reachHit
    if mins and maxs then
        reachHit, _ = BoxCollidesWithWorld(pos, ang, shapeMins, shapeMaxs, reach)
    else
        local tr = util.TraceLine({
            start = pos,
            endpos = pos + ang:Forward() * reach,
            mask = MASK_SOLID_BRUSHONLY
        })

        reachHit = tr.Hit and tr.HitWorld or false
    end

    local shape = {
        pos = pos,
        radius = radius,
        mins = shapeMins,
        maxs = shapeMaxs,
        angles = ang,
        hit = reachHit,
        pushOutPos = pushOutPos,
        isClipped = isClipped,
        hitNormal = hitNormal,
        -- OPTIMIZATION: reuse isClipped instead of running a redundant trace.
        -- Previously this line ran BoxCollidesWithWorld or SphereCollidesWithWorld
        -- a second time with the exact same parameters as the isClipped check above.
        hitWorld = isClipped,
    }

    return shape
end

function vrmod.utils.CheckWeaponPushout(pos, ang)
    --local pos, ang = g_VR.viewModelPos, g_VR.viewModelAng
    -- Early out if no collision broad-phase
    if not vrmod._collisionNearby then
        table.Empty(vrmod.collisionBoxes)
        return pos, ang
    end

    -- Addon override: return false from VRMod_AllowWeaponPushout to keep the
    -- weapon at its tracked pose (no wall slide) this frame.
    if hook.Run("VRMod_AllowWeaponPushout", pos, ang) == false then
        table.Empty(vrmod.collisionBoxes)
        return pos, ang
    end

    local ply = LocalPlayer()
    if not IsValid(ply) then return pos, ang end
    local wep = ply:GetActiveWeapon()
    if not vrmod.utils.IsValidWep(wep) then return pos, ang end
    local radius, reach, mins, maxs, _, isMelee = vrmod.utils.GetCachedWeaponParams(wep, ply, "right")
    radius = radius or vrmod.DEFAULT_RADIUS
    mins = mins or vrmod.DEFAULT_MINS
    maxs = maxs or vrmod.DEFAULT_MAXS
    reach = reach or vrmod.DEFAULT_REACH
    if not isnumber(reach) then reach = math.max(math.abs(maxs.x), math.abs(maxs.y), math.abs(maxs.z)) * 2 end
    local adjustedPos = vrmod.utils.AdjustCollisionsBox(pos, ang, isMelee)
    local shape = vrmod.utils.CheckWorldCollisions(adjustedPos, nil, mins, maxs, ang, "right", reach)
    -- OPTIMIZATION: clear and reuse table instead of replacing with {}
    table.Empty(vrmod.collisionBoxes)
    if shape then
        vrmod.collisionBoxes[1] = shape
    end

    if shape and shape.isClipped and shape.pushOutPos and type(shape.pushOutPos) == "Vector" then
        local normal = shape.hitNormal
        local plyPos = g_VR.tracking.hmd.pos or Vector()
        local distanceSqr = (shape.pushOutPos - plyPos):LengthSqr()
        if distanceSqr > 500 then
            table.Empty(vrmod.collisionBoxes)
            return pos, ang
        end

        -- Plane projection: slide weapon along surface
        local penetration = (pos - shape.pushOutPos):Dot(normal)
        if penetration >= 0 then return pos, ang end
        local correctedPos = pos - normal * penetration

        -- Calculate corrected angle
        local correctedAng = Angle(ang.pitch, ang.yaw, ang.roll)
        local forward = ang:Forward()
        local dot = forward:Dot(normal)
        if math.abs(dot) > 0.1 then -- Only adjust if not already nearly perpendicular
            -- Project forward onto plane perpendicular to normal
            local adjustedForward = forward - normal * dot
            adjustedForward:Normalize()
            -- Reconstruct angle from adjusted forward vector, preserving right and up as much as possible
            local newRight = adjustedForward:Cross(normal)
            newRight:Normalize()
            local newUp = newRight:Cross(adjustedForward)
            newUp:Normalize()
            correctedAng = adjustedForward:Angle()
            correctedAng:RotateAroundAxis(newRight, ang:Up():Dot(newUp) < 0 and -90 or 90)
        end

        if DebugEnabled() then vrmod.logger.Debug("Weapon clipping detected. Push-out pos:", correctedPos, "angle:", correctedAng) end
        return correctedPos, correctedAng
    end
    return pos, ang
end

function vrmod.utils.UpdateHandCollisions(lefthandPos, lefthandAng, righthandPos, righthandAng)
    if not vrmod._collisionNearby then
        if #vrmod.collisionSpheres > 0 then table.Empty(vrmod.collisionSpheres) end
        vrmod._collisionShapeByHand.left = nil
        vrmod._collisionShapeByHand.right = nil
        return lefthandPos, lefthandAng, righthandPos, righthandAng
    end

    local ply = LocalPlayer()
    if not IsValid(ply) then return lefthandPos, lefthandAng, righthandPos, righthandAng end
    local wep = ply:GetActiveWeapon()
    if not vrmod.utils.IsValidWep(wep) then table.Empty(vrmod.collisionBoxes) end

    table.Empty(vrmod.collisionSpheres)
    vrmod._collisionShapeByHand.left = nil
    vrmod._collisionShapeByHand.right = nil

    local hmdPos = g_VR.tracking.hmd.pos
    if not hmdPos then return lefthandPos, lefthandAng, righthandPos, righthandAng end

    local leftGrip, rightGrip = vrmod.utils.GetClimbingGripState()

    for _, hand in ipairs(HANDS) do
        local gripping = (hand == "left") and leftGrip or (hand == "right") and rightGrip
        local handPos = hand == "left" and lefthandPos or righthandPos
        local ang = hand == "left" and lefthandAng or righthandAng

        -- Addon override: return false from VRMod_AllowHandCollision to skip
        -- clip handling for this hand this frame. Skipping (or gripping) also
        -- skips the HMD→hand trace entirely.
        local skip = gripping or hook.Run("VRMod_AllowHandCollision", hand, handPos, ang) == false
        local isClipped, tr = false, nil
        if not skip then
            -- Ray from HMD toward hand, extended slightly past for earlier detection
            local dir = handPos - hmdPos
            tr = util.TraceLine({
                start = hmdPos,
                endpos = handPos + dir:GetNormalized() * 1.25,
                mask = MASK_SOLID_BRUSHONLY
            })
            isClipped = tr.Hit and tr.HitWorld and tr.Fraction < 0.99
        end
        local shape = {
            pos = handPos,
            radius = vrmod.DEFAULT_RADIUS,
            mins = Vector(-vrmod.DEFAULT_RADIUS, -vrmod.DEFAULT_RADIUS, -vrmod.DEFAULT_RADIUS),
            maxs = Vector(vrmod.DEFAULT_RADIUS, vrmod.DEFAULT_RADIUS, vrmod.DEFAULT_RADIUS),
            angles = ang,
            hit = isClipped,
            isClipped = isClipped,
            hitNormal = tr and tr.HitNormal or nil,
            hitWorld = isClipped,
            pushOutPos = isClipped and tr.HitPos or handPos,
        }
        vrmod.collisionSpheres[#vrmod.collisionSpheres + 1] = shape
        vrmod._collisionShapeByHand[hand] = shape

        if isClipped then
            g_VR._cachedFrameRelative = nil
            g_VR._cachedFrameAbsolute = nil
            local normal = tr.HitNormal
            local corrected = tr.HitPos + normal * 0.5

            -- Angle palm flat against wall: back of hand faces player, fingers slide along surface
            local fwd = ang:Forward()
            -- Project finger direction onto wall plane
            fwd = fwd - normal * fwd:Dot(normal)
            if fwd:LengthSqr() < 0.001 then fwd = ang:Right():Cross(normal) end
            fwd:Normalize()
            local wallAng = fwd:Angle()
            -- Compute roll to align hand's up with wall normal (palm flat on surface)
            local noRollRight = wallAng:Right()
            local noRollUp = wallAng:Up()
            -- Blend out the 90° palm flip on floors/ceilings where the angle's natural up already matches the normal
            local vertBlend = 1 - math.abs(normal.z)
            local rollOffset = (hand == "left" and -90 or 90) * vertBlend
            wallAng.roll = math.deg(math.atan2(-normal:Dot(noRollRight), normal:Dot(noRollUp))) + rollOffset

            if hand == "left" then
                lefthandPos = corrected
                lefthandAng = wallAng
                if g_VR.input and g_VR.input.skeleton_lefthand then
                    local fc = g_VR.input.skeleton_lefthand.fingerCurls
                    if fc then for i = 1, 5 do fc[i] = 0 end end
                end
            else
                righthandPos = corrected
                righthandAng = wallAng
                if g_VR.input and g_VR.input.skeleton_righthand then
                    local fc = g_VR.input.skeleton_righthand.fingerCurls
                    if fc then for i = 1, 5 do fc[i] = 0 end end
                end
            end
        end
    end
    return lefthandPos, lefthandAng, righthandPos, righthandAng
end

function vrmod.utils.SphereCollidesWithProp(pos, radius, filter)
    local hullSize = Vector(radius, radius, radius)
    local tr = util.TraceHull({
        start = pos,
        endpos = pos,
        mins = -hullSize,
        maxs = hullSize,
        mask = MASK_SOLID,
        filter = filter
    })

    if not tr.Hit or not IsValid(tr.Entity) then return false end
    if tr.Entity:IsWorld() then return false end
    return tr.Entity, tr.HitNormal
end