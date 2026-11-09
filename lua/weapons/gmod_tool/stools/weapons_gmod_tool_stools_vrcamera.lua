-- lua/weapons/gmod_tool/stools/vrcamera.lua
--  Render tab clone of the stock Camera tool. Same key binding, same "shoot it
--  from where you're looking" placement, but the view is rendered through
--  VRMod's spectator pipeline so it actually works in VR.

TOOL.Category    = "Render"
TOOL.Name        = "VR Camera"
TOOL.Information = {
    { name = "left",   text = "Shoot a camera from where you are looking" },
    { name = "right",  text = "Apply these settings to the camera you are aiming at" },
    { name = "reload", text = "Remove the camera you are aiming at" },
}

TOOL.ClientConVar["key"]    = "-1"
TOOL.ClientConVar["toggle"] = "1"
TOOL.ClientConVar["locked"] = "1"
TOOL.ClientConVar["fov"]    = "90"
TOOL.ClientConVar["num"]    = "0"

local CAM = "vrmod_speccam"

function TOOL:Settings()
    return self:GetClientNumber("fov", 90), self:GetClientNumber("num", 0),
           self:GetClientNumber("key", -1), self:GetClientNumber("toggle", 1) ~= 0,
           self:GetClientNumber("locked", 1) ~= 0
end

function TOOL:LeftClick()
    if CLIENT then return true end
    local ply = self:GetOwner()
    -- Console rather than silent: a missing autorun file used to just do nothing.
    if not (VRSpecCam and VRSpecCam.Create) then
        ErrorNoHalt("[VR Camera] VRMod's utils/sh_speccam.lua is not loaded on the server\n")
        return false
    end
    local pos, ang = VRSpecCam.ViewOf(ply)
    return VRSpecCam.Create(ply, pos, ang, self:Settings()) ~= nil
end

function TOOL:RightClick(trace)
    local ent = trace.Entity
    if not IsValid(ent) or ent:GetClass() ~= CAM then return false end
    if SERVER and VRSpecCam then VRSpecCam.Apply(ent, self:GetOwner(), self:Settings()) end
    return true
end

function TOOL:Reload(trace)
    local ent = trace.Entity
    if not IsValid(ent) or ent:GetClass() ~= CAM then return false end
    if SERVER then ent:Remove() end
    return true
end

function TOOL.BuildCPanel(panel)
    panel:ClearControls()
    panel:SetName("VR Camera")
    panel:Help("Left-click shoots a camera from your current viewpoint (the headset's,\nin VR). Press its key to look through it. Works exactly like the stock\nCamera tool, but renders through VRMod so the view is correct in VR.")

    panel:AddControl("Numpad", { Label = "Camera Key", Command = "vrcamera_key" })

    panel:CheckBox("Static Camera", "vrcamera_locked")
    panel:ControlHelp("Never moves. Unchecked, it hangs in place until something hits it.")
    panel:CheckBox("Toggle", "vrcamera_toggle")
    panel:ControlHelp("Key switches the camera on and off instead of holding it.")

    panel:NumSlider("Camera FOV", "vrcamera_fov", 10, 150, 0)
    panel:NumSlider("Camera Number", "vrcamera_num", 0, 32, 0)
    panel:ControlHelp("0 = next free number. Used by vrmod_speccam_select <number>.")

    panel:Help("Viewing, switching and blend live in VRMod settings > Client >\nDesktop Rendering > VR Cameras. In VR they need Cheap Rendering off.")
end