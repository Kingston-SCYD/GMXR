--[[
    cl_input.lua
    OpenXR Action Set & Binding Definitions
    Rewritten for Linux/DXVK/WiVRn compatibility
]]

if SERVER then return end

g_VR = g_VR or {}
vrmod = vrmod or {}
g_VR.input = g_VR.input or {}
g_VR.input.vector2_walkdirection = g_VR.input.vector2_walkdirection or { x = 0, y = 0 }
g_VR.input.vector2_smoothturn = g_VR.input.vector2_smoothturn or { x = 0, y = 0 }
g_VR.input.vector2_steer = g_VR.input.vector2_steer or { x = 0, y = 0 }
g_VR.input.vector1_primaryfire = g_VR.input.vector1_primaryfire or 0
g_VR.input.vector1_secondaryfire = g_VR.input.vector1_secondaryfire or 0
g_VR.input.vector1_left_squeeze = g_VR.input.vector1_left_squeeze or 0
g_VR.input.vector1_right_squeeze = g_VR.input.vector1_right_squeeze or 0
g_VR.input.vector1_forward = g_VR.input.vector1_forward or 0
g_VR.input.vector1_reverse = g_VR.input.vector1_reverse or 0

local ALL_ACTIONS = {
    -- Poses
    pose_lefthand              = { type = "pose",     localizedActionName = "Left Hand Pose" },
    pose_righthand             = { type = "pose",     localizedActionName = "Right Hand Pose" },
    pose_leftfoot              = { type = "pose",     localizedActionName = "Left Foot Pose" },
    pose_rightfoot             = { type = "pose",     localizedActionName = "Right Foot Pose" },
    pose_waist                 = { type = "pose",     localizedActionName = "Waist Pose" },

    -- Booleans
    boolean_primaryfire        = { type = "boolean",  localizedActionName = "Primary Fire" },
    boolean_secondaryfire      = { type = "boolean",  localizedActionName = "Secondary Fire" },
    boolean_left_pickup        = { type = "boolean",  localizedActionName = "Left Pickup" },
    boolean_right_pickup       = { type = "boolean",  localizedActionName = "Right Pickup" },
    boolean_jump               = { type = "boolean",  localizedActionName = "Jump" },
    boolean_crouch             = { type = "boolean",  localizedActionName = "Crouch" },
    boolean_spawnmenu          = { type = "boolean",  localizedActionName = "Spawn Menu" },
    boolean_use                = { type = "boolean",  localizedActionName = "Use" },
    boolean_reload             = { type = "boolean",  localizedActionName = "Reload" },
    boolean_undo               = { type = "boolean",  localizedActionName = "Undo" },
    boolean_chat               = { type = "boolean",  localizedActionName = "Chat" },
    boolean_changeweapon       = { type = "boolean",  localizedActionName = "Change Weapon" },
    boolean_teleport           = { type = "boolean",  localizedActionName = "Teleport" },
    boolean_sprint             = { type = "boolean",  localizedActionName = "Sprint" },
    boolean_flashlight         = { type = "boolean",  localizedActionName = "Flashlight" },
    boolean_menucontext        = { type = "boolean",  localizedActionName = "Context Menu" },
    boolean_noclip             = { type = "boolean",  localizedActionName = "Noclip" },
    boolean_turbo              = { type = "boolean",  localizedActionName = "Turbo" },
    boolean_handbrake          = { type = "boolean",  localizedActionName = "Handbrake" },
    boolean_exit               = { type = "boolean",  localizedActionName = "Exit Vehicle" },
    boolean_turret             = { type = "boolean",  localizedActionName = "Turret" },
    boolean_horn               = { type = "boolean",  localizedActionName = "Horn" },
    boolean_lights             = { type = "boolean",  localizedActionName = "Lights" },
    boolean_alt_turret         = { type = "boolean",  localizedActionName = "Alt Turret" },
    boolean_switch_weapon      = { type = "boolean",  localizedActionName = "Switch Weapon" },
    boolean_siren              = { type = "boolean",  localizedActionName = "Siren" },
    boolean_signal_left        = { type = "boolean",  localizedActionName = "Signal Left" },
    boolean_signal_right       = { type = "boolean",  localizedActionName = "Signal Right" },
    boolean_toggle_engine      = { type = "boolean",  localizedActionName = "Toggle Engine" },
    boolean_detach_trailer     = { type = "boolean",  localizedActionName = "Detach Trailer" },
    boolean_shift_up           = { type = "boolean",  localizedActionName = "Shift Up" },
    boolean_shift_down         = { type = "boolean",  localizedActionName = "Shift Down" },
    boolean_shift_neutral      = { type = "boolean",  localizedActionName = "Shift Neutral" },
    lweaponmenu                = { type = "boolean",  localizedActionName = "Left Weapon Menu" },
    dummy                      = { type = "boolean",  localizedActionName = "Dummy" },
    boolean_left_fire          = { type = "boolean",  localizedActionName = "Left Fire" },
    boolean_right_fire         = { type = "boolean",  localizedActionName = "Right Fire" },
    boolean_walk               = { type = "boolean",  localizedActionName = "Walk" },
    boolean_turnleft           = { type = "boolean",  localizedActionName = "Turn Left" },
    boolean_turnright          = { type = "boolean",  localizedActionName = "Turn Right" },
    boolean_left_thumb_touch   = { type = "boolean",  localizedActionName = "Left Thumb Touch" },
    boolean_right_thumb_touch  = { type = "boolean",  localizedActionName = "Right Thumb Touch" },

    -- Floats
    vector1_primaryfire        = { type = "float",    localizedActionName = "Primary Fire Analog" },
    vector1_secondaryfire      = { type = "float",    localizedActionName = "Secondary Fire Analog" },
    vector1_left_squeeze       = { type = "float",    localizedActionName = "Left Squeeze Axis" },
    vector1_right_squeeze      = { type = "float",    localizedActionName = "Right Squeeze Axis" },
    vector1_forward            = { type = "float",    localizedActionName = "Forward" },
    vector1_reverse            = { type = "float",    localizedActionName = "Reverse" },
    trigger_left_axis          = { type = "float",    localizedActionName = "Left Trigger Axis" },
    trigger_right_axis         = { type = "float",    localizedActionName = "Right Trigger Axis" },

    -- Vectors
    vector2_walkdirection      = { type = "vector2f", localizedActionName = "Walk Direction" },
    vector2_smoothturn         = { type = "vector2f", localizedActionName = "Smooth Turn" },
    vector2_steer              = { type = "vector2f", localizedActionName = "Steer" },
    analog_left                = { type = "vector2f", localizedActionName = "Left Analog Stick" },
    analog_right               = { type = "vector2f", localizedActionName = "Right Analog Stick" },

    -- Haptics (vibration = XR_ACTION_TYPE_VIBRATION_OUTPUT in the module)
    vibration_left             = { type = "vibration", localizedActionName = "Left Haptic" },
    vibration_right            = { type = "vibration", localizedActionName = "Right Haptic" },
}

-- Oculus Touch / Meta Quest controllers
local OCULUS_TOUCH = {
    profile = "/interaction_profiles/oculus/touch_controller",
    bindings = {
        pose_lefthand              = "/user/hand/left/input/grip/pose",
        pose_righthand             = "/user/hand/right/input/grip/pose",

        boolean_primaryfire        = "/user/hand/right/input/trigger/value",
        vector1_primaryfire        = "/user/hand/right/input/trigger",
        boolean_secondaryfire      = "/user/hand/left/input/trigger/value",
        vector1_secondaryfire      = "/user/hand/left/input/trigger",

        -- Vehicle throttle: right trigger = forward/accelerate, left trigger = reverse/brake
        vector1_forward            = "/user/hand/right/input/trigger",
        vector1_reverse            = "/user/hand/left/input/trigger",

        boolean_left_pickup        = "/user/hand/left/input/squeeze/value",
        boolean_right_pickup       = "/user/hand/right/input/squeeze/value",
        vector1_left_squeeze       = "/user/hand/left/input/squeeze/value",
        vector1_right_squeeze      = "/user/hand/right/input/squeeze/value",

        boolean_use                = "/user/hand/left/input/x/click",
        boolean_spawnmenu          = "/user/hand/left/input/y/click",
        lweaponmenu                = "/user/hand/left/input/y/touch",
        boolean_jump               = "/user/hand/right/input/a/click",
        boolean_crouch             = "/user/hand/right/input/b/click",

        vector2_walkdirection      = "/user/hand/left/input/thumbstick",
        vector2_smoothturn         = "/user/hand/right/input/thumbstick",
        boolean_sprint             = "/user/hand/left/input/thumbstick/click",
        boolean_changeweapon       = "/user/hand/right/input/thumbstick/click",
        boolean_left_thumb_touch   = "/user/hand/left/input/thumbstick/touch",
        boolean_right_thumb_touch  = "/user/hand/right/input/thumbstick/touch",

        vibration_left             = "/user/hand/left/output/haptic",
        vibration_right            = "/user/hand/right/output/haptic",
    },
}

-- Valve Index Controllers
local VALVE_INDEX = {
    profile = "/interaction_profiles/valve/index_controller",
    bindings = {
        pose_lefthand              = "/user/hand/left/input/grip/pose",
        pose_righthand             = "/user/hand/right/input/grip/pose",

        boolean_primaryfire        = "/user/hand/right/input/trigger/click",
        vector1_primaryfire        = "/user/hand/right/input/trigger/value",
        boolean_secondaryfire      = "/user/hand/left/input/trigger/click",
        vector1_secondaryfire      = "/user/hand/left/input/trigger/value",

        -- Vehicle throttle: right trigger = forward/accelerate, left trigger = reverse/brake
        vector1_forward            = "/user/hand/right/input/trigger/value",
        vector1_reverse            = "/user/hand/left/input/trigger/value",

        boolean_left_pickup        = "/user/hand/left/input/squeeze/force",
        boolean_right_pickup       = "/user/hand/right/input/squeeze/force",
        vector1_left_squeeze       = "/user/hand/left/input/squeeze/force",
        vector1_right_squeeze      = "/user/hand/right/input/squeeze/force",

        boolean_use                = "/user/hand/left/input/a/click",
        boolean_spawnmenu          = "/user/hand/left/input/b/click",
        boolean_jump               = "/user/hand/right/input/a/click",
        boolean_crouch             = "/user/hand/right/input/b/click",

        vector2_walkdirection      = "/user/hand/left/input/thumbstick",
        vector2_smoothturn         = "/user/hand/right/input/thumbstick",
        boolean_sprint             = "/user/hand/left/input/thumbstick/click",
        boolean_changeweapon       = "/user/hand/right/input/thumbstick/click",
        boolean_left_thumb_touch   = "/user/hand/left/input/thumbstick/touch",
        boolean_right_thumb_touch  = "/user/hand/right/input/thumbstick/touch",

        lweaponmenu                = "/user/hand/left/input/b/touch",

        vibration_left             = "/user/hand/left/output/haptic",
        vibration_right            = "/user/hand/right/output/haptic",
    },
}

-- HTCX Vive Tracker (FBT) — pose-only, no buttons
local VIVE_TRACKER_HTCX = {
    profile = "/interaction_profiles/htc/vive_tracker_htcx",
    bindings = {
        pose_waist     = "/user/vive_tracker_htcx/role/waist/input/grip/pose",
        pose_leftfoot  = "/user/vive_tracker_htcx/role/left_foot/input/grip/pose",
        pose_rightfoot = "/user/vive_tracker_htcx/role/right_foot/input/grip/pose",
    },
}

local ALL_PROFILES = { OCULUS_TOUCH, VALVE_INDEX }

function vrmod.SetupXRActions()
    VRMOD_CreateActionSet("base", "VRMod Controls", ALL_ACTIONS)
    -- Build profile list; append tracker profile when runtime has HTCX extension
    -- (append, not overwrite — controller bindings must survive alongside trackers)
    local profiles = { ALL_PROFILES[1], ALL_PROFILES[2] }
    if vrmod.HasTrackerSupport and vrmod.HasTrackerSupport() then
        profiles[#profiles + 1] = VIVE_TRACKER_HTCX
    end
    -- Merge user binding overrides from the XR bindings editor
    local allOverrides = vrmod.LoadAllBindingOverrides and vrmod.LoadAllBindingOverrides() or {}
    for _, prof in ipairs(profiles) do
        local bindings = prof.bindings
        local ov = allOverrides[prof.profile]
        if ov then
            bindings = {}
            for k, v in pairs(prof.bindings) do bindings[k] = ov[k] or v end
            for k, v in pairs(ov) do if not bindings[k] and v ~= "" then bindings[k] = v end end
        end
        VRMOD_SuggestBindings(prof.profile, bindings)
    end
    VRMOD_SetActiveActionSets("base")
    VRMOD_AttachActionSets()

    for actionName, def in pairs(ALL_ACTIONS) do
        if def.type == "boolean" then
            g_VR.input[actionName] = g_VR.input[actionName] or false
        elseif def.type == "float" then
            g_VR.input[actionName] = g_VR.input[actionName] or 0
        elseif def.type == "vector2f" then
            g_VR.input[actionName] = g_VR.input[actionName] or { x = 0, y = 0 }
        end
    end
    g_VR.input.skeleton_lefthand = { fingerCurls = {0, 0, 0, 0, 0} }
    g_VR.input.skeleton_righthand = { fingerCurls = {0, 0, 0, 0, 0} }
end

function vrmod.GetAllActions()
    return ALL_ACTIONS
end

function vrmod.GetDefaultProfiles()
    local out = {}
    for _, prof in ipairs(ALL_PROFILES) do
        out[prof.profile] = { bindings = table.Copy(prof.bindings) }
    end
    if vrmod.HasTrackerSupport and vrmod.HasTrackerSupport() then
        out[VIVE_TRACKER_HTCX.profile] = { bindings = table.Copy(VIVE_TRACKER_HTCX.bindings) }
    end
    return out
end