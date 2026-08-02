if CLIENT then return end
local vrHands = {}
local SIDES = {"right", "left"} -- hoisted: no per-call table alloc in spawn/repair loops
-- Master switch for the server-side hand physics props. On (default): solid vphysics
-- hands that push objects. Off: nothing spawns, so nothing can block bullets/movement.
local cv_handphysics = CreateConVar("vrmod_hand_physics", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY, "Enable server-side VR hand physics props. Disable to stop hands interacting with the world.")
-- Utility to get cached physics data from weapon
local function GetCachedWeaponParams(wep, ply, side)
    local radius, reach, mins, maxs, angles = vrmod.utils.GetWeaponMeleeParams(wep, ply, side)
    if radius == vrmod.DEFAULT_RADIUS and reach == vrmod.DEFAULT_REACH then return nil end
    return radius, reach, mins, maxs, angles
end

-- Applies sphere collision
local function ApplySphere(hand, handData, radius)
    if not IsValid(hand) then return end
    hand:PhysicsInitSphere(radius, "metal_bouncy")
    local phys = hand:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMass(20)
        handData.phys = phys
    end
end

-- Applies box collision
local function ApplyBox(hand, handData, mins, maxs, angles)
    if not IsValid(hand) then return end
    hand:PhysicsInitBox(mins, maxs)
    --hand:SetAngles(angles)
    local phys = hand:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMass(20)
        handData.phys = phys
    end
end

-- Apply appropriate collision shape based on weapon
local function UpdateWeaponCollisionShape(ply, wep)
    if not cv_handphysics:GetBool() then return end
    if not IsValid(ply) or not vrmod.IsPlayerInVR(ply) then return end
    timer.Simple(0.1, function()
        if not IsValid(ply) or not vrmod.IsPlayerInVR(ply) then return end
        local hands = vrHands[ply]
        if not hands or not hands.right or not IsValid(hands.right.ent) then
            vrmod.logger.Debug("UpdateWeaponCollisionShape: No valid right hand for %s", ply:Nick())
            return
        end

        local right = hands.right
        local hand = right.ent
        if not vrmod.utils.IsValidWep(wep) then
            vrmod.logger.Debug("UpdateWeaponCollisionShape: Invalid weapon %s, applying default sphere", tostring(wep))
            timer.Simple(0, function() ApplySphere(hand, right, vrmod.DEFAULT_RADIUS) end)
            return
        end

        local radius, reach, mins, maxs, angles = GetCachedWeaponParams(wep, ply, "right")
        if not radius or not mins or not maxs or not angles or radius == vrmod.DEFAULT_RADIUS and reach == vrmod.DEFAULT_REACH and mins == vrmod.DEFAULT_MINS and maxs == vrmod.DEFAULT_MAXS then
            vrmod.logger.Debug("UpdateWeaponCollisionShape: Invalid or default params for %s, retrying", wep:GetClass())
            timer.Simple(0.5, function() UpdateWeaponCollisionShape(ply, wep) end)
            return
        end

        vrmod.logger.Debug("UpdateWeaponCollisionShape: Applying box for %s, mins=%s, maxs=%s", wep:GetClass(), tostring(mins), tostring(maxs))
        timer.Simple(0, function() ApplyBox(hand, right, mins, maxs, angles) end)
    end)
end

-- Triggers on weapon switch
hook.Add("PlayerSwitchWeapon", "VRHand_UpdateCollisionOnWeaponSwitch", function(ply, oldWep, newWep) UpdateWeaponCollisionShape(ply, newWep) end)
local function SpawnVRHands(ply)
    if not cv_handphysics:GetBool() then return end
    if not IsValid(ply) or not ply:Alive() or not vrmod.IsPlayerInVR(ply) then return end
    if not vrHands[ply] then vrHands[ply] = {} end
    local hands = vrHands[ply]
    for _, side in ipairs(SIDES) do
        timer.Simple(0, function()
            if not IsValid(ply) or not ply:Alive() then return end
            local handData = hands[side]
            local hand = handData and IsValid(handData.ent) and handData.ent or nil
            if not IsValid(hand) then
                hand = ents.Create("base_anim")
                if not IsValid(hand) then return end
                hand:SetPos(ply:GetPos())
                hand:SetModel("models/props_junk/PopCan01a.mdl")
			hand:Spawn()
                hand:SetPersistent(true)
                hand:SetNoDraw(true)
                hand:DrawShadow(false)
                hand:SetNWBool("isVRHand", true)
                -- no model, just physics sphere
                local radius = 2
                hand:PhysicsInitSphere(radius, "metal_bouncy")
                hand:SetCollisionBounds(Vector(-radius, -radius, -radius), Vector(radius, radius, radius))
                hand:SetCollisionGroup(COLLISION_GROUP_WEAPON)
                hand:Activate()
                local phys = hand:GetPhysicsObject()
                if IsValid(phys) then
                    phys:SetMass(20)
                    hands[side] = {
                        ent = hand,
                        phys = phys
                    }
                else
                    hand:Remove()
                    return
                end
            end
        end)
    end

    timer.Simple(0.1, function()
        if IsValid(ply) and hands.right and IsValid(hands.right.ent) then
            local wep = ply:GetActiveWeapon()
            if vrmod.utils.IsValidWep(wep) then UpdateWeaponCollisionShape(ply, wep) end
        end
    end)
end

local function RemoveVRHands(ply)
    if not IsValid(ply) then return end
    local hands = vrHands[ply]
    if not hands then return end
    for _, side in pairs(hands) do
        local ent = side.ent
        if IsValid(ent) then
            ent:SetNoDraw(true)
            ent:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
            ent:SetPos(Vector(0, 0, -10000))
            if IsValid(side.phys) then
                side.phys:EnableMotion(false)
                side.phys:Sleep()
            end
        end
    end
end

-- Full teardown for the disable path: delete props + clear state so re-enable rebuilds fresh.
local function DestroyVRHands(ply)
    local hands = vrHands[ply]
    if not hands then return end
    for _, side in pairs(hands) do
        if IsValid(side.ent) then side.ent:Remove() end
    end

    vrHands[ply] = nil
end

hook.Add("PlayerTick", "VRHand_PhysicsSync", function(ply)
    if not cv_handphysics:GetBool() then return end
    local hands = vrHands[ply]
    if (not hands or not hands.right or not hands.left) and not ply:InVehicle() then
        RemoveVRHands(ply)
        timer.Simple(1, function() SpawnVRHands(ply) end)
        return
    elseif ply:InVehicle() then
        RemoveVRHands(ply)
        return
    end

    local function UpdateHand(side, getPos, getAng)
        local hand = hands[side]
        if not hand or not IsValid(hand.ent) or not IsValid(hand.phys) then return end
        local pos = getPos(ply)
        local ang = getAng(ply)
        -- Apply forward offset
        local offsetPos = pos + ang:Forward() * vrmod.DEFAULT_OFFSET
        local phys = hand.phys
        phys:Wake()
        phys:ComputeShadowControl({
            secondstoarrive = engine.TickInterval(),
            pos = offsetPos,
            angle = ang,
            maxangular = 5000,
            maxangulardamp = 5000,
            maxspeed = 2000000,
            maxspeeddamp = 20000,
            dampfactor = 0.3,
            teleportdistance = 2000,
            deltatime = 0,
        })
    end

    UpdateHand("right", vrmod.GetRightHandPos, vrmod.GetRightHandAng)
    UpdateHand("left", vrmod.GetLeftHandPos, vrmod.GetLeftHandAng)
end)

hook.Add("VRMod_Pickup", "VRHand_BlockPickup", function(ply, ent)
    local hands = vrHands[ply]
    if hands and (ent == hands.right.ent or ent == hands.left.ent) then return false end
end)

hook.Add("VRMod_Start", "VRHand_VRStart", function(ply) SpawnVRHands(ply) end)
hook.Add("PlayerSpawn", "VRHand_PlayerSpawn", function(ply) if vrmod.IsPlayerInVR(ply) then timer.Simple(0.1, function() if IsValid(ply) then SpawnVRHands(ply) end end) end end)
hook.Add("PlayerDeath", "VRHand_PlayerDeath", function(ply) RemoveVRHands(ply) end)
hook.Add("VRMod_Exit", "VRHand_VREnd", function(ply) RemoveVRHands(ply) end)
hook.Add("PlayerDisconnected", "VRHand_Disconnect", function(ply)
    if vrHands[ply] then
        for _, side in pairs(vrHands[ply]) do
            if IsValid(side.ent) then side.ent:Remove() end
        end

        vrHands[ply] = nil
    end
end)

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

hook.Add("Think", "VRHand_ThinkRespawn", function()
    for ply, hands in pairs(vrHands) do
        if not IsValid(ply) or not ply:Alive() or not vrmod.IsPlayerInVR(ply) then continue end
        local repair = false
        for _, side in ipairs(SIDES) do
            if not hands[side] or not IsValid(hands[side].ent) then
                repair = true
                break
            end
        end

        if repair then SpawnVRHands(ply) end
    end
end)

hook.Add("VRMod_Pickup", "VRHand_AVRMagPickup", function(ply, ent)
    if not IsValid(ent) or not string.match(ent:GetClass(), "avrmag_") then return end
    local hands = vrHands[ply]
    if hands and hands.left and IsValid(hands.left.ent) then hands.left.ent:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE) end
end)

hook.Add("VRMod_Drop", "VRHand_AVRMagDrop", function(ply, ent)
    if not IsValid(ent) or not string.match(ent:GetClass(), "avrmag_") then return end
    local hands = vrHands[ply]
    if hands and hands.left and IsValid(hands.left.ent) then hands.left.ent:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR) end
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