local U = vrmod.utils
local pickupList = {}
local pickupCount = 0
local pickupController
local dbgAny = false -- someone holding has vrmod_debug_grab on (timer below)
-- Held-prop hull error gates, as sv_physhands' hand props: free within 2u and
-- ~6 degrees (squared sums), lost past 24u
-- ERR_MAX: a held prop never teleports (teleportdistance 2000), so its
-- hand stays pinned to it however deep the hand goes; past this it's lost
local ERR_P, ERR_A, ERR_MAX = 4, 36, 128 * 128
local CAP_D, CAP_A = 2, 3 -- stuck: the most the prop is aimed past itself per step (u, deg)
local _capP = Vector()

local LocalToWorld = LocalToWorld
local WorldToLocal = WorldToLocal
local LerpAngle = LerpAngle
local IsValid = IsValid
-- Entity fields straight from the entity table: ent.x is a Lua __index call
-- plus a GetTable per read
local GetTable = FindMetaTable("Entity").GetTable
-- Hand pose sources are players or plain tables: sv_physhands' FOOTSRC
-- stand-ins run the foot stream through the same HandPoseIn/HandPoseNow
local type = type
local function PoseTab(src)
    if type(src) == "table" then return src end
    return GetTable(src)
end

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
if SERVER then util.AddNetworkString("vrmod_pickuplists_reload") util.AddNetworkString("vrmod_pickup_update") util.AddNetworkString("vrmod_grab_dbg") end
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
-- The class half is cached per class; the weapon test stays per entity (a
-- prop_physics with a w_ model counts)
local importantClass = {}
function U.IsImportantPickup(ent)
    local class = ent:GetClass()
    local c = importantClass[class]
    if c == nil then
        c = (class:find("^item_") or class:find("^ammo_") or class:find("^hl1_") or class:find("^spawned_") or class:find("^vr_item")) and true or false
        importantClass[class] = c
    end
    return c or U.IsWeaponEntity(ent)
end

function U.IsValidPickupTarget(ent, ply, bLeftHand)
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
        if not U.IsImportantPickup(ent) then invalidPickupCache[ent] = false end
        return false
    end
    if U.IsNonPickupable(ent) then invalidPickupCache[ent] = false return false end
    if ent:GetNWBool("is_npc_ragdoll", false) then invalidPickupCache[ent] = false return false end
    if bLeftHand and ent == g_VR.heldEntityLeft then return false end
    if not bLeftHand and ent == g_VR.heldEntityRight then return false end
    invalidPickupCache[ent] = true
    return true
end

function U.IsIgnoredProp(ent)
    if not IsValid(ent) then return true end
    local class = ent:GetClass() or ""
    return class == "prop_ragdoll" or U.IsImportantPickup(ent) or string.StartWith(class, "avrmag_")
end

function U.CanPickupEntity(v, ply, cv)
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
        if U.IsImportantPickup(v) then return true end
        local phys = v:GetPhysicsObject()
        if not IsValid(phys) then return false end
        if cv.vrmod_pickup_limit == 1 then return v:GetMoveType() == MOVETYPE_VPHYSICS and phys:GetMass() <= cv.vrmod_pickup_weight end
    end
    return true
end

function U.ValidatePickup(ply, bLeftHand, ent)
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
    if not U.CanPickupEntity(ent, ply, convarValues) then return false end
if hook.Call("VRMod_Pickup", nil, ply, ent) == false then return false end
    if not IsValid(ent) then return false end
    return true
end

function U.IsNonPickupable(ent)
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
    if U.IsWeaponEntity(ent) or class:find("prop_") or U.IsImportantPickup(ent) then
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

function U.FindPickupTarget(ply, bLeftHand, handPos, handAng, pickupRange)
    if type(pickupRange) ~= "number" or pickupRange <= 0 then pickupRange = 1.2 end
    local radius = pickupRange * 10
    local candidates = ents.FindInSphere(handPos, radius)
    local best, bestPriority, bestDistSqr = nil, -1, math.huge
    -- Looked up per call: sh_playergrab wraps both. CanPickupEntity gets the
    -- convar VALUES (this passed the ConVar objects, so its
    -- vrmod_pickup_npcs test could never match here).
    local IsValidPickupTarget, CanPickupEntity = U.IsValidPickupTarget, U.CanPickupEntity
    for i = 1, #candidates do
        local ent = candidates[i]
        if ent ~= ply and IsValidPickupTarget(ent, ply, bLeftHand) and CanPickupEntity(ent, ply, convarValues) then
            -- Weapons and important pickups (IsImportantPickup covers
            -- IsWeaponEntity), then NPCs, then the rest
            local priority = U.IsImportantPickup(ent) and 2 or (ent:IsNPC() or ent:IsNextBot()) and 1 or 0
            local distSqr
            if ent:GetClass() == "prop_ragdoll" then
                distSqr = math.huge
                for j = 0, ent:GetPhysicsObjectCount() - 1 do
                    local bp = ent:GetPhysicsObjectNum(j)
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
    if U.IsWeaponEntity(best) then
        local aw, class = ply:GetActiveWeapon(), best:GetClass()
        -- One you already own only hands over its ammo (ManualWeaponPickupHook's
        -- duplicate branch), so either hand may take it, the gun hand included.
        -- The same-as-active rule below hid every duplicate of the gun you were
        -- holding: no halo, no grab, no ammo. ArcVR keeps that rule (dual wield).
        if not best.ArcticVR and best:IsWeapon() and ply:HasWeapon(class) then return best end
        if IsValid(aw) and aw:GetClass() == class then
            if not (ArcticVR and aw.ArcticVR and bLeftHand ~= (ArcticVR.GunInLeftHand or false)) then return nil end
        end
        -- The gun hand can't take a new weapon; the free one can. Was hardwired
        -- to the right hand, so a left-held gun blocked the free right instead.
        if bLeftHand == (g_VR.gunInLeftHand or (ArcticVR and ArcticVR.GunInLeftHand) or false) and U.IsValidWep(aw) then return nil end
    end
    return best
end

function U.FindPickupBySteamIDAndHand(steamid, bLeft)
    for i = 1, pickupCount do
        local t = pickupList[i]
        if t and t.steamid == steamid and t.left == bLeft then return i, t end
    end
    return nil, nil
end

function U._FinalizePickupRemoval(index, info)
    if not index or not info then return end
    if g_VR[info.steamid] and g_VR[info.steamid].heldItems then g_VR[info.steamid].heldItems[info.left and 1 or 2] = nil end
    table.remove(pickupList, index)
    pickupCount = math.max(0, pickupCount - 1)
    -- Only clear if this info still owns the entity. After a two-hand release,
    -- CleanupTwoHand reassigns vrmod_pickup_info to the surviving hand — clobbering
    -- it here would strand the survivor (PhysicsSimulate bails, prop falls server-side).
    if IsValid(info.ent) and info.ent.vrmod_pickup_info == info then
        info.ent.vrmod_pickup_info = nil
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
function U.PurgePickupByEntity(ent)
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

function U.ReleasePickupEntry(index, info, handVel)
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
        if IsValid(npc) and not U.IsRagdollDead(ent) then
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
            U.SendPickupNetMessage(info.ply, ent, info.left)
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
            U.SendPickupNetMessage(info.ply, ent, info.left)
        end
    elseif IsValid(ent) then
        if not skip and GetConVar("vrmod_pickup_no_phys"):GetBool() then ent:SetCollisionGroup(COLLISION_GROUP_NONE) end
        U.SendPickupNetMessage(info.ply, ent, info.left)
    else
        U.SendPickupNetMessage(info.ply, nil, info.left)
    end
    if not skip then
        if IsValid(ent) then
            -- Leaving the controller doesn't wake it: one dropped while held
            -- still against something (a stuck prop sits capped on the
            -- surface) went to sleep right there, floating
            ent:PhysWake()
            ent:SetCollisionGroup(info.collisionGroup)
            if ent:GetClass() ~= "prop_ragdoll" and not GetConVar("vrmod_pickup_no_phys"):GetBool() then
                U.UnpatchOwnerCollision(ent)
            end
        end
        hook.Call("VRMod_Drop", nil, info.ply, ent)
    end
    U._FinalizePickupRemoval(index, info)
    return true
end

--=======================================================================
-- NPC Handling / Ragdoll Conversion
--=======================================================================
function U.HandleNPCRagdoll(ply, ent)
    if ent:IsNPC() then ent = U.SpawnPickupRagdoll(ply, ent) end
    return ent
end

--=======================================================================
-- Hand Transform Retrieval
--=======================================================================
-- HELD-PROP HULL. A held prop is its hand's hull, as a weapon's segment is
-- (sv_physhands): the client hand leads, the prop chases it, and where the
-- prop is pressed on something and can't follow, the contact goes to the
-- client as that hand's hull error (vrmod_hull_error, Tick below): the
-- surface as a plane, which the hand -- and the prop drawn on it -- is
-- lifted out of but slides along. It used to just lag on the server while
-- the client drew it on the hand, through walls and props alike. Error is
-- the prop against the target it chased last step; per hand it's the hand
-- pose that would carry the prop where it is, in that hand's last-step
-- space. Ragdolls are no hull: they hang.
-- Contact lists (GetFrictionSnapshot) are only ever read between physics steps
-- (Tick), never from PhysicsSimulate: a motion controller runs mid-step, and
-- walking the contact list there reads friction data the step is rebuilding
-- -- bullet impacts make and break contacts in that same step, and crashed.
local HAS_SNAP = FindMetaTable("PhysObj").GetFrictionSnapshot ~= nil

local function HullErr(v, on, pp, pa, tp, ta, seq)
    on = on and v.hullHP ~= nil
    v.errOn = on
    if not on then return end
    v.errSeq = seq
    -- The hand pose that carries the prop where it is, world space (the
    -- client pins the hand to it), and the push direction past it
    local rp, ra = WorldToLocal(v.hullHP, v.hullHA, tp, ta)
    rp, ra = LocalToWorld(rp, ra, pp, pa)
    local n = v.hullHP - rp
    v.errP, v.errA, v.errN = rp, ra, n:LengthSqr() > ERR_P and n:GetNormalized() or nil
end

local CurTime = CurTime
-- HAND POSE INTERPOLATION. vrmod_hand_pose arrives unreliable, up to 150/s,
-- bunched and gapped by the network. Driving the hand hulls (sv_physhands
-- Sim) and held things (pickup controller) off the newest pose stepped their
-- targets unevenly -- several poses' worth one tick, none the next -- so
-- everything they push or carry moved in jolts only MP shows (the host's
-- poses arrive evenly). Each pose now carries the client's send clock: the
-- server keeps the last HB and plays them back on that clock, one pose
-- interval plus the jitter it has seen behind (capped at HB_MAX), lerped --
-- the scheme other players' frames get client-side. Resolved once per tick
-- into ply.vrHLP/HLA/HRP/HRA/HS, fresh objects as before (snapshots stay
-- snapshots). The hull error echoes the nearer pose's sequence, so the
-- client's round-trip estimate takes the delay in. vrmod_hand_interp 0:
-- newest pose, as before.
local HandPoseNow = function() end
-- Shared and replicated: the settings menu (Server > Pickup) shows its value
local cv_interp = CreateConVar("vrmod_hand_interp", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Interpolate VR hand poses driving hand physics and held props (0 = newest packet)", 0, 1)
if SERVER then
    local HB, HB_GAP, HB_MAX = 16, 0.1, 0.1
    local SysTime, TickCount, LerpVector = SysTime, engine.TickCount, LerpVector
    -- Rotation a -> b in a's frame, scaled: a slerp for the small steps
    -- between poses, with no Euler wrap or gimbal trouble
    local function ALerp(f, a, b)
        local _, d = WorldToLocal(vector_origin, b, vector_origin, a)
        d:Mul(f)
        local _, r = LocalToWorld(vector_origin, d, vector_origin, a)
        return r
    end
    -- ms: the client's SysTime in ms, 16 bits. fresh: the last pose is
    -- under 0.25s old; after a lapse the buffer and clock start over.
    function U.HandPoseIn(ply, lp, la, rp, ra, seq, ms, fresh)
        local et = PoseTab(ply)
        if not cv_interp:GetBool() then
            et.vrHB, et.vrHLP, et.vrHLA, et.vrHRP, et.vrHRA, et.vrHS = nil, lp, la, rp, ra, seq
            return
        end
        local b, now, t = et.vrHB, SysTime()
        if not (b and fresh) then
            b = {n = 0, h = 0, jit = 0, iv = 0.011}
            et.vrHB = b
        end
        if b.n == 0 then
            t, b.off = 0, now
        else
            local d = (ms - b.ms) % 65536
            if d == 0 or d > 32768 then return end -- repeat or out of order
            d = d * 0.001
            t = b.t + d
            b.iv = b.iv + (d - b.iv) * 0.05
        end
        b.ms, b.t = ms, t
        -- off: server minus client clock, on the least-delayed poses (lower
        -- envelope), creeping up slowly for drift. jit: delay past that,
        -- rising a quarter of each spike (one hiccup doesn't set the buffer
        -- for seconds), easing back down
        local o = now - t
        local off = b.off + 1e-5
        if o < off then off = o end
        b.off = off
        o = o - off
        b.jit = b.jit + (o - b.jit) * (o > b.jit and 0.25 or 0.02)
        local h = b.h % HB + 1
        local e = b[h]
        if not e then
            e = {}
            b[h] = e
        end
        e.t, e.lp, e.la, e.rp, e.ra, e.s = t, lp, la, rp, ra, seq
        b.h = h
        if b.n < HB then b.n = b.n + 1 end
    end
    function HandPoseNow(ply, et)
        et = et or PoseTab(ply)
        local b = et.vrHB
        local tick = TickCount()
        if not b or b.rt == tick or b.n == 0 then return end
        b.rt = tick
        local dl = b.iv + b.jit
        local tc = SysTime() - b.off - (dl < HB_MAX and dl or HB_MAX)
        local h, B, A = b.h, b[b.h]
        if tc < B.t then
            for k = 1, b.n - 1 do
                A = b[(h - k - 1) % HB + 1]
                if A.t <= tc then break end
                B, A = A, nil
            end
        end
        if A and B.t - A.t < HB_GAP then
            local f = (tc - A.t) / (B.t - A.t)
            et.vrHLP, et.vrHRP = LerpVector(f, A.lp, B.lp), LerpVector(f, A.rp, B.rp)
            et.vrHLA, et.vrHRA = ALerp(f, A.la, B.la), ALerp(f, A.ra, B.ra)
            et.vrHS = f < 0.5 and A.s or B.s
        else -- newest; the newer one across a send gap; oldest past the buffer
            et.vrHLP, et.vrHLA, et.vrHRP, et.vrHRA, et.vrHS = B.lp, B.la, B.rp, B.ra, B.s
        end
    end
    U.HandPoseNow = HandPoseNow
end
-- Server: the client's world-space hand pose (vrmod_hand_pose, sv_physhands)
-- while fresh -- the same pose the hand props chase -- third return true.
-- Else the network frame, which is relative to a player position the server
-- has a step behind while you move: held things trailed the hand that way.
-- Live references: copy to keep.
local function HandTransform(ply, left)
    if SERVER then
        local et = PoseTab(ply)
        if et and CurTime() < (et.vrHT or 0) then
            HandPoseNow(ply, et)
            if left then return et.vrHLP, et.vrHLA, true end
            return et.vrHRP, et.vrHRA, true
        end
    end
    if left then return vrmod.GetLeftHandPos(ply), vrmod.GetLeftHandAng(ply) end
    return vrmod.GetRightHandPos(ply), vrmod.GetRightHandAng(ply)
end
U.GetHandTransform = HandTransform

--=======================================================================
-- Pickup Controller
--=======================================================================
function U.GetPickupController() return pickupController end

function U.InitPickupController()
    if IsValid(pickupController) then return pickupController end
    pickupController = ents.Create("vrmod_pickup")
    local baseTick = engine.TickInterval()
    local sp = {
        secondstoarrive = baseTick,
        maxangular = 5000, maxangulardamp = 5000,
        maxspeed = 2000000, maxspeeddamp = 20000,
        dampfactor = 0.3, teleportdistance = 2000, deltatime = 0,
    }
    pickupController.ShadowParams = sp

    function pickupController:PhysicsSimulate(phys, dt)
        local ent = phys:GetEntity()
        local et = GetTable(ent)
        local rag = ent:GetClass() == "prop_ragdoll"
        local info, idx
        if rag then
            for i = 0, ent:GetPhysicsObjectCount() - 1 do
                if ent:GetPhysicsObjectNum(i) == phys then idx = i break end
            end
            local map = et.vrmod_bone_hand_map
            info = map and idx and map[idx]
        end
        info = info or et.vrmod_pickup_info
        if not info then return end
        local ply = info.ply
        if not IsValid(ply) then return end
        local handPos, handAng, fresh = HandTransform(ply, info.left)
        if not handPos or not handAng then return end

        local targetPos, targetAng, th
        if rag then
            local o = idx and info.vrmod_physOffsets
            o = o and o[idx]
            if o then targetPos, targetAng = LocalToWorld(o.localPos, o.localAng, handPos, handAng) end
        else
            th = et.vrmod_twohand
            local lt = info.hullP
            if lt then
                local pp, pa = phys:GetPos(), phys:GetAngles()
                local ep, ea = WorldToLocal(pp, pa, lt, info.hullA)
                local d2 = ep:LengthSqr()
                -- Past the deadzone; Tick confirms contact (pressed on
                -- something, not trailing a swing in free air)
                local a2 = ea.p * ea.p + ea.y * ea.y + ea.r * ea.r
                local on = d2 < ERR_MAX and (d2 > ERR_P or a2 > ERR_A)
                if d2 <= ERR_P and a2 <= ERR_A then et.vrCap = nil end -- back on target: uncapped
                if th then
                    HullErr(th.infoA, on, pp, pa, lt, info.hullA, info.hullSeq)
                    HullErr(th.infoB, on, pp, pa, lt, info.hullA, info.hullSeq)
                else
                    HullErr(info, on, pp, pa, lt, info.hullA, info.hullSeq)
                end
            end
            if th then targetPos, targetAng = U.TwoHandTarget(th, ply) end
            if not targetPos then
                th = nil
                targetPos, targetAng = LocalToWorld(info.localPos, info.localAng, handPos, handAng)
            end
        end
        if not targetPos then return end

        -- Frame pose only: physics runs before player movement in the tick,
        -- so it's a tick behind; add velocity to predict. The client's own
        -- world pose needs none. targetPos is fresh: mutated in place.
        if not fresh then
            local vel = ply:GetVelocity()
            if vel:LengthSqr() > 1 then
                targetPos.x, targetPos.y, targetPos.z = targetPos.x + vel.x * baseTick, targetPos.y + vel.y * baseTick, targetPos.z + vel.z * baseTick
            end
        end
        -- What next step's hull error is measured against
        if not rag then
            info.hullP, info.hullA, info.hullSeq = targetPos, targetAng, fresh and ply.vrHS or 0
            if not th then info.hullHP, info.hullHA = handPos, handAng end -- else TwoHandTarget set both
        end
        -- The hand's own grip only (not a ragdoll's root riding along)
        if dbgAny and (not rag or info.ragdoll_bone_phys and info.ragdoll_bone_phys[1] == phys) then
            info.dbgP, info.dbgA, info.dbgHP, info.dbgHA, info.dbgFresh = targetPos, targetAng, handPos, handAng, fresh or false
        end

        -- Pressed on something (Tick below), until back on target: driven at
        -- a target deep inside it, the prop was shoved through other props
        -- and brushes (a corner first, worst). Stuck, it's aimed at most
        -- CAP_D / CAP_A past where it is, so it only leans on the surface;
        -- hullP keeps the real target, which the hull error measures.
        if not rag and et.vrCap then
            local pp, pa = phys:GetPos(), phys:GetAngles()
            local dx, dy, dz = targetPos.x - pp.x, targetPos.y - pp.y, targetPos.z - pp.z
            local l2 = dx * dx + dy * dy + dz * dz
            local n = et.vrCapN
            if n then
                -- Only the push into the surface is capped; along it the
                -- target passes whole, so a prop pressed on a floor or wall
                -- slides with the hand. Capping the whole move crawled: the
                -- deeper the hand went, the less of each step ran along it.
                local dn = dx * n.x + dy * n.y + dz * n.z + CAP_D
                if dn < 0 then dx, dy, dz = dx - n.x * dn, dy - n.y * dn, dz - n.z * dn end
                _capP:SetUnpacked(pp.x + dx, pp.y + dy, pp.z + dz)
                sp.pos = _capP
            elseif l2 > CAP_D * CAP_D then
                local k = CAP_D * l2 ^ -0.5
                _capP:SetUnpacked(pp.x + dx * k, pp.y + dy * k, pp.z + dz * k)
                sp.pos = _capP
            else
                sp.pos = targetPos
            end
            local _, la = WorldToLocal(pp, targetAng, pp, pa)
            local a = (la.p * la.p + la.y * la.y + la.r * la.r) ^ 0.5
            sp.angle = a > CAP_A and LerpAngle(CAP_A / a, pa, targetAng) or targetAng
        else
            sp.pos, sp.angle = targetPos, targetAng
        end
        phys:ComputeShadowControl(sp)
    end

    pickupController:StartMotionController()
    return pickupController
end

--=======================================================================
-- Two-Hand Prop Helpers
--=======================================================================
function U.TwoHandTarget(th, ply)
    local a, b = th.infoA, th.infoB
    local pA, aA = HandTransform(ply, a.left)
    local pB, aB = HandTransform(ply, b.left)
    if not pA or not pB then return nil, nil end
    a.hullHP, a.hullHA, b.hullHP, b.hullHA = pA, aA, pB, aB -- the hull error's hand poses
    local posA, angA = LocalToWorld(a.localPos, a.localAng, pA, aA)
    local posB, angB = LocalToWorld(b.localPos, b.localAng, pB, aB)
    return (posA + posB) * 0.5, LerpAngle(0.5, angA, angB)
end

function U.SetupTwoHand(ply, ent, infoL, infoR, secondaryIsLeft)
    ent.vrmod_twohand = {
        infoA = secondaryIsLeft and infoR or infoL,
        infoB = secondaryIsLeft and infoL or infoR,
    }
end

function U.CleanupTwoHand(droppedInfo)
    local ent = droppedInfo.ent
    if not IsValid(ent) or not ent.vrmod_twohand then return end
    local th = ent.vrmod_twohand
    local survivor = (droppedInfo == th.infoA) and th.infoB or th.infoA
    if survivor and IsValid(survivor.ply) then
        local hPos, hAng = HandTransform(survivor.ply, survivor.left)
        if hPos and hAng then
            -- Use shadow controller target, not ent:GetPos() which includes
            -- physics droop from gravity — baking that in causes
            -- the prop to lower progressively on each two-hand grab cycle
            local tPos, tAng = U.TwoHandTarget(th, survivor.ply)
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
        survivor.hullP = nil -- its last target may be the two-hand one
        ent.vrmod_pickup_info = survivor
    end
    droppedInfo._skipControllerRemoval = true
    ent.vrmod_twohand = nil
end

--=======================================================================
-- Pickup Registration
--=======================================================================
-- Grip offset for a fresh grab: the prop's pose in the hand's frame. A hand
-- genuinely off the prop (> 4u from its surface) pulls the surface onto the
-- palm; a hand already on it keeps exactly the pose it was taken in. Shared:
-- the client runs it at grip press on the pose it renders from, the server
-- only when no client offset came with the request.
function U.GrabOffset(ent, handPos, handAng)
    local epos = ent:GetPos()
    if ent:NearestPoint(handPos):DistToSqr(handPos) > 16 then
        local palm = handPos + handAng:Forward() * (vrmod.DEFAULT_OFFSET or 3)
        epos = epos + (palm - ent:NearestPoint(palm))
    end
    return WorldToLocal(epos, ent:GetAngles(), handPos, handAng)
end

-- cPos/cAng: the client's GrabOffset on its raw controller pose, sent with
-- the pickup request; handPos/handAng are that pose when it came along.
function U.CreatePickupInfo(ply, bLeftHand, ent, handPos, handAng, cPos, cAng)
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
            U.CacheBoneMasses(ent)
            U.SetBoneMass(ent, 35, 0.5)
        end
    end
    local lpos, lang, offSrc
    if ent:GetClass() ~= "prop_ragdoll" then
        if existingInfo then
            -- When the other hand already holds this entity, reconstruct the
            -- entity position from the existing info's shadow-controller target
            -- instead of ent:GetPos() which lags behind due to physics droop
            local epos, eang = ent:GetPos(), ent:GetAngles()
            local eHP, eHA = HandTransform(existingInfo.ply, existingInfo.left)
            if eHP and eHA then
                epos, eang = LocalToWorld(existingInfo.localPos, existingInfo.localAng, eHP, eHA)
            end
            lpos, lang = WorldToLocal(epos, eang, handPos, handAng)
            offSrc = "hand2"
        else
            -- The client's offset, measured on the hand it renders from at the
            -- moment of the press. Measuring here used handPos, the hand as of
            -- your last network frame: whatever it moved in that latency was
            -- baked into the grip (the prop jumped on grab), and a hand still
            -- reaching read as "off the prop" and pulled it onto a stale palm.
            -- Clamped to what a real grab can produce -- the target radius plus
            -- the prop's own size -- so it can't hold anything at a distance.
            local lim = ent:BoundingRadius() + GetConVar("vrmod_pickup_range"):GetFloat() * 10 + 4
            if cPos and cPos:LengthSqr() <= lim * lim then
                lpos, lang, offSrc = cPos, cAng, "client"
            else
                lpos, lang = U.GrabOffset(ent, handPos, handAng)
                offSrc = cPos and "clamped" or "server"
            end
        end
    else
        -- Ragdolls: sh_pickup sets the grabbed bone's offset
        lpos, lang, offSrc = Vector(), Angle(), "bone"
    end
    local info = {
        ent = ent, phys = ent:GetPhysicsObject(), left = bLeftHand,
        localPos = lpos, localAng = lang, offSrc = offSrc,
        collisionGroup = inheritCollision or ent:GetCollisionGroup(),
        steamid = sid, ply = ply,
    }
    pickupList[index] = info
    g_VR[sid].heldItems = g_VR[sid].heldItems or {}
    g_VR[sid].heldItems[bLeftHand and 1 or 2] = info
    ent.vrmod_pickup_info = info
    -- Self-cleanup if the entity is removed while held (constant name = idempotent)
    ent:CallOnRemove("vrmod_pickup_purge", U.PurgePickupByEntity)
    -- Mirrors the Unpatch condition in ReleasePickupEntry
    if ent:GetClass() ~= "prop_ragdoll" and not GetConVar("vrmod_pickup_no_phys"):GetBool() then
        U.PatchOwnerCollision(ent, ply)
    end
    return info
end

--=======================================================================
-- Physics Controller Attachment
--=======================================================================
function U.AttachPhysicsToController(info, controller)
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
function U.SendPickupNetMessage(ply, ent, bLeftHand, localPos, localAng)
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
    -- A held prop doesn't crush its holder. Only crush: a barrel that blows
    -- up in your hand is the inflictor of its blast too, and that should hurt.
    hook.Add("EntityTakeDamage", "VRMod_PreventOwnerSelfDamage", function(target, dmg)
        if not dmg:IsDamageType(DMG_CRUSH) then return end -- first: other damage costs one call
        local inflictor = dmg:GetInflictor()
        if IsValid(inflictor) and inflictor._pickupOwner == target then return true end
    end)
    -- A held prop passes through its holder. Hands are sv_physhands' (Held):
    -- every hand prop has the custom check on, so its rule always runs, and
    -- it lets weapon hulls and other players' hands hit what you hold. Traces filtered
    -- on the holder ask this too, and bullets are such traces: excluding the
    -- holder outright let your own shots through anything you held, so it
    -- never took damage, broke or blew up. While the holder is firing
    -- (vrFiring: set in sh_startup's VRMod_Bullets, cleared before its next
    -- move) the holder is left to the default rules. Physics keeps the answer
    -- it cached for the pair (CollisionRulesChanged at the patch), and
    -- movement traces run after the clear, so only that window's traces --
    -- the shot -- hit. Held props keep their own group (not PASSABLE_DOOR):
    -- other players are solid to them.
    hook.Add("ShouldCollide", "VRMod_IgnoreOwnerAndHandCollisions", function(ent1, ent2)
        -- Asked for every pair any addon flagged for custom collision checks:
        -- two GetTable calls instead of IsValid x2 and two Entity.__index reads
        local t = GetTable(ent1)
        local o = t and t._collisionPatched and t._pickupOwner
        if o and ent2 == o and not o.vrFiring then return false end
        t = GetTable(ent2)
        o = t and t._collisionPatched and t._pickupOwner
        if o and ent1 == o and not o.vrFiring then return false end
    end)
    -- Before movement traces: the holder blocks nothing it holds again
    hook.Add("SetupMove", "VRMod_FiringClear", function(ply)
        local t = GetTable(ply)
        if t.vrFiring then t.vrFiring = nil end
    end)
    function U.PatchOwnerCollision(ent, ply)
        if not IsValid(ent) or not IsValid(ply) or ent._collisionPatched then return end
        ent._pickupOwner = ply
        ent._collisionPatched = true
        -- ShouldCollide is only consulted for entities with the custom check on:
        -- without it the owner rule above never ran.
        ent._vrmod_ccc = ent:GetCustomCollisionCheck()
        ent:SetCustomCollisionCheck(true)
        ent:CollisionRulesChanged()
    end
    function U.UnpatchOwnerCollision(ent)
        if not IsValid(ent) or not ent._collisionPatched then return end
        ent._pickupOwner = nil
        ent._collisionPatched = nil
        ent:SetCustomCollisionCheck(ent._vrmod_ccc or false)
        ent._vrmod_ccc = nil
        ent:CollisionRulesChanged()
    end

    -- A contact as a plane, for the client's lift (ApplyHullError): the
    -- surface in the touched entity's space (world space for the world) and
    -- the touching point in the frame of hand pose (cp, ca). Writes nothing
    -- and returns false where no plane fits (a many-bone ragdoll). Shared
    -- with sv_physhands' hand hulls.
    function U.WriteContactPlane(oe, pt, n, cp, ca)
        local world = oe == game.GetWorld()
        if not (world or IsValid(oe) and oe:GetPhysicsObjectCount() == 1) then return false end
        net.WriteBool(true)
        net.WriteBool(world)
        if world then
            net.WriteVector(pt)
            net.WriteNormal(n)
        else
            local oa = oe:GetAngles()
            net.WriteEntity(oe)
            net.WriteVector((WorldToLocal(pt, angle_zero, oe:GetPos(), oa)))
            net.WriteNormal((WorldToLocal(n, angle_zero, vector_origin, oa)))
        end
        net.WriteVector((WorldToLocal(pt, angle_zero, cp, ca)))
        return true
    end
    local WriteContactPlane = U.WriteContactPlane

    -- Held-prop hull error to its holder: with v, stuck -- contact c as a
    -- plane (n: its normal out of the surface) plus the turn the prop has
    -- taken off the hand pose it chased, else v's pose pin -- unreliable,
    -- each replacing the last; without, one reliable clear.
    local function SendHullError(ply, right, v, c, n)
        net.Start("vrmod_hull_error", v ~= nil)
        net.WriteBool(right)
        net.WriteBool(v ~= nil)
        if v then
            net.WriteUInt(v.errSeq or 0, 16) -- the client pose it answers: round-trip timing
            if c and WriteContactPlane(c.Other:GetEntity(), c.ContactPoint, n, v.errP, v.errA) then
                local _, ra = WorldToLocal(vector_origin, v.errA, vector_origin, v.hullHA)
                net.WriteAngle(ra)
            else
                net.WriteBool(false)
                net.WriteVector(v.errP)
                net.WriteAngle(v.errA)
                net.WriteBool(v.errN ~= nil)
                if v.errN then net.WriteNormal(v.errN) end
            end
        end
        net.Send(ply)
    end

    -- The contact a pressed prop is pushed into: of its contacts, the one
    -- whose surface faces the push most squarely. Returns it and its normal
    -- out of the surface (toward the prop's mass centre).
    local function Pressed(p, push)
        local s = p:GetFrictionSnapshot()
        local m = p:LocalToWorld(p:GetMassCenter())
        local best, bd, bn
        for k = 1, #s do
            local c = s[k]
            local pt, n = c.ContactPoint, c.Normal
            local sg = (m.x - pt.x) * n.x + (m.y - pt.y) * n.y + (m.z - pt.z) * n.z < 0 and -1 or 1
            local d = push and (push.x * n.x + push.y * n.y + push.z * n.z) * sg or 0
            if not best or d < bd then best, bd, bn = c, d, sg < 0 and -n or n end
        end
        return best, bn
    end

    -- Held-prop hull errors to their holders. A drop needs none: the
    -- client drops a hand's error when its hold ends.
    hook.Add("Tick", "vrmod_pickup_hullerr", function()
        for i = 1, pickupCount do
            local v = pickupList[i]
            if v and (v.errOn or v.errSent) and IsValid(v.ply) then
                local on, c, n = v.errOn and IsValid(v.phys) or false
                if on and HAS_SNAP then
                    c, n = Pressed(v.phys, v.errN)
                    on = c ~= nil
                end
                -- clear only once: free-air trailing used to resend it every tick
                if on then SendHullError(v.ply, not v.left, v, c, n)
                elseif v.errSent then SendHullError(v.ply, not v.left) end
                v.errSent = on
                -- capped while pressed (into the contact only, when there is
                -- one); free again the moment it isn't (a capped prop pulled
                -- clear trailed the hand)
                local ent = v.ent
                if IsValid(ent) then ent.vrCap, ent.vrCapN = on or nil, n end
            end
        end
    end)

    -- vrmod_debug_grab (client userinfo): each held thing's server side, to
    -- its holder, 20/s -- the hand pose it was driven from, its target, and
    -- where it is (a ragdoll: the grabbed bone). dbgAny gates PhysicsSimulate's
    -- bookkeeping, so with nobody debugging this costs one loop over holds.
    timer.Create("vrmod_grab_dbg", 0.05, 0, function()
        dbgAny = false
        for i = 1, pickupCount do
            local v = pickupList[i]
            local ply = v and v.ply
            if IsValid(ply) and ply:GetInfoNum("vrmod_debug_grab", 0) ~= 0 then
                dbgAny = true
                local ph = v.ragdoll_bone_phys and v.ragdoll_bone_phys[1] or v.phys
                if v.dbgP and IsValid(ph) and IsValid(v.ent) then
                    net.Start("vrmod_grab_dbg", true)
                    net.WriteUInt(v.ent:EntIndex(), 16)
                    net.WriteBool(v.left)
                    net.WriteBool(v.dbgFresh)
                    net.WriteVector(v.dbgHP)
                    net.WriteAngle(v.dbgHA)
                    net.WriteVector(v.dbgP)
                    net.WriteAngle(v.dbgA)
                    net.WriteVector(ph:GetPos())
                    net.WriteAngle(ph:GetAngles())
                    net.Send(ply)
                end
            end
        end
    end)
end