-- sh_playergrab.lua
-- Grabbing live players. The player is carried by the hand that took hold,
-- translation only: the hand's offset at the grab is kept in world axes, so
-- turning the wrist doesn't swing them round it. No stand-in body -- they
-- stay themselves (hitboxes, weapon, damage), held still (MOVETYPE_NONE)
-- and set where the hand carries them each tick, swept with their own hull
-- so they can't be shoved into walls. Letting go hands them the hand's
-- velocity.
--
-- Hooks in by wrapping the pickup predicates, the NPC->ragdoll step (a
-- player grab ends the normal pickup there) and vrmod.Drop, so sh_pickup and
-- sh_pickup_util are untouched; delete this file to remove the feature.

local U = vrmod.utils

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
        return CAMI.UsergroupInherits(tg, gg) and not CAMI.UsergroupInherits(gg, tg)
    end
    return RankOf(target) > RankOf(grabber)
end

--=======================================================================
-- Eligibility
--=======================================================================
local cv_players = GetConVar("vrmod_pickup_players")
local cv_protect = GetConVar("vrmod_pickup_players_adminprotect")
local pOn, pProt = cv_players:GetBool(), cv_protect:GetBool()
cvars.AddChangeCallback("vrmod_pickup_players", function() pOn = cv_players:GetBool() end, "vrmod_playergrab_cv")
cvars.AddChangeCallback("vrmod_pickup_players_adminprotect", function() pProt = cv_protect:GetBool() end, "vrmod_playergrab_cv")

-- Shared so the client greys out targets the server would refuse anyway.
function U.CanGrabPlayer(grabber, target)
    if not pOn then return false end
    if not IsValid(grabber) or not IsValid(target) then return false end
    if target == grabber or not target:IsPlayer() then return false end
    if not target:Alive() or target:InVehicle() then return false end
    if IsValid(target:GetNW2Entity("vrmod_grabber")) then return false end
    -- Nobody carries someone carrying them, however far up: each would
    -- chase the other's hand
    local up = grabber
    for _ = 1, 8 do
        up = up:GetNW2Entity("vrmod_grabber")
        if not IsValid(up) then break end
        if up == target then return false end
    end
    if pProt and Outranks(target, grabber) then return false end
    -- Addon override, same shape as VRMod_Pickup: return false to refuse.
    if hook.Call("VRMod_CanGrabPlayer", nil, grabber, target) == false then return false end
    return true
end

--=======================================================================
-- Server: carry
--=======================================================================
local grabs = {} -- [target] = {by, sid, left, off, mt, cg, filter}; server only
local Release
if SERVER then
    util.AddNetworkString("vrmod_playergrab_state")

    -- Past this between where the hand would put them and where the sweep
    -- left them (a wall in between), the grip is lost
    local GAP2 = 96 * 96
    local _out = {}
    local _tr = {mask = MASK_PLAYERSOLID, output = _out}

    -- Tells the carried client to ride the carrier's hand instead of its own
    -- locomotion: its origin would integrate against a player that is set
    -- somewhere else every tick.
    local function SendState(target, g)
        net.Start("vrmod_playergrab_state")
        net.WriteBool(g ~= nil)
        if g then
            net.WriteEntity(g.by)
            net.WriteBool(g.left)
            net.WriteVector(g.off)
        end
        net.Send(target)
    end

    local function Carry()
        for target, g in pairs(grabs) do
            local by = g.by
            if not (IsValid(target) and target:Alive() and IsValid(by) and by:Alive() and g_VR[g.sid]) then
                Release(target)
            else
                local hp = U.GetHandTransform(by, g.left)
                if hp then
                    local to = hp + g.off
                    _tr.start, _tr.endpos, _tr.filter = target:GetPos(), to, g.filter
                    _tr.mins, _tr.maxs = target:OBBMins(), target:OBBMaxs()
                    util.TraceHull(_tr)
                    if _out.StartSolid then
                        -- Already overlapping something: take the target if it's clear
                        _tr.start = to
                        util.TraceHull(_tr)
                        if not _out.StartSolid then target:SetPos(to) end
                    else
                        target:SetPos(_out.HitPos)
                        if _out.HitPos:DistToSqr(to) > GAP2 then Release(target) end
                    end
                end
            end
        end
    end

    -- vel: the carrying hand's, on a let-go. SetVelocity adds on players, so
    -- whatever they had going in is cancelled with it.
    function Release(target, vel)
        local g = grabs[target]
        if not g then return end
        grabs[target] = nil
        if not next(grabs) then hook.Remove("Tick", "vrmod_playergrab") end
        if not IsValid(target) then return end
        target:SetNW2Entity("vrmod_grabber", NULL)
        target:SetMoveType(g.mt)
        target:SetCollisionGroup(g.cg)
        if not (vel and vel:LengthSqr() > 400) then
            vel = vector_origin
        elseif vel:LengthSqr() > 2250000 then
            vel = vel:GetNormalized() * 1500
        end
        target:SetVelocity(vel - target:GetVelocity())
        SendState(target, nil)
    end
    U.ReleasePlayer = Release

    function U.GrabPlayer(ply, target, left)
        if not U.CanGrabPlayer(ply, target) then return end
        left = left == true
        for t, g in pairs(grabs) do
            if g.by == ply and g.left == left then Release(t) end -- one per hand
        end
        local hp = U.GetHandTransform(ply, left)
        if not hp then return end
        local g = {by = ply, sid = ply:SteamID(), left = left, off = target:GetPos() - hp, mt = target:GetMoveType(), cg = target:GetCollisionGroup()}
        -- The sweep skips both players and every VR hand prop (sv_physhands):
        -- the carrier's sits right at the grip
        g.filter = function(e) return e ~= target and e ~= ply and e.vrOwner == nil end
        if not next(grabs) then hook.Add("Tick", "vrmod_playergrab", Carry) end
        grabs[target] = g
        target:SetMoveType(MOVETYPE_NONE)
        -- Other players, the carrier first, walk through them; shots still land
        target:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)
        target:SetNW2Entity("vrmod_grabber", ply)
        SendState(target, g)
    end

    local function ReleaseInvolving(ply)
        for t, g in pairs(grabs) do
            if t == ply or g.by == ply then Release(t) end
        end
    end
    hook.Add("PlayerDeath", "vrmod_playergrab", ReleaseInvolving)
    hook.Add("PlayerDisconnected", "vrmod_playergrab", ReleaseInvolving)
    hook.Add("VRMod_Exit", "vrmod_playergrab", ReleaseInvolving)
    -- Noclip or a seat would leave a carried player's state behind
    hook.Add("PlayerNoClip", "vrmod_playergrab", function(ply) if grabs[ply] then return false end end)
    hook.Add("CanPlayerEnterVehicle", "vrmod_playergrab", function(ply) if grabs[ply] then return false end end)

    -- Turning the feature off mid-round has to let go of anyone already held.
    cvars.AddChangeCallback("vrmod_pickup_players", function(_, _, new)
        if tonumber(new) ~= 0 then return end
        for t in pairs(grabs) do Release(t) end
    end, "vrmod_playergrab")
end

-- Wrap rather than edit. Deferred a tick because the pickup files load after
-- this one and we must wrap the real functions, not be overwritten by them.
timer.Simple(0, function()
    local canPickup = U.CanPickupEntity
    if canPickup then
        function U.CanPickupEntity(v, ply, cv)
            if IsValid(v) and v:IsPlayer() then return U.CanGrabPlayer(ply, v) end
            return canPickup(v, ply, cv)
        end
    end

    local validTarget = U.IsValidPickupTarget
    if validTarget then
        function U.IsValidPickupTarget(ent, ply, bLeftHand)
            if IsValid(ent) and ent:IsPlayer() then return U.CanGrabPlayer(ply, ent) end
            return validTarget(ent, ply, bLeftHand)
        end
    end

    if not SERVER then return end
    -- vrmod.Pickup runs every grab through here after validation; a player
    -- is carried instead, and the nil ends the prop pickup there.
    local handleNPC = U.HandleNPCRagdoll
    if handleNPC then
        function U.HandleNPCRagdoll(ply, ent)
            if IsValid(ent) and ent:IsPlayer() then return U.GrabPlayer(ply, ent, ply.vrmod_pickup_left_hand) end
            return handleNPC(ply, ent)
        end
    end

    -- The carrier's client never holds an entity here, so its grip release
    -- arrives as a drop with no pickup entry: let go of the carried player.
    local drop = vrmod.Drop
    if drop then
        function vrmod.Drop(steamid, bLeft)
            for t, g in pairs(grabs) do
                local by = g.by
                if g.left == bLeft and IsValid(by) and by:SteamID() == steamid then
                    Release(t, bLeft and vrmod.GetLeftHandVelocity(by) or vrmod.GetRightHandVelocity(by))
                end
            end
            return drop(steamid, bLeft)
        end
    end
end)

if SERVER then return end

--=======================================================================
-- Client: ride the carrier's hand instead of driving locomotion
--=======================================================================
-- The server sets the player on the hand at tick rate; the view rides the
-- carrier's interpolated network hand at frame rate instead, by the same
-- offset. lift keeps the playspace origin where it sat against the player.
local by, left, sid, rode
-- off + lift, and lift alone, as numbers: both fixed for the ride
local ox, oy, oz, lx, ly, lz = 0, 0, 0, 0, 0, 0
local VUnpack, VSetU = FindMetaTable("Vector").Unpack, FindMetaTable("Vector").SetUnpacked

local function Stop()
    hook.Remove("VRMod_Tracking", "vrmod_playergrab_ride")
    if rode and g_VR.active then vrmod.StartLocomotion() end
    by, rode = nil, false
end

local function Ride()
    if not IsValid(by) then return Stop() end
    sid = sid or by:SteamID()
    local nd = g_VR.net[sid]
    local f = nd and nd.lerpedFrame
    local hp = f and (left and f.lefthandPos or f.righthandPos)
    -- g_VR.origin is a live reference other systems reassign: written in place
    if hp then
        local x, y, z = VUnpack(hp)
        VSetU(g_VR.origin, x + ox, y + oy, z + oz)
    else
        local x, y, z = VUnpack(LocalPlayer():GetPos())
        VSetU(g_VR.origin, x + lx, y + ly, z + lz)
    end
end

net.Receive("vrmod_playergrab_state", function()
    if not net.ReadBool() then return Stop() end
    local off
    by, left, off = net.ReadEntity(), net.ReadBool(), net.ReadVector()
    -- Desktop players need nothing: their camera rides the player entity
    if not g_VR.active then return end
    if not rode then
        vrmod.StopLocomotion()
        rode = true
    end
    sid = nil -- resolved on the first ride frame, once by is valid
    lx, ly, lz = VUnpack(g_VR.origin - LocalPlayer():GetPos())
    local x, y, z = VUnpack(off)
    ox, oy, oz = x + lx, y + ly, z + lz
    hook.Add("VRMod_Tracking", "vrmod_playergrab_ride", Ride)
end)

hook.Add("VRMod_Exit", "vrmod_playergrab_exit", function(ply)
    if ply ~= LocalPlayer() then return end
    hook.Remove("VRMod_Tracking", "vrmod_playergrab_ride")
    by, rode = nil, false
end)
