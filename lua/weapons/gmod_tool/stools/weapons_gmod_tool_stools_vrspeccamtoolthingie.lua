-- lua/weapons/gmod_tool/stools/vrspeccamtoolthingie.lua
--  Client-side spectator camera placer. For the key-bound VR cameras that
--  replace the stock ones, use the VR Camera tool in the Render tab.

TOOL.Category    = "VRMod"
TOOL.Name        = "VR Spec Cam Placer"
TOOL.Information = {
    { name = "left",  text = "Place / Attach spectator camera" },
    { name = "right", text = "Detach / Reset to eye position"  },
}

function TOOL:LeftClick(trace)
    local ent = trace.Entity
    if IsValid(ent) and not ent:IsWorld() then
        if CLIENT then
            net.Start("vrmod_specfov_attach_ent")
            net.WriteEntity(ent)
            net.SendToServer()
        end
    else
        local p = trace.HitPos + trace.HitNormal * 6
        local a = (self:GetOwner():EyePos() - p):Angle()
        self:GetOwner():ConCommand(string.format(
            "vrmod_specfov_place_surface %f %f %f %f %f %f\n",
            p.x, p.y, p.z, a.p, a.y, a.r))
    end
    return true
end

function TOOL:RightClick()
    self:GetOwner():ConCommand("vrmod_specfov_detach\n")
    return true
end

function TOOL:DrawHUD() end

function TOOL.BuildCPanel(panel)
    panel:ClearControls()
    panel:SetName("VR Spec Cam Placer")

    panel:Help("Left-click a surface to place the spectator camera there.\nLeft-click a prop to attach the camera to it.\nRight-click to detach or reset to your current VR eye position.")

    local btnPlace = panel:Button("Place at Eye Position Now")
    btnPlace.DoClick = function() RunConsoleCommand("vrmod_specfov_place_static") end

    local btnDetach = panel:Button("Detach from Entity")
    btnDetach.DoClick = function() RunConsoleCommand("vrmod_specfov_detach") end

    panel:Help("Placement only. Rotation, offsets and every other spectator setting\nlive in VRMod settings > Client > Desktop Rendering (Static / Attached).\nThe spectator view needs Cheap Rendering off.")
end