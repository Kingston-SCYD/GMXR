-- sv_arcvr_pouch_fix.lua
-- Spawns magazines and places them in the player's hand using ArcVR's client rendering path

if SERVER then
    util.AddNetworkString("vrmod_pouch_spawnmag")

    net.Receive("vrmod_pouch_spawnmag", function(_, ply)
        local pos = net.ReadVector()
        local ang = net.ReadAngle()
        local leftHand = net.ReadBool()
        local sid = ply:SteamID()
        if not g_VR or not g_VR[sid] then return end

        local wpn = ply:GetActiveWeapon()
        if not IsValid(wpn) or not wpn.ArcticVR then return end
        if not ArcticVR or not ArcticVR.CreateMag or not ArcticVR.MagazineTable then return end

        local magid = wpn.DefaultMagazine
        if wpn.GetAttOverride then
            if wpn:GetAttOverride("MagExtender") and wpn.ExtendedMagazine then
                magid = wpn.ExtendedMagazine
            end
            if wpn:GetAttOverride("MagReducer") and wpn.ReducedMagazine then
                magid = wpn.ReducedMagazine
                if wpn:GetAttOverride("MagExtender") then magid = wpn.DefaultMagazine end
            end
        end

        local magtbl = ArcticVR.MagazineTable[magid]
        if not magtbl then return end
        local cap = magtbl.Capacity
        local ammotype = wpn.Primary.Ammo
        local reserve = ply:GetAmmoCount(ammotype)
        if reserve <= 0 then return end
        local toload = math.Clamp(reserve, 0, cap)

        local mag = ArcticVR.CreateMag(magid, toload)
        if not IsValid(mag) then return end
        ply:SetAmmo(reserve - toload, ammotype)

        -- Position using EntityPose logic (same as GrabAndPose)
        local ppos, pang = pos, ang
        if mag.Pose and mag.Pose.pos ~= Vector() then
            local p = mag.Pose
            local rflip = (not leftHand) and -1 or 1
            ppos = pos + ang:Forward() * p.pos.x + ang:Right() * p.pos.y * rflip + ang:Up() * p.pos.z
            local poseAng = leftHand and Angle(p.ang) or Angle(p.ang.p, -p.ang.y, -p.ang.r)
            _, pang = LocalToWorld(Vector(0,0,0), poseAng, Vector(0,0,0), ang)
        end
        mag:SetPos(ppos)
        mag:SetAngles(pang)
        local locpos, locang = WorldToLocal(ppos, pang, pos, ang)

        -- Clear any existing mag in this hand slot
        local slot = leftHand and 1 or 2
        g_VR[sid].heldItems = g_VR[sid].heldItems or {}
        local existing = g_VR[sid].heldItems[slot]
        if existing and IsValid(existing.ent) then
            existing.ent:SetCollisionGroup(existing.ent.originalCollisionGroup or COLLISION_GROUP_NONE)
            existing.ent:Remove()
        end
        g_VR[sid].heldItems[slot] = nil
        g_VR[sid].heldItems[slot] = {
            ent = mag, left = leftHand,
            localPos = locpos, localAng = locang,
            targetPos = Vector(0,0,0), targetReached = SysTime()
        }

        -- Setup physics
        mag.originalCollisionGroup = mag:GetCollisionGroup()
        mag:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)
        mag:MakePhysicsObjectAShadow(true, true)

        -- Notify client after entity replicates (sh_pickup_arcvr.lua handles RenderOverride)
        timer.Simple(0.1, function()
            if not IsValid(mag) or not IsValid(ply) then return end
            net.Start("vrutil_net_pickup")
            net.WriteEntity(ply)
            net.WriteEntity(mag)
            net.WriteBool(leftHand)
            net.WriteVector(locpos)
            net.WriteAngle(locang)
            net.Broadcast()
        end)
    end)
end

-- Block ArcVR's built-in avr_spawnmag to prevent double mag spawns
-- Also block ArcVR melee damage (our fling system handles melee damage instead)
-- Also override avr_magin to prevent weapon deletion from stale entity refs
timer.Simple(1, function()
    net.Receive("avr_spawnmag", function(_, ply)
        net.ReadVector() net.ReadAngle() net.ReadBool()
    end)
    net.Receive("avr_meleeattack", function(_, ply) end)
    net.Receive("avr_meleeattack_weapon", function(_, ply) end)

    -- Safe avr_magin: only accept actual magazine entities, never weapons
    net.Receive("avr_magin", function(_, ply)
        local mag = net.ReadEntity()
        print("[MAGIN DBG] mag=" .. tostring(mag) .. " class=" .. (IsValid(mag) and mag:GetClass() or "INVALID") .. " ArcticVRMagazine=" .. tostring(IsValid(mag) and mag.ArcticVRMagazine))
        local dc = net.ReadBool()
        local wpn = ply:GetActiveWeapon()
        if not IsValid(mag) then return end
        if not mag.ArcticVRMagazine then return end -- SAFETY: must be a magazine entity
        if not mag.ArcticVR then return end
        if not mag.MagType then return end
        if not IsValid(wpn) or not wpn.ArcticVR then return end
        local magtbl = ArcticVR.MagazineTable[mag.MagID]
        if not magtbl then return end
        if magtbl.IsBeltBox then
            if mag.MagType ~= wpn.BeltBoxType then return end
        else
            if mag.MagType ~= wpn.MagType then return end
        end

        if not dc then
            if wpn.InternalMagazine then
                wpn.LoadedRounds = wpn.LoadedRounds + mag.Rounds
                if wpn.LoadedRounds > wpn.InternalMagazineCapacity then wpn.LoadedRounds = wpn.InternalMagazineCapacity end
            else
                wpn.Magazine = mag.Name
                wpn.LoadedRounds = mag.Rounds
            end
        end

        mag:Remove()
        net.Start("avr_magin_forclient")
        net.WriteUInt(wpn.LoadedRounds, 16)
        net.Send(ply)
    end)
end)

-- Clean up stuck mags when weapon is switched or dropped
hook.Add("PlayerSwitchWeapon", "arcvr_pouch_cleanup_mags", function(ply, oldWep, newWep)
    local sid = ply:SteamID()
    if not g_VR or not g_VR[sid] or not g_VR[sid].heldItems then return end
    for slot = 1, 2 do
        local held = g_VR[sid].heldItems[slot]
        if held and IsValid(held.ent) and held.ent.ArcticVRMagazine then
            -- Release the mag
            held.ent:SetCollisionGroup(held.ent.originalCollisionGroup or COLLISION_GROUP_NONE)
            local phys = held.ent:GetPhysicsObject()
            if IsValid(phys) then phys:EnableMotion(true) phys:Wake() end
            -- Notify client to clear RenderOverride
            net.Start("vrutil_net_drop")
            net.WriteEntity(ply)
            net.WriteEntity(held.ent)
            net.Broadcast()
            g_VR[sid].heldItems[slot] = nil
        end
    end
end)

-- Clear all heldItems on death to prevent stale references after respawn
hook.Add("PlayerDeath", "arcvr_pouch_death_cleanup", function(ply)
    local sid = ply:SteamID()
    if not g_VR or not g_VR[sid] or not g_VR[sid].heldItems then return end
    for slot = 1, 2 do
        g_VR[sid].heldItems[slot] = nil
    end
end)

-- Fix: re-select active weapon after mag grab (DropObject deselects it)
hook.Add("VRMod_Pickup", "arcvr_reselect_weapon_after_mag", function(ply, ent)
    if not IsValid(ent) or not ent.ArcticVRMagazine then return end
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) or wep:GetClass() == "weapon_vrmod_empty" then return end
    local class = wep:GetClass()
    timer.Simple(0.1, function()
        if not IsValid(ply) then return end
        local cur = ply:GetActiveWeapon()
        if not IsValid(cur) or cur:GetClass() == "weapon_vrmod_empty" then
            if ply:HasWeapon(class) then
                ply:SelectWeapon(class)
            end
        end
    end)
end)
