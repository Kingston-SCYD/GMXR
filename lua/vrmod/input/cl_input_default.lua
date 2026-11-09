-- VRMod Input Handler (rewritten for Linux/WiVRn compatibility)
-- Maps XR action names to game behavior

if SERVER then return end

local hook_Call, IsValid = hook.Call, IsValid

-- Clear old ProcessInput if present
hook.Add("VRMod_Start", "xr_clear_old_processinput", function()
    if g_VR.ProcessInput then g_VR.ProcessInput = nil end
end)

-- Custom action support (console command binds from action editor).
-- Returns true if any custom action matched.
local function RunCustomActions(action, pressed)
    local list = g_VR.CustomActions
    if not list then return end
    local hit
    for i = 1, #list do
        local info = list[i]
        if info[1] == action then
            hit = true
            local cmds = string.Explode(";", info[pressed and 2 or 3], false)
            for j = 1, #cmds do
                local args = string.Explode(" ", string.Trim(cmds[j]), false)
                if args[1] ~= "" then RunConsoleCommand(unpack(args)) end
            end
        end
    end
    return hit
end
local function CustomRelease(_, action) RunCustomActions(action, false) end

-- Gates apply to the press only. A release runs exactly when its press did, so
-- menu focus, a weapon swap or AllowDefaultAction changing mid-hold can't
-- strand a +command. boolean_use / boolean_exit live in sh_gravity_and_physgun.
local function MenuFree() return not g_VR.menuFocus end
local function NotArc(ply) -- ArcVR handles reload via VRInput
    local wep = ply:GetActiveWeapon()
    return not (IsValid(wep) and wep.ArcticVR)
end
local function Con(cmd) return function(ply) ply:ConCommand(cmd) end end
local function Hold(cmd, gate) return { Con("+" .. cmd), Con("-" .. cmd), gate } end
local function WepMenuOpen() if VRUtilWeaponMenuOpen then VRUtilWeaponMenuOpen() end end
local function WepMenuClose() if VRUtilWeaponMenuClose then VRUtilWeaponMenuClose() end end

-- action -> { press, release (nil = press-only), press gate }
local ACTIONS = {
    boolean_primaryfire   = Hold("attack", MenuFree),
    boolean_secondaryfire = Hold("attack2", MenuFree),
    boolean_jump          = Hold("jump"),
    boolean_crouch        = Hold("duck"),
    boolean_sprint        = Hold("speed"),
    boolean_reload        = Hold("reload", NotArc),
    boolean_chat          = Hold("zoom"),
    boolean_menucontext   = Hold("menu_context"),
    boolean_horn          = Hold("use"),
    boolean_flashlight    = { Con("impulse 100") },
    boolean_undo          = { Con("gmod_undo") },
    boolean_noclip        = { Con("noclip") },
    boolean_changeweapon  = { WepMenuOpen, WepMenuClose },
    boolean_spawnmenu     = {
        function() if g_VR.MenuOpen then g_VR.MenuOpen() elseif VRUtilOpenMenu then VRUtilOpenMenu() end end,
        function() if g_VR.MenuClose then g_VR.MenuClose() elseif VRUtilMenuClose then VRUtilMenuClose() end end,
    },
    boolean_teleport      = {
        function() if vrmod.TeleportStart then vrmod.TeleportStart() end end,
        function() if vrmod.TeleportEnd then vrmod.TeleportEnd() end end,
    },
}
ACTIONS.boolean_turret = ACTIONS.boolean_primaryfire
ACTIONS.lweaponmenu = ACTIONS.boolean_changeweapon

local PICKUP = { boolean_left_pickup = true, boolean_right_pickup = false }
local held = {} -- action -> release fn, for presses that ran

hook.Add("VRMod_Input", "vrutil_hook_defaultinput", function(action, pressed)
    local left = PICKUP[action]
    if left ~= nil then
        -- Release stays gated: holster / grip-fix block it to store instead of drop
        if hook_Call("VRMod_AllowDefaultAction", nil, action) == false or g_VR.menuFocus then return end
        vrmod.Pickup(left, not pressed)
        return
    end
    if not pressed then
        local rel = held[action]
        if rel then held[action] = nil; rel(LocalPlayer(), action) end
        return
    end
    if hook_Call("VRMod_AllowDefaultAction", nil, action) == false then return end
    local a, ply = ACTIONS[action], LocalPlayer()
    if a then
        if a[3] and not a[3](ply) then return end
        a[1](ply)
        held[action] = a[2]
    elseif RunCustomActions(action, true) then
        held[action] = CustomRelease
    end
end)