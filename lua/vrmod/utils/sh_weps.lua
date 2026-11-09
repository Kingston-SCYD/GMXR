local U = vrmod.utils
vrmod.suppressViewModelUpdates = false
local IsValid, LocalToWorld, LocalPlayer = IsValid, LocalToWorld, LocalPlayer
-- WEP UTILS
-- Empty hands are ruled out before the viewmodel read
local function IsValidWep(wep, get)
    if not IsValid(wep) then return false end
    local class = wep:GetClass()
    if class == "weapon_vrmod_empty" then return false end
    local vm = wep:GetWeaponViewModel()
    if vm == "" or vm == "models/weapons/c_arms.mdl" then return false end
    if get then return class, vm end
    return true
end
U.IsValidWep = IsValidWep

function U.IsWeaponEntity(ent)
    if not IsValid(ent) then return false end
    local c = ent:GetClass()
    return ent:IsWeapon() or c:find("weapon_", 1, true) or c == "prop_physics" and ent:GetModel():find("w_", 1, true)
end

function U.WepInfo(wep)
    local class, vm = IsValidWep(wep, true)
    if class then return class, vm end
end

function U.UpdateViewModelPos(pos, ang, override)
    if vrmod.suppressViewModelUpdates and not override then
        U.UpdateViewModel()
        return
    end
    local ply = LocalPlayer()
    if not IsValid(ply) or not g_VR.active or not ply:Alive() then return end
    local currentvmi = g_VR.currentvmi
    if currentvmi then
        -- pos is the gun hand's final pose (GunWallPivot and hull error, in
        -- cl_vrmod). This used to swap in the hand sphere's raw HMD->hand
        -- trace HitPos instead: a point ON the wall along the head ray,
        -- nowhere near the grip, so any gun with a vmi entry jumped there
        -- whenever the hand neared a wall.
        g_VR.viewModelPos, g_VR.viewModelAng = LocalToWorld(currentvmi.offsetPos, currentvmi.offsetAng, pos, ang)
    else
        g_VR.viewModelPos, g_VR.viewModelAng = pos, ang
    end
    U.UpdateViewModel()
end

-- Muzzle attachment index, resolved by name and cached per model. Index 1 is
-- the muzzle on purpose-built VR weapons, but on HL2 viewmodels it is often the
-- shell-eject/casing attachment.
--
-- Cached per model rather than in a single slot: worldmodel mode alternates
-- between the weapon's w_ model and the viewmodel across a frame, and a
-- one-entry cache re-ran LookupAttachment on every switch.
local muzIdxCache = {}
local function MuzzleIndex(ent, mdl)
    mdl = mdl or ent:GetModel()
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
local rigidOn = cv_rigid:GetBool()
cvars.AddChangeCallback("vrmod_muzzle_rigid", function() rigidOn = cv_rigid:GetBool() end, "vrmod_muzzle_rigid")
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
local FrameNumber, WorldToLocal, AUnpack = FrameNumber, WorldToLocal, FindMetaTable("Angle").Unpack
-- |math.AngleDifference| <= SETTLE_ANG on every axis, inlined
local function Settled(a, b)
    local p1, y1, r1 = AUnpack(a)
    local p2, y2, r2 = AUnpack(b)
    local d = (p1 - p2 + 180) % 360 - 180
    if not (d <= SETTLE_ANG and d >= -SETTLE_ANG) then return false end
    d = (y1 - y2 + 180) % 360 - 180
    if not (d <= SETTLE_ANG and d >= -SETTLE_ANG) then return false end
    d = (r1 - r2 + 180) % 360 - 180
    return d <= SETTLE_ANG and d >= -SETTLE_ANG
end
local capMdl, capFrame, capN, capPos, capAng = nil, -1, 0, nil, nil
concommand.Add("vrmod_muzzle_recapture", function()
    muzLocal, capMdl, capN = {}, nil, 0
end, nil, "Forget the cached rigid muzzle offsets and measure them again")

-- Viewmodel attachments come back FOV-warped. C_BaseViewModel runs every
-- attachment through FormatViewModelAttachment, which squashes its POSITION
-- (not angle) toward the main view's centre line by
-- tan(fov/2) / tan(fovViewmodel/2), so that muzzle flashes line up with a gun
-- drawn at viewmodel FOV. We draw the gun at the eye FOV
-- (g_VR.view.viewmodelfov), so the warp is pure error: a fixed XYZ shift that
-- depends on the desktop camera, and the rigid capture bakes it in. Catse's
-- VRMod forced viewmodel_fov to match fov, making the factor 1; x64 blocks that
-- convar from Lua. SWEPs dodge it via the ViewModelFOV override in
-- sh_network, engine weapons (SMG, shotgun, AR2...) read the convar and don't.
--
-- Bone matrices are NOT warped, and an attachment is rigid on its parent bone
-- in every pose, so the offset is measured once per model on a plain
-- clientside copy (bind pose is fine here) and composed onto the live bone.
-- false = no usable bone, stay on GetAttachment.
local muzBone = {} -- [model] = { bone, localPos, localAng } | false
local function MuzzleBone(vm, mdl)
    local c = muzBone[mdl]
    if c ~= nil then return c end
    c = false
    local cm = ClientsideModel(mdl, RENDERGROUP_OTHER)
    if IsValid(cm) then
        cm:SetupBones()
        local att = cm:GetAttachment(MuzzleIndex(vm, mdl))
        local b = att and att.Bone
        local mtx = b and b >= 0 and cm:GetBoneMatrix(b)
        if mtx then c = { b, WorldToLocal(att.Pos, att.Ang, mtx:GetTranslation(), mtx:GetAngles()) } end
        cm:Remove()
    end
    muzBone[mdl] = c
    return c
end

-- Reposition the viewmodel and re-read its muzzle from g_VR.viewModelPos/Ang.
-- Shared by the early tracking pass, the left-hand path and the per-eye
-- refresh, so all three agree.
--
-- Scratch muzzle table. GetAttachment and LocalToWorld both hand back fresh
-- Vector/Angle objects every call, so muzzlefix rotating .Ang in place still
-- cannot accumulate across frames -- only the outer table is reused.
local _muz = {}
function U.RefreshViewModelMuzzle(vm)
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
    local rigid = rigidOn
    local mdl = vm:GetModel()
    local m = rigid and muzLocal[mdl]
    if m then
        _muz.Pos, _muz.Ang = LocalToWorld(m.Pos, m.Ang, pos, ang)
        g_VR.viewModelMuzzle = _muz
        return
    end
    -- Live path: build now so the bone read reflects the pose we just set
    -- rather than whatever it was cached at. This is also the sampler for the
    -- settle capture below, so an uncommitted model costs one bone build per
    -- frame -- exactly what the live path cost on its own.
    vm:SetupBones()
    local c = MuzzleBone(vm, mdl)
    local mtx = c and vm:GetBoneMatrix(c[1])
    local mp, ma
    if mtx then
        mp, ma = LocalToWorld(c[2], c[3], mtx:GetTranslation(), mtx:GetAngles())
    else
        local att = vm:GetAttachment(MuzzleIndex(vm, mdl))
        if not att then
            if rigid then muzLocal[mdl] = false end
            g_VR.viewModelMuzzle = nil
            return
        end
        mp, ma = att.Pos, att.Ang
    end

    _muz.Pos, _muz.Ang = mp, ma
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
    local lp, la = WorldToLocal(mp, ma, pos, ang)
    if capMdl ~= mdl then
        capMdl, capN = mdl, 1
    elseif lp:DistToSqr(capPos) <= SETTLE_DIST and Settled(la, capAng) then
        capN = capN + 1
        if capN >= SETTLE_HITS then muzLocal[mdl] = {Pos = lp, Ang = la} end
    else
        capN = 1
    end

    capPos, capAng = lp, la
end

-- muzzlefix wraps UpdateViewModel (callers go through U); Refresh is not wrapped
local RefreshMuzzle = U.RefreshViewModelMuzzle
function U.UpdateViewModel()
    RefreshMuzzle(g_VR.viewModel)
end

if CLIENT then
    -- Engine muzzle flashes on viewmodels are placed from the viewmodel's
    -- attachment, and C_BaseViewModel runs every attachment through
    -- FormatViewModelAttachment: its distance from the MAIN view's forward axis
    -- is scaled by tan(fov/2) / tan(fovviewmodel/2) (the wiki's GetAttachment
    -- example reproduces it from render.GetViewSetup()). Catse made that ratio 1
    -- by forcing viewmodel_fov; x64 blocks the convar, so the HL2 guns' flashes
    -- were pushed off the barrel, away from the view axis -- below the gun when
    -- held low. The laser and bullets don't care: they use the bone-built muzzle
    -- and EntityFireBullets.
    --
    -- Aiming the main view through the muzzle puts the muzzle ON that axis, so
    -- its distance, and the warp, is zero regardless of the fov ratio. Origin
    -- stays on the head so the audio listener is where Catse put it (its
    -- "3D audio fix"). The main view is never drawn in VR; only the listener,
    -- the attachment warp and global EyePos/EyeAngles outside a render see it.
    local _view = {}
    local function CalcVRView(_, _, _, fov)
        local hmd = g_VR.threePoints and g_VR.tracking.hmd
        if not hmd then return end
        local muz = g_VR.viewModelMuzzle
        _view.origin = hmd.pos
        _view.angles = muz and (muz.Pos - hmd.pos):Angle() or hmd.ang
        _view.fov = fov
        return _view
    end
    hook.Add("VRMod_Start", "vrmod_muzzle_view", function(ply)
        if ply == LocalPlayer() then hook.Add("CalcView", "vrutil_hook_calcview", CalcVRView) end
    end)
    hook.Add("VRMod_Exit", "vrmod_muzzle_view", function(ply)
        if ply == LocalPlayer() then hook.Remove("CalcView", "vrutil_hook_calcview") end
    end)
end