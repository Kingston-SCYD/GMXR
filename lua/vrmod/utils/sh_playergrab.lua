-- sh_playergrab.lua
-- Grabbing live players, mirroring the NPC path in sh_npc2rag.lua: a prop_ragdoll
-- stands in as the visible body while the real player is hidden, frozen and
-- dragged along by SetPos so their PVS, audio and hitboxes stay with the body.
--
-- Everything hooks in by wrapping the existing pickup predicates rather than
-- editing them, so sh_pickup_util.lua is untouched and this file can be deleted
-- to remove the feature entirely.

AddCSLuaFile()

g_VR  = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}

local PELVIS_BONE = "ValveBiped.Bip01_Pelvis"

-- Server-authoritative, so the client's targeting and halo code agrees with what
-- the server will actually permit.
vrmod.AddCallbackedConvar("vrmod_pickup_players", nil, 0, FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "Allow VR players to physically grab other players", 0, 1, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_players_adminprotect", nil, 1, FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "Block grabbing players whose usergroup outranks yours", 0, 1, tonumber)

--=======================================================================
-- Rank comparison
--=======================================================================
-- GMod has no ordering on usergroups, so ask CAMI first: every current admin
-- mod (ULX, SAM, ServerGuard) registers its inheritance there. Without CAMI
-- the only thing that exists is the built-in superadmin > admin > user tier.
local function RankOf(ply)
    if ply:IsSuperAdmin() then return 3 end
    if ply:IsAdmin() then return 2 end
    return 1
end

local function Outranks(target, grabber)
    if CAMI and CAMI.UsergroupInherits then
        local tg, gg = target:GetUserGroup(), grabber:GetUserGroup()
        if tg == gg then return false end
        -- Target outranks the grabber when the target's group inherits from the
        -- grabber's but not the other way round.
        if CAMI.UsergroupInherits(tg, gg) and not CAMI.UsergroupInherits(gg, tg) then return true end
        return false
    end
    return RankOf(target) > RankOf(grabber)
end

--=======================================================================
-- Eligibility
--=======================================================================
local cv_players = GetConVar("vrmod_pickup_players")
local cv_protect = GetConVar("vrmod_pickup_players_adminprotect")

-- Shared so the client greys out targets the server would refuse anyway.
function vrmod.utils.CanGrabPlayer(grabber, target)
    if not cv_players:GetBool() then return false end
    if not IsValid(grabber) or not IsValid(target) then return false end
    if target == grabber or not target:IsPlayer() then return false end
    if not target:Alive() or target:InVehicle() then return false end
    if target:GetNWBool("vrmod_grabbed", false) then return false end
    if cv_protect:GetBool() and Outranks(target, grabber) then return false end
    -- Addon override, same shape as VRMod_Pickup: return false to refuse.
    if hook.Run("VRMod_CanGrabPlayer", grabber, target) == false then return false end
    return true
end

-- Wrap rather than edit. Deferred a tick because load order between this file
-- and sh_pickup_util.lua is not guaranteed and we must wrap the real function,
-- not be overwritten by it.
timer.Simple(0, function()
    local canPickup = vrmod.utils.CanPickupEntity
    if canPickup then
        function vrmod.utils.CanPickupEntity(v, ply, cv)
            if IsValid(v) and v:IsPlayer() then return vrmod.utils.CanGrabPlayer(ply, v) end
            return canPickup(v, ply, cv)
        end
    end

    local validTarget = vrmod.utils.IsValidPickupTarget
    if validTarget then
        function vrmod.utils.IsValidPickupTarget(ent, ply, bLeftHand)
            if IsValid(ent) and ent:IsPlayer() then return vrmod.utils.CanGrabPlayer(ply, ent) end
            return validTarget(ent, ply, bLeftHand)
        end
    end

    -- The pickup path funnels NPCs through here to swap in a ragdoll; players
    -- take the same route so every downstream prop_ragdoll branch (bone grabs,
    -- two-hand, throw velocity) works with no further changes.
    if SERVER then
        local handleNPC = vrmod.utils.HandleNPCRagdoll
        if handleNPC then
            function vrmod.utils.HandleNPCRagdoll(ply, ent)
                if IsValid(ent) and ent:IsPlayer() then return vrmod.utils.SpawnPlayerRagdoll(ply, ent) end
                return handleNPC(ply, ent)
            end
        end
    end
end)

--=======================================================================
-- Server: ragdoll stand-in
--=======================================================================
if SERVER then
    util.AddNetworkString("vrmod_playergrab_state")

    local grabbed = {}   -- ragdoll -> player
    local ragdollOf = {} -- player  -> ragdoll

    local function PelvisPos(rag)
        local bone = rag:LookupBone(PELVIS_BONE)
        if bone then
            local pos = rag:GetBonePosition(bone)
            if pos and pos ~= rag:GetPos() then return pos end
        end
        return rag:GetPos()
    end

    -- Snap the ragdoll's physics bones onto the player's current animation pose,
    -- otherwise it spawns T-posed and snaps a frame later.
    local function CopyPose(ply, rag)
        local plyPos = ply:GetPos()
        for i = 0, rag:GetPhysicsObjectCount() - 1 do
            local phys = rag:GetPhysicsObjectNum(i)
            if not IsValid(phys) then continue end
            local bone = rag:TranslatePhysBoneToBone(i)
            if not bone or bone < 0 then continue end
            local pos, ang = ply:GetBonePosition(bone)
            if not pos or pos == plyPos then continue end
            phys:EnableMotion(false)
            phys:SetPos(pos)
            phys:SetAngles(ang)
            phys:EnableMotion(true)
            phys:Wake()
        end
    end

    local function CopyAppearance(ply, rag)
        rag:SetSkin(ply:GetSkin())
        for i = 0, ply:GetNumBodyGroups() - 1 do
            rag:SetBodygroup(i, ply:GetBodygroup(i))
        end
        for i = 0, 31 do
            local mat = ply:GetSubMaterial(i)
            if mat ~= "" then rag:SetSubMaterial(i, mat) end
        end
        local col = ply:GetColor()
        if col.r ~= 255 or col.g ~= 255 or col.b ~= 255 or col.a ~= 255 then
            rag:SetColor(col)
            rag:SetRenderMode(ply:GetRenderMode())
        end
    end

    -- Tell the grabbed client to stop driving its own locomotion. Without this a
    -- VR player's origin integrates velocity against a hull the server is
    -- teleporting every tick, and the view tears away from the body.
    local function SendState(target, rag)
        net.Start("vrmod_playergrab_state")
        net.WriteBool(IsValid(rag))
        net.WriteEntity(rag or NULL)
        net.Send(target)
    end

    function vrmod.utils.ReleasePlayerRagdoll(rag)
        local target = grabbed[rag]
        grabbed[rag] = nil
        if not IsValid(target) then
            if IsValid(rag) then rag:Remove() end
            return
        end
        ragdollOf[target] = nil

        local restorePos = IsValid(rag) and PelvisPos(rag) or target:GetPos()
        -- Read before the ragdoll goes away. The pickup system has already put
        -- the throw velocity on it by the time VRMod_Drop fires, so this is the
        -- hand's throw and it should carry over to the player.
        local vel
        if IsValid(rag) then
            local bone = rag:LookupBone(PELVIS_BONE)
            local phys = bone and rag:GetPhysicsObjectNum(rag:TranslateBoneToPhysBone(bone) or 0)
            if not IsValid(phys) then phys = rag:GetPhysicsObject() end
            if IsValid(phys) then vel = phys:GetVelocity() end
        end
        target:SetNWBool("vrmod_grabbed", false)
        target:Freeze(false)
        target:SetMoveType(target._vrgrab_movetype or MOVETYPE_WALK)
        target:SetCollisionGroup(target._vrgrab_group or COLLISION_GROUP_PLAYER)
        target:SetNotSolid(false)
        target:SetNoDraw(false)
        local wep = target._vrgrab_wep
        if IsValid(wep) then wep:SetNoDraw(target._vrgrab_wep_nodraw == true) end
        target._vrgrab_movetype, target._vrgrab_group = nil, nil
        target._vrgrab_wep, target._vrgrab_wep_nodraw = nil, nil
        target:SetPos(restorePos)
        -- Player:SetVelocity is additive, which is fine here: they were frozen,
        -- so they are starting from zero. DropToFloor would eat the throw, so it
        -- only runs when they were set down rather than launched.
        if vel and vel:LengthSqr() > 400 then
            target:SetVelocity(vel)
        else
            target:DropToFloor()
        end
        SendState(target, nil)
        if IsValid(rag) then rag:Remove() end
    end

    function vrmod.utils.SpawnPlayerRagdoll(ply, target)
        if not vrmod.utils.CanGrabPlayer(ply, target) then return target end

        local existing = ragdollOf[target]
        if IsValid(existing) then return existing end

        -- First grab of a given playermodel used to come out wrong: nothing had
        -- spawned a prop_ragdoll of it yet, so SetModel landed before the model
        -- was ready and GetPhysicsObjectCount was 0 when CopyPose ran, leaving a
        -- T-posed body. Precaching costs nothing once it is already loaded.
        local mdl = target:GetModel()
        util.PrecacheModel(mdl)

        local rag = ents.Create("prop_ragdoll")
        if not IsValid(rag) then return target end
        rag:SetModel(mdl)
        rag:SetPos(target:GetPos())
        rag:SetAngles(target:GetAngles())
        -- Reuses the existing ragdoll release path (throw velocity, mass, the
        -- flag being cleared on drop), so no new drop handling is needed.
        rag:SetNWBool("is_npc_ragdoll", true)
        rag:SetNWBool("vrmod_is_player_ragdoll", true)
        rag:Spawn()
        rag:Activate()
        rag:SetSaveValue("m_takedamage", 2)
        rag:SetHealth(99999)
        CopyPose(target, rag)
        CopyAppearance(target, rag)

        if IsValid(ply) then
            rag:SetOwner(ply)
            cleanup.Add(ply, "props", rag)
        end

        target._vrgrab_movetype = target:GetMoveType()
        target._vrgrab_group    = target:GetCollisionGroup()
        target:SetNWBool("vrmod_grabbed", true)
        target:SetMoveType(MOVETYPE_NONE)
        target:SetNotSolid(true)
        target:SetNoDraw(true)
        -- IN_VEHICLE on top of NotSolid: the player keeps a physics shadow that
        -- shoves nearby props, and the ragdoll is the nearest prop there is.
        -- That shove was the grabbed body kicking itself out of the hand.
        target:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
        target:Freeze(true)

        -- NoDraw on the player does not hide the weapon: the worldmodel is its
        -- own entity and keeps rendering at the old position.
        local wep = target:GetActiveWeapon()
        if IsValid(wep) then
            target._vrgrab_wep = wep
            target._vrgrab_wep_nodraw = wep:GetNoDraw()
            wep:SetNoDraw(true)
        end

        grabbed[rag] = target
        ragdollOf[target] = rag
        SendState(target, rag)

        rag:CallOnRemove("vrmod_playergrab_" .. rag:EntIndex(), function(self)
            if grabbed[self] then vrmod.utils.ReleasePlayerRagdoll(self) end
        end)

        return rag
    end

    -- The player entity deliberately stays put while held. Teleporting it onto
    -- the pelvis every tick is what made the body jolt out of the hand, and it
    -- is not needed: the only thing the position was buying was network
    -- visibility, which AddOriginToPVS gives for free. Position is reconciled
    -- once, on release.
    hook.Add("SetupPlayerVisibility", "vrmod_playergrab_pvs", function(ply)
        local rag = ragdollOf[ply]
        if IsValid(rag) then AddOriginToPVS(PelvisPos(rag)) end
    end)

    -- Real damage lands on the ragdoll while the player is non-solid, so it is
    -- forwarded on. Physics-impact types are dropped: those are the carrier
    -- bumping the body into walls, not someone attacking it.
    hook.Add("EntityTakeDamage", "vrmod_playergrab_damage", function(ent, dmg)
        local victim = grabbed[ent]
        if not IsValid(victim) then return end
        if dmg:IsDamageType(DMG_CRUSH) or dmg:IsDamageType(DMG_FALL) or dmg:IsDamageType(DMG_VEHICLE) then return true end
        victim:TakeDamageInfo(dmg)
        ent:SetHealth(99999)
        return true
    end)

    -- Rummaging through weapons mid-carry would leave a visible worldmodel we
    -- are not tracking. Simpler to refuse the switch than to chase it.
    hook.Add("PlayerSwitchWeapon", "vrmod_playergrab_noswitch", function(ply)
        if ragdollOf[ply] then return true end
    end)

    hook.Add("VRMod_Drop", "vrmod_playergrab_drop", function(_, ent)
        if IsValid(ent) and grabbed[ent] then vrmod.utils.ReleasePlayerRagdoll(ent) end
    end)

    hook.Add("PlayerDeath", "vrmod_playergrab_death", function(ply)
        local rag = ragdollOf[ply]
        if IsValid(rag) then vrmod.utils.ReleasePlayerRagdoll(rag) end
    end)

    -- Warm the ragdoll model for every playermodel in play, so the cold path
    -- above is never hit during an actual grab.
    hook.Add("PlayerSpawn", "vrmod_playergrab_precache", function(ply)
        timer.Simple(0, function()
            if IsValid(ply) then util.PrecacheModel(ply:GetModel()) end
        end)
    end)

    hook.Add("PlayerDisconnected", "vrmod_playergrab_disconnect", function(ply)
        local rag = ragdollOf[ply]
        if IsValid(rag) then vrmod.utils.ReleasePlayerRagdoll(rag) end
    end)

    hook.Add("PreCleanupMap", "vrmod_playergrab_cleanup", function()
        for rag in pairs(grabbed) do vrmod.utils.ReleasePlayerRagdoll(rag) end
    end)

    -- Turning the feature off mid-round has to let go of anyone already held.
    cvars.AddChangeCallback("vrmod_pickup_players", function(_, _, new)
        if tonumber(new) ~= 0 then return end
        for rag in pairs(grabbed) do vrmod.utils.ReleasePlayerRagdoll(rag) end
    end, "vrmod_playergrab")

--=======================================================================
-- Client: ride the ragdoll instead of driving locomotion
--=======================================================================
else
    local heldBy = nil

    local VIEW_LIFT = Vector(0, 0, 8)

    local function StopRiding()
        heldBy = nil
        hook.Remove("VRMod_Tracking", "vrmod_playergrab_ride")
        hook.Remove("CalcView", "vrmod_playergrab_view")
        if g_VR.active then vrmod.StartLocomotion() end
    end

    net.Receive("vrmod_playergrab_state", function()
        local held = net.ReadBool()
        local rag = net.ReadEntity()
        if not held then return StopRiding() end

        heldBy = rag
        if not g_VR.active then
            -- Desktop players have no origin override, and the player entity no
            -- longer moves, so the camera has to be pointed at the body.
            hook.Add("CalcView", "vrmod_playergrab_view", function(_, _, ang, fov)
                if not IsValid(heldBy) then
                    hook.Remove("CalcView", "vrmod_playergrab_view")
                    return
                end
                return { origin = heldBy:GetPos() + VIEW_LIFT, angles = ang, fov = fov }
            end)
            return
        end
        -- Locomotion owns g_VR.origin and would fight the server's SetPos.
        vrmod.StopLocomotion()
        hook.Add("VRMod_Tracking", "vrmod_playergrab_ride", function()
            if not IsValid(heldBy) then return StopRiding() end
            -- g_VR.origin is a live reference other systems reassign, so it is
            -- re-fetched and written in place rather than cached across frames.
            local o = g_VR.origin
            local p = heldBy:GetPos()
            o.x, o.y, o.z = p.x, p.y, p.z
        end)
    end)

    hook.Add("VRMod_Exit", "vrmod_playergrab_exit", function(ply)
        if ply == LocalPlayer() then hook.Remove("VRMod_Tracking", "vrmod_playergrab_ride") end
    end)
end