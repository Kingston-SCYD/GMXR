-- vrmod_arccw_vmfix.lua  (client)
-- ArcCW <-> VRMod viewmodel compatibility.
--
-- ArcCW's SWEP:PreDrawViewModel wraps the viewmodel in cam.Start3D (a custom
-- flat-screen VM FOV + squashed DepthRange) and SWEP:PostDrawViewModel closes
-- it. VRMod blocks the engine viewmodel pass (its PreDrawViewModel hook returns
-- blockViewModelDraw) and then redraws the VM itself in
-- PostDrawTranslucentRenderables via g_VR.viewModel:DrawModel(). That splits
-- ArcCW's Start3D/End3D across passes, so End3D fires on an empty cam stack ->
-- "[ArcCW] cam.End3D underflow" spam on every eye, every frame.
--
-- In VR the eye cam is already established by VRMod and ArcCW's VM FOV is
-- unwanted, so we swap ArcCW's two VM hooks for cam-free versions that still
-- draw attachments (DrawCustomModel), left-hand IK, and lasers in the existing
-- eye context. Originals are used unchanged outside VR.
--
-- Place in lua/autorun/client/ (or any client-loaded path).

if SERVER then return end

local active = false

local function install()
    local base = weapons.GetStored("arccw_base")
    if not base or base._vrmod_vmfix then return end
    base._vrmod_vmfix = true

    local origPre  = base.PreDrawViewModel
    local origPost = base.PostDrawViewModel

    -- Cam-free viewmodel draw: VRMod's eye cam is already active, so we skip
    -- ArcCW's cam.Start3D/DepthRange and draw its custom content directly.
    -- DoLaser(false, true): the 2nd arg (nocontext) makes it reuse the current
    -- cam instead of pushing its own.
    function base:PreDrawViewModel(vm, ...)
        if not active then return origPre(self, vm, ...) end
        if ArcCW.VM_OverDraw then return end
        vm = vm or (IsValid(self:GetOwner()) and self:GetOwner():GetViewModel())
        if not IsValid(vm) then return end
        self:DrawCustomModel(false)
        self:DoLHIK()
        if not ArcCW.Overdraw then self:DoLaser(false, true) end
    end

    -- Nothing to close (Pre pushed no cam). Just clear the overdraw latch so
    -- ArcCW's RT-scope state machine stays consistent.
    function base:PostDrawViewModel(...)
        if not active then return origPost(self, ...) end
        ArcCW.Overdraw = false
    end
end

hook.Add("InitPostEntity", "vrmod_arccw_vmfix_install", install)
install() -- in case ArcCW + this file are already loaded (e.g. autorefresh)

hook.Add("VRMod_Start", "vrmod_arccw_vmfix", function(ply)
    if ply == LocalPlayer() then active = true end
end)
hook.Add("VRMod_Exit", "vrmod_arccw_vmfix", function(ply)
    if ply == LocalPlayer() then active = false end
end)
