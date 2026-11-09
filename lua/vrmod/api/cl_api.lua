-- The one GMXR module build this addon speaks to. Exact match: an older or
-- newer module both get sent to the workshop page for the matching set.
local REQUIRED_MODULE = 2
g_VR = g_VR or {}
vrmod = vrmod or {}
local convars = vrmod.GetConvars()
local EmptyHandsWeapons = {
    ["weapon_vrmod_empty"] = true,
    ["vr_spooderman"] = true,
}

if CLIENT then
    g_VR.net = g_VR.net or {}
    g_VR.viewModelInfo = g_VR.viewModelInfo or {}
    g_VR.locomotionOptions = g_VR.locomotionOptions or {}
    g_VR.menuItems = g_VR.menuItems or {}
-- Helper to get player VR data
    local function getPlayerVRData(ply)
        if not IsValid(ply) then ply = LocalPlayer() end
        if not IsValid(ply) or not ply:IsPlayer() then return nil end
        local sid = ply:SteamID()
        if not sid then return nil end
        return g_VR.net[sid]
    end

    -- smoothing helper
    local function SmoothValue(oldVal, newVal, factor)
        if not oldVal then return newVal end
        if not factor or factor <= 0 then return newVal end
        if oldVal.Lerp then
            -- Vector or Angle
            return LerpVector(factor, oldVal, newVal)
        else
            -- Fallback for numbers
            return Lerp(factor, oldVal, newVal)
        end
    end

    local moduleFile = system.IsLinux() and "lua/bin/gmcl_vrmod_linux64.dll" or "lua/bin/gmcl_vrmod_win64.dll"
    -- Returns error, code. code: "nomodule" | "loadfail" | "outdated" | "nohmd".
    -- probeHMD is opt-in: VRMOD_IsHMDPresent creates AND tears down a real XR
    -- instance, and that instance creation is what wakes the runtime -- so the
    -- first call reports false while the runtime is still coming up. Only probe
    -- when the answer is actually acted on, never just to label a menu.
    function vrmod.GetStartupError(probeHMD)
        local ver = g_VR.moduleVersion or 0
        if ver == 0 then
            if not file.Exists(moduleFile, "GAME") then return "Module not installed.\nPlease follow the workshop instructions to install the module.", "nomodule" end
            return "Failed to load module.\nModule file exists but could not be loaded. Check antivirus or permissions.", "loadfail"
        elseif ver ~= REQUIRED_MODULE then
            return "Module version mismatch.\nDownload the new modules from the workshop page.\n\nInstalled: v" .. ver .. "\nRequired: v" .. REQUIRED_MODULE, "outdated"
        end
        if probeHMD and VRMOD_IsHMDPresent and not VRMOD_IsHMDPresent() then return "VR headset not detected.", "nohmd" end
    end

    function vrmod.GetModuleVersion()
        return g_VR.moduleVersion, REQUIRED_MODULE, REQUIRED_MODULE
    end

    -- This addon's workshop id, found by which mounted addon carries the
    -- loader (an addon's title is a file search path). false: none, e.g. a
    -- legacy addons/ folder install. Resolved once.
    local wsid
    local function WorkshopID()
        if wsid == nil then
            wsid = false
            local list = engine.GetAddons()
            for i = 1, #list do
                local a = list[i]
                if a.mounted and a.wsid and file.Exists("lua/vrmod/loader.lua", a.title) then
                    wsid = a.wsid
                    break
                end
            end
        end
        return wsid
    end

    -- Opens the workshop page in the Steam overlay; false when there is none
    function vrmod.OpenWorkshopPage()
        local id = WorkshopID()
        if id then steamworks.ViewFile(id) end
        return id ~= false
    end

    local COL_WARN = Color(255, 190, 60)
    local function ModuleNotice(ver)
        local id = WorkshopID()
        local body = "The installed VR module is v" .. ver .. ", this version of VRMod needs v" .. REQUIRED_MODULE .. ".\nDownload the new modules from the workshop page."
        chat.AddText(COL_WARN, "[VRMod] ", color_white, "Module v" .. ver .. " detected, v" .. REQUIRED_MODULE .. " required. Download the new modules from the workshop page.")
        if id then
            Derma_Query(body, "VRMod: module version mismatch", "Open Workshop Page", vrmod.OpenWorkshopPage, "Later")
        else
            Derma_Message(body, "VRMod: module version mismatch", "OK")
        end
    end

    -- Only a module that loaded and reports another version: 0 is "not
    -- installed", which every non-VR player on a VRMod server has.
    hook.Add("InitPostEntity", "vrmod_modulecheck", function()
        local ver = g_VR.moduleVersion or 0
        if ver ~= 0 and ver ~= REQUIRED_MODULE then ModuleNotice(ver) end
    end)

    -- vrmod_module_check [version]: module status, and the notice as a
    -- mismatch shows it. A version argument stands in for the installed one.
    concommand.Add("vrmod_module_check", function(_, _, args)
        local real = g_VR.moduleVersion or 0
        local ver = tonumber(args[1]) or real
        local n = 0
        for k in pairs(_G) do
            if isstring(k) and k:sub(1, 6) == "VRMOD_" then n = n + 1 end
        end
        local id = WorkshopID()
        print("[VRMod Module] installed v" .. real .. (ver ~= real and (" (testing as v" .. ver .. ")") or "") .. " | required v" .. REQUIRED_MODULE)
        print("[VRMod Module] " .. moduleFile .. ": " .. (file.Exists(moduleFile, "GAME") and "present" or "MISSING") .. " | " .. n .. " module functions")
        print("[VRMod Module] workshop id: " .. (id or "none (not a mounted workshop addon)"))
        if g_VR.moduleLoadError then print("[VRMod Module] load error: " .. g_VR.moduleLoadError) end
        if ver == REQUIRED_MODULE then
            print("[VRMod Module] OK")
        else
            ModuleNotice(ver)
        end
    end)

    function vrmod.IsPlayerInVR(ply)
        return getPlayerVRData(ply) ~= nil
    end

    function vrmod.UsingEmptyHands(ply)
        local wep = ply and ply:GetActiveWeapon() or LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then return false end
        return EmptyHandsWeapons[wep:GetClass()] or false
    end

    function vrmod.GetHeldEntity(ply, hand)
        if not IsValid(ply) then return nil end
        if hand ~= "left" and hand ~= "right" then return nil end
        if hand == "left" then
            return g_VR.heldEntityLeft
        else
            return g_VR.heldEntityRight
        end
        return nil
    end

    function vrmod.GetHMDPos(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.hmd then return Vector() end
        return g_VR.tracking.hmd.pos or Vector()
    end

    function vrmod.GetHMDAng(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.hmd then return Angle() end
        return g_VR.tracking.hmd.ang or Angle()
    end

    function vrmod.GetHMDPose(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.hmd then return Vector(), Angle() end
        return g_VR.tracking.hmd.pos or Vector(), g_VR.tracking.hmd.ang or Angle()
    end

    function vrmod.GetHMDVelocity()
        return g_VR.threePoints and g_VR.tracking.hmd.vel or Vector()
    end

    function vrmod.GetHMDAngularVelocity()
        return g_VR.threePoints and g_VR.tracking.hmd.angvel or Angle()
    end

    function vrmod.GetHMDVelocities()
        if g_VR.threePoints then return g_VR.tracking.hmd.vel or Vector(), g_VR.tracking.hmd.angvel or Angle() end
        return Vector(), Angle()
    end

    function vrmod.GetLeftHandPos(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.pose_lefthand then return Vector() end
        return g_VR.tracking.pose_lefthand.pos or Vector()
    end

    function vrmod.GetLeftHandAng(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.pose_lefthand then return Angle() end
        return g_VR.tracking.pose_lefthand.ang or Angle()
    end

    function vrmod.GetLeftHandPose(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.pose_lefthand then return Vector(), Angle() end
        return g_VR.tracking.pose_lefthand.pos or Vector(), g_VR.tracking.pose_lefthand.ang or Angle()
    end

    function vrmod.GetLeftHandVelocity()
        return g_VR.threePoints and g_VR.tracking.pose_lefthand.vel or Vector()
    end

    function vrmod.GetLeftHandAngularVelocity()
        return g_VR.threePoints and g_VR.tracking.pose_lefthand.angvel or Angle()
    end

    function vrmod.GetLeftHandVelocityRelative()
        if not g_VR.threePoints or not g_VR.tracking or not g_VR.tracking.pose_lefthand or not g_VR.tracking.hmd then return Vector() end
        return (g_VR.tracking.pose_lefthand.vel or Vector()) - (g_VR.tracking.hmd.vel or Vector())
    end

    function vrmod.GetLeftHandVelocities()
        if g_VR.threePoints and g_VR.tracking and g_VR.tracking.pose_lefthand then return g_VR.tracking.pose_lefthand.vel or Vector(), g_VR.tracking.pose_lefthand.angvel or Angle(), vrmod.GetLeftHandVelocityRelative() end
        return Vector(), Angle(), Vector()
    end

    function vrmod.GetRightHandPos(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.pose_righthand then return Vector() end
        return g_VR.tracking.pose_righthand.pos or Vector()
    end

    function vrmod.GetRightHandAng(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.pose_righthand then return Angle() end
        return g_VR.tracking.pose_righthand.ang or Angle()
    end

    function vrmod.GetRightHandPose(ply)
        local t = getPlayerVRData(ply)
        if not t or not g_VR.tracking or not g_VR.tracking.pose_righthand then return Vector(), Angle() end
        return g_VR.tracking.pose_righthand.pos or Vector(), g_VR.tracking.pose_righthand.ang or Angle()
    end

    function vrmod.GetRightHandVelocity()
        return g_VR.threePoints and g_VR.tracking.pose_righthand.vel or Vector()
    end

    function vrmod.GetRightHandAngularVelocity()
        return g_VR.threePoints and g_VR.tracking.pose_righthand.angvel or Angle()
    end

    function vrmod.GetRightHandVelocityRelative()
        if not g_VR.threePoints or not g_VR.tracking or not g_VR.tracking.pose_righthand or not g_VR.tracking.hmd then return Vector() end
        return (g_VR.tracking.pose_righthand.vel or Vector()) - (g_VR.tracking.hmd.vel or Vector())
    end

    function vrmod.GetRightHandVelocities()
        if g_VR.threePoints and g_VR.tracking and g_VR.tracking.pose_righthand then return g_VR.tracking.pose_righthand.vel or Vector(), g_VR.tracking.pose_righthand.angvel or Angle(), vrmod.GetRightHandVelocityRelative() end
        return Vector(), Angle(), Vector()
    end

    -- ── FBT parts: waist + feet ──
    -- Resolved through the tracker registry (g_VR.fbtPose) so an OSC/SlimeVR
    -- rig drives these exactly like Vive pucks. g_VR.tracking.pose_waist and
    -- friends only exist while an HTCX role is bound, so reading them directly
    -- handed back a zero vector for every external tracker -- which is what
    -- left GetLeftFootVelocityRelative at 0 and killed the FBT kick. The legacy
    -- keys stay as the fallback for when sh_trackers.lua is absent.
    --
    -- The old g_VR.fbtActive guard is gone on purpose: it is a table keyed by
    -- steamid, so `not g_VR.fbtActive` was always false and the test never did
    -- anything. A resolved pose is the real availability signal.
    local FBT_SLOTS = {
        {"Waist", "pelvis", "pose_waist"},
        {"LeftFoot", "leftfoot", "pose_leftfoot"},
        {"RightFoot", "rightfoot", "pose_rightfoot"},
    }

    for i = 1, 3 do
        local name, slot, legacy = FBT_SLOTS[i][1], FBT_SLOTS[i][2], FBT_SLOTS[i][3]
        -- Two table indexes on the hit path.
        local function Pose()
            local f = g_VR.fbtPose
            local p = f and f[slot]
            if p then return p end
            local t = g_VR.tracking
            return t and t[legacy]
        end

        vrmod["Get" .. name .. "Pos"] = function(ply)
            local p = getPlayerVRData(ply) and Pose()
            return p and p.pos or Vector()
        end

        vrmod["Get" .. name .. "Ang"] = function(ply)
            local p = getPlayerVRData(ply) and Pose()
            return p and p.ang or Angle()
        end

        vrmod["Get" .. name .. "Pose"] = function(ply)
            local p = getPlayerVRData(ply) and Pose()
            if not p then return Vector(), Angle() end
            return p.pos or Vector(), p.ang or Angle()
        end

        vrmod["Get" .. name .. "Velocity"] = function()
            local p = Pose()
            return p and p.vel or Vector()
        end

        vrmod["Get" .. name .. "AngularVelocity"] = function()
            local p = Pose()
            return p and p.angvel or Angle()
        end

        local function Rel()
            local p = Pose()
            local h = g_VR.tracking and g_VR.tracking.hmd
            if not p or not h then return Vector() end
            return (p.vel or Vector()) - (h.vel or Vector())
        end

        vrmod["Get" .. name .. "VelocityRelative"] = Rel
        -- Combined form, feet only, matching the previous surface.
        if i > 1 then
            vrmod["Get" .. name .. "Velocities"] = function()
                local p = Pose()
                if not p then return Vector(), Angle(), Vector() end
                return p.vel or Vector(), p.angvel or Angle(), Rel()
            end
        end
    end

    function vrmod.SetLeftHandPose(pos, ang, smoothing)
        local ply = LocalPlayer()
        local netFrame = g_VR.net and g_VR.net[ply:SteamID()] and g_VR.net[ply:SteamID()].lerpedFrame
        if not netFrame then return end
        -- Apply smoothing
        netFrame.lefthandPos = SmoothValue(netFrame.lefthandPos, pos, smoothing or 0)
        netFrame.lefthandAng = SmoothValue(netFrame.lefthandAng, ang, smoothing or 0)
    end

    function vrmod.SetRightHandPose(pos, ang, smoothing)
        local ply = LocalPlayer()
        local netFrame = g_VR.net and g_VR.net[ply:SteamID()] and g_VR.net[ply:SteamID()].lerpedFrame
        if not netFrame then return end
        -- Apply smoothing
        netFrame.righthandPos = SmoothValue(netFrame.righthandPos, pos, smoothing or 0)
        netFrame.righthandAng = SmoothValue(netFrame.righthandAng, ang, smoothing or 0)
        -- Call utils update if available
        --if vrmod.utils then vrmod.utils.UpdateViewModelPos(netFrame.righthandPos, netFrame.righthandAng) end
    end

    local function HandleFingerAngles(mode, hand, state, tbl)
        local isGetter = mode == "get"
        local isDefault = mode == "get_default"
        local sourceTable = isDefault and (state == "open" and g_VR.defaultOpenHandAngles or g_VR.defaultClosedHandAngles) or state == "open" and g_VR.openHandAngles or g_VR.closedHandAngles
        local offset = hand == "right" and 15 or 0
        if isGetter or isDefault then
            local r = {}
            for i = 1, 15 do
                r[i] = sourceTable[i + offset]
            end
            return r
        else -- Setter
            local t = table.Copy(sourceTable)
            for i = 1, 15 do
                t[i + offset] = tbl[i]
            end

            if state == "open" then
                g_VR.openHandAngles = t
            else
                g_VR.closedHandAngles = t
            end
        end
    end

    -- Getter functions
    function vrmod.GetLeftHandOpenFingerAngles()
        return HandleFingerAngles("get", "left", "open")
    end

    function vrmod.GetLeftHandClosedFingerAngles()
        return HandleFingerAngles("get", "left", "closed")
    end

    function vrmod.GetRightHandOpenFingerAngles()
        return HandleFingerAngles("get", "right", "open")
    end

    function vrmod.GetRightHandClosedFingerAngles()
        return HandleFingerAngles("get", "right", "closed")
    end

    -- Setter functions
    function vrmod.SetLeftHandOpenFingerAngles(tbl)
        HandleFingerAngles("set", "left", "open", tbl)
    end

    function vrmod.SetLeftHandClosedFingerAngles(tbl)
        HandleFingerAngles("set", "left", "closed", tbl)
    end

    function vrmod.SetRightHandOpenFingerAngles(tbl)
        HandleFingerAngles("set", "right", "open", tbl)
    end

    function vrmod.SetRightHandClosedFingerAngles(tbl)
        HandleFingerAngles("set", "right", "closed", tbl)
    end

    -- Default getter functions
    function vrmod.GetDefaultLeftHandOpenFingerAngles()
        return HandleFingerAngles("get_default", "left", "open")
    end

    function vrmod.GetDefaultLeftHandClosedFingerAngles()
        return HandleFingerAngles("get_default", "left", "closed")
    end

    function vrmod.GetDefaultRightHandOpenFingerAngles()
        return HandleFingerAngles("get_default", "right", "open")
    end

    function vrmod.GetDefaultRightHandClosedFingerAngles()
        return HandleFingerAngles("get_default", "right", "closed")
    end

    local function GetFingerAnglesFromModel(modelName, sequenceNumber)
        sequenceNumber = sequenceNumber or 0
        local pm = convars.vrmod_floatinghands:GetBool() and "models/weapons/c_arms.mdl" or LocalPlayer():GetModel()
        local pmdl = ClientsideModel(pm)
        pmdl:SetupBones()
        local tmdl = ClientsideModel(modelName)
        tmdl:ResetSequence(sequenceNumber)
        tmdl:SetupBones()
        local tmp = {"0", "01", "02", "1", "11", "12", "2", "21", "22", "3", "31", "32", "4", "41", "42"}
        local r = {}
        for i = 1, 30 do
            r[i] = Angle()
            local fingerBoneName = "ValveBiped.Bip01_" .. (i < 16 and "L" or "R") .. "_Finger" .. tmp[i - (i < 16 and 0 or 15)]
            local pfinger = pmdl:LookupBone(fingerBoneName) or -1
            local tfinger = tmdl:LookupBone(fingerBoneName) or -1
            if pmdl:GetBoneMatrix(pfinger) then
                local _, pmoffset = WorldToLocal(Vector(0, 0, 0), pmdl:GetBoneMatrix(pfinger):GetAngles(), Vector(0, 0, 0), pmdl:GetBoneMatrix(pmdl:GetBoneParent(pfinger)):GetAngles())
                if tfinger ~= -1 then
                    local _, tmoffset = WorldToLocal(Vector(0, 0, 0), tmdl:GetBoneMatrix(tfinger):GetAngles(), Vector(0, 0, 0), tmdl:GetBoneMatrix(tmdl:GetBoneParent(tfinger)):GetAngles())
                    r[i] = tmoffset - pmoffset
                end
            end
        end

        pmdl:Remove()
        tmdl:Remove()
        return r
    end

    function vrmod.GetLeftHandFingerAnglesFromModel(modelName, sequenceNumber)
        local angles = GetFingerAnglesFromModel(modelName, sequenceNumber)
        local r = {}
        for i = 1, 15 do
            r[i] = angles[i]
        end
        return r
    end

    function vrmod.GetRightHandFingerAnglesFromModel(modelName, sequenceNumber)
        local angles = GetFingerAnglesFromModel(modelName, sequenceNumber)
        local r = {}
        for i = 1, 15 do
            r[i] = angles[15 + i]
        end
        return r
    end

    local function GetRelativeBonePoseFromModel(modelName, sequenceNumber, boneName, refBoneName)
        sequenceNumber = sequenceNumber or 0
        local ent = ClientsideModel(modelName)
        ent:ResetSequence(sequenceNumber)
        ent:SetupBones()
        local mtx, mtxRef = ent:GetBoneMatrix(ent:LookupBone(boneName)), ent:GetBoneMatrix(refBoneName and ent:LookupBone(refBoneName) or 0)
        local relativePos, relativeAng = WorldToLocal(mtx:GetTranslation(), mtx:GetAngles(), mtxRef:GetTranslation(), mtxRef:GetAngles())
        ent:Remove()
        return relativePos, relativeAng
    end

    function vrmod.GetLeftHandPoseFromModel(modelName, sequenceNumber, refBoneName)
        return GetRelativeBonePoseFromModel(modelName, sequenceNumber, "ValveBiped.Bip01_L_Hand", refBoneName)
    end

    function vrmod.GetRightHandPoseFromModel(modelName, sequenceNumber, refBoneName)
        return GetRelativeBonePoseFromModel(modelName, sequenceNumber, "ValveBiped.Bip01_R_Hand", refBoneName)
    end

    function vrmod.GetLerpedFingerAngles(fraction, from, to)
        local r = {}
        for i = 1, 15 do
            r[i] = LerpAngle(fraction, from[i], to[i])
        end
        return r
    end

    function vrmod.GetLerpedHandPose(fraction, fromPos, fromAng, toPos, toAng)
        return LerpVector(fraction, fromPos, toPos), LerpAngle(fraction, fromAng, toAng)
    end

    function vrmod.GetInput(name)
        return g_VR.input[name]
    end

    vrmod.MenuCreate = function() end
    vrmod.MenuClose = function() end
    vrmod.MenuExists = function() end
    vrmod.MenuRenderStart = function() end
    vrmod.MenuRenderEnd = function() end
    vrmod.MenuCursorPos = function() return g_VR.menuCursorX, g_VR.menuCursorY end
    vrmod.MenuFocused = function() return g_VR.menuFocus end
    timer.Simple(0, function()
        vrmod.MenuCreate = VRUtilMenuOpen
        vrmod.MenuClose = VRUtilMenuClose
        vrmod.MenuExists = VRUtilIsMenuOpen
        vrmod.MenuRenderStart = VRUtilMenuRenderStart
        vrmod.MenuRenderEnd = VRUtilMenuRenderEnd
    end)

    function vrmod.SetViewModelOffsetForWeaponClass(classname, pos, ang)
        local vmi = g_VR.viewModelInfo[classname] or {}
        vmi.offsetPos = pos
        vmi.offsetAng = ang
        vmi.autoComputed = nil -- user-set: persists to config
        g_VR.viewModelInfo[classname] = vmi
    end

    function vrmod.SetViewModelFixMuzzle(classname, bool)
        g_VR.viewModelInfo[classname] = g_VR.viewModelInfo[classname] or {}
        g_VR.viewModelInfo[classname].wrongMuzzleAng = bool
    end

    function vrmod.SetViewModelNoLaser(classname, bool)
        g_VR.viewModelInfo[classname] = g_VR.viewModelInfo[classname] or {}
        g_VR.viewModelInfo[classname].noLaser = bool
    end

    vrmod.AddCallbackedConvar("vrmod_locomotion", nil, "1")
    function vrmod.AddLocomotionOption(name, startfunc, stopfunc, buildcpanelfunc)
        g_VR.locomotionOptions[#g_VR.locomotionOptions + 1] = {
            name = name,
            startfunc = startfunc,
            stopfunc = stopfunc,
            buildcpanelfunc = buildcpanelfunc
        }
    end

    function vrmod.StartLocomotion()
        local selectedOption = g_VR.locomotionOptions[convars.vrmod_locomotion:GetInt()]
        if selectedOption then selectedOption.startfunc() end
    end

    function vrmod.StopLocomotion()
        local selectedOption = g_VR.locomotionOptions[convars.vrmod_locomotion:GetInt()]
        if selectedOption then selectedOption.stopfunc() end
    end

    function vrmod.GetOrigin()
        return g_VR.origin, g_VR.originAngle
    end

    function vrmod.GetOriginPos()
        return g_VR.origin
    end

    function vrmod.GetOriginAng()
        return g_VR.originAngle
    end

    function vrmod.SetOrigin(pos, ang)
        g_VR.origin = pos
        g_VR.originAngle = ang
    end

    function vrmod.SetOriginPos(pos)
        g_VR.origin = pos
    end

    function vrmod.SetOriginAng(ang)
        g_VR.originAngle = ang
    end

    -- Quick menu registry: one entry per name, never wiped. Registering again
    -- (every VRMod_Start, respawns included) updates the entry in place, so
    -- nothing can be lost to registration order or duplicated. slot/slotpos
    -- are a preference; cl_quickmenu resolves clashes and paging on open.
    -- forceSlot marks built-ins, which are placed before everything else.
    local menuOrder = 0
    -- Placement for items registered by other addons, which we can't edit.
    -- slotpos 4+ is page 2 (see cl_quickmenu).
    local PLACE = { ["ArcCW Customize"] = { 0, 4 } }
    function vrmod.AddInGameMenuItem(name, slot, slotpos, func, forceSlot, hint)
        local o = PLACE[name]
        if o then slot, slotpos = o[1], o[2] end
        local items = g_VR.menuItems
        for i = 1, #items do
            local it = items[i]
            if it.name == name then
                it.slot, it.slotPos, it.func, it.hint, it.forced = slot or 0, slotpos or 0, func, hint, forceSlot == true
                return
            end
        end
        menuOrder = menuOrder + 1
        items[#items + 1] = { name = name, slot = slot or 0, slotPos = slotpos or 0, func = func, hint = hint, forced = forceSlot == true, order = menuOrder }
    end

    -- func narrows the match; the third (permanent) arg is accepted for old
    -- callers but meaningless now that nothing restores removed items.
    function vrmod.RemoveInGameMenuItem(name, func)
        local items = g_VR.menuItems
        for i = #items, 1, -1 do
            if items[i].name == name and (not func or items[i].func == func) then table.remove(items, i) end
        end
    end

    function vrmod.GetLeftEyePos()
        return g_VR.eyePosLeft or Vector()
    end

    function vrmod.GetRightEyePos()
        return g_VR.eyePosRight or Vector()
    end

    function vrmod.GetEyePos()
        return g_VR.view and g_VR.view.origin or Vector()
    end

    function vrmod.GetTrackedDeviceNames()
        return g_VR.active and VRMOD_GetTrackedDeviceNames and VRMOD_GetTrackedDeviceNames() or {}
    end
end