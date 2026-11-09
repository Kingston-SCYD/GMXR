-- lua/vrmod/utils/sh_speccam.lua
-- Desktop spectator camera + key-bound VR Cameras (formerly the separate
-- vrspeccam addon). Loaded by the VRMod loader (sh_ = both realms). Settings
-- live in VRMod settings > Client > Desktop Rendering; "Cheap Rendering"
-- (vrmod_cheaprender) turns the whole spectator pass off and leaves the
-- desktop mirroring a headset eye.

-- ============================================================
--  VR CAMERA ENTITY
--  Registered here instead of lua/entities/ so there is no second file to
--  install and no load-order question: the tool, the render path and the
--  entity all come from this one file.
-- ============================================================

local CAMCLASS = "vrmod_speccam"

VRSpecCam = VRSpecCam or {}
local reg = VRSpecCam.reg or {}
VRSpecCam.reg = reg

local ENT = {
    Type        = "anim",
    Base        = "base_gmodentity",
    PrintName   = "VR Camera",
    Author      = "VRMod",
    Category    = "VRMod",
    Spawnable   = false,
    Editable    = true,
    RenderGroup = RENDERGROUP_OPAQUE,
}

function ENT:SetupDataTables()
    self:NetworkVar("Float", 0, "CamFOV", {
        KeyName = "camfov",
        Edit = { type = "Float", min = 10, max = 150, order = 1, title = "Camera FOV" },
    })
    self:NetworkVar("Int", 0, "CamIndex", {
        KeyName = "camindex",
        Edit = { type = "Int", min = 1, max = 32, order = 2, title = "Camera Number" },
    })
end

-- Registers itself on both realms, so switching cameras never walks the
-- entity list.
function ENT:Initialize()
    reg[self] = true
    if CLIENT then return end
    self:SetModel("models/dav0r/camera.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    -- Spawns at the player's eye, so it must never shove them.
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

function ENT:OnRemove()
    reg[self] = nil
    if CLIENT then return end
    if self.NumDown then numpad.Remove(self.NumDown) end
    if self.NumUp   then numpad.Remove(self.NumUp)   end
end

if SERVER then
    -- Every camera is pinned where it is placed, so nothing ever sags out of
    -- shot on its own. Static ones stay that way for good; the rest hang there
    -- until something hits them hard enough, and are ordinary props after that.
    -- The collision group stays COLLISION_GROUP_WEAPON either way: props and
    -- bullets hit it, the player it spawned on does not.
    function ENT:Unstick()
        if self.locked or not self.stuck then return end
        self.stuck = false
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            phys:EnableMotion(true)
            phys:Wake()
        end
    end

    -- Both hooks pass self first and Unstick guards itself, so they alias it.
    ENT.PhysicsCollide = ENT.Unstick
    ENT.OnTakeDamage   = ENT.Unstick
end

if CLIENT then
    -- Never draw the camera being looked through: in VR that is the spectator
    -- pass, on flatscreen the main view itself is the camera view.
    function ENT:Draw()
        if VRSpecCam.active == self
            and (g_VR == nil or not g_VR.active or g_VR.specCamRendering) then return end
        self:DrawModel()
    end
end

scripted_ents.Register(ENT, CAMCLASS)
-- Re-assert after the gamemode's entity pass, in case this file loaded first.
hook.Add("InitPostEntity", "VRSpecCam_Register", function()
    if not scripted_ents.GetStored(CAMCLASS) then scripted_ents.Register(ENT, CAMCLASS) end
end)

local function ByNumber(a, b) return a:GetCamIndex() < b:GetCamIndex() end

-- Live cameras ordered by camera number. Only walk of the registry, and only
-- on a switch; stale keys are swept here.
function VRSpecCam.Sorted()
    local out, n = {}, 0
    for e in pairs(reg) do
        if IsValid(e) then
            n = n + 1
            out[n] = e
        else
            reg[e] = nil
        end
    end
    if n > 1 then table.sort(out, ByNumber) end
    return out
end

-- ============================================================
--  SERVER
-- ============================================================

if SERVER then
    util.AddNetworkString("vrmod_specfov_attach_ent")
    util.AddNetworkString("vrmod_specfov_attach_reply")
    util.AddNetworkString("vrmod_speccam_set")

    net.Receive("vrmod_specfov_attach_ent", function(len, ply)
        local ent = net.ReadEntity()
        local ok  = IsValid(ent) and not ent:IsPlayer() and not ent:IsWorld()
        net.Start("vrmod_specfov_attach_reply")
        net.WriteEntity(ok and ent or NULL)
        net.Send(ply)
    end)

    -- --------------------------------------------------------
    --  Activation (server drives it, the client renders it)
    -- --------------------------------------------------------
    function VRSpecCam.Activate(ply, e)
        ply.vrSpecCam = IsValid(e) and e or nil
        net.Start("vrmod_speccam_set")
        net.WriteEntity(ply.vrSpecCam or NULL)
        net.Send(ply)
    end

    -- Manual switches (binds, tool, spawnmenu) report back so the toggle key
    -- stays in step with what the client is looking through.
    net.Receive("vrmod_speccam_set", function(_, ply)
        local e = net.ReadEntity()
        ply.vrSpecCam = (IsValid(e) and e:GetClass() == CAMCLASS) and e or nil
    end)

    numpad.Register("VRSpecCam_Down", function(ply, e, toggle)
        if not IsValid(e) then return false end
        VRSpecCam.Activate(ply, (toggle and ply.vrSpecCam == e) and NULL or e)
        return true
    end)

    numpad.Register("VRSpecCam_Up", function(ply, e)
        if not IsValid(e) then return false end
        VRSpecCam.Activate(ply, NULL)
        return true
    end)

    -- --------------------------------------------------------
    --  Placement
    -- --------------------------------------------------------

    -- Where the player is actually looking from: the HMD in VR, the eyes
    -- otherwise. Stock cameras are shot from the viewpoint, not the surface.
    function VRSpecCam.ViewOf(ply)
        if vrmod and vrmod.IsPlayerInVR and vrmod.IsPlayerInVR(ply) then
            local p = vrmod.GetHMDPos and vrmod.GetHMDPos(ply)
            local a = vrmod.GetHMDAng and vrmod.GetHMDAng(ply)
            if p and a then return p, a end
        end
        return ply:EyePos(), ply:EyeAngles()
    end

    function VRSpecCam.FreeIndex()
        local used = {}
        for e in pairs(reg) do
            if IsValid(e) then used[e:GetCamIndex()] = true end
        end
        local i = 1
        while used[i] do i = i + 1 end
        return i
    end

    -- Single configuration point for spawn, tool re-apply and dupe paste.
    -- Table fields mirror the settings so the duplicator can read them back.
    function VRSpecCam.Apply(e, ply, fov, idx, key, toggle, locked)
        fov = math.Clamp(tonumber(fov) or 90, 10, 150)
        idx = tonumber(idx) or 0
        if idx <= 0 then idx = e:GetCamIndex() end
        if idx <= 0 then idx = VRSpecCam.FreeIndex() end
        key = tonumber(key) or -1
        toggle, locked = toggle ~= false, locked ~= false

        e:SetCamFOV(fov)
        e:SetCamIndex(idx)
        e.fov, e.idx, e.key, e.toggle, e.locked = fov, idx, key, toggle, locked
        e.stuck = true

        if e.NumDown then numpad.Remove(e.NumDown) e.NumDown = nil end
        if e.NumUp   then numpad.Remove(e.NumUp)   e.NumUp   = nil end
        if IsValid(ply) and key >= 0 then
            e.NumDown = numpad.OnDown(ply, key, "VRSpecCam_Down", e, toggle)
            if not toggle then e.NumUp = numpad.OnUp(ply, key, "VRSpecCam_Up", e) end
        end

        local phys = e:GetPhysicsObject()
        if IsValid(phys) then phys:EnableMotion(false) end
        return e
    end

    -- Set while cameras are being swapped realm-to-realm: the player did not
    -- place these, so no undo entry and no chat line per camera.
    local converting = false

    function VRSpecCam.Create(ply, pos, ang, fov, idx, key, toggle, locked)
        local e = ents.Create(CAMCLASS)
        if not IsValid(e) then
            ErrorNoHalt("[VR Camera] ents.Create failed - " .. CAMCLASS .. " is not registered\n")
            return
        end
        e:SetPos(pos)
        e:SetAngles(ang)
        e:Spawn()
        e:Activate()
        VRSpecCam.Apply(e, ply, fov, idx, key, toggle, locked)

        if IsValid(ply) then
            e:SetCreator(ply)
            cleanup.Add(ply, "props", e)
            if not converting then
                undo.Create("VR Camera")
                undo.AddEntity(e)
                undo.SetPlayer(ply)
                undo.Finish()
            end
        end
        return e
    end

    -- Reads the player's own VR Camera tool convars, so a bind works from
    -- anywhere without the toolgun out.
    concommand.Add("vrmod_speccam_place", function(ply)
        if not IsValid(ply) then return end
        local pos, ang = VRSpecCam.ViewOf(ply)
        VRSpecCam.Create(ply, pos, ang,
            ply:GetInfoNum("vrcamera_fov", 90), ply:GetInfoNum("vrcamera_num", 0),
            ply:GetInfoNum("vrcamera_key", -1),
            ply:GetInfoNum("vrcamera_toggle", 1) ~= 0,
            ply:GetInfoNum("vrcamera_locked", 1) ~= 0)
    end, nil, "Place a VR camera at your viewpoint")

    duplicator.RegisterEntityClass(CAMCLASS, function(ply, pos, ang, fov, idx, key, toggle, locked)
        return VRSpecCam.Create(ply, pos, ang, fov, idx, key, toggle, locked)
    end, "Pos", "Angle", "fov", "idx", "key", "toggle", "locked")

    -- --------------------------------------------------------
    --  Stock camera <-> VR camera
    --  Placement is intercepted at the tool (CanTool fires with a known player
    --  and tool mode, so there is no classname timing or missing-creator
    --  guesswork), and existing cameras are swapped both ways as the player
    --  enters and leaves VR.
    -- --------------------------------------------------------
    local STOCK = "gmod_cameraprop"

    local cv_replace = CreateConVar("vrmod_speccam_replace", "1",
        { FCVAR_ARCHIVE, FCVAR_NOTIFY },
        "Replace the stock Camera tool: 0 off, 1 always, 2 VR players only")

    local function ShouldReplace(ply)
        local m = cv_replace:GetInt()
        if m <= 0 or not IsValid(ply) then return false end
        if m == 1 then return true end
        return vrmod ~= nil and vrmod.IsPlayerInVR ~= nil and vrmod.IsPlayerInVR(ply)
    end

    local function StockToVR(ent, ply)
        local cam = VRSpecCam.Create(ply, ent:GetPos(), ent:GetAngles(),
            ent.vrfov, 0, ent.vrkey, ent.vrtoggle, ent.vrlocked)
        ent:Remove()
        return cam
    end

    -- Rebuilt through the stock tool's own duplicator entry, so the key
    -- binding, toggle and lock are wired up by the code that owns them.
    -- Arguments are filled by name because that signature is the stock tool's
    -- business; a bare spawn is the fallback, and our camera is only removed
    -- once a replacement actually exists.
    local function VRToStock(cam, ply)
        local pos, ang = cam:GetPos(), cam:GetAngles()
        local fov, key = cam:GetCamFOV(), cam.key
        local toggle, locked = cam.toggle, cam.locked
        local new

        local cls = duplicator.FindEntityClass(STOCK)
        if cls and cls.Func and cls.Args then
            local data = {
                Pos = pos, Ang = ang, Angle = ang,
                key = key, Key = key,
                toggle = toggle, Toggle = toggle,
                locked = locked, Locked = locked, frozen = locked,
                fov = fov, FOV = fov,
                Vel = vector_origin, aVel = angle_zero,
            }
            data.Data = { Pos = pos, Angle = ang, key = key,
                toggle = toggle, locked = locked, fov = fov }
            local args, n = {}, #cls.Args
            for i = 1, n do args[i] = data[cls.Args[i]] end
            local ok, res = pcall(cls.Func, ply, unpack(args, 1, n))
            if ok then new = res end
        end

        if not IsValid(new) then
            new = ents.Create(STOCK)
            if not IsValid(new) then return end
            new:SetPos(pos)
            new:SetAngles(ang)
            new:Spawn()
            local sf = new.SetFOV
            if sf then sf(new, fov) end
        end

        new.vrfov, new.vrkey, new.vrtoggle, new.vrlocked = fov, key, toggle, locked
        new:SetCreator(ply)
        cam:Remove()
        return new
    end

    local function ConvertFor(ply, toVR)
        if not IsValid(ply) then return end
        local list = toVR and ents.FindByClass(STOCK) or VRSpecCam.Sorted()
        converting = true
        for i = 1, #list do
            local e = list[i]
            if IsValid(e) and e:GetCreator() == ply then
                if toVR then StockToVR(e, ply) else VRToStock(e, ply) end
            end
        end
        converting = false
    end

    -- Entering VR takes over the cameras this player already placed; leaving
    -- hands them back, so nothing is ever stranded in the wrong realm.
    hook.Add("VRMod_Start", "VRModSpecCam_Enter", function(ply)
        if cv_replace:GetInt() > 0 then ConvertFor(ply, true) end
    end)

    hook.Add("VRMod_Exit", "VRModSpecCam_Leave", function(ply)
        ConvertFor(ply, false)
    end)

    -- Tool-spawned entities do not reliably carry a creator, so remember who
    -- last swung the stock camera tool.
    local lastCamTool

    hook.Add("CanTool", "VRModSpecCam_Camera", function(ply, _, mode, _, button)
        if mode ~= "camera" then return end
        lastCamTool = ply
        if not ShouldReplace(ply) then return end
        -- button: 1 left, 2 right, 3 reload. Nil on older builds - treat as left.
        if button == nil or button == 1 then
            local pos, ang = VRSpecCam.ViewOf(ply)
            VRSpecCam.Create(ply, pos, ang,
                ply:GetInfoNum("vrcamera_fov", 90), 0,
                ply:GetInfoNum("camera_key", -1),
                ply:GetInfoNum("camera_toggle", 1) ~= 0,
                ply:GetInfoNum("camera_locked", 1) ~= 0)
        end
        return false
    end)

    -- Every stock camera that does get made is tagged with the settings it was
    -- built from and a known creator, so a later VR entry can convert it
    -- faithfully instead of guessing at the player's current tool settings.
    hook.Add("OnEntityCreated", "VRModSpecCam_Stock", function(ent)
        if ent:GetClass() ~= STOCK then return end
        timer.Simple(0, function()
            if not IsValid(ent) then return end
            local ply = ent:GetCreator()
            if not IsValid(ply) then
                ply = lastCamTool
                if IsValid(ply) then ent:SetCreator(ply) end
            end
            if not IsValid(ply) then return end

            if ent.vrkey == nil then
                local f = ent.GetFOV
                ent.vrfov    = f and f(ent) or 90
                ent.vrkey    = ply:GetInfoNum("camera_key", -1)
                ent.vrtoggle = ply:GetInfoNum("camera_toggle", 1) ~= 0
                ent.vrlocked = ply:GetInfoNum("camera_locked", 1) ~= 0
            end
            if ShouldReplace(ply) then StockToVR(ent, ply) end
        end)
    end)
    return
end

-- ============================================================
--  UPVALUES  (hot-path globals)
-- ============================================================

local RealTime, IsValid, EyeAngles, LocalPlayer = RealTime, IsValid, EyeAngles, LocalPlayer
local ScrW, ScrH, Angle, Vector, Entity = ScrW, ScrH, Angle, Vector, Entity
local AngleDifference, exp = math.AngleDifference, math.exp
local sin, cos, atan2, sqrt, random = math.sin, math.cos, math.atan2, math.sqrt, math.random
local band, bor, bnot, lshift = bit.band, bit.bor, bit.bnot, bit.lshift
local TraceLine = util.TraceLine


-- ============================================================
--  CONVARS
-- ============================================================

local cv_cheap        = CreateClientConVar("vrmod_cheaprender",           "1",    true, false, "Cheap Rendering: mirror a headset eye to the desktop instead of rendering a spectator view", 0, 1)
local cv_specfov      = CreateClientConVar("vrmod_specfov",               "90",   true, false, "Spectator FOV",                                0, 150)
local cv_smooth_ang   = CreateClientConVar("vrmod_specfov_smooth_ang",    "0.25", true, false, "Rotation smoothing (0-1)",                     0, 1)
local cv_hidehead     = CreateClientConVar("vrmod_specfov_hidehead",      "0",    true, false, "Hide player head in eye (first-person) mode",  0, 1)
-- modes: 0=eye, 1=static/attached, 2=thirdperson, 3=bodycam, 4=bone,
-- 5=chase (vehicles only, else eye), 6=random shots
-- (a live server camera overrides all of them)
local cv_cammode      = CreateClientConVar("vrmod_specfov_mode",          "3",    true, false, "Camera mode 0=eye 1=static 2=thirdperson 3=bodycam 4=bone 6=random shots", 0, 6)

-- Eye mode
local cv_eyepos       = CreateClientConVar("vrmod_specfov_eyepos",        "0",    true, false, "Eye pos 0=center 1=left 2=right",              0, 2)

-- Static / attached
local cv_static_p     = CreateClientConVar("vrmod_specfov_static_p",      "0",    true, false, "Static pitch",                               -89, 89)
local cv_static_y_cv  = CreateClientConVar("vrmod_specfov_static_y",      "0",    true, false, "Static yaw",                                -180, 180)
local cv_static_r     = CreateClientConVar("vrmod_specfov_static_r",      "0",    true, false, "Static roll",                               -180, 180)
local cv_att_x        = CreateClientConVar("vrmod_specfov_att_x",         "0",    true, false, "Attached fwd",                              -100, 100)
local cv_att_y        = CreateClientConVar("vrmod_specfov_att_y",         "0",    true, false, "Attached right",                            -100, 100)
local cv_att_z        = CreateClientConVar("vrmod_specfov_att_z",         "0",    true, false, "Attached up",                               -100, 100)

-- Third-person position offsets
local cv_tp_x         = CreateClientConVar("vrmod_specfov_tp_x",          "19",   true, false, "TP right",                                  -100, 100)
local cv_tp_y         = CreateClientConVar("vrmod_specfov_tp_y",          "-123.6", true, false, "TP back",                                   -300, 0)
local cv_tp_z         = CreateClientConVar("vrmod_specfov_tp_z",          "50",   true, false, "TP up",                                     -100, 100)
-- Third-person angle offsets (added on top of HMD-derived angle)
local cv_tp_ang_p     = CreateClientConVar("vrmod_specfov_tp_ang_p",      "0",    true, false, "TP angle pitch offset",                      -89, 89)
local cv_tp_ang_y     = CreateClientConVar("vrmod_specfov_tp_ang_y",      "-1.9", true, false, "TP angle yaw offset",                       -180, 180)
local cv_tp_ang_r     = CreateClientConVar("vrmod_specfov_tp_ang_r",      "0",    true, false, "TP angle roll offset",                      -180, 180)
local cv_tp_faceply   = CreateClientConVar("vrmod_specfov_tp_faceply",    "1",    true, false, "TP face player",                               0, 1)
local cv_tp_use_pitch = CreateClientConVar("vrmod_specfov_tp_usepitch",   "1",    true, false, "TP follow HMD pitch",                          0, 1)
local cv_tp_use_yaw   = CreateClientConVar("vrmod_specfov_tp_useyaw",     "1",    true, false, "TP follow HMD yaw",                            0, 1)
local cv_tp_use_roll  = CreateClientConVar("vrmod_specfov_tp_useroll",    "0",    true, false, "TP follow HMD roll",                           0, 1)

-- Body cam (mode 3) — offsets in chest bone local space
-- Spine1 bone axes: Right=bone right, Up=bone up (roughly out the chest forward), Forward=bone forward (roughly up the body)
local cv_bodycam_x    = CreateClientConVar("vrmod_specfov_bodycam_x",     "-12.7", true, false, "Body cam right/left",                        -30, 30)
local cv_bodycam_y    = CreateClientConVar("vrmod_specfov_bodycam_y",     "0.2",  true, false, "Body cam up/down",                           -30, 30)
local cv_bodycam_z    = CreateClientConVar("vrmod_specfov_bodycam_z",     "5.5",  true, false, "Body cam forward/back",                      -30, 30)

-- Bone attach (mode 4)
local cv_bone_name    = CreateClientConVar("vrmod_specfov_bone_name",     "ValveBiped.Bip01_R_Hand", true, false, "Bone name to attach to")
local cv_bone_rotmode = CreateClientConVar("vrmod_specfov_bone_rotmode",  "0",    true, false, "Bone rotation 0=bone 1=HMD",                    0, 1)
local cv_bone_flip    = CreateClientConVar("vrmod_specfov_bone_flip",     "1",    true, false, "Flip camera (selfie mode)",                       0, 1)
local cv_bone_x       = CreateClientConVar("vrmod_specfov_bone_x",       "6.3",  true, false, "Bone cam right/left",                         -100, 100)
local cv_bone_y       = CreateClientConVar("vrmod_specfov_bone_y",       "-2.8", true, false, "Bone cam up/down",                            -100, 100)
local cv_bone_z       = CreateClientConVar("vrmod_specfov_bone_z",       "1.8",  true, false, "Bone cam forward/back",                       -100, 100)
local cv_bone_ang_p   = CreateClientConVar("vrmod_specfov_bone_ang_p",   "-25.5", true, false, "Bone angle pitch offset",                      -89, 89)
local cv_bone_ang_y   = CreateClientConVar("vrmod_specfov_bone_ang_y",   "-7.7", true, false, "Bone angle yaw offset",                       -180, 180)
local cv_bone_ang_r   = CreateClientConVar("vrmod_specfov_bone_ang_r",   "180",  true, false, "Bone angle roll offset",                      -180, 180)

-- HUD overlay on desktop spectator view
local cv_showhud      = CreateClientConVar("vrmod_specfov_showhud",       "0",    true, false, "Force HUD visible on desktop spectator view", 0, 1)

-- Post-processing shaders on spectator view
local cv_shaders      = CreateClientConVar("vrmod_specfov_shaders",       "1",    true, false, "Run RenderScreenspaceEffects on spectator view", 0, 1)

-- Camera position sprite
local cv_showsprite   = CreateClientConVar("vrmod_specfov_showsprite",    "0",    true, false, "Draw a sprite at the spectator camera position", 0, 1)

-- Camera switching
local cv_blend        = CreateClientConVar("vrmod_speccam_blend",         "0",    true, false, "Seconds to fly between cameras on a switch (0 = instant cut)", 0, 3)

-- Cost. The pass runs after the headset frame is submitted, so SteamVR never
-- counts its GPU time -- yet the next frame's eyes queue behind it, and at high
-- refresh that alone drops headset frames. Rate > 1 or scale < 1 renders into
-- an offscreen target every Nth frame and re-shows it in between.
local cv_rate         = CreateClientConVar("vrmod_specfov_rate",          "2",    true, false, "Render the spectator view every Nth frame (1 = every frame)", 1, 4)
local cv_scale        = CreateClientConVar("vrmod_specfov_scale",         "1",    true, false, "Spectator resolution scale (applies on VR start)", 0.25, 1)

-- Vehicles: own camera mode, and the chase cam's distance/height in multiples
-- of the vehicle's bounding radius, so one setting fits a bike and a bus.
local cv_vehmode      = CreateClientConVar("vrmod_specfov_vehmode",       "-1",   true, false, "Camera mode in vehicles: -1 same as on foot, else as vrmod_specfov_mode (5 = chase)", -1, 6)
local cv_chase_dist   = CreateClientConVar("vrmod_specfov_chase_dist",    "2.2",  true, false, "Chase cam distance, in vehicle sizes", 1, 6)
local cv_chase_z      = CreateClientConVar("vrmod_specfov_chase_z",       "0.5",  true, false, "Chase cam height, in vehicle sizes", 0, 2)

-- Awesome camera: speed FOV, turn banking, brake dip, speed shake, crash jolt
local cv_fx           = CreateClientConVar("vrmod_specfov_awesome",       "0",    true, false, "Awesome camera 0=off 1=always 2=vehicles only", 0, 2)
local cv_fx_fov       = CreateClientConVar("vrmod_specfov_awesome_fov",   "30",   true, false, "Awesome camera: extra FOV at full speed", 0, 60)
local cv_fx_sway      = CreateClientConVar("vrmod_specfov_awesome_sway",  "1",    true, false, "Awesome camera: turn bank / brake dip strength", 0, 3)
local cv_fx_shake     = CreateClientConVar("vrmod_specfov_awesome_shake", "1",    true, false, "Awesome camera: speed shake / crash jolt strength", 0, 3)
local cv_fx_speed     = CreateClientConVar("vrmod_specfov_awesome_speed", "1500", true, false, "Awesome camera: vehicle speed for the full effect, units/s", 100, 5000)
local cv_fx_speed_ft  = CreateClientConVar("vrmod_specfov_awesome_speed_foot", "400", true, false, "Awesome camera: on-foot speed for the full effect, units/s", 50, 2000)

-- Random Shots: shot length range, seconds
local cv_shot_min     = CreateClientConVar("vrmod_specfov_shot_min",      "10",   true, false, "Random Shots: shortest shot, seconds", 3, 60)
local cv_shot_max     = CreateClientConVar("vrmod_specfov_shot_max",      "20",   true, false, "Random Shots: longest shot, seconds", 3, 60)

-- Camera rotation: random mode on a timer, from a pool of modes (bit n = mode n)
local cv_rot          = CreateClientConVar("vrmod_specfov_rotate",        "0",    true, false, "Camera rotation: switch to a random camera mode on a timer", 0, 1)
local cv_rot_time     = CreateClientConVar("vrmod_specfov_rotate_time",   "30",   true, false, "Camera rotation: seconds per camera", 5, 300)
local cv_rot_check    = CreateClientConVar("vrmod_specfov_rotate_checklist", "1", true, false, "Camera rotation: no repeats until every pooled camera has had a turn", 0, 1)
local cv_rot_pool     = CreateClientConVar("vrmod_specfov_rotate_pool",   "125",  true, false, "Camera rotation pool bitmask: 1 eye 2 static 4 thirdperson 8 bodycam 16 bone 32 chase 64 random shots", 0, 127)


-- ============================================================
--  RUNTIME STATE
-- ============================================================

local isRendering   = false
local smoothAngles  = nil
local lastFrameTime = nil
local staticCamPos  = nil
local staticCamSet  = false
local attachedEnt   = nil
local indicatorPos  = nil
local indicatorAng  = nil
local spriteMat     = Material("sprites/light_glow02_add")
local spriteColor   = Color(100, 200, 255, 200)
local spriteDirColor = Color(255, 60, 60, 200)
-- Offscreen target: size is fixed at creation, so scale is latched once per
-- session (specScale nil = not yet read) and the target made on first use.
-- fbW/fbH: the engine frame-buffer RTs' size when it isn't the desktop's.
local specRT, specMat, specScale, fbW, fbH
local rtW, rtH, specSkip, useRT = 0, 0, 0, false


-- ============================================================
--  SMOOTHING
-- ============================================================

local smoothScratch = Angle()

-- One shared scratch angle: smoothAngles aliases it, which is safe because all
-- three components are evaluated before any of them is written back.
local function Smooth(raw, dt)
    local s = smoothAngles
    if s and dt > 0 then
        local sm = cv_smooth_ang:GetFloat()
        local f  = sm <= 0 and 1 or 1 - exp(-0.693 / (sm * 0.5) * dt)
        smoothScratch:SetUnpacked(
            s.p + AngleDifference(raw.p, s.p) * f,
            s.y + AngleDifference(raw.y, s.y) * f,
            s.r + AngleDifference(raw.r, s.r) * f)
        raw = smoothScratch
    end
    smoothAngles = raw
    return raw
end

-- ============================================================
--  CHEST BONE  (Spine1 = chest, one above Spine)
-- ============================================================

local chestBoneIdx = -1
local lastPlyModel = nil

local function GetChestBoneMatrix(ply)
    if not IsValid(ply) then return nil end
    local model = ply:GetModel()
    if model ~= lastPlyModel then
        chestBoneIdx = ply:LookupBone("ValveBiped.Bip01_Spine1") or -1
        lastPlyModel = model
    end
    if chestBoneIdx < 0 then return nil end
    return ply:GetBoneMatrix(chestBoneIdx)
end

-- ============================================================
--  BONE ATTACH CACHE
-- ============================================================

local boneCacheName  = ""
local boneCacheModel = nil
local boneCacheIdx   = -1

local function GetAttachBoneMatrix(ply)
    if not IsValid(ply) then return nil end
    local name  = cv_bone_name:GetString()
    if name == "" then return nil end
    local model = ply:GetModel()
    if name ~= boneCacheName or model ~= boneCacheModel then
        boneCacheIdx   = ply:LookupBone(name) or -1
        boneCacheName  = name
        boneCacheModel = model
    end
    if boneCacheIdx < 0 then return nil end
    return ply:GetBoneMatrix(boneCacheIdx)
end

-- ============================================================
--  EYE POSITION
-- ============================================================

local function GetEyePosition()
    if not g_VR or not g_VR.view then return EyePos() end
    local m = cv_eyepos:GetInt()
    if m == 1 then return g_VR.eyePosLeft  or g_VR.view.origin or EyePos() end
    if m == 2 then return g_VR.eyePosRight or g_VR.view.origin or EyePos() end
    if g_VR.eyePosLeft and g_VR.eyePosRight then
        return (g_VR.eyePosLeft + g_VR.eyePosRight) * 0.5
    end
    return g_VR.view.origin or EyePos()
end

-- ============================================================
--  STATIC CAM HELPERS
-- ============================================================

local function SyncStaticAngleConvars(ang)
    RunConsoleCommand("vrmod_specfov_static_p", tostring(math.Round(ang.p, 2)))
    RunConsoleCommand("vrmod_specfov_static_y", tostring(math.Round(ang.y, 2)))
    RunConsoleCommand("vrmod_specfov_static_r", tostring(math.Round(ang.r, 2)))
end

local function GetStaticManualAngle()
    return Angle(cv_static_p:GetFloat(), cv_static_y_cv:GetFloat(), cv_static_r:GetFloat())
end

local function PlaceStaticCam()
    if not g_VR or not g_VR.active or not g_VR.view then return end
    attachedEnt  = nil
    staticCamPos = GetEyePosition()
    staticCamSet = true
    local manual = GetStaticManualAngle()
    if manual == Angle(0,0,0) then
        SyncStaticAngleConvars(g_VR.view.angles or EyeAngles())
    end
end

concommand.Add("vrmod_specfov_place_static", PlaceStaticCam,
    nil, "Place static cam at current VR eye position")

concommand.Add("vrmod_specfov_detach", function()
    attachedEnt  = nil
    staticCamSet = false
end, nil, "Detach spectator cam from entity")

concommand.Add("vrmod_specfov_place_surface", function(_, _, args)
    if #args < 6 then return end
    attachedEnt  = nil
    staticCamPos = Vector(tonumber(args[1]), tonumber(args[2]), tonumber(args[3]))
    staticCamSet = true
    SyncStaticAngleConvars(Angle(tonumber(args[4]), tonumber(args[5]), tonumber(args[6])))
    RunConsoleCommand("vrmod_specfov_mode", "1")
end, nil, "Internal: place static cam at surface pos")

-- ============================================================
--  ENTITY ATTACHMENT
-- ============================================================

net.Receive("vrmod_specfov_attach_reply", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) then return end
    attachedEnt  = ent
    staticCamSet = false
    RunConsoleCommand("vrmod_specfov_mode", "1")
end)

-- ============================================================
--  STATIC ANGLE RESOLUTION
-- ============================================================

local function ResolveStaticAngles(baseAng)
    local delta = GetStaticManualAngle()
    return baseAng and (baseAng + delta) or delta
end

-- ============================================================
--  THIRD-PERSON CAMERA
-- ============================================================

local function GetThirdPersonOriginAndAngle()
    if not g_VR or not g_VR.tracking or not g_VR.tracking.hmd then return nil, nil end
    local hmdPos = g_VR.tracking.hmd.pos
    local hmdAng = g_VR.tracking.hmd.ang or g_VR.view.angles or EyeAngles()

    -- Build base angle from selected HMD axes
    local baseAng = Angle(
        cv_tp_use_pitch:GetBool() and hmdAng.p or 0,
        cv_tp_use_yaw:GetBool()   and hmdAng.y or 0,
        cv_tp_use_roll:GetBool()  and hmdAng.r or 0
    )
    -- Add user angle offsets
    local camAng = baseAng + Angle(
        cv_tp_ang_p:GetFloat(),
        cv_tp_ang_y:GetFloat(),
        cv_tp_ang_r:GetFloat()
    )

    local flat     = Angle(0, hmdAng.y, 0)
    local idealPos = hmdPos
                   + flat:Right()   * cv_tp_x:GetFloat()
                   + flat:Forward() * cv_tp_y:GetFloat()
                   + Vector(0, 0, cv_tp_z:GetFloat())

    local tr = util.TraceLine({
        start  = hmdPos, endpos = idealPos,
        filter = LocalPlayer(), mask = MASK_SOLID_BRUSHONLY,
    })
    local camPos = tr.HitPos + tr.HitNormal * 4

    if cv_tp_faceply:GetBool() then camAng = (hmdPos - camPos):Angle() end
    return camPos, camAng
end

-- ============================================================
--  VR CAMERAS  (override: always beats the client-side modes)
--  Key-bound camera entities placed with the VR Camera tool (Render tab).
--  Activation comes from the server's numpad hooks, exactly like the stock
--  camera; rendering happens here so VR gets a correct image. VRSpecCam.reg is
--  maintained by the entity itself, so switching never scans the entity list.
-- ============================================================

local activeCam
local lastFov

-- Switch blending. Position, angle and FOV all fly together from wherever the
-- view was to wherever it is going; at 0 the switch is a hard cut, which is
-- what a camera key should do by default.
local blendPos, blendAng, blendFov, blendEnd, blendDur
local blendPosScratch, blendAngScratch = Vector(), Angle()

local function StartBlend()
    local dur = cv_blend:GetFloat()
    if dur <= 0 then blendEnd = nil return end
    -- indicator* is the last thing the spectator view rendered; outside VR the
    -- engine's own eye position is already the outgoing camera's.
    local p, a = indicatorPos, indicatorAng
    if not p then p, a = EyePos(), EyeAngles() end
    -- Copies: both sources can be scratch values that move underneath us.
    blendPos, blendAng = Vector(p), Angle(a or angle_zero)
    blendFov = lastFov or (IsValid(activeCam) and activeCam:GetCamFOV()) or 90
    blendDur, blendEnd = dur, RealTime() + dur
end

-- Smoothstep, so the fly eases out of the old camera and into the new one.
local function Blend(pos, ang, fov)
    local left = blendEnd - RealTime()
    if left <= 0 then
        blendEnd = nil
        return pos, ang, fov
    end
    local f = 1 - left / blendDur
    f = f * f * (3 - 2 * f)
    blendPosScratch:SetUnpacked(
        blendPos.x + (pos.x - blendPos.x) * f,
        blendPos.y + (pos.y - blendPos.y) * f,
        blendPos.z + (pos.z - blendPos.z) * f)
    blendAngScratch:SetUnpacked(
        blendAng.p + AngleDifference(ang.p, blendAng.p) * f,
        blendAng.y + AngleDifference(ang.y, blendAng.y) * f,
        blendAng.r + AngleDifference(ang.r, blendAng.r) * f)
    return blendPosScratch, blendAngScratch, blendFov + (fov - blendFov) * f
end

-- Desktop parity: outside VR the camera takes over the main view like the stock
-- one does. VRMod owns CalcView while a session is live, so this stands down.
-- The hook outlives deactivation by one blend, so the fly back to the player's
-- own view runs too, then removes itself.
local function DesktopView(_, pos, ang, fov)
    if g_VR and g_VR.active then return end
    local e = activeCam
    if IsValid(e) then
        pos, ang = e:GetPos(), e:GetAngles()
        local f = e:GetCamFOV()
        if f > 0 then fov = f end
    elseif not blendEnd then
        hook.Remove("CalcView", "VRSpecCam_View")
        return
    end
    if blendEnd then pos, ang, fov = Blend(pos, ang, fov) end
    lastFov = fov
    return { origin = pos, angles = ang, fov = fov, drawviewer = IsValid(e) }
end

local function SetActive(e, fromNet)
    if not IsValid(e) then e = nil end
    if e ~= activeCam then StartBlend() end
    activeCam = e
    VRSpecCam.active = e
    -- Rotation smoothing must not carry across a switch, or the angle drifts
    -- into the new camera on its own and there is no such thing as a cut.
    smoothAngles = nil

    -- Keep the server's toggle state in step with what we are looking through.
    if not fromNet then
        net.Start("vrmod_speccam_set")
        net.WriteEntity(e or NULL)
        net.SendToServer()
    end

    if (e or blendEnd) and not (g_VR and g_VR.active) then
        hook.Add("CalcView", "VRSpecCam_View", DesktopView)
    else
        hook.Remove("CalcView", "VRSpecCam_View")
    end
end

-- Key-bound activation arrives from the server's numpad hooks.
net.Receive("vrmod_speccam_set", function() SetActive(net.ReadEntity(), true) end)

local function Cycle(step)
    local list = VRSpecCam.Sorted()
    local n = #list
    if n == 0 then return end
    local i = 0
    for k = 1, n do
        if list[k] == activeCam then i = k break end
    end
    SetActive(list[(i - 1 + step) % n + 1])
end

concommand.Add("vrmod_speccam_next", function() Cycle(1) end,  nil, "Next VR camera")
concommand.Add("vrmod_speccam_prev", function() Cycle(-1) end, nil, "Previous VR camera")
concommand.Add("vrmod_speccam_off",  function() SetActive(nil) end, nil, "Stop viewing VR cameras")

concommand.Add("vrmod_speccam_toggle", function()
    if IsValid(activeCam) then SetActive(nil) else Cycle(1) end
end, nil, "Toggle VR cameras on/off")

concommand.Add("vrmod_speccam_select", function(_, _, args)
    local want = tonumber(args[1]) or 0
    local list = VRSpecCam.Sorted()
    for i = 1, #list do
        if list[i]:GetCamIndex() == want then return SetActive(list[i]) end
    end
end, nil, "Select a VR camera by its number")

concommand.Add("vrmod_speccam_pick", function(_, _, args)
    local e = args[1] and Entity(tonumber(args[1]) or 0) or LocalPlayer():GetEyeTrace().Entity
    if IsValid(e) and e:GetClass() == "vrmod_speccam" then SetActive(e) end
end, nil, "Use the VR camera under your aim (or an entity index)")

-- ============================================================
--  RENDER
-- ============================================================

-- Reused across frames: render.RenderView reads it immediately and keeps no
-- reference, so one persistent table removes a per-frame allocation.
local viewTbl = {
    x = 0, y = 0,
    drawviewmodel = false, drawmonitors = true, dopostprocess = false,
}
local hideHeadFn = function() return g_VR.eyePosLeft end

local function SpecTarget()
    if fbW then
        rtW, rtH = fbW, fbH
    else
        rtW, rtH = math.floor(ScrW() * specScale), math.floor(ScrH() * specScale)
    end
    specRT = GetRenderTargetEx("vrmod_spec_" .. rtW .. "x" .. rtH, rtW, rtH, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_SEPARATE, bit.bor(4, 8, 256, 32768), 0, IMAGE_FORMAT_BGRA8888)
    if specMat then
        specMat:SetTexture("$basetexture", specRT)
    else
        specMat = CreateMaterial("vrmod_specMat", "UnlitGeneric", { ["$basetexture"] = specRT:GetName() })
    end
end

local function Blit()
    cam.Start2D()
    surface.SetDrawColor(255, 255, 255, 255)
    surface.SetMaterial(specMat)
    surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
    cam.End2D()
end

local function DoRenderView(origin, angles, fov, hide)
    if blendEnd then origin, angles, fov = Blend(origin, angles, fov) end
    indicatorPos, indicatorAng, lastFov = origin, angles, fov
    local ht = hook.GetTable()

    -- Head hiding (eye mode only; the caller gates it)
    local origEP
    if hide and g_VR.eyePosLeft then
        origEP = EyePos
        EyePos = hideHeadFn
    end

    -- HUD: VRMod suppresses it via HUDShouldDraw "vrmod_hud".
    -- If the user wants the HUD on the desktop view, temporarily remove
    -- that hook so GMod's normal HUD draw path runs inside RenderView.
    local showHud = cv_showhud:GetBool()
    local hudHook = showHud and ht.HUDShouldDraw and ht.HUDShouldDraw.vrmod_hud
    if hudHook then hook.Remove("HUDShouldDraw", "vrmod_hud") end

    local w, h
    if useRT then w, h = rtW, rtH else w, h = ScrW(), ScrH() end
    -- Desktop aspect even when the target isn't: Blit stretches it back
    local a = ScrW() / ScrH()
    -- Post-processing as the eyes have it (vrmod_postprocess), so this view
    -- renders like an eye: without it, depth-reading effects (ambient
    -- occlusion) showed in the headset but not here.
    local shaders = cv_shaders:GetBool()
    local pp = shaders and g_VR.view.dopostprocess or false
    viewTbl.origin, viewTbl.angles, viewTbl.fov, viewTbl.dopostprocess = origin, angles, fov, pp
    viewTbl.w, viewTbl.h, viewTbl.aspect, viewTbl.aspectratio, viewTbl.drawhud = w, h, a, a, showHud

    isRendering, g_VR.specCamRendering = true, true
    if useRT then
        render.PushRenderTarget(specRT)
        render.Clear(0, 0, 0, 255, true, true)
    end
    render.RenderView(viewTbl)

    -- With post-processing off the engine skips RenderScreenspaceEffects, so
    -- fire it here while the target still holds our render (unrecord,
    -- bodycam, etc.); with it on the engine already did.
    if shaders and not pp then hook.Run("RenderScreenspaceEffects") end
    if useRT then render.PopRenderTarget() end

    isRendering, g_VR.specCamRendering = false, false

    -- Restore everything
    if hudHook then hook.Add("HUDShouldDraw", "vrmod_hud", hudHook) end
    if origEP then EyePos = origEP end
    if useRT then Blit() end
end

-- ============================================================
--  MOTION  (feeds the chase cam and the awesome camera)
--  Follows the seat in a vehicle (rigid with the body, and its +Y is the way
--  the driver faces in HL2, simfphys, Glide and LVS alike) or the player on
--  foot. Velocity is differenced from positions: client-side GetVelocity on
--  a server-simulated vehicle is not dependable.
-- ============================================================

local trackEnt, lastYaw, chaseYaw, kSlow = nil, 0, 0, 0
local lx, ly, lz, svx, svy, svz = 0, 0, 0, 0, 0, 0
local fxSpeed, fxAccel, fxYawRate, fxJolt = 0, 0, 0, 0
local fxLean, fxLook, fxPitch, fxPunch = 0, 0, 0, 0

local function Track(ent, dt)
    local px, py, pz = ent:GetPos():Unpack()
    local y = ent:GetAngles().y
    local inv = dt > 0 and 1 / dt or 0
    local vx, vy, vz = (px - lx) * inv, (py - ly) * inv, (pz - lz) * inv
    lx, ly, lz = px, py, pz
    -- New subject, first frame, or a teleport (>20000 u/s): start at rest
    if ent ~= trackEnt or inv == 0 or vx * vx + vy * vy + vz * vz > 4e8 then
        trackEnt, lastYaw, chaseYaw, kSlow = ent, y, y + 90, 0
        svx, svy, svz, fxSpeed, fxAccel, fxYawRate, fxJolt = 0, 0, 0, 0, 0, 0, 0
        fxLean, fxLook, fxPitch, fxPunch = 0, 0, 0, 0
        return
    end
    local kFast = 1 - exp(-10 * dt)
    kSlow = 1 - exp(-5 * dt)
    local ox, oy, oz = svx, svy, svz
    svx, svy, svz = ox + (vx - ox) * kFast, oy + (vy - oy) * kFast, oz + (vz - oz) * kFast
    local sp = sqrt(svx * svx + svy * svy + svz * svz)
    fxAccel = fxAccel + ((sp - fxSpeed) * inv - fxAccel) * kSlow
    fxYawRate = fxYawRate + (AngleDifference(y, lastYaw) * inv - fxYawRate) * kFast
    fxSpeed, lastYaw = sp, y
    -- Crash / hard landing: a velocity change far past what brakes can do
    ox, oy, oz = (svx - ox) * inv, (svy - oy) * inv, (svz - oz) * inv
    local j = (sqrt(ox * ox + oy * oy + oz * oz) - 4000) * 0.000125
    fxJolt = fxJolt * (1 - kSlow)
    if j > fxJolt then fxJolt = j < 1 and j or 1 end
end

local function Lim(v, a) return v > a and a or v < -a and -a or v end

-- Awesome camera: angles and FOV only, written to its own scratch. The
-- incoming angle can be Smooth's scratch; writing through it would feed the
-- effects back into the smoothing.
local fxAng = Angle()
local function Awesome(ang, fov, t, top)
    local s = fxSpeed / top
    if s > 1 then s = 1 end
    local sway, shake, k = cv_fx_sway:GetFloat(), cv_fx_shake:GetFloat(), kSlow
    -- Bank and look into turns harder the faster you go; dip under braking,
    -- rear up and punch the FOV out under throttle.
    local turn = fxYawRate * s
    fxLean  = fxLean  + (Lim(turn * -0.2, 20) - fxLean) * k
    fxLook  = fxLook  + (Lim(turn * 0.12, 15) - fxLook) * k
    fxPitch = fxPitch + (Lim(fxAccel * -0.004, 8) - fxPitch) * k
    fxPunch = fxPunch + (Lim(fxAccel * 0.0004, 0.4) - fxPunch) * k
    -- Shake: road rumble from 40% speed up, plus the crash jolt. Detuned sines
    -- per axis never line up into a visible loop.
    local hs = s > 0.4 and (s - 0.4) * 1.6667 or 0
    local amp = shake * (hs * hs * 1.5 + fxJolt * 8)
    local p, y, r = ang:Unpack()
    fxAng:SetUnpacked(
        p + fxPitch * sway + (sin(t * 31) + sin(t * 17.3 + 1.7) * 0.6) * amp,
        y + fxLook * sway + (sin(t * 23.7 + 0.5) + sin(t * 41.1) * 0.4) * amp * 0.7,
        r + fxLean * sway + sin(t * 19.9 + 2.1) * amp * 0.5)
    -- Speed widens the view (eased); a crash slams it in
    fov = fov + cv_fx_fov:GetFloat() * (s * s * (3 - 2 * s) + fxPunch) - fxJolt * 12 * shake
    return fxAng, fov < 10 and 10 or fov > 170 and 170 or fov
end

-- The body a seat rides on (simfphys, Glide, LVS), or the vehicle itself
local function Body(veh)
    local b = veh:GetParent()
    return IsValid(b) and b or veh
end

-- Chase and Random Shots never run in the same frame, so they share scratch.
local camPos, camAng, focusPos = Vector(), Angle(), Vector()
local camTr = { mask = MASK_SOLID_BRUSHONLY, output = {} }

-- Chase cam (vehicles only): behind the body and sized to it, lagging its
-- turns, pulled in off walls like Third-Person. Smooths itself.
local function Chase(veh)
    local body = Body(veh)
    local c, rad = body:WorldSpaceCenter(), body:BoundingRadius()
    chaseYaw = chaseYaw + AngleDifference(lastYaw + 90, chaseYaw) * kSlow
    local d, h = rad * cv_chase_dist:GetFloat(), rad * cv_chase_z:GetFloat()
    local yr = chaseYaw * 0.017453293
    local ox, oy = cos(yr) * -d, sin(yr) * -d
    local cx, cy, cz = c:Unpack()
    camPos:SetUnpacked(cx + ox, cy + oy, cz + h)
    camTr.start, camTr.endpos = c, camPos
    local f = TraceLine(camTr).Fraction
    if f < 1 then
        f = f * 0.9
        camPos:SetUnpacked(cx + ox * f, cy + oy * f, cz + h * f)
    end
    -- Aim just above the body's center, which sits it in the lower frame
    camAng:SetUnpacked(atan2(h * f - rad * 0.15, d * f) * 57.29578, chaseYaw, 0)
    return camPos, camAng
end

-- Random set bit of mask (bit index), avoiding `last` unless it's all there is
local pickList = {}
local function Pick(mask, last)
    if last then
        local rest = band(mask, bnot(lshift(1, last)))
        if rest ~= 0 then mask = rest end
    end
    local n = 0
    for i = 0, 9 do
        if band(mask, lshift(1, i)) ~= 0 then n = n + 1 pickList[n] = i end
    end
    return pickList[random(n)]
end

-- ============================================================
--  MODE PICK  (on foot, the vehicle's own, or camera rotation)
--  Any change of mode cuts, or flies per vrmod_speccam_blend, and starts
--  rotation smoothing and Random Shots fresh.
-- ============================================================

local rotMode, rotNext, rotUsed, lastMode, shotEnd = nil, 0, 0, nil, 0

local function PickMode(veh, now)
    local mode = cv_cammode:GetInt()
    if veh then
        local vm = cv_vehmode:GetInt()
        if vm >= 0 then mode = vm end
    end
    if cv_rot:GetBool() then
        local pool = cv_rot_pool:GetInt()
        if not veh then pool = band(pool, 95) end -- chase (32) needs a vehicle
        if pool ~= 0 then
            if now >= rotNext or not rotMode or band(pool, lshift(1, rotMode)) == 0 then
                local avail = pool
                -- Checklist: draw without replacement, refill once the pool is spent
                if cv_rot_check:GetBool() then
                    avail = band(pool, bnot(rotUsed))
                    if avail == 0 then rotUsed, avail = 0, pool end
                end
                rotMode, rotNext = Pick(avail, rotMode), now + cv_rot_time:GetFloat()
                rotUsed = bor(rotUsed, lshift(1, rotMode))
            end
            mode = rotMode
        end
    end
    if mode ~= lastMode then
        if lastMode then StartBlend() end
        lastMode, smoothAngles, shotEnd = mode, nil, 0
    end
    return mode
end

-- ============================================================
--  RANDOM SHOTS
--  Rows: relative to the subject's heading?, yaw offset, yaw rate (deg/s),
--  distance and its growth per second, height and its growth (both in
--  subject sizes), roll, framing (larger = wider). Every shot looks at the
--  subject, is pulled in off walls, and sets its FOV from the distance, so
--  the subject stays in frame at a steady size however the shot moves.
--  The false row is the tripod: a fixed spot ahead that pans and zooms as
--  the subject passes, and cuts away once it loses sight or range.
-- ============================================================

local SHOTS = {
    {false,   0,    9, 2.6, 0,    0.35, 0,     0, 1.6}, -- orbit
    {true,   35,    0, 1.6, 0,   -0.6,  0,     0, 1.9}, -- low-angle hero
    {true,   80,    0, 2.0, 0,    0.1,  0,    22, 1.4}, -- dutch tilt
    {true,   12,    0, 1.8, 0,    0.15, 0,     0, 1.3}, -- leading, looking back
    {false,   0,    4, 1.0, 0.06, 2.6,  0.12,  0, 1.8}, -- rising crane
    {true,  110, -1.5, 7.0, 0,    0.25, 0,     0, 1.1}, -- telephoto
    {true,  150,    0, 1.3, 0.35, 0.2,  0,     0, 1.2}, -- dolly zoom
    {true,   30,    0, 1.2, 0,    0.15, 0,    -8, 0.9}, -- canted close-up
    false,                                              -- tripod
}
-- In a vehicle: 1 = the vehicle, 2 = vehicle and driver, 0 = the driver
local SUBJECTS = {1, 1, 2, 2, 0}
local shotType, shotT0, shotSide, shotA, shotHd, shotSubj = nil, 0, 1, 0, 0, 0
local shotPos = Vector()

local function Shots(veh, now)
    local hmd = g_VR.tracking and g_VR.tracking.hmd
    if not hmd then return end
    local fresh = now >= shotEnd
    if fresh then
        local lo, hi = cv_shot_min:GetFloat(), cv_shot_max:GetFloat()
        if hi < lo then hi = lo end
        shotType = Pick(1022, shotType) -- bits 1-9 = SHOTS rows
        shotEnd, shotT0 = now + lo + random() * (hi - lo), now
        shotSide, shotA = random(2) * 2 - 3, random() * 360
        shotHd = veh and lastYaw + 90 or (hmd.ang or g_VR.view.angles).y
        shotSubj = veh and SUBJECTS[random(5)] or 0
        StartBlend()
    end

    -- Subject: upper chest below the headset, the vehicle, or between them
    local px, py, pz = hmd.pos:Unpack()
    local R
    pz = pz - 14
    if veh and shotSubj > 0 then
        local body = Body(veh)
        local cx, cy, cz = body:WorldSpaceCenter():Unpack()
        R = body:BoundingRadius()
        if shotSubj == 2 then
            px, py, pz, R = (px + cx) * 0.5, (py + cy) * 0.5, (pz + cz) * 0.5, R * 0.8
        else
            px, py, pz = cx, cy, cz
        end
    else
        R = veh and 48 or 36
    end
    -- On foot the heading is frozen per shot, so head turns don't swing it;
    -- a vehicle's live heading makes mounted shots ride along with it.
    local hd = veh and lastYaw + 90 or shotHd

    local S, ox, oy, oz = SHOTS[shotType]
    if S then
        local e = now - shotT0
        if e > 20 then e = 20 end
        local yr = ((S[1] and hd or shotA) + (S[2] + S[3] * e) * shotSide) * 0.017453293
        local d = R * (S[4] + S[5] * e)
        ox, oy, oz = cos(yr) * d, sin(yr) * d, R * (S[6] + S[7] * e)
    else
        if fresh then
            -- Ahead along the way it's moving (or facing), off to one side
            local yr = fxSpeed > 60 and atan2(svy, svx) or hd * 0.017453293
            local c, sn, a, b = cos(yr), sin(yr), R * 4.5, R * 1.8 * shotSide
            shotPos:SetUnpacked(px + c * a - sn * b, py + sn * a + c * b, pz + R * 0.3)
        end
        local sx, sy, sz = shotPos:Unpack()
        ox, oy, oz = sx - px, sy - py, sz - pz
    end

    focusPos:SetUnpacked(px, py, pz)
    camPos:SetUnpacked(px + ox, py + oy, pz + oz)
    camTr.start, camTr.endpos = focusPos, camPos
    local f = TraceLine(camTr).Fraction
    if f < 1 then
        if not S and not fresh then shotEnd = 0 end -- tripod lost sight: cut next frame
        f = f * 0.9
        ox, oy, oz = ox * f, oy * f, oz * f
        camPos:SetUnpacked(px + ox, py + oy, pz + oz)
    end
    if not S and fresh then shotPos:Set(camPos) end

    local h2 = ox * ox + oy * oy
    local dist = sqrt(h2 + oz * oz)
    if not S and dist > R * 16 then shotEnd = 0 end -- tripod out of range
    -- Look at the subject, with a slow operator drift
    camAng:SetUnpacked(
        atan2(oz, sqrt(h2)) * 57.29578 + sin(now * 0.9) * 0.6,
        atan2(-oy, -ox) * 57.29578 + sin(now * 0.7 + 2) * 0.8,
        S and S[8] * shotSide or 0)
    local fov = atan2(R * (S and S[9] or 1.3), dist) * 114.59156
    return camPos, camAng, fov < 20 and 20 or fov > 110 and 110 or fov
end

-- g_VR.specCamDesktop: this pass owns the desktop, so cl_vrmod skips its
-- eye-mirror blit (it would only be painted over).
local function Idle()
    smoothAngles, lastFrameTime, indicatorPos, indicatorAng, specSkip, trackEnt, lastMode = nil, nil, nil, nil, 0, nil, nil
    if g_VR then g_VR.specCamDesktop = false end
end

local function SpecRender()
    if isRendering then return end
    if gui.IsConsoleVisible() or gui.IsGameUIVisible() then return end
    local cam = IsValid(activeCam) and activeCam or nil
    if activeCam ~= cam then activeCam, VRSpecCam.active = cam, cam end

    if cv_cheap:GetBool() or not g_VR or not g_VR.active or not g_VR.view then return Idle() end
    g_VR.specCamDesktop = true
    -- Throttled/scaled: render on every Nth frame, re-show the target between.
    -- Placed before the dt sample so smoothing spans the skipped frames.
    if not specScale then
        specScale = cv_scale:GetFloat()
        -- Engine frame-buffer RTs sized to the eye (cl_vrmod): a pass drawn
        -- straight to the desktop copies into and samples them at the wrong
        -- scale (screen-space addons show a zoomed corner), so render at
        -- their exact size and stretch -- every view then matches them.
        local fb = render.GetScreenEffectTexture()
        fbW, fbH = fb:Width(), fb:Height()
        if fbW == ScrW() and fbH == ScrH() then fbW = nil end
    end
    local rate = cv_rate:GetInt()
    useRT = fbW or rate > 1 or specScale < 1
    if useRT then
        if not specRT then SpecTarget() end
        if specSkip > 0 then
            specSkip = specSkip - 1
            return Blit()
        end
        specSkip = rate - 1
    else
        specSkip = 0
    end
    local fov = cv_specfov:GetFloat()
    if fov <= 0 then fov = 90 end

    local now = RealTime()
    local dt  = lastFrameTime and (now - lastFrameTime) or 0
    lastFrameTime = now

    -- VR CAMERA: overrides every client-side mode while one is selected
    if cam then
        local f = cam:GetCamFOV()
        DoRenderView(cam:GetPos(), Smooth(cam:GetAngles(), dt), f > 0 and f or fov)
        return
    end

    local ply = LocalPlayer()
    local veh = ply:GetVehicle()
    if not IsValid(veh) then veh = nil end
    local fx = cv_fx:GetInt()
    fx = fx == 1 or fx == 2 and veh ~= nil
    local mode = PickMode(veh, now)
    if fx or mode >= 5 then Track(veh or ply, dt) else trackEnt = nil end

    local origin, ang, hide
    if mode == 1 then
        -- MODE 1: STATIC / ATTACHED
        if IsValid(attachedEnt) then
            local ep, ea = attachedEnt:GetPos(), attachedEnt:GetAngles()
            origin = ep + ea:Forward()*cv_att_x:GetFloat()
                       + ea:Right()  *cv_att_y:GetFloat()
                       + ea:Up()     *cv_att_z:GetFloat()
            ang = ResolveStaticAngles(ea)
        else
            if not staticCamSet then PlaceStaticCam() end
            origin, ang = staticCamPos, ResolveStaticAngles(nil)
        end
    elseif mode == 2 then
        -- MODE 2: THIRD-PERSON
        origin, ang = GetThirdPersonOriginAndAngle()
        if not origin then return Idle() end
        ang = Smooth(ang, dt)
    elseif mode == 3 then
        -- MODE 3: BODY CAM (chest-anchored, HMD look direction)
        local bm = GetChestBoneMatrix(ply)
        if bm then
            local ba = bm:GetAngles()
            -- Spine1 local axes: Right=right, Up=out chest (forward in world), Forward=up the body
            origin = bm:GetTranslation()
                   + ba:Right()   * cv_bodycam_x:GetFloat()
                   + ba:Up()      * cv_bodycam_y:GetFloat()
                   + ba:Forward() * cv_bodycam_z:GetFloat()
        else
            origin = GetEyePosition()
        end
        ang = Smooth(g_VR.view.angles or EyeAngles(), dt)
    elseif mode == 4 then
        -- MODE 4: ATTACH TO BONE
        local bm = GetAttachBoneMatrix(ply)
        if not bm then return Idle() end
        local ba = bm:GetAngles()
        origin = bm:GetTranslation()
               + ba:Right()   * cv_bone_x:GetFloat()
               + ba:Up()      * cv_bone_y:GetFloat()
               + ba:Forward() * cv_bone_z:GetFloat()
        ang = cv_bone_rotmode:GetInt() == 0 and ba or (g_VR.view.angles or EyeAngles())
        if cv_bone_flip:GetBool() then
            ang = Angle(-ang.p, ang.y + 180, -ang.r)
        end
        ang = Smooth(ang + Angle(cv_bone_ang_p:GetFloat(), cv_bone_ang_y:GetFloat(), cv_bone_ang_r:GetFloat()), dt)
    elseif mode == 5 and veh then
        -- MODE 5: CHASE (vehicles only; on foot it falls through to eye)
        origin, ang = Chase(veh)
    elseif mode == 6 then
        -- MODE 6: RANDOM SHOTS (sets its own FOV)
        origin, ang, fov = Shots(veh, now)
        if not origin then return Idle() end
    else
        -- MODE 0: EYE (HMD eye position)
        origin, ang, hide = GetEyePosition(), Smooth(g_VR.view.angles or EyeAngles(), dt), cv_hidehead:GetBool()
    end
    if fx then ang, fov = Awesome(ang, fov, now, (veh and cv_fx_speed or cv_fx_speed_ft):GetFloat()) end
    DoRenderView(origin, ang, fov, hide)
end

-- Only hooked while this client is in VR with Cheap Rendering off. With it on
-- (the default), or outside VR, the pass only ran Idle() every frame, on
-- every client.
local function SyncRender(inVR)
    if inVR and not cv_cheap:GetBool() then
        hook.Add("PostRender", "VRModSpecFOV_Render", SpecRender)
    else
        hook.Remove("PostRender", "VRModSpecFOV_Render")
        Idle()
    end
end
cvars.AddChangeCallback("vrmod_cheaprender", function() SyncRender(g_VR and g_VR.active) end, "VRModSpecFOV_Render")
hook.Add("VRMod_Start", "VRModSpecFOV_Render", function(ply)
    if ply == LocalPlayer() then SyncRender(true) end
end)
SyncRender(g_VR and g_VR.active)

-- Next session re-reads the scale and re-makes the target at that size
hook.Add("VRMod_Exit", "VRModSpecFOV_RT", function(ply)
    if ply ~= LocalPlayer() then return end
    specRT, specScale, specSkip, fbW = nil, nil, 0, nil
    SyncRender(false)
end)

-- ============================================================
--  CAMERA POSITION SPRITE
-- ============================================================

local function DrawSprite(depth, sky)
    if depth or sky or isRendering or not indicatorPos then return end
    render.SetMaterial(spriteMat)
    render.DrawSprite(indicatorPos, 8, 8, spriteColor)
    if indicatorAng then
        render.DrawSprite(indicatorPos + indicatorAng:Forward() * 6, 4, 4, spriteDirColor)
    end
end
-- Only hooked while on: PostDrawTranslucentRenderables runs several times a frame
local function SyncSprite()
    if cv_showsprite:GetBool() then
        hook.Add("PostDrawTranslucentRenderables", "VRModSpecFOV_Sprite", DrawSprite)
    else
        hook.Remove("PostDrawTranslucentRenderables", "VRModSpecFOV_Sprite")
    end
end
cvars.AddChangeCallback("vrmod_specfov_showsprite", SyncSprite, "VRModSpecFOV_Sprite")
SyncSprite()