g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}
local trackedRagdolls = trackedRagdolls or {}
local lastDamageTime = {}
local npcRagdolls = {}

local PELVIS_BONE = "ValveBiped.Bip01_Pelvis"
local HAND_BONE   = "ValveBiped.Bip01_R_Hand"

-- ── Helpers ─────────────────────────────────────────────────

--- Snap ragdoll physics bones to the NPC's current animation pose.
local function CopyNPCPoseToRagdoll(npc, rag)
    local npcPos = npc:GetPos()
    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        if not IsValid(phys) then continue end
        local bone = rag:TranslatePhysBoneToBone(i)
        if not bone or bone < 0 then continue end
        local pos, ang = npc:GetBonePosition(bone)
        if not pos or pos == npcPos then continue end
        phys:EnableMotion(false)
        phys:SetPos(pos)
        phys:SetAngles(ang)
        phys:EnableMotion(true)
        phys:Wake()
    end
end

--- Copy all visual properties from NPC to ragdoll.
local function CopyNPCAppearance(npc, rag)
    rag:SetSkin(npc:GetSkin())
    for i = 0, npc:GetNumBodyGroups() - 1 do
        rag:SetBodygroup(i, npc:GetBodygroup(i))
    end
    for i = 0, 31 do
        local mat = npc:GetSubMaterial(i)
        if mat ~= "" then rag:SetSubMaterial(i, mat) end
    end
    for i = 0, npc:GetFlexNum() - 1 do
        rag:SetFlexWeight(i, npc:GetFlexWeight(i))
    end
    local col = npc:GetColor()
    if col.r ~= 255 or col.g ~= 255 or col.b ~= 255 or col.a ~= 255 then
        rag:SetColor(col)
        rag:SetRenderMode(npc:GetRenderMode())
    end
end

--- Weld a visual weapon prop to the ragdoll's right hand.
--- Uses a breakable forcelimit so players can grab the weapon out.
local function AttachWeaponToRagdoll(npc, rag)
    local wep = npc:GetActiveWeapon()
    if not IsValid(wep) then return end

    local handBone = rag:LookupBone(HAND_BONE)
    if not handBone then return end

    wep:SetNoDraw(true)

    local fake = ents.Create("prop_physics")
    if not IsValid(fake) then return end

    fake:SetModel(wep:GetModel())
    fake:Spawn()
    fake:SetCollisionGroup(COLLISION_GROUP_WEAPON)

    local wepHand = fake:LookupBone(HAND_BONE)
    if wepHand then
        local ragMat = rag:GetBoneMatrix(handBone)
        local wepMat = fake:GetBoneMatrix(wepHand)
        if ragMat and wepMat then
            wepMat:Invert()
            ragMat:Mul(wepMat)
            fake:SetPos(ragMat:GetTranslation())
            fake:SetAngles(ragMat:GetAngles())
        end
    else
        local pos, ang = rag:GetBonePosition(handBone)
        fake:SetPos(pos)
        fake:SetAngles(ang)
    end

    -- Unbreakable weld — grab is intercepted by VRMod_Pickup hook before attachment
    constraint.Weld(rag, fake, rag:TranslateBoneToPhysBone(handBone), 0, 0, true)

    fake.vrmod_is_ragdoll_weapon = true
    fake.vrmod_source_ragdoll    = rag
    rag.vrmod_fake_weapon        = fake
    rag.vrmod_original_weapon    = wep
end

--- Clean up fake weapon + restore real weapon visibility.
local function CleanupRagdollWeapon(rag)
    if IsValid(rag.vrmod_fake_weapon) then
        rag.vrmod_fake_weapon:Remove()
        rag.vrmod_fake_weapon = nil
    end
    if IsValid(rag.vrmod_original_weapon) then
        rag.vrmod_original_weapon:SetNoDraw(false)
        rag.vrmod_original_weapon = nil
    end
end

--- Release the fake weapon prop from the ragdoll's hand as a loose physics object.
--- Called when the NPC dies so the prop falls free and can still be grabbed.
local function DropFakeWeapon(rag)
    local fake = rag.vrmod_fake_weapon
    if not IsValid(fake) then return end
    constraint.RemoveAll(fake)
    fake:SetCollisionGroup(COLLISION_GROUP_NONE)
    local phys = fake:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(true)
        phys:Wake()
    end
    -- Keep vrmod_is_ragdoll_weapon flag so VRMod_Pickup hook still gives the weapon
end

--- Get pelvis world position from ragdoll (waist anchor).
local function GetRagdollPelvisPos(rag)
    if not IsValid(rag) then return rag:GetPos() end
    local bone = rag:LookupBone(PELVIS_BONE)
    if bone then
        local pos = rag:GetBonePosition(bone)
        if pos and pos ~= rag:GetPos() then return pos end
    end
    return rag:GetPos()
end

--- Drive ragdoll physics bones toward a prop_dynamic poser's standing pose
--- via ComputeShadowControl. Called every Think tick during get-up.
local _shadowParams = {
    secondstoarrive = 0.3, maxangular = 500, maxangulardamp = 300,
    maxspeed = 300, maxspeeddamp = 150, teleportdistance = 0,
    pos = Vector(), angle = Angle(), deltatime = 0
}
local function DriveRagdollToStandingPose(rag, poser)
    if not IsValid(rag) or not IsValid(poser) then return end
    local ct = CurTime()
    local dt = ct - (rag._getup_delta or ct)
    rag._getup_delta = ct
    _shadowParams.deltatime = dt

    local poserPos = poser:GetPos()
    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        if not IsValid(phys) then continue end
        local bone = rag:TranslatePhysBoneToBone(i)
        if not bone or bone < 0 then continue end
        local pos, ang = poser:GetBonePosition(bone)
        if not pos or pos == poserPos then continue end
        _shadowParams.pos = pos
        _shadowParams.angle = ang
        phys:Wake()
        phys:ComputeShadowControl(_shadowParams)
    end
end

-- ── Bone mass utilities ─────────────────────────────────────

function vrmod.utils.GetBoneMass(ent, physIndex)
    if not IsValid(ent) then return nil end
    local physCount = ent.GetPhysicsObjectCount and ent:GetPhysicsObjectCount() or 0
    if physCount <= 0 then
        local p = ent:GetPhysicsObject()
        if not IsValid(p) then return nil end
        if physIndex then return physIndex == 0 and p:GetMass() or nil end
        return { [0] = p:GetMass() }
    end
    if physIndex then
        local p = ent:GetPhysicsObjectNum(physIndex)
        return IsValid(p) and p:GetMass() or nil
    end
    local masses = {}
    for i = 0, physCount - 1 do
        local p = ent:GetPhysicsObjectNum(i)
        if IsValid(p) then masses[i] = p:GetMass() end
    end
    return masses
end

function vrmod.utils.CacheBoneMasses(ent, force)
    if not IsValid(ent) then return end
    if ent.vrmod_original_masses and not force then return end
    ent.vrmod_original_masses = vrmod.utils.GetBoneMass(ent) or {}
end

function vrmod.utils.RestoreBoneMasses(ent, delay, damp, vel, angvel, resetmotion)
    if not IsValid(ent) then return end
    local original = ent.vrmod_original_masses
    if not original then return end
    local function doRestore()
        if not IsValid(ent) then return end
        for i, mass in pairs(original) do
            local phys = ent:GetPhysicsObjectNum(i)
            if not IsValid(phys) and i == 0 then phys = ent:GetPhysicsObject() end
            if IsValid(phys) then
                phys:EnableMotion(not resetmotion)
                if resetmotion then phys:EnableMotion(true) end
                phys:SetMass(mass)
                if damp then phys:SetDamping(damp, damp) end
                if vel then phys:SetVelocity(vel) end
                if angvel then phys:AddAngleVelocity(VectorRand() * angvel) end
                phys:EnableGravity(true)
                phys:Wake()
            end
        end
    end
    if delay and delay > 0 then timer.Simple(delay, doRestore) else doRestore() end
end

function vrmod.utils.ClearCachedBoneMasses(ent)
    if not IsValid(ent) then return end
    ent.vrmod_original_masses = nil
end

function vrmod.utils.TempSetDamping(ent, highDamp, restoreDamp, delay)
    if not IsValid(ent) then return end
    delay = delay or 0.01
    for i = 0, ent:GetPhysicsObjectCount() - 1 do
        local phys = ent:GetPhysicsObjectNum(i)
        if IsValid(phys) then
            phys:SetDamping(highDamp, highDamp)
            phys:SetMaterial("default_silent")
            phys:Wake()
        end
    end
    timer.Simple(delay, function()
        if not IsValid(ent) then return end
        for i = 0, ent:GetPhysicsObjectCount() - 1 do
            local phys = ent:GetPhysicsObjectNum(i)
            if IsValid(phys) then
                phys:SetDamping(restoreDamp, restoreDamp)
                phys:SetMaterial("flesh")
                phys:Wake()
            end
        end
    end)
end

function vrmod.utils.SetBoneMass(ent, mass, damp, vel, angvel, resetmotion, delay)
    if not IsValid(ent) or not IsValid(ent:GetPhysicsObject()) then return end
    timer.Simple(delay or 0, function()
        if not IsValid(ent) then return end
        for i = 0, ent:GetPhysicsObjectCount() - 1 do
            local phys = ent:GetPhysicsObjectNum(i)
            if not IsValid(phys) then continue end
            if resetmotion then
                phys:EnableMotion(false)
                phys:EnableMotion(true)
            else
                phys:EnableMotion(true)
            end
            phys:SetMass(mass)
            phys:SetDamping(damp, damp)
            if vel then phys:SetVelocity(vel) end
            if angvel then phys:AddAngleVelocity(VectorRand() * angvel) end
            phys:EnableGravity(true)
            phys:Wake()
        end
    end)
end

function vrmod.utils.ForwardRagdollDamage(ent, dmginfo)
    if not (ent:IsRagdoll() and trackedRagdolls[ent]) then return end
    if ent.noDamage then return end
    local isBullet = dmginfo:IsBulletDamage()
    local now = CurTime()
    local last = lastDamageTime[ent] or 0
    -- Bullets need fast response; blunt/fall damage keeps the 0.4s debounce
    if now - last < (isBullet and 0.05 or 0.4) then return end
    lastDamageTime[ent] = now
    local npc = trackedRagdolls[ent]
    if not IsValid(npc) then
        trackedRagdolls[ent] = nil
        return
    end

    -- Temporarily position NPC at ragdoll so pain sounds emit from correct location.
    -- Route damage through TakeDamageInfo so the engine fires its native pain response
    -- (vocalizations, flinch events) without needing to know the NPC's sound scripts.
    local savedPos = npc:GetPos()
    npc:SetPos(ent:GetPos())
    npc:TakeDamageInfo(dmginfo)
    npc:SetPos(savedPos)

    -- Apply force to ragdoll physics
    local force = dmginfo:GetDamageForce()
    if not force or force:IsZero() then return end

    if isBullet then
        -- Localized hit: find the nearest physics bone to the impact point
        local hitPos = dmginfo:GetDamagePosition()
        local bestPhys, bestDist = nil, math.huge
        for i = 0, ent:GetPhysicsObjectCount() - 1 do
            local phys = ent:GetPhysicsObjectNum(i)
            if IsValid(phys) then
                local d = phys:GetPos():DistToSqr(hitPos)
                if d < bestDist then bestDist, bestPhys = d, phys end
            end
        end
        if bestPhys then
            bestPhys:Wake()
            bestPhys:ApplyForceOffset(force, hitPos)
        end
    else
        for i = 0, ent:GetPhysicsObjectCount() - 1 do
            local phys = ent:GetPhysicsObjectNum(i)
            if IsValid(phys) then phys:ApplyForceCenter(force) end
        end
    end
end

-- ── SpawnPickupRagdoll ──────────────────────────────────────

function vrmod.utils.SpawnPickupRagdoll(ply, npc)
    if not IsValid(npc) then return end

    local existing = npcRagdolls[npc]
    if IsValid(existing) then
        -- Cancel any in-progress get-up so it doesn't fight the new grab
        if existing._getup_active then
            existing._getup_active = false
            if IsValid(existing._getup_poser) then existing._getup_poser:Remove() end
        end
        existing.dropped_manually = false
        existing.noDamage = false
        existing._getup_triggered = false
        -- Cancel the deferred removal timer from the previous drop
        timer.Remove("vrmod_npcrag_remove_" .. existing:EntIndex())
        return existing
    end

    local rag = ents.Create("prop_ragdoll")
    if not IsValid(rag) then return end

    rag:SetModel(npc:GetModel())
    rag:SetPos(npc:GetPos())
    rag:SetAngles(npc:GetAngles())
    rag:SetNWBool("is_npc_ragdoll", true)
    rag:Spawn()
    rag:Activate()

    -- Enable bullet damage on ragdoll (prop_ragdoll defaults to DAMAGE_NO for bullets)
    rag:SetSaveValue("m_takedamage", 2) -- DAMAGE_YES
    rag:SetHealth(99999)

    -- Copy NPC pose to ragdoll physics bones (prevents T-pose)
    CopyNPCPoseToRagdoll(npc, rag)

    -- Copy all visual properties (skin, bodygroups, flexes, submats, color)
    CopyNPCAppearance(npc, rag)

    if IsValid(ply) then
        rag:SetOwner(ply)
        cleanup.Add(ply, "props", rag)
        undo.Create("VRMod NPC Ragdoll")
        undo.AddEntity(rag)
        undo.SetPlayer(ply)
        undo.Finish()
    end

    trackedRagdolls[rag] = npc
    npcRagdolls[npc]     = rag
    rag.original_npc     = npc
    rag.dropped_manually = false

    -- Disable NPC AI + hide
    npc:SetNoDraw(true)
    npc:SetNotSolid(true)
    npc:SetMoveType(MOVETYPE_NONE)
    npc:SetCollisionGroup(COLLISION_GROUP_VEHICLE)
    npc:ClearSchedule()
    if npc.StopMoving then npc:StopMoving() end
    npc:AddEFlags(EFL_NO_THINK_FUNCTION)
    if npc.SetNPCState then npc:SetNPCState(NPC_STATE_NONE) end
    npc:SetSaveValue("m_bInSchedule", false)
    -- Prevent engine from dropping a world weapon on NPC death (we handle it via fake prop)
    rag._npc_orig_spawnflags = npc:GetSpawnFlags()
    npc:AddSpawnFlags(SF_NPC_NO_WEAPON_DROP)

    -- Keep weapon on NPC, weld visual copy to ragdoll hand
    AttachWeaponToRagdoll(npc, rag)

    rag:AddCallback("PhysicsCollide", function(self, data)
        if rag.picked or rag.noDamage then return end
        local speed = data.OurOldVelocity:Length()
        -- Hard impact: damping + fall damage
        if speed > 500 then
            local dmg = DamageInfo()
            dmg:SetDamage(speed - 250)
            dmg:SetDamageType(DMG_FALL)
            dmg:SetAttacker(game.GetWorld())
            dmg:SetInflictor(game.GetWorld())
            dmg:SetDamageForce(data.OurOldVelocity * -100)
            vrmod.utils.TempSetDamping(rag, 15, 0.3, 0.08)
            vrmod.utils.ForwardRagdollDamage(rag, dmg)
        elseif speed > 250 then
            -- Moderate impact: light damping, ragdoll tumbles naturally
            vrmod.utils.TempSetDamping(rag, 3, 0.2, 0.05)
        end
    end)

    local ragIdx = rag:EntIndex()
    rag:CallOnRemove("vrmod_cleanup_npc_" .. ragIdx, function()
        trackedRagdolls[rag] = nil
        npcRagdolls[npc]     = nil
        CleanupRagdollWeapon(rag)
        if IsValid(rag._getup_poser) then rag._getup_poser:Remove() end

        if not IsValid(npc) then return end
        npc:RemoveEFlags(EFL_NO_THINK_FUNCTION)
        -- Restore original spawnflags (undo SF_NPC_NO_WEAPON_DROP)
        if rag._npc_orig_spawnflags then
            npc:SetSpawnFlags(rag._npc_orig_spawnflags)
        end

        if rag.dropped_manually then
            local spawnPos = GetRagdollPelvisPos(rag)
            timer.Simple(0, function()
                if not IsValid(npc) then return end
                npc:SetPos(spawnPos)
                npc:SetNoDraw(false)
                npc:SetNotSolid(false)
                npc:SetMoveType(MOVETYPE_STEP)
                npc:SetCollisionGroup(COLLISION_GROUP_NONE)
                npc:ClearSchedule()
                npc:SetSaveValue("m_bInSchedule", false)
                if npc.SetNPCState then npc:SetNPCState(NPC_STATE_ALERT) end
                npc:DropToFloor()
                if npc.BehaveStart then pcall(npc.BehaveStart, npc) end
                npc:SetSchedule(SCHED_IDLE_STAND)
                npc:NextThink(CurTime())
            end)
        else
            npc:Remove()
        end
    end)

    -- Combined Think: gibbing monitor + death weapon drop + get-up bone driving
    local weaponDropped  = false
    hook.Add("Think", "VRMod_RagdollMonitor_" .. ragIdx, function()
        if not IsValid(rag) then
            hook.Remove("Think", "VRMod_RagdollMonitor_" .. ragIdx)
            return
        end
        if vrmod.utils.IsRagdollGibbed(rag) then
            rag:Remove()
            hook.Remove("Think", "VRMod_RagdollMonitor_" .. ragIdx)
            return
        end

        -- When NPC dies, release the fake weapon so it falls loose from the hand.
        -- The VRMod_Pickup hook still handles giving the real weapon when grabbed.
        if not weaponDropped and vrmod.utils.IsRagdollDead(rag) and IsValid(rag.vrmod_fake_weapon) then
            weaponDropped = true
            DropFakeWeapon(rag)
        end

        -- Detect drop and start get-up bone driving after settling
        if rag.dropped_manually and not rag._getup_triggered then
            rag._getup_triggered = true
            timer.Simple(1.5, function()
                if not IsValid(rag) or not IsValid(npc) then return end
                -- Abort if ragdoll was re-grabbed during the delay
                if not rag.dropped_manually then return end
                if rag.vrmod_bone_hand_map and next(rag.vrmod_bone_hand_map) then
                    rag.dropped_manually = false
                    rag.noDamage = false
                    rag._getup_triggered = false
                    return
                end
                local pelvisPos = GetRagdollPelvisPos(rag)
                local tr = util.TraceLine({
                    start  = pelvisPos,
                    endpos = pelvisPos - Vector(0, 0, 200),
                    mask   = MASK_NPCSOLID,
                    filter = { rag, npc }
                })
                local groundPos = tr.Hit and tr.HitPos or pelvisPos
                local poser = ents.Create("prop_dynamic")
                if not IsValid(poser) then return end
                poser:SetModel(npc:GetModel())
                poser:SetPos(groundPos)
                poser:SetAngles(npc:GetAngles())
                poser:Spawn()
                poser:SetNoDraw(true)
                local idleSeq = poser:SelectWeightedSequence(ACT_IDLE)
                if not idleSeq or idleSeq < 0 then idleSeq = 0 end
                poser:SetSequence(idleSeq)
                poser:SetCycle(0)
                for i = 0, rag:GetPhysicsObjectCount() - 1 do
                    local phys = rag:GetPhysicsObjectNum(i)
                    if IsValid(phys) then
                        phys:SetMass(15)
                        phys:SetDamping(2, 2)
                        phys:EnableGravity(false)
                    end
                end
                rag._getup_poser = poser
                rag._getup_delta = CurTime()
                rag._getup_active = true
            end)
        end

        -- Drive ragdoll bones toward standing pose every tick
        if rag._getup_active then
            -- Abort get-up if ragdoll was re-grabbed mid-animation
            if rag.vrmod_bone_hand_map and next(rag.vrmod_bone_hand_map) then
                rag._getup_active = false
                rag.dropped_manually = false
                rag.noDamage = false
                rag._getup_triggered = false
                if IsValid(rag._getup_poser) then rag._getup_poser:Remove() end
            else
                DriveRagdollToStandingPose(rag, rag._getup_poser)
            end
        end
    end)

    return rag
end

-- ── Ragdoll state queries ───────────────────────────────────

function vrmod.utils.IsRagdollGibbed(ent)
    if not IsValid(ent) then return true end
    local hpTable  = ent.ZippyGoreMod3_PhysBoneHPs
    local gibTable = ent.ZippyGoreMod3_GibbedPhysBones
    if type(hpTable) == "table" then
        for _, hp in pairs(hpTable) do
            if hp == -1 then return true end
        end
    end
    if type(gibTable) == "table" then
        for _, wasGibbed in pairs(gibTable) do
            if wasGibbed then return true end
        end
    end
    if hpTable == nil and gibTable == nil then return false end
    if type(hpTable) == "table" then
        if ent:GetPhysicsObjectCount() < table.Count(hpTable) then return true end
    end
    return false
end

function vrmod.utils.IsRagdollDead(ent)
    if not IsValid(ent) then return true end
    local npc = ent.original_npc
    if IsValid(npc) and npc:Health() <= 0 then return true end
    return vrmod.utils.IsRagdollGibbed(ent)
end

if SERVER then
    -- Intercept VR grabs on fake weapon props BEFORE the pickup system attaches.
    -- Blocks the pickup, removes the prop, gives the real weapon class to the player.
    hook.Add("VRMod_Pickup", "VRMod_RagdollWeaponGrab", function(ply, ent)
        if not ent.vrmod_is_ragdoll_weapon then return end

        local rag = ent.vrmod_source_ragdoll
        local wepClass = nil
        if IsValid(rag) and IsValid(rag.vrmod_original_weapon) then
            wepClass = rag.vrmod_original_weapon:GetClass()
            -- Remove the NPC's weapon entity so re-grabs can't re-attach it
            rag.vrmod_original_weapon:Remove()
            rag.vrmod_original_weapon = nil
            rag.vrmod_fake_weapon = nil
        end

        constraint.RemoveAll(ent)
        ent:Remove()

        if wepClass and IsValid(ply) then
            ply:Give(wepClass)
            ply:SelectWeapon(wepClass)
        end

        return false
    end)

    -- Suppress the engine's own ragdoll when we already have a tracked one for this NPC.
    -- Without this, killing a grabbed NPC spawns an invisible/broken duplicate ragdoll.
    hook.Add("CreateEntityRagdoll", "VRMod_SuppressDuplicateRagdoll", function(npc, ragdoll)
        if IsValid(npcRagdolls[npc]) then
            SafeRemoveEntity(ragdoll)
        end
    end)

    if not (hook.GetTable()["EntityTakeDamage"] or {})["VRMod_ForwardRagdollDamage"] then
        hook.Add("EntityTakeDamage", "VRMod_ForwardRagdollDamage", function(ent, dmginfo)
            vrmod.utils.ForwardRagdollDamage(ent, dmginfo)
            -- Keep ragdoll alive — reset health so Source doesn't remove it
            if trackedRagdolls[ent] then ent:SetHealth(99999) end
        end)
    end
    timer.Create("VRMod_Cleanup_DeadRagdolls", 60, 0, function()
        for rag, npc in pairs(trackedRagdolls) do
            if not IsValid(rag) or not IsValid(npc) then trackedRagdolls[rag] = nil end
        end
    end)
end