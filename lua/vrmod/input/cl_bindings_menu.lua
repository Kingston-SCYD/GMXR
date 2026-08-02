--[[
    cl_bindings_menu.lua
    In-game OpenXR Binding Editor for x64-community VRMod (XR module)

    Lets users remap actions to different controller inputs per profile.
    Saves overrides to DATA/vrmod_xr_bindings/<profile_key>.json
    Overrides are loaded and merged over defaults in vrmod.SetupXRActions().
    A VR restart is required for changes to take effect.
]]

if SERVER then return end

-- ─────────────────────────────────────────────────────────────────────────────
-- Available XR input paths per controller profile
-- These are the physical inputs each controller type actually exposes.
-- Grouped by hand for readability; the editor flattens them into a single list.
-- ─────────────────────────────────────────────────────────────────────────────

local CONTROLLER_INPUTS = {
    -- Oculus Touch / Meta Quest
    ["/interaction_profiles/oculus/touch_controller"] = {
        label = "Oculus Touch / Meta Quest",
        key   = "oculus-touch_controller",
        paths = {
            -- Left hand
            "/user/hand/left/input/grip/pose",
            "/user/hand/left/input/trigger",
            "/user/hand/left/input/trigger/value",
            "/user/hand/left/input/squeeze/value",
            "/user/hand/left/input/thumbstick",
            "/user/hand/left/input/thumbstick/click",
            "/user/hand/left/input/x/click",
            "/user/hand/left/input/y/click",
            "/user/hand/left/input/menu/click",
            "/user/hand/left/output/haptic",
            -- Right hand
            "/user/hand/right/input/grip/pose",
            "/user/hand/right/input/trigger",
            "/user/hand/right/input/trigger/value",
            "/user/hand/right/input/squeeze/value",
            "/user/hand/right/input/thumbstick",
            "/user/hand/right/input/thumbstick/click",
            "/user/hand/right/input/a/click",
            "/user/hand/right/input/b/click",
            "/user/hand/right/output/haptic",
        },
    },

    -- Valve Index (Knuckles)
    ["/interaction_profiles/valve/index_controller"] = {
        label = "Valve Index",
        key   = "valve-index_controller",
        paths = {
            "/user/hand/left/input/grip/pose",
            "/user/hand/left/input/trigger",
            "/user/hand/left/input/trigger/click",
            "/user/hand/left/input/trigger/value",
            "/user/hand/left/input/squeeze/value",
            "/user/hand/left/input/squeeze/force",
            "/user/hand/left/input/thumbstick",
            "/user/hand/left/input/thumbstick/click",
            "/user/hand/left/input/thumbstick/touch",
            "/user/hand/left/input/trackpad",
            "/user/hand/left/input/trackpad/force",
            "/user/hand/left/input/trackpad/touch",
            "/user/hand/left/input/a/click",
            "/user/hand/left/input/a/touch",
            "/user/hand/left/input/b/click",
            "/user/hand/left/input/b/touch",
            "/user/hand/left/output/haptic",

            "/user/hand/right/input/grip/pose",
            "/user/hand/right/input/trigger",
            "/user/hand/right/input/trigger/click",
            "/user/hand/right/input/trigger/value",
            "/user/hand/right/input/squeeze/value",
            "/user/hand/right/input/squeeze/force",
            "/user/hand/right/input/thumbstick",
            "/user/hand/right/input/thumbstick/click",
            "/user/hand/right/input/thumbstick/touch",
            "/user/hand/right/input/trackpad",
            "/user/hand/right/input/trackpad/force",
            "/user/hand/right/input/trackpad/touch",
            "/user/hand/right/input/a/click",
            "/user/hand/right/input/a/touch",
            "/user/hand/right/input/b/click",
            "/user/hand/right/input/b/touch",
            "/user/hand/right/output/haptic",
        },
    },

    -- HTC Vive wands
    ["/interaction_profiles/htc/vive_controller"] = {
        label = "HTC Vive",
        key   = "htc-vive_controller",
        paths = {
            "/user/hand/left/input/grip/pose",
            "/user/hand/left/input/trigger",
            "/user/hand/left/input/trigger/click",
            "/user/hand/left/input/trigger/value",
            "/user/hand/left/input/squeeze/click",
            "/user/hand/left/input/trackpad",
            "/user/hand/left/input/trackpad/click",
            "/user/hand/left/input/trackpad/touch",
            "/user/hand/left/input/menu/click",
            "/user/hand/left/output/haptic",

            "/user/hand/right/input/grip/pose",
            "/user/hand/right/input/trigger",
            "/user/hand/right/input/trigger/click",
            "/user/hand/right/input/trigger/value",
            "/user/hand/right/input/squeeze/click",
            "/user/hand/right/input/trackpad",
            "/user/hand/right/input/trackpad/click",
            "/user/hand/right/input/trackpad/touch",
            "/user/hand/right/input/menu/click",
            "/user/hand/right/output/haptic",
        },
    },

    -- WMR
    ["/interaction_profiles/microsoft/motion_controller"] = {
        label = "Windows MR",
        key   = "microsoft-motion_controller",
        paths = {
            "/user/hand/left/input/grip/pose",
            "/user/hand/left/input/trigger",
            "/user/hand/left/input/trigger/value",
            "/user/hand/left/input/squeeze/click",
            "/user/hand/left/input/thumbstick",
            "/user/hand/left/input/thumbstick/click",
            "/user/hand/left/input/trackpad",
            "/user/hand/left/input/trackpad/click",
            "/user/hand/left/input/trackpad/touch",
            "/user/hand/left/input/menu/click",
            "/user/hand/left/output/haptic",

            "/user/hand/right/input/grip/pose",
            "/user/hand/right/input/trigger",
            "/user/hand/right/input/trigger/value",
            "/user/hand/right/input/squeeze/click",
            "/user/hand/right/input/thumbstick",
            "/user/hand/right/input/thumbstick/click",
            "/user/hand/right/input/trackpad",
            "/user/hand/right/input/trackpad/click",
            "/user/hand/right/input/trackpad/touch",
            "/user/hand/right/input/menu/click",
            "/user/hand/right/output/haptic",
        },
    },

    -- Vive Tracker HTCX (FBT)
    ["/interaction_profiles/htc/vive_tracker_htcx"] = {
        label = "Vive Tracker (FBT)",
        key   = "htc-vive_tracker_htcx",
        paths = {
            "/user/vive_tracker_htcx/role/waist/input/grip/pose",
            "/user/vive_tracker_htcx/role/left_foot/input/grip/pose",
            "/user/vive_tracker_htcx/role/right_foot/input/grip/pose",
        },
    },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Persistence helpers
-- ─────────────────────────────────────────────────────────────────────────────

local SAVE_FOLDER = "vrmod_xr_bindings"

local function EnsureSaveFolder()
    if not file.Exists(SAVE_FOLDER, "DATA") then
        file.CreateDir(SAVE_FOLDER)
    end
end

--- Save user overrides for a specific controller profile.
-- @param profilePath  e.g. "/interaction_profiles/oculus/touch_controller"
-- @param overrides    table { actionName = xrPath, ... }
local function SaveProfileOverrides(profilePath, overrides)
    EnsureSaveFolder()
    local info = CONTROLLER_INPUTS[profilePath]
    if not info then return end
    local json = util.TableToJSON(overrides, true)
    file.Write(SAVE_FOLDER .. "/" .. info.key .. ".json", json)
end

--- Load user overrides for a specific controller profile.
-- Returns nil if no overrides exist.
local function LoadProfileOverrides(profilePath)
    local info = CONTROLLER_INPUTS[profilePath]
    if not info then return nil end
    local path = SAVE_FOLDER .. "/" .. info.key .. ".json"
    if not file.Exists(path, "DATA") then return nil end
    local raw = file.Read(path, "DATA")
    if not raw then return nil end
    return util.JSONToTable(raw)
end

--- Load overrides for ALL profiles. Returns { [profilePath] = { action = path, ... }, ... }
function vrmod.LoadAllBindingOverrides()
    local all = {}
    for profilePath, info in pairs(CONTROLLER_INPUTS) do
        local ov = LoadProfileOverrides(profilePath)
        if ov then
            all[profilePath] = ov
        end
    end
    return all
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Friendly name helpers
-- ─────────────────────────────────────────────────────────────────────────────

--- Turn an XR path into a short, human-readable label.
-- "/user/hand/right/input/trigger/click" → "Right Trigger Click"
local function PrettyPath(xrPath)
    if not xrPath or xrPath == "" then return "(unbound)" end
    local hand = ""
    if string.find(xrPath, "/left/") then hand = "L " end
    if string.find(xrPath, "/right/") then hand = "R " end

    -- Extract the meaningful tail after /input/ or /output/
    local tail = string.match(xrPath, "/input/(.+)$") or string.match(xrPath, "/output/(.+)$") or xrPath
    tail = string.gsub(tail, "/", " ")
    -- Capitalize first letter of each word
    tail = string.gsub(tail, "(%a)([%w_']*)", function(first, rest)
        return string.upper(first) .. rest
    end)

    return hand .. tail
end

-- ─────────────────────────────────────────────────────────────────────────────
-- The menu itself
-- ─────────────────────────────────────────────────────────────────────────────

local editorFrame = nil

function vrmod.OpenBindingsEditor()
    if IsValid(editorFrame) then
        editorFrame:MakePopup()
        return editorFrame
    end

    -- Get the default bindings from cl_input.lua's profile tables
    -- We access them through vrmod.GetDefaultProfiles() which cl_input.lua exposes
    local profiles = vrmod.GetDefaultProfiles and vrmod.GetDefaultProfiles() or {}
    local actions  = vrmod.GetAllActions and vrmod.GetAllActions() or {}

    if table.IsEmpty(profiles) then
        Derma_Message("No controller profiles available.\nMake sure cl_input.lua is loaded.", "Bindings Editor", "OK")
        return
    end

    editorFrame = vgui.Create("DFrame")
    editorFrame:SetSize(780, 560)
    editorFrame:SetTitle("XR Bindings Editor")
    editorFrame:MakePopup()
    editorFrame:Center()
    editorFrame:SetDeleteOnClose(true)
    editorFrame:SetSizable(true)
    editorFrame:SetMinWidth(600)
    editorFrame:SetMinHeight(400)
    editorFrame.OnClose = function() editorFrame = nil end

    -- Warning banner
    local banner = vgui.Create("DPanel", editorFrame)
    banner:Dock(TOP)
    banner:SetTall(28)
    banner:DockMargin(0, 0, 0, 4)
    banner.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(80, 60, 10, 220))
        draw.SimpleText("Changes require a VR restart to take effect.", "DermaDefaultBold", w / 2, h / 2, Color(255, 220, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- Bottom buttons
    local bottomBar = vgui.Create("DPanel", editorFrame)
    bottomBar:Dock(BOTTOM)
    bottomBar:SetTall(32)
    bottomBar:DockMargin(0, 4, 0, 0)
    bottomBar.Paint = nil

    local btnResetAll = vgui.Create("DButton", bottomBar)
    btnResetAll:SetText("Reset All to Defaults")
    btnResetAll:Dock(LEFT)
    btnResetAll:SetWide(160)
    btnResetAll:DockMargin(0, 0, 4, 0)
    btnResetAll.DoClick = function()
        Derma_Query(
            "Delete ALL custom bindings and restore defaults?\nThis will remove all saved overrides.",
            "Confirm Reset",
            "Reset All", function()
                for profilePath, info in pairs(CONTROLLER_INPUTS) do
                    local path = SAVE_FOLDER .. "/" .. info.key .. ".json"
                    if file.Exists(path, "DATA") then
                        file.Delete(path)
                    end
                end
                -- Reload the editor
                if IsValid(editorFrame) then editorFrame:Close() end
                timer.Simple(0.1, function() vrmod.OpenBindingsEditor() end)
            end,
            "Cancel", function() end
        )
    end

    local btnClose = vgui.Create("DButton", bottomBar)
    btnClose:SetText("Close")
    btnClose:Dock(RIGHT)
    btnClose:SetWide(80)
    btnClose.DoClick = function()
        if IsValid(editorFrame) then editorFrame:Close() end
    end

    -- Tabbed sheet for each controller profile
    local sheet = vgui.Create("DPropertySheet", editorFrame)
    sheet:Dock(FILL)
    sheet:SetPadding(4)

    -- Sort profiles for consistent tab order
    local sortedProfiles = {}
    for profilePath, profData in pairs(profiles) do
        local ci = CONTROLLER_INPUTS[profilePath]
        if ci then
            table.insert(sortedProfiles, {
                path     = profilePath,
                label    = ci.label,
                key      = ci.key,
                defaults = profData.bindings,
                paths    = ci.paths,
            })
        end
    end
    table.sort(sortedProfiles, function(a, b) return a.label < b.label end)

    for _, prof in ipairs(sortedProfiles) do
        local overrides = LoadProfileOverrides(prof.path) or {}

        -- Merge defaults + overrides to get current effective bindings
        local effective = {}
        -- Start with profile defaults
        for actionName, xrPath in pairs(prof.defaults) do
            effective[actionName] = overrides[actionName] or xrPath
        end
        -- Also include overrides for actions that have no default (user-added bindings)
        for actionName, xrPath in pairs(overrides) do
            if not effective[actionName] then
                effective[actionName] = xrPath
            end
        end

        local tabPanel = vgui.Create("DPanel", sheet)
        tabPanel.Paint = nil

        -- Per-profile reset button
        local profileBtnBar = vgui.Create("DPanel", tabPanel)
        profileBtnBar:Dock(BOTTOM)
        profileBtnBar:SetTall(28)
        profileBtnBar:DockMargin(0, 2, 0, 0)
        profileBtnBar.Paint = nil

        local btnResetProfile = vgui.Create("DButton", profileBtnBar)
        btnResetProfile:SetText("Reset " .. prof.label .. " to Defaults")
        btnResetProfile:Dock(LEFT)
        btnResetProfile:SetWide(240)
        btnResetProfile.DoClick = function()
            local path = SAVE_FOLDER .. "/" .. prof.key .. ".json"
            if file.Exists(path, "DATA") then
                file.Delete(path)
            end
            -- Refresh
            if IsValid(editorFrame) then editorFrame:Close() end
            timer.Simple(0.1, function() vrmod.OpenBindingsEditor() end)
        end

        -- Scroll panel for the action rows
        local scroll = vgui.Create("DScrollPanel", tabPanel)
        scroll:Dock(FILL)

        -- Build path choices for combo boxes: "(unbound)" + all valid paths
        local pathChoices = { { label = "(unbound)", value = "" } }
        for _, p in ipairs(prof.paths) do
            table.insert(pathChoices, { label = PrettyPath(p), value = p })
        end

        -- Build sorted action list from ALL actions, not just profile defaults.
        -- This ensures actions like boolean_flashlight appear even if they have
        -- no default binding for this controller profile.
        local sortedActions = {}
        for actionName, _ in pairs(actions) do
            -- Skip internal-only types the user shouldn't touch
            local def = actions[actionName]
            if def and def.type ~= "pose" and def.type ~= "vibration" then
                table.insert(sortedActions, actionName)
            end
        end
        -- Also add pose/vibration at the end for completeness
        for actionName, def in pairs(actions) do
            if def.type == "pose" or def.type == "vibration" then
                table.insert(sortedActions, actionName)
            end
        end
        table.sort(sortedActions, function(a, b)
            local function sortKey(name)
                if string.StartsWith(name, "pose_") then return "0_" .. name end
                if string.StartsWith(name, "boolean_") then return "1_" .. name end
                if string.StartsWith(name, "vector1_") or string.StartsWith(name, "vector2_") then return "2_" .. name end
                if string.StartsWith(name, "trigger_") then return "3_" .. name end
                if string.StartsWith(name, "analog_") then return "3_" .. name end
                if string.StartsWith(name, "vibration") then return "5_" .. name end
                return "4_" .. name
            end
            return sortKey(a) < sortKey(b)
        end)

        -- Section headers
        local lastPrefix = ""
        local ROW_HEIGHT = 28

        for _, actionName in ipairs(sortedActions) do
            local currentPath = effective[actionName]
            local defaultPath = prof.defaults[actionName]
            local actionDef = actions[actionName]
            local friendlyName = actionDef and actionDef.localizedActionName or actionName

            -- Section divider
            local prefix = string.match(actionName, "^(%a+)_") or ""
            if prefix ~= lastPrefix then
                lastPrefix = prefix
                local sectionNames = {
                    pose = "Poses",
                    boolean = "Buttons",
                    vector1 = "Analog (1D)",
                    vector2 = "Analog (2D)",
                    vibration = "Haptics",
                    trigger = "Legacy Triggers",
                    analog = "Legacy Sticks",
                    lweaponmenu = "Other",
                    dummy = "Other",
                }
                -- Try vector1/vector2 match
                local sectionKey = string.match(actionName, "^(vector%d)_") or prefix
                local sectionLabel = sectionNames[sectionKey] or (string.upper(prefix) .. " Actions")

                local divider = vgui.Create("DPanel", scroll)
                divider:Dock(TOP)
                divider:SetTall(22)
                divider:DockMargin(0, 4, 0, 2)
                divider.Paint = function(self, w, h)
                    surface.SetDrawColor(60, 60, 60, 200)
                    surface.DrawRect(0, 0, w, h)
                    draw.SimpleText(sectionLabel, "DermaDefaultBold", 6, h / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                end
            end

            -- Row: [Action Label] [Dropdown] [Default indicator]
            local row = vgui.Create("DPanel", scroll)
            row:Dock(TOP)
            row:SetTall(ROW_HEIGHT)
            row:DockMargin(0, 1, 0, 0)

            local isModified = overrides[actionName] ~= nil and overrides[actionName] ~= defaultPath
            local isUnbound = not currentPath or currentPath == ""
            row.Paint = function(self, w, h)
                local bgCol = isUnbound and Color(40, 20, 20, 120) or isModified and Color(50, 50, 30, 120) or Color(30, 30, 30, 80)
                surface.SetDrawColor(bgCol)
                surface.DrawRect(0, 0, w, h)
            end

            -- Action name label
            local lbl = vgui.Create("DLabel", row)
            lbl:SetText(friendlyName)
            lbl:SetWide(180)
            lbl:Dock(LEFT)
            lbl:DockMargin(6, 0, 4, 0)
            lbl:SetTextColor(Color(220, 220, 220))

            -- "Modified" / default indicator on the right
            local indicator = vgui.Create("DLabel", row)
            indicator:SetWide(80)
            indicator:Dock(RIGHT)
            indicator:DockMargin(4, 0, 6, 0)
            indicator:SetContentAlignment(6) -- right align
            if isUnbound then
                indicator:SetText("unbound")
                indicator:SetTextColor(Color(255, 100, 100))
            elseif isModified then
                indicator:SetText("modified")
                indicator:SetTextColor(Color(255, 200, 60))
            else
                indicator:SetText("default")
                indicator:SetTextColor(Color(120, 120, 120))
            end

            -- Dropdown for XR path
            local combo = vgui.Create("DComboBox", row)
            combo:Dock(FILL)
            combo:DockMargin(0, 2, 0, 2)
            combo:SetSortItems(false)

            for _, choice in ipairs(pathChoices) do
                combo:AddChoice(choice.label, choice.value, choice.value == currentPath)
            end

            -- If the current path isn't in our known list, add it anyway
            if currentPath and currentPath ~= "" then
                local found = false
                for _, choice in ipairs(pathChoices) do
                    if choice.value == currentPath then found = true break end
                end
                if not found then
                    combo:AddChoice(PrettyPath(currentPath) .. " (custom)", currentPath, true)
                end
            end

            combo.OnSelect = function(self, index, label, value)
                if value == "" then
                    -- Unbound: if there was a default, save empty string to explicitly unbind
                    -- If no default existed, remove the override
                    if defaultPath and defaultPath ~= "" then
                        overrides[actionName] = ""
                    else
                        overrides[actionName] = nil
                    end
                    isModified = false
                    isUnbound = true
                elseif value == defaultPath then
                    -- Same as default: remove override
                    overrides[actionName] = nil
                    isModified = false
                    isUnbound = false
                else
                    overrides[actionName] = value
                    isModified = true
                    isUnbound = false
                end

                if isUnbound then
                    indicator:SetText("unbound")
                    indicator:SetTextColor(Color(255, 100, 100))
                elseif isModified then
                    indicator:SetText("modified")
                    indicator:SetTextColor(Color(255, 200, 60))
                else
                    indicator:SetText("default")
                    indicator:SetTextColor(Color(120, 120, 120))
                end

                row.Paint = function(self, w, h)
                    local bgCol = isUnbound and Color(40, 20, 20, 120) or isModified and Color(50, 50, 30, 120) or Color(30, 30, 30, 80)
                    surface.SetDrawColor(bgCol)
                    surface.DrawRect(0, 0, w, h)
                end

                -- Auto-save
                SaveProfileOverrides(prof.path, overrides)
            end
        end

        sheet:AddSheet(prof.label, tabPanel, "icon16/joystick.png")
    end

    return editorFrame
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Console command
-- ─────────────────────────────────────────────────────────────────────────────
concommand.Add("vrmod_bindings", function()
    vrmod.OpenBindingsEditor()
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Hook into the VRMod settings menu to add a button
-- ─────────────────────────────────────────────────────────────────────────────
hook.Add("VRMod_Settings", "xr_bindings_editor_btn", function(form)
    if not form then return end

    local btn = form:Button("Edit XR Controller Bindings")
    if btn then
        btn.DoClick = function()
            vrmod.OpenBindingsEditor()
        end
    end
end)