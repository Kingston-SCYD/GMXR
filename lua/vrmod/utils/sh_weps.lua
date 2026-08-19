g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}
vrmod.suppressViewModelUpdates = false
-- WEP UTILS
function vrmod.utils.IsValidWep(wep, get)
    if not IsValid(wep) then return false end
    local class = wep:GetClass()
    local vm
    vm = wep:GetWeaponViewModel()
    if class == "weapon_vrmod_empty" or vm == "" or vm == "models/weapons/c_arms.mdl" then return false end
    if get then
        return class, vm
    else
        return true
    end
end

function vrmod.utils.IsWeaponEntity(ent)
    if not IsValid(ent) then return false end
    local c = ent:GetClass()
    return ent:IsWeapon() or c:find("weapon_") or c == "prop_physics" and ent:GetModel():find("w_")
end

function vrmod.utils.WepInfo(wep)
    local class, vm = vrmod.utils.IsValidWep(wep, true)
    if class and vm then return class, vm end
end

function vrmod.utils.UpdateViewModelPos(pos, ang, override)
    local ply = LocalPlayer()
    if vrmod.suppressViewModelUpdates and not override then
        vrmod.utils.UpdateViewModel()
        return
    end

    pos, ang = vrmod.utils.CheckWeaponPushout(pos, ang)
    if not IsValid(ply) or not g_VR.active then return end
    if not ply:Alive() then return end
    local currentvmi = g_VR.currentvmi
    local modelPos = pos
    if currentvmi then
        local collisionShape = vrmod._collisionShapeByHand and vrmod._collisionShapeByHand.right
        if collisionShape and collisionShape.isClipped and collisionShape.pushOutPos then
            modelPos = collisionShape.pushOutPos
            vrmod.logger.Debug("[VRMod] Applying collision-corrected pos for viewmodel:", modelPos)
        end

        local offsetPos, offsetAng = LocalToWorld(currentvmi.offsetPos, currentvmi.offsetAng, modelPos, ang)
        g_VR.viewModelPos = offsetPos
        g_VR.viewModelAng = offsetAng
    else
        g_VR.viewModelPos = pos
        g_VR.viewModelAng = ang
    end

    vrmod.utils.UpdateViewModel()
end

-- Muzzle attachment index, resolved by name and cached per model. Index 1 is
-- the muzzle on purpose-built VR weapons, but on HL2 viewmodels it is often the
-- shell-eject/casing attachment.
--
-- Cached per model rather than in a single slot: worldmodel mode alternates
-- between the weapon's w_ model and the viewmodel across a frame, and a
-- one-entry cache re-ran LookupAttachment on every switch.
local muzIdxCache = {}
local function MuzzleIndex(ent)
    local mdl = ent:GetModel()
    if not mdl then return 1 end
    local i = muzIdxCache[mdl]
    if i then return i end
    i = ent:LookupAttachment("muzzle") or 0
    if i <= 0 then i = ent:LookupAttachment("muzzle_flash") or 0 end
    if i <= 0 then i = 1 end
    muzIdxCache[mdl] = i
    return i
end

-- Rigid muzzle: the attachment transform in model space, captured once per
-- model and then carried on the weapon pose.
--
-- Reading the live attachment every frame makes the muzzle inherit whatever the
-- viewmodel animation is doing. HL2 deploy and idle anims swing it around; the
-- physgun's prongs move it while it is holding something, which shakes the held
-- prop because the server drives it off this angle. In VR the gun is rigid in
-- your hand and recoil is already applied to the hand pose, so a fixed offset
-- is both more correct and much cheaper -- no per-frame bone rebuild once the
-- offset is committed.
--
-- Captured from the LIVE viewmodel rather than a neutral clientside copy. A
-- freshly spawned copy stands in its BIND pose, and on a v_ model built around
-- arms the bind pose parks the gun bones nowhere near where any animation puts
-- them -- v_toolgun lands a long way out to the side, which is the whole
-- "toolgun muzzle is way off" symptom. WorldToLocal against the pose we just
-- set turns the on-screen attachment into the model-space offset, so the cached
-- value always describes the gun the player is actually looking at.
local cv_rigid = CreateClientConVar("vrmod_muzzle_rigid", "1", true, false, "Carry the muzzle rigidly on the weapon instead of following viewmodel animation", 0, 1)
local muzLocal = {} -- [model] = {Pos, Ang} in model space, or false = stay live
-- The offset is only meaningful measured while the gun is STILL, and a fixed
-- delay cannot know when that is. Deploy animations outlast 0.5s on the slower
-- weapons, so the single sample landed mid-swing and froze the muzzle wherever
-- the animation happened to be -- muzzle flies around for half a second, then
-- sticks in the wrong place. Sample every frame instead and only commit once
-- the model-space offset has held still for SETTLE_HITS frames running.
-- Anything still animating simply never commits and keeps using the live
-- attachment, which is what every weapon did before rigid mode existed.
--
-- Per FRAME, not per call: RefreshViewModelMuzzle runs once in the tracking
-- pass and again for each eye, and model-space samples inside one frame are
-- identical by construction -- counting those would "settle" on the first two
-- frames and bake in exactly the bad pose the timer did.
--
-- Hand movement does not block settling: lp/la are relative to the viewmodel
-- pose, so only the ANIMATION can move them.
local SETTLE_HITS = 6      -- consecutive still frames required (~66ms @ 90fps)
local SETTLE_DIST = 0.01   -- squared units of allowed drift between samples
local SETTLE_ANG = 0.25    -- degrees of allowed drift, per axis
local FrameNumber, math_abs, AngleDifference = FrameNumber, math.abs, math.AngleDifference
local capMdl, capFrame, capN, capPos, capAng = nil, -1, 0, nil, nil
concommand.Add("vrmod_muzzle_recapture", function()
    muzLocal, capMdl, capN = {}, nil, 0
end, nil, "Forget the cached rigid muzzle offsets and measure them again")

-- Reposition the viewmodel and re-read its muzzle from g_VR.viewModelPos/Ang.
-- Shared by the early tracking pass, the left-hand path and the per-eye
-- refresh, so all three agree.
--
-- Scratch muzzle table. GetAttachment and LocalToWorld both hand back fresh
-- Vector/Angle objects every call, so muzzlefix rotating .Ang in place still
-- cannot accumulate across frames -- only the outer table is reused.
local _muz = {}
function vrmod.utils.RefreshViewModelMuzzle(vm)
    vm = vm or g_VR.viewModel
    -- _muz is shared, and muzzlefix wraps UpdateViewModel to rotate .Ang IN
    -- PLACE. Any path that leaves a previously-published _muz live while the
    -- wrapper still runs re-rotates the same Angle every frame, so the muzzle
    -- winds away from the barrel until it is pointing somewhere else entirely.
    -- Every exit from here must therefore either write a fresh transform or
    -- clear the muzzle outright.
    if not IsValid(vm) then
        g_VR.viewModelMuzzle = nil
        return
    end
    -- WORLDMODEL MODE -------------------------------------------------------
    -- Here g_VR.viewModel is the WEAPON ENTITY, not a viewmodel, and the engine
    -- bonemerges its worldmodel onto the owner's hand bone. Two consequences the
    -- viewmodel path below gets wrong, and the reason only worldmodel muzzles
    -- were broken:
    --
    --  1. SetPos/SetAngles on a held weapon does not move what you see. The
    --     render transform comes from the owner's hand bone, and the value is
    --     stomped again by interpolation. Two wasted natives per eye.
    --  2. The rigid branch composes the model-space muzzle onto
    --     g_VR.viewModelPos/Ang -- the HAND pose. A w_ model's origin is not its
    --     hand bone, so that displaced the muzzle by the model's whole
    --     origin->hand-bone offset AND rotated it by that bone's orientation.
    --     Wrong by a different arbitrary amount per model.
    --
    -- The engine has already placed this entity correctly, so read the
    -- attachment back off it. Invalidate first for the same reason the viewmodel
    -- path does: Source keys the bone cache on TIME, so anything that built
    -- these bones earlier in the frame (before VRMod_PreRender consumers moved
    -- the pose) would be returned stale. sh_lefthand's BuildBonePositions runs
    -- inside this rebuild and shifts the bones RH->LH before we read, so the two
    -- paths agree by construction.
    --
    -- IsWeapon is the test, not g_VR.wmActive: worldmodel mode IS "g_VR.viewModel
    -- is the weapon entity", and every producer (sh_network, WMApplyNow,
    -- cl_thirdparty_wm) assigns the weapon when it sets the flag. The flag can
    -- outlive its mode -- cl_thirdparty_wm sets it and never clears it -- and a
    -- stale true sent the real viewmodel down this branch, skipping the SetPos
    -- that puts it in your hand.
    if vm:IsWeapon() then
        vm:InvalidateBoneCache()
        local att = vm:GetAttachment(MuzzleIndex(vm))
        if att then
            _muz.Pos, _muz.Ang = att.Pos, att.Ang
            g_VR.viewModelMuzzle = _muz
        else
            -- No usable attachment: drop it rather than leave the previous
            -- weapon's muzzle hanging around for the laser and aim vector.
            g_VR.viewModelMuzzle = nil
        end
        return
    end
    -- VIEWMODEL MODE --------------------------------------------------------
    local pos, ang = g_VR.viewModelPos, g_VR.viewModelAng
    vm:SetPos(pos)
    vm:SetAngles(ang)
    -- Source keys its bone cache on TIME, not on position, so moving the entity
    -- does NOT dirty it. Anything that already built this viewmodel's bones
    -- earlier in the frame leaves DrawModel rendering the previous pose, and the
    -- animation pass on an animated viewmodel does exactly that -- which is why
    -- the HL2 weapons trailed the hand while the static physgun and camera were
    -- fine. Must stay outside the rigid branch: the rigid muzzle no longer needs
    -- bones, but the RENDER still does.
    vm:InvalidateBoneCache()
    local rigid = cv_rigid:GetBool()
    local mdl = vm:GetModel()
    local m = rigid and muzLocal[mdl]
    if m then
        _muz.Pos, _muz.Ang = LocalToWorld(m.Pos, m.Ang, pos, ang)
        g_VR.viewModelMuzzle = _muz
        return
    end
    -- Live path: build now so GetAttachment reflects the pose we just set
    -- rather than whatever it was cached at. This is also the sampler for the
    -- settle capture below, so an uncommitted model costs one bone build per
    -- frame -- exactly what the live path cost on its own.
    vm:SetupBones()
    local att = vm:GetAttachment(MuzzleIndex(vm))
    if not att then
        if rigid then muzLocal[mdl] = false end
        g_VR.viewModelMuzzle = nil
        return
    end

    _muz.Pos, _muz.Ang = att.Pos, att.Ang
    g_VR.viewModelMuzzle = _muz
    -- Settle sampler. Reads the RAW attachment: muzzlefix's per-weapon angle
    -- correction is applied by its UpdateViewModel wrapper only after this
    -- returns, so a committed offset can never bake that correction in and
    -- double-apply it. m is false here when rigid is off or the model has no
    -- attachment, and nil when it is still uncommitted.
    if m == false then return end
    local fn = FrameNumber()
    if fn == capFrame then return end
    capFrame = fn
    -- vm is already at pos/ang, so WorldToLocal against it yields the
    -- model-space offset directly.
    local lp, la = WorldToLocal(att.Pos, att.Ang, pos, ang)
    if capMdl ~= mdl then
        capMdl, capN = mdl, 1
    elseif lp:DistToSqr(capPos) <= SETTLE_DIST and math_abs(AngleDifference(la.p, capAng.p)) <= SETTLE_ANG and math_abs(AngleDifference(la.y, capAng.y)) <= SETTLE_ANG and math_abs(AngleDifference(la.r, capAng.r)) <= SETTLE_ANG then
        capN = capN + 1
        if capN >= SETTLE_HITS then muzLocal[mdl] = {Pos = lp, Ang = la} end
    else
        capN = 1
    end

    capPos, capAng = lp, la
end

function vrmod.utils.UpdateViewModel()
    vrmod.utils.RefreshViewModelMuzzle(g_VR.viewModel)
end