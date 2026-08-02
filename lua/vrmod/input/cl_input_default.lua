-- VRMod Input Handler (rewritten for Linux/WiVRn compatibility)
-- Maps XR action names to game behavior

if SERVER then return end

-- Clear old ProcessInput if present
hook.Add("VRMod_Start", "xr_clear_old_processinput", function()
    if g_VR.ProcessInput then g_VR.ProcessInput = nil end
end)

-- Custom action support (console command binds from action editor)
local function RunCustomActions(action, pressed)
    if not g_VR.CustomActions then return end
    for i = 1, #g_VR.CustomActions do
        local info = g_VR.CustomActions[i]
        if action == info[1] then
            local commands = string.Explode(";", info[pressed and 2 or 3], false)
            for j, txt in ipairs(commands) do
                local args = string.Explode(" ", string.Trim(txt), false)
                if args[1] and args[1] ~= "" then
                    RunConsoleCommand(args[1], unpack(args, 2))
                end
            end
        end
    end
end

hook.Add("VRMod_Input", "vrutil_hook_defaultinput", function(action, pressed)
    if hook.Call("VRMod_AllowDefaultAction", nil, action) == false then return end

    -- Primary Fire
    if action == "boolean_primaryfire" or action == "boolean_turret" then
        if not g_VR.menuFocus then
            LocalPlayer():ConCommand(pressed and "+attack" or "-attack")
        end
        return
    end

    -- Secondary Fire
    if action == "boolean_secondaryfire" then
        if not g_VR.menuFocus then
            LocalPlayer():ConCommand(pressed and "+attack2" or "-attack2")
        end
        return
    end

    -- Left Pickup
    if action == "boolean_left_pickup" then
        if not g_VR.menuFocus then
            vrmod.Pickup(true, not pressed)
        end
        return
    end

    -- Right Pickup
    if action == "boolean_right_pickup" then
        if not g_VR.menuFocus then
            vrmod.Pickup(false, not pressed)
        end
        return
    end

    -- Use (with physgun wheel control)
    if action == "boolean_use" then
        local wep = LocalPlayer():GetActiveWeapon()
        if IsValid(wep) and wep.ArcticVR then return end
        if pressed then
            LocalPlayer():ConCommand("+use")
            local wep = LocalPlayer():GetActiveWeapon()
            if IsValid(wep) and wep:GetClass() == "weapon_physgun" then
                hook.Add("CreateMove", "vrutil_hook_cmphysguncontrol", function(cmd)
                    local vec = g_VR.input.vector2_walkdirection or { x = 0, y = 0 }
                    if vec.y > 0.9 then
                        cmd:SetButtons(bit.bor(cmd:GetButtons(), IN_FORWARD))
                    elseif vec.y < -0.9 then
                        cmd:SetButtons(bit.bor(cmd:GetButtons(), IN_BACK))
                    else
                        cmd:SetMouseX(vec.x * 50)
                        cmd:SetMouseY(vec.y * -50)
                    end
                end)
            end
        else
            LocalPlayer():ConCommand("-use")
            hook.Remove("CreateMove", "vrutil_hook_cmphysguncontrol")
        end
        return
    end

    -- Spawn Menu
    if action == "boolean_spawnmenu" then
        if pressed then
            if g_VR.MenuOpen then g_VR.MenuOpen() elseif VRUtilOpenMenu then VRUtilOpenMenu() end
        else
            if g_VR.MenuClose then g_VR.MenuClose() elseif VRUtilMenuClose then VRUtilMenuClose() end
        end
        return
    end

    -- Weapon Menu (stick click)
    if action == "boolean_changeweapon" then
        if pressed then
            if VRUtilWeaponMenuOpen then VRUtilWeaponMenuOpen() end
        else
            if VRUtilWeaponMenuClose then VRUtilWeaponMenuClose() end
        end
        return
    end

    -- Jump
    if action == "boolean_jump" then
        LocalPlayer():ConCommand(pressed and "+jump" or "-jump")
        return
    end

    -- Crouch
    if action == "boolean_crouch" then
        LocalPlayer():ConCommand(pressed and "+duck" or "-duck")
        return
    end

    -- Sprint
    if action == "boolean_sprint" then
        LocalPlayer():ConCommand(pressed and "+speed" or "-speed")
        return
    end

    -- Reload (skip for ArcVR weapons — they handle it via VRInput)
    if action == "boolean_reload" then
        local wep = LocalPlayer():GetActiveWeapon()
        if not (IsValid(wep) and wep.ArcticVR) then
            LocalPlayer():ConCommand(pressed and "+reload" or "-reload")
        end
        return
    end

    -- Flashlight
    if action == "boolean_flashlight" then
        if pressed then LocalPlayer():ConCommand("impulse 100") end
        return
    end

    -- Undo
    if action == "boolean_undo" then
        if pressed then LocalPlayer():ConCommand("gmod_undo") end
        return
    end

    -- Teleport
    if action == "boolean_teleport" then
        if pressed then
            if vrmod.TeleportStart then vrmod.TeleportStart() end
        else
            if vrmod.TeleportEnd then vrmod.TeleportEnd() end
        end
        return
    end

    -- Noclip
    if action == "boolean_noclip" then
        if pressed then LocalPlayer():ConCommand("noclip") end
        return
    end

    -- Chat
    if action == "boolean_chat" then
        LocalPlayer():ConCommand(pressed and "+zoom" or "-zoom")
        return
    end

    -- Context Menu
    if action == "boolean_menucontext" then
        LocalPlayer():ConCommand(pressed and "+menu_context" or "-menu_context")
        return
    end

    -- Exit Vehicle
    if action == "boolean_exit" then
        LocalPlayer():ConCommand(pressed and "+use" or "-use")
        return
    end

    -- Horn
    if action == "boolean_horn" then
        LocalPlayer():ConCommand(pressed and "+use" or "-use")
        return
    end

    -- Weapon Menu (touch-based)
    if action == "lweaponmenu" then
        if pressed then
            if VRUtilWeaponMenuOpen then VRUtilWeaponMenuOpen() end
        else
            if VRUtilWeaponMenuClose then VRUtilWeaponMenuClose() end
        end
        return
    end

    -- Custom Actions
    RunCustomActions(action, pressed)
end)
