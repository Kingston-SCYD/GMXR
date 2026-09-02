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
    -- Tracker poses are generated from TRACKER_ROLES below.

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
-- Mirrors the saved SteamVR/OpenXR Touch action manifest. Path fragments are
-- hoisted so every shared physical input is written once -- five actions ride
-- the right trigger, three the left stick click -- which makes the overlaps
-- visible instead of hiding them in 30+ near-identical string literals.
local OCULUS_TOUCH
do
    local L, R   = "/user/hand/left/input/", "/user/hand/right/input/"
    local LT, RT = L .. "trigger/value", R .. "trigger/value"
    local LG, RG = L .. "squeeze/value", R .. "squeeze/value"
    local LJ, RJ = L .. "thumbstick", R .. "thumbstick"
    local LJC = LJ .. "/click"

    OCULUS_TOUCH = {
        profile = "/interaction_profiles/oculus/touch_controller",
        bindings = {
            pose_lefthand              = L .. "grip/pose",
            pose_righthand             = R .. "grip/pose",

            -- Right trigger: primary fire + vehicle throttle
            boolean_primaryfire        = RT,
            boolean_right_fire         = RT,
            vector1_primaryfire        = RT,
            vector1_forward            = RT,
            trigger_right_axis         = RT,

            -- Left trigger: secondary fire + vehicle reverse/brake
            boolean_secondaryfire      = LT,
            boolean_left_fire          = LT,
            vector1_secondaryfire      = LT,
            vector1_reverse            = LT,
            trigger_left_axis          = LT,

            -- Grips: pickup on both hands, +use on the right
            boolean_left_pickup        = LG,
            vector1_left_squeeze       = LG,
            boolean_right_pickup       = RG,
            vector1_right_squeeze      = RG,
            boolean_use                = RG,

            -- Face buttons
            boolean_spawnmenu          = L .. "x/click",
            boolean_flashlight         = L .. "y/click",
            boolean_jump               = R .. "a/click",
            boolean_reload             = R .. "b/click",

            -- Sticks
            vector2_walkdirection      = LJ,
            vector2_steer              = LJ,
            analog_left                = LJ,
            vector2_smoothturn         = RJ,
            boolean_walk               = LJC,
            boolean_sprint             = LJC,
            boolean_handbrake          = LJC,
            boolean_changeweapon       = RJ .. "/click",
            boolean_left_thumb_touch   = LJ .. "/touch",
            boolean_right_thumb_touch  = RJ .. "/touch",

            -- Haptics: absent from the manifest, required by the module
            vibration_left             = "/user/hand/left/output/haptic",
            vibration_right            = "/user/hand/right/output/haptic",
        },
    }
end

-- Valve Index (Knuckles) Controllers
-- Mirrors the saved SteamVR/OpenXR Knuckles action manifest. Same hoisting as
-- the Touch block: shared physical inputs are written once, so the overlaps
-- (five actions on the right trigger, two on each trackpad) stay visible.
local VALVE_INDEX
do
    local L, R     = "/user/hand/left/input/", "/user/hand/right/input/"
    local LT, RT   = L .. "trigger/value", R .. "trigger/value"
    local LTC, RTC = L .. "trigger/click", R .. "trigger/click"
    local LJ, RJ   = L .. "thumbstick", R .. "thumbstick"

    VALVE_INDEX = {
        profile = "/interaction_profiles/valve/index_controller",
        bindings = {
            pose_lefthand              = L .. "grip/pose",
            pose_righthand             = R .. "grip/pose",

            -- Right trigger: primary fire + vehicle throttle
            boolean_primaryfire        = RTC,
            boolean_right_fire         = RTC,
            vector1_primaryfire        = RT,
            vector1_forward            = RT,
            trigger_right_axis         = RT,

            -- Left trigger: secondary fire + vehicle reverse/brake
            boolean_secondaryfire      = LTC,
            boolean_left_fire          = LTC,
            vector1_secondaryfire      = LT,
            vector1_reverse            = LT,
            trigger_left_axis          = LT,

            -- Grips: force sensor clicks pickup, capacitive axis drives squeeze
            boolean_left_pickup        = L .. "squeeze/force",
            boolean_right_pickup       = R .. "squeeze/force",
            vector1_left_squeeze       = L .. "squeeze/value",
            vector1_right_squeeze      = R .. "squeeze/value",

            -- Face buttons
            boolean_use                = L .. "a/click",
            boolean_spawnmenu          = L .. "b/click",
            boolean_crouch             = R .. "a/click",
            boolean_jump               = R .. "b/click",

            -- Trackpads
            boolean_reload             = L .. "trackpad/click",
            lweaponmenu                = R .. "trackpad/click",

            -- Sticks
            vector2_walkdirection      = LJ,
            vector2_steer              = LJ,
            analog_left                = LJ,
            vector2_smoothturn         = RJ,
            analog_right               = RJ,
            boolean_sprint             = LJ .. "/click",
            boolean_flashlight         = RJ .. "/click",
            boolean_left_thumb_touch   = LJ .. "/touch",
            boolean_right_thumb_touch  = RJ .. "/touch",

            -- Haptics: absent from the manifest, required by the module
            vibration_left             = "/user/hand/left/output/haptic",
            vibration_right            = "/user/hand/right/output/haptic",
        },
    }
end

-- HTCX Vive Tracker — pose-only, no buttons.
--
-- Every role the extension defines, not just the three FBT ones. Actions cannot
-- be created after xrAttachSessionActionSets, so anything we might ever want a
-- tracker on has to be declared here up front; there is no discover-then-bind.
-- Unconnected roles simply never go active and never appear in the pose table.
--
-- The first three names are kept for compatibility with existing calibration
-- data and the sh_character_fbt.lua reads. /role/camera is the one to assign in
-- SteamVR for a physical camera rig.
--
-- Runtime notes, from SteamVR's OpenXR behaviour:
--  * xrGetCurrentInteractionProfile on a role path is unreliable -- it reports
--    the profile as bound even with the tracker switched off. The module keys
--    off xrGetActionStatePose().isActive instead, which is correct.
--  * Per-role bindings set in SteamVR's own binding UI override these and will
--    break them. Clear them there if a role refuses to go active.
--  * handheld_object was broken in SteamVR for longer than the others; treat it
--    as the least reliable of the set.
local TRACKER_ROLES = {
    { "pose_waist",      "waist",           "Waist"          },
    { "pose_leftfoot",   "left_foot",       "Left Foot"      },
    { "pose_rightfoot",  "right_foot",      "Right Foot"     },
    { "pose_chest",      "chest",           "Chest"          },
    { "pose_leftknee",   "left_knee",       "Left Knee"      },
    { "pose_rightknee",  "right_knee",      "Right Knee"     },
    { "pose_leftelbow",  "left_elbow",      "Left Elbow"     },
    { "pose_rightelbow", "right_elbow",     "Right Elbow"    },
    { "pose_leftshldr",  "left_shoulder",   "Left Shoulder"  },
    { "pose_rightshldr", "right_shoulder",  "Right Shoulder" },
    { "pose_leftwrist",  "left_wrist",      "Left Wrist"     },
    { "pose_rightwrist", "right_wrist",     "Right Wrist"    },
    { "pose_leftankle",  "left_ankle",      "Left Ankle"     },
    { "pose_rightankle", "right_ankle",     "Right Ankle"    },
    { "pose_camera",     "camera",          "Camera"         },
    { "pose_keyboard",   "keyboard",        "Keyboard"       },
    { "pose_handheld",   "handheld_object", "Handheld Object"},
}

local TRACKER_PATHS = {}
local VIVE_TRACKER_HTCX = {
    profile = "/interaction_profiles/htc/vive_tracker_htcx",
    bindings = {},
}

for i = 1, #TRACKER_ROLES do
    local r = TRACKER_ROLES[i]
    local path = "/user/vive_tracker_htcx/role/" .. r[2] .. "/input/grip/pose"
    ALL_ACTIONS[r[1]] = { type = "pose", localizedActionName = r[3] .. " Pose" }
    VIVE_TRACKER_HTCX.bindings[r[1]] = path
    TRACKER_PATHS[i] = path
end

--- Action name + role name pairs, for the tracker registry and the menu.
function vrmod.GetTrackerRoleActions() return TRACKER_ROLES end

--- Bindable paths, for the XR bindings editor's tracker tab.
function vrmod.GetTrackerRolePaths() return TRACKER_PATHS end

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
        local bindings, ov = prof.bindings, allOverrides[prof.profile]
        if ov then
            bindings = {}
            -- A binding cleared to "(unbound)" in the editor is saved as "",
            -- which is truthy in Lua: `ov[k] or v` let it win over the default
            -- instead of falling back to it. That matters more than one dead
            -- action, because an empty path fails xrSuggestInteractionProfileBindings
            -- for the ENTIRE profile -- every binding in the call dies with it.
            for k, v in pairs(prof.bindings) do
                local o = ov[k]
                bindings[k] = (o and o ~= "") and o or v
            end
            for k, v in pairs(ov) do
                if v ~= "" and not bindings[k] then bindings[k] = v end
            end
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