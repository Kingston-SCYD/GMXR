g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}
local pickupList = pickupList or {}
local pickupCount = pickupCount or 0
local pickupController

local LocalToWorld = LocalToWorld
local WorldToLocal = WorldToLocal
local LerpAngle = LerpAngle
local IsValid = IsValid

local _, convarValues = vrmod.GetConvars()
local blacklistedClasses = {
    ["npc_turret_floor"] = true,
    ["info_particle_system"] = true,
    ["item_healthcharger"] = true,
    ["item_suitcharger"] = true,
    ["item_ammo_crate"] = true,
}

local blacklistedPatterns = {"beam", "button", "dynamic", "func_", "c_base", "laser", "info_", "sprite", "env_", "fire", "trail", "light", "spotlight", "streetlight", "traffic", "texture", "shadow", "keypad"}
local pickupableCache = {}
local invalidPickupCache = {}
if SERVER then util.AddNetworkString("vrmod_pickuplists_reload") util.AddNetworkString("vrmod_pickup_update") end
local function DebugEnabled()
    local cv = GetConVar("vrmod_debug_pickup")
    return cv and cv:GetBool() or false
end

vrmod.pickupLists = vrmod.pickupLists or {
    whitelist = {},
    blacklist = {}
}

local listPath = "vrmod/pickup_lists.json"
local function LoadPickupLists()
    if CLIENT then
        if not file.Exists("vrmod/pickup_lists.json", "DATA") then return end
        local data = util.JSONToTable(file.Read("vrmod/pickup_lists.json", "DATA") or "")
        if istable(data) then
            vrmod.pickupLists.whitelist = data.whitelist or {}
            vrmod.pickupLists.blacklist = data.blacklist or {}
        end
        pickupableCache = {}
        print("[VRMod] Pickup lists hot-reloaded (client)")
    end
end

local function SavePickupLists()
    file.Write(listPath, util.TableToJSON(vrmod.pickupLists, true))
end

vrmod.LoadPickupLists = LoadPickupLists
vrmod.SavePickupLists = SavePickupLists
if CLIENT then net.Receive("vrmod_pickuplists_reload", function() vrmod.LoadPickupLists() end) end
hook.Add("Initialize", "VRMod_LoadPickupLists", LoadPickupLists)
--=======================================================================
-- Validation and Eligibility
--=======================================================================
function vrmod.utils.IsImportantPickup(ent)
    local class = ent:GetClass()
    return class:find("^item_") or class:find("^ammo_") or class:find("^hl1_") or class:find("^spawned_") or class:find("^vr_item") or vrmod.utils.IsWeaponEntity(ent)
end

function vrmod.utils.HasHeldWeaponRight(ply)
    return vrmod.utils.IsValidWep(ply:GetActiveWeapon())
end

function vrmod.utils.IsValidPickupTarget(ent, ply, bLeftHand)
    if not IsValid(ent) then
        if not invalidPickupCache[ent] then invalidPickupCache[ent] = false end
        return false
    end
    -- Ownership is dynamic — must check every frame, before cache
    if ent:IsWeapon() then
        local wo = ent:GetOwner()
        -- NPC-owned weapons are claimed via the npc2rag fake-weapon flow, never
        -- the physics path — grabbing the live weapon strands a pickup entry on
        -- an entity npc2rag hides/removes, leaking pickupCount and breaking grips.
        if IsValid(wo) and (wo:IsPlayer() or wo:IsNPC()) then return false end
    end
    -- Two-hand ragdoll grab: other hand holds this ragdoll → allow targeting (dynamic, skip cache)
    if ent:GetClass() == "prop_ragdoll" then
        local otherHeld = bLeftHand and g_VR.heldEntityRight or g_VR.heldEntityLeft
        if otherHeld == ent then return true end
    end
    if invalidPickupCache[ent] ~= nil then return invalidPickupCache[ent] end
    if ent:GetNoDraw() or ent:IsDormant() then
        if not vrmod.utils.IsImportantPickup(ent) then invalidPickupCache[ent] = false end
        return false
    end
    if vrmod.utils.IsNonPickupable(ent) then invalidPickupCache[ent] = false return false end
    if ent:GetNWBool("is_npc_ragdoll", false) then invalidPickupCache[ent] = false return false end
    if bLeftHand and ent == g_VR.heldEntityLeft then return false end
    if not bLeftHand and ent == g_VR.heldEntityRight then return false end
    invalidPickupCache[ent] = true
    return true
end

function vrmod.utils.IsIgnoredProp(ent)
    if not IsValid(ent) then return true end
    local class = ent:GetClass() or ""
    return class == "prop_ragdoll" or vrmod.utils.IsImportantPickup(ent) or string.StartWith(class, "avrmag_")
end

function vrmod.utils.CanPickupEntity(v, ply, cv)
    if not IsValid(v) or v == ply or ply:InVehicle() then return false end
    -- NPC weapons stay on the ragdoll: the welded fake prop is decoration only,
    -- and the real weapon is rejected below. Neither is grabbable.
    if v.vrmod_is_ragdoll_weapon then return false end
    if cv.vrmod_pickup_npcs == 1 then if v:IsNPC() or v:IsNextBot() then return true end end
    local class = v:GetClass():lower()
    local model = (v:GetModel() or ""):lower()
    local key = class .. "|" .. model
    if vrmod.pickupLists then
        if vrmod.pickupLists.whitelist[key] then return true end
        if vrmod.pickupLists.blacklist[key] then return false end
    end
    if v:IsWeapon() then
        local wo = v:GetOwner()
        if IsValid(wo) and wo:IsNPC() then return false end
        return true
    end
    if SERVER then
        if vrmod.utils.IsImportantPickup(v) then return true end
        local phys = v:GetPhysicsObject()
        if not IsValid(phys) then return false end
        if cv.vrmod_pickup_limit == 1 then return v:GetMoveType() == MOVETYPE_VPHYSICS and phys:GetMass() <= cv.vrmod_pickup_weight end
    end
    return true
end

function vrmod.utils.ValidatePickup(ply, bLeftHand, ent)
    local sid = ply:SteamID()
    if not IsValid(ply) or not IsValid(ent) then return false end
if g_VR[sid] and g_VR[sid].heldItems then
        local idx = bLeftHand and 1 or 2
        local held = g_VR[sid].heldItems[idx]
        if held then
            if not IsValid(held.ent) then g_VR[sid].heldItems[idx] = nil
            else return false end
        end
    end
    if not vrmod.utils.CanPickupEntity(ent, ply, convarValues) then return false end
if hook.Call("VRMod_Pickup", nil, ply, ent) == false then return false end
    if not IsValid(ent) then return false end
    return true
end

function vrmod.utils.IsNonPickupable(ent)
    if not IsValid(ent) then return true end
    local class = ent:GetClass():lower()
    local model = (ent:GetModel() or ""):lower()
    local key   = class .. "|" .. model
    if vrmod.pickupLists then
        if vrmod.pickupLists.whitelist[key] then return false end
        if vrmod.pickupLists.blacklist[key] then return true end
    end
    if pickupableCache[key] ~= nil then return pickupableCache[key] end
    if blacklistedClasses[class] then pickupableCache[key] = true return true end
    for _, pattern in ipairs(blacklistedPatterns) do
        if class:find(pattern, 1, true) or model:find(pattern, 1, true) then
            pickupableCache[key] = true
            return true
        end
    end
    if vrmod.utils.IsWeaponEntity(ent) or class:find("prop_") or vrmod.utils.IsImportantPickup(ent) then
        pickupableCache[key] = false
        return false
    end
    if ent:IsNPC() or ent:IsNextBot() then
        local cv = GetConVar("vrmod_pickup_npcs")
        return not (cv and cv:GetInt() >= 1 or false)
    end
    if ent:GetMoveType() ~= MOVETYPE_VPHYSICS then pickupableCache[key] = true return true end
    pickupableCache[key] = false
    return false
end

local function GetPickupPriority(ent)
    if vrmod.utils.IsWeaponEntity(ent) or vrmod.utils.IsImportantPickup(ent) then return 2 end
    if ent:IsNPC() or ent:IsNextBot() then return 1 end
    return 0
end

function vrmod.utils.FindPickupTarget(ply, bLeftHand, handPos, handAng, pickupRange)
    if type(pickupRange) ~= "number" or pickupRange <= 0 then pickupRange = 1.2 end
    local convars = vrmod.GetConvars()
    local radius = pickupRange * 10
    local candidates = ents.FindInSphere(handPos, radius)
    local best, bestPriority, bestDistSqr = nil, -1, math.huge
    for _, ent in ipairs(candidates) do
        if IsValid(ent) and ent ~= ply
            and vrmod.utils.IsValidPickupTarget(ent, ply, bLeftHand)
            and vrmod.utils.CanPickupEntity(ent, ply, convars)
        then
            local priority = GetPickupPriority(ent)
            local distSqr
            if ent:GetClass() == "prop_ragdoll" then
                distSqr = math.huge
                for i = 0, ent:GetPhysicsObjectCount() - 1 do
                    local bp = ent:GetPhysicsObjectNum(i)
                    if IsValid(bp) then
                        local d = handPos:DistToSqr(bp:GetPos())
                        if d < distSqr then distSqr = d end
                    end
                end
            else
                distSqr = handPos:DistToSqr(ent:GetPos())
            end
            if priority > bestPriority or (priority == bestPriority and distSqr < bestDistSqr) then
                best, bestPriority, bestDistSqr = ent, priority, distSqr
            end
        end
    end
    if not IsValid(best) then return nil end
    if vrmod.utils.IsWeaponEntity(best) then
        local aw = ply:GetActiveWeapon()
        if IsValid(aw) and aw:GetClass() == best:GetClass() then
            if not (ArcticVR and aw.ArcticVR and bLeftHand ~= (ArcticVR.GunInLeftHand or false)) then return nil end
        end
        if not bLeftHand and vrmod.utils.IsValidWep(aw) then
            if not (ArcticVR and ArcticVR.GunInLeftHand) then return nil end
        end
    end
    return best
end

function vrmod.utils.FindPickupBySteamIDAndHand(steamid, bLeft)
    for i = 1, pickupCount do
        local t = pickupList[i]
        if t and t.steamid == steamid and t.left == bLeft then return i, t end
    end
    return nil, nil
end

function vrmod.utils._FinalizePickupRemoval(index, info)
    if not index or not info then return end
    if g_VR[info.steamid] and g_VR[info.steamid].heldItems then g_VR[info.steamid].heldItems[info.left and 1 or 2] = nil end
    table.remove(pickupList, index)
    pickupCount = math.max(0, pickupCount - 1)
    -- Only clear if this info still owns the entity. After a two-hand release,
    -- CleanupTwoHand reassigns vrmod_pickup_info to the surviving hand — clobbering
    -- it here would strand the survivor (PhysicsSimulate bails, prop falls server-side).
    if IsValid(info.ent) and info.ent.vrmod_pickup_info == info then
        info.ent.vrmod_pickup_info = nil
        info.ent.vrmod_physOffsets = nil
        info.ent.picked = false
    end
    if pickupCount == 0 and IsValid(pickupController) then
        pickupController:StopMotionController()
        pickupController:Remove()
        pickupController = nil
    end
end

-- Held entity removed out from under us (NPC weapon stripped by npc2rag, prop
-- broken, etc.). Drop never runs for these, so without this their pickupList
-- entry + pickupCount leak permanently — pickupCount never returns to 0, the
-- shared controller is never torn down, and grips desync globally. Purge every
-- entry referencing the entity. Registered via CallOnRemove in CreatePickupInfo.
function vrmod.utils.PurgePickupByEntity(ent)
    for i = pickupCount, 1, -1 do
        local v = pickupList[i]
        if v and v.ent == ent then
            if g_VR[v.steamid] and g_VR[v.steamid].heldItems then
                g_VR[v.steamid].heldItems[v.left and 1 or 2] = nil
            end
            table.remove(pickupList, i)
            pickupCount = math.max(0, pickupCount - 1)
        end
    end
    if pickupCount == 0 and IsValid(pickupController) then
        pickupController:StopMotionController()
        pickupController:Remove()
        pickupController = nil
    end
end

function vrmod.utils.ReleasePickupEntry(index, info, handVel)
    if not info then return false end
    handVel = handVel or Vector(0, 0, 0)
    local ent = info.ent
    local skip = info._skipControllerRemoval
    -- Other hand still holds this ragdoll: keep controller, collision, and hooks intact
    if not skip and IsValid(ent) and ent.vrmod_bone_hand_map and next(ent.vrmod_bone_hand_map) then
        skip = true
    end
    if not skip and IsValid(pickupController) then
        local phys = IsValid(info.phys) and info.phys or (IsValid(ent) and ent:GetPhysicsObject() or nil)
        if IsValid(phys) then pickupController:RemoveFromMotionController(phys) end
        -- Phys left the controller: clear the dedupe flag so a later re-grab re-adds it
        if IsValid(ent) then ent._vrmod_onmc = nil end
    end
    if IsValid(ent) and ent.original_npc and not (ent.vrmod_bone_hand_map and next(ent.vrmod_bone_hand_map)) then
        local npc = ent.original_npc
        if IsValid(npc) and not vrmod.utils.IsRagdollDead(ent) then
            ent.dropped_manually = true
            ent.noDamage = true
            for i = 0, ent:GetPhysicsObjectCount() - 1 do
                local phys = ent:GetPhysicsObjectNum(i)
                if IsValid(phys) then
                    phys:EnableMotion(true)
                    phys:SetMass(300)
                    phys:SetDamping(0, 0)
                    phys:SetVelocity(handVel)
                    phys:AddAngleVelocity(VectorRand() * 5)
                    phys:EnableGravity(true)
                    phys:Wake()
                end
            end
            vrmod.utils.SendPickupNetMessage(info.ply, ent, info.left)
            -- Named timer so SpawnPickupRagdoll can cancel on re-grab
            timer.Create("vrmod_npcrag_remove_" .. ent:EntIndex(), 3.0, 1, function()
                if IsValid(ent) then ent:Remove() end
            end)
        else
            ent.dropped_manually = false
            if IsValid(ent) then
                ent:SetNWBool("is_npc_ragdoll", false)
                ent:SetCollisionGroup(COLLISION_GROUP_NONE)
            end
            vrmod.utils.SendPickupNetMessage(info.ply, ent, info.left)
        end
    elseif IsValid(ent) then
        if not skip and GetConVar("vrmod_pickup_no_phys"):GetBool() then ent:SetCollisionGroup(COLLISION_GROUP_NONE) end
        vrmod.utils.SendPickupNetMessage(info.ply, ent, info.left)
    else
        vrmod.utils.SendPickupNetMessage(info.ply, nil, info.left)
    end
    if not skip then
        if IsValid(ent) then
            ent:SetCollisionGroup(info.collisionGroup)
            if ent:GetClass() ~= "prop_ragdoll" and not GetConVar("vrmod_pickup_no_phys"):GetBool() then
                vrmod.utils.UnpatchOwnerCollision(ent)
            end
        end
        hook.Call("VRMod_Drop", nil, info.ply, ent)
    end
    vrmod.utils._FinalizePickupRemoval(index, info)
    return true
end

--=======================================================================
-- NPC Handling / Ragdoll Conversion
--=======================================================================
function vrmod.utils.HandleNPCRagdoll(ply, ent)
    if ent:IsNPC() then ent = vrmod.utils.SpawnPickupRagdoll(ply, ent) end
    return ent
end

--=======================================================================
-- Hand Transform Retrieval
--=======================================================================
function vrmod.utils.GetHandTransform(ply, bLeftHand)
    if bLeftHand then return vrmod.GetLeftHandPos(ply), vrmod.GetLeftHandAng(ply)
    else return vrmod.GetRightHandPos(ply), vrmod.GetRightHandAng(ply) end
end

--=======================================================================
-- Ragdoll Bone Offsets
--=======================================================================
function vrmod.utils.BuildRagdollOffsets(ent, handPos, handAng)
    local physOffsets = {}
    for i = 0, ent:GetPhysicsObjectCount() - 1 do
        local phys = ent:GetPhysicsObjectNum(i)
        if IsValid(phys) then
            local physPos, physAng = phys:GetPos(), phys:GetAngles()
            local lpos, lang = WorldToLocal(physPos, physAng, handPos, handAng)
            physOffsets[i] = { localPos = lpos, localAng = lang }
        end
    end
    return physOffsets
end

--=======================================================================
-- Pickup Controller + Weight Simulation
--=======================================================================
function vrmod.utils.GetPickupController() return pickupController end

if SERVER then
    vrmod.AddCallbackedConvar("vrmod_weight_sim", nil, "1", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Simulate prop weight via physics response", 0, 1, tonumber)
end

function vrmod.utils.InitPickupController()
    if IsValid(pickupController) then return pickupController end
    pickupController = ents.Create("vrmod_pickup")
    local baseTick = engine.TickInterval()
    pickupController.ShadowParams = {
        secondstoarrive = baseTick,
        maxangular = 5000, maxangulardamp = 5000,
        maxspeed = 2000000, maxspeeddamp = 20000,
        dampfactor = 0.3, teleportdistance = 2000, deltatime = 0,
    }

    function pickupController:PhysicsSimulate(phys, dt)
        local ent = phys:GetEntity()
        local class = ent:GetClass()
        local info
        if class == "prop_ragdoll" and ent.vrmod_bone_hand_map then
            for i = 0, ent:GetPhysicsObjectCount() - 1 do
                if ent:GetPhysicsObjectNum(i) == phys then info = ent.vrmod_bone_hand_map[i] break end
            end
        end
        info = info or ent.vrmod_pickup_info
        if not info then return end
        local ply = info.ply
        if not IsValid(ply) then return end
        local handPos, handAng
        if info.left then
            handPos, handAng = vrmod.GetLeftHandPos(ply), vrmod.GetLeftHandAng(ply)
        else
            handPos, handAng = vrmod.GetRightHandPos(ply), vrmod.GetRightHandAng(ply)
        end
        if not handPos or not handAng then return end

        local targetPos, targetAng
        if class == "prop_ragdoll" then
            local offsets = info.vrmod_physOffsets or ent.vrmod_physOffsets
            if offsets then
                for i = 0, ent:GetPhysicsObjectCount() - 1 do
                    if ent:GetPhysicsObjectNum(i) == phys then
                        local o = offsets[i]
                        if o then targetPos, targetAng = LocalToWorld(o.localPos, o.localAng, handPos, handAng) end
                        break
                    end
                end
            end
        else
            local th = ent.vrmod_twohand
            if th then targetPos, targetAng = vrmod.utils.TwoHandTarget(th, ply) end
            if not targetPos then targetPos, targetAng = LocalToWorld(info.localPos, info.localAng, handPos, handAng) end
        end
        if not targetPos then return end

        -- Compensate for locomotion: physics runs before player movement in the
        -- tick, so the hand position is one tick behind. Add velocity to predict.
        local vel = ply:GetVelocity()
        if vel:LengthSqr() > 1 then targetPos = targetPos + vel * baseTick end

        -- Weight simulation via shadow controller params.
        -- Heavy objects arrive slower — pure server-side, no tracking modification.
        local sp = self.ShadowParams
        local weightCV = GetConVar("vrmod_weight_sim")
        if weightCV and weightCV:GetInt() == 1 and IsValid(info.phys) and class ~= "prop_ragdoll" then
            local m = info.phys:GetMass()
            if ent.vrmod_twohand then m = m * 0.3 end
            sp.secondstoarrive = baseTick * (1 + m * 0.04)
            sp.dampfactor = 0.3 + m * 0.015
            sp.maxspeed = 2000000 / (1 + m * 0.02)
        else
            sp.secondstoarrive = baseTick
            sp.dampfactor = 0.3
            sp.maxspeed = 2000000
        end

        sp.pos = targetPos
        sp.angle = targetAng
        phys:ComputeShadowControl(sp)
    end

    pickupController:StartMotionController()
    return pickupController
end

--=======================================================================
-- Two-Hand Prop Helpers
--=======================================================================
function vrmod.utils.TwoHandTarget(th, ply)
    local a, b = th.infoA, th.infoB
    local pA = a.left and vrmod.GetLeftHandPos(ply)  or vrmod.GetRightHandPos(ply)
    local aA = a.left and vrmod.GetLeftHandAng(ply)  or vrmod.GetRightHandAng(ply)
    local pB = b.left and vrmod.GetLeftHandPos(ply)  or vrmod.GetRightHandPos(ply)
    local aB = b.left and vrmod.GetLeftHandAng(ply)  or vrmod.GetRightHandAng(ply)
    if not pA or not pB then return nil, nil end
    local posA, angA = LocalToWorld(a.localPos, a.localAng, pA, aA)
    local posB, angB = LocalToWorld(b.localPos, b.localAng, pB, aB)
    return (posA + posB) * 0.5, LerpAngle(0.5, angA, angB)
end

function vrmod.utils.SetupTwoHand(ply, ent, infoL, infoR, secondaryIsLeft)
    ent.vrmod_twohand = {
        infoA = secondaryIsLeft and infoR or infoL,
        infoB = secondaryIsLeft and infoL or infoR,
    }
end

function vrmod.utils.CleanupTwoHand(droppedInfo)
    local ent = droppedInfo.ent
    if not IsValid(ent) or not ent.vrmod_twohand then return end
    local th = ent.vrmod_twohand
    local survivor = (droppedInfo == th.infoA) and th.infoB or th.infoA
    if survivor and IsValid(survivor.ply) then
        local hPos = survivor.left and vrmod.GetLeftHandPos(survivor.ply) or vrmod.GetRightHandPos(survivor.ply)
        local hAng = survivor.left and vrmod.GetLeftHandAng(survivor.ply) or vrmod.GetRightHandAng(survivor.ply)
        if hPos and hAng then
            -- Use shadow controller target, not ent:GetPos() which includes
            -- physics droop from gravity/weight sim — baking that in causes
            -- the prop to lower progressively on each two-hand grab cycle
            local tPos, tAng = vrmod.utils.TwoHandTarget(th, survivor.ply)
            survivor.localPos, survivor.localAng = WorldToLocal(
                tPos or ent:GetPos(), tAng or ent:GetAngles(), hPos, hAng)
            net.Start("vrmod_pickup_update")
            net.WriteUInt(ent:EntIndex(), 16)
            net.WriteBool(survivor.left)
            net.WriteVector(survivor.localPos)
            net.WriteAngle(survivor.localAng)
            net.Broadcast()
        end
        survivor.collisionGroup = th.infoA.collisionGroup
        ent.vrmod_pickup_info = survivor
    end
    droppedInfo._skipControllerRemoval = true
    ent.vrmod_twohand = nil
end

--=======================================================================
-- Pickup Registration
--=======================================================================
function vrmod.utils.CreatePickupInfo(ply, bLeftHand, ent, handPos, handAng)
    local sid = ply:SteamID()
    -- Re-grabbing a dropped NPC ragdoll: kill the pending despawn timer and clear
    -- the drop/get-up flags. Otherwise the timer fires mid-hold and Remove()s the
    -- ragdoll — its CallOnRemove then deletes (or revives) the NPC, so it vanishes
    -- or "dies" while still in hand. Spamming grab/regrab makes this race trivially.
    if ent.original_npc then
        timer.Remove("vrmod_npcrag_remove_" .. ent:EntIndex())
        ent.dropped_manually = false
        ent._getup_triggered = false
    end
    -- Last-grab-wins: if another player holds this entity, force-drop their grip. allow people to steal shit
    local evSid, evL1, evL2
    for k = 1, pickupCount do
        local v = pickupList[k]
        if v and v.ent == ent and v.steamid ~= sid then
            evSid = v.steamid
            if evL1 == nil then evL1 = v.left else evL2 = v.left end
        end
    end
    if evSid then
        vrmod.Drop(evSid, evL1)
        if evL2 ~= nil then vrmod.Drop(evSid, evL2) end
    end
    local index = pickupCount + 1
    local inheritCollision, existingInfo
    for k, v in ipairs(pickupList) do
        if v.ent == ent then
            if v.steamid == sid and v.left ~= bLeftHand then
                inheritCollision = v.collisionGroup
                existingInfo = v
                break
            end
            index = k
            g_VR[v.steamid].heldItems[v.left and 1 or 2] = nil
            break
        end
    end
    if index > pickupCount then
        pickupCount = pickupCount + 1
        if ent:GetClass() == "prop_ragdoll" then
            vrmod.utils.CacheBoneMasses(ent)
            vrmod.utils.SetBoneMass(ent, 35, 0.5)
        end
    end
    local lpos, lang
    if ent:GetClass() ~= "prop_ragdoll" then
        -- When the other hand already holds this entity, reconstruct the
        -- entity position from the existing info's shadow-controller target
        -- instead of ent:GetPos() which lags behind due to physics droop
        local epos, eang = ent:GetPos(), ent:GetAngles()
        if existingInfo then
            local eHP, eHA = vrmod.utils.GetHandTransform(existingInfo.ply, existingInfo.left)
            if eHP and eHA then
                epos, eang = LocalToWorld(existingInfo.localPos, existingInfo.localAng, eHP, eHA)
            end
        end
        lpos, lang = WorldToLocal(epos, eang, handPos, handAng)
    else
        lpos, lang = Vector(0, 0, 0), Angle(0, 0, 0)
    end
    local info = {
        ent = ent, phys = ent:GetPhysicsObject(), left = bLeftHand,
        localPos = lpos, localAng = lang,
        collisionGroup = inheritCollision or ent:GetCollisionGroup(),
        steamid = sid, ply = ply,
    }
    pickupList[index] = info
    g_VR[sid].heldItems = g_VR[sid].heldItems or {}
    g_VR[sid].heldItems[bLeftHand and 1 or 2] = info
    ent.vrmod_pickup_info = info
    -- Self-cleanup if the entity is removed while held (constant name = idempotent)
    ent:CallOnRemove("vrmod_pickup_purge", vrmod.utils.PurgePickupByEntity)
    return info
end

--=======================================================================
-- Physics Controller Attachment
--=======================================================================
function vrmod.utils.AttachPhysicsToController(info, controller)
    if not info or not IsValid(info.ent) or not IsValid(controller) then return end
    local ent  = info.ent
    local phys = info.phys or ent:GetPhysicsObject()
    if not IsValid(phys) then return end
    -- Non-ragdoll has one phys: never add it twice (second-hand grab)
    if ent:GetClass() ~= "prop_ragdoll" then
        if ent._vrmod_onmc then phys:Wake() return end
        ent._vrmod_onmc = true
    end
    controller:AddToMotionController(phys)
    phys:Wake()
end

--=======================================================================
-- Networking
--=======================================================================
function vrmod.utils.SendPickupNetMessage(ply, ent, bLeftHand, localPos, localAng)
    net.Start("vrmod_pickup")
    net.WriteEntity(ply)
    net.WriteUInt(IsValid(ent) and ent:EntIndex() or 0, 16)
    local isDrop = not localPos
    net.WriteBool(isDrop) net.WriteBool(bLeftHand or false)
    if not isDrop then
        net.WriteVector(localPos)
        net.WriteAngle(localAng or angle_zero)
    end
    net.Broadcast()
end

if SERVER then
    hook.Add("EntityTakeDamage", "VRMod_PreventOwnerSelfDamage", function(target, dmg)
        local inflictor = dmg:GetInflictor()
        if IsValid(inflictor) and inflictor._pickupOwner == target then return true end
    end)
    hook.Add("ShouldCollide", "VRMod_IgnoreOwnerAndHandCollisions", function(ent1, ent2)
        if not (IsValid(ent1) and IsValid(ent2)) then return end
        if ent1._collisionPatched then
            if ent2 == ent1._pickupOwner or ent2:GetNWBool("isVRHand", false) then return false end
        end
        if ent2._collisionPatched then
            if ent1 == ent2._pickupOwner or ent1:GetNWBool("isVRHand", false) then return false end
        end
    end)
    function vrmod.utils.PatchOwnerCollision(ent, ply)
        if not IsValid(ent) or not IsValid(ply) or ent._collisionPatched then return end
        ent._pickupOwner = ply
        ent._collisionPatched = true
    end
    function vrmod.utils.UnpatchOwnerCollision(ent)
        if not IsValid(ent) or not ent._collisionPatched then return end
        ent._pickupOwner = nil
        ent._collisionPatched = nil
    end
end
