-- vrmod_arc9_vmfix.lua  (client) -> lua/autorun/client/
-- ARC9 <-> VRMod viewmodel compatibility.
--
-- VRMod draws the VM itself (g_VR.viewModel:DrawModel() in
-- PostDrawTranslucentRenderables). Its PreDrawViewModel hook returns false
-- for that draw, and a non-nil hook return stops hook.Call before the
-- gamemode forwards to SWEP:PreDrawViewModel -- so ARC9's Pre, which opens
-- cam.Start3D (flat-screen VM FOV), never runs. PostDrawViewModel has no
-- such hook, so ARC9's Post still runs and its cam.End3D underflows: one
-- "[ARC9 Weapon Base] cam.End3D underflow" per eye, every frame.
--
-- In VR, Post is swapped for a cam-free version that keeps what belongs in the
-- eye view (translucent attachment pass, muzzle particles, holosights) and
-- drops the flat-screen-only work (the VM-FOV cams, ADS DoF blur).
-- Attachments, RHIK, lasers and flashlights are drawn by SWEP:ViewModelDrawn,
-- which VRMod's draw still calls. Outside VR the original runs unchanged.
--
-- The swap is a PostDrawViewModel hook that returns, which stops hook.Call
-- before the gamemode forwards to SWEP:PostDrawViewModel -- the same way
-- VRMod's Pre hook keeps ARC9's Pre out. Patching the stored arc9_base
-- missed every instance copied before the patch (a gun given before
-- InitPostEntity, or after ARC9 autorefreshes): their original Post kept
-- underflowing, and died before undoing ViewModelDrawn's squashed depth
-- range, which then broke the body (IK arms) VRMod draws right after.

if SERVER then return end

local active = false
local DEPTH = STUDIO_SSAODEPTHTEXTURE + STUDIO_SHADOWDEPTHTEXTURE

local function VRPost(self, flags)
    if not IsValid(self:GetVM()) then return end
    if bit.band(flags or STUDIO_RENDER, DEPTH) ~= 0 then return end

    self:DrawTranslucentPass()

    local pcfs, keep = self.MuzzPCFs, {}
    if pcfs then
        for i = 1, #pcfs do
            local pcf = pcfs[i]
            if IsValid(pcf) then
                pcf:Render()
                keep[#keep + 1] = pcf
            end
        end
    end
    self.MuzzPCFs = keep

    -- Reticles in the eye cam ARC9 would otherwise wrap in its VM FOV.
    local vmodels = self.VModel
    if vmodels then
        for i = 1, #vmodels do
            local model = vmodels[i]
            local att = model.atttbl
            if att and att.HoloSight then self:DoHolosight(model, att) end
        end
    end

    cam.IgnoreZ(false)
    render.SetBlend(1)
    render.DepthRange(0, 1) -- ViewModelDrawn leaves the VM's squashed range set
end

hook.Add("PostDrawViewModel", "vrmod_arc9_vmfix", function(vm, ply, wep, flags)
    if active and IsValid(wep) and wep.ARC9 then
        VRPost(wep, flags)
        return true
    end
end)

-- ARC9's TPIK (its PrePlayerDraw hook) re-solves a player's arms onto ARC9's
-- worldmodel gun every draw. On a VR player that overwrites VRMod's arm IK
-- with arms reaching for a gun that isn't drawn, and sets the player
-- translucent. NoTPIK is ARC9's per-weapon off switch, the first thing
-- ShouldTPIK checks: set it on ARC9 guns VR players hold (us and others),
-- clear it once they're out of VR. Never returns, so other hooks still run.
hook.Add("PrePlayerDraw", "vrmod_arc9_notpik", function(ply)
    local w = ply:GetActiveWeapon()
    if not (w:IsValid() and w.ARC9) then return end
    if vrmod.IsPlayerInVR(ply) then
        if not w.NoTPIK then
            w.NoTPIK, w.vrmodNoTPIK = true, true
            ply:SetRenderMode(RENDERMODE_NORMAL) -- undo TPIK's translucency crutch
        end
    elseif w.vrmodNoTPIK then
        w.NoTPIK, w.vrmodNoTPIK = false, nil
    end
end)

hook.Add("VRMod_Start", "vrmod_arc9_vmfix", function(ply)
    if ply == LocalPlayer() then active = true end
end)
hook.Add("VRMod_Exit", "vrmod_arc9_vmfix", function(ply)
    if ply == LocalPlayer() then active = false end
end)