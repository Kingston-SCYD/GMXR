-- VR GetAimVector override — returns dominant hand direction for all VR contexts
local _vrAimPatched = false
local function PatchVRAim()
    if _vrAimPatched then return end
    _vrAimPatched = true
    local plyMeta = FindMetaTable("Player")
    if not plyMeta then return end
    local HAND_CORRECTION = Angle(2, 6, 0)
    local _GetAimVector = plyMeta.GetAimVector

    function plyMeta:GetAimVector()
        if not g_VR then return _GetAimVector(self) end
        if SERVER then
            local vrData = g_VR[self:SteamID()]
            if not vrData then return _GetAimVector(self) end
            if vrData.muzzleAng then return vrData.muzzleAng:Forward() end
        else
            if self ~= LocalPlayer() or not g_VR.active then return _GetAimVector(self) end
            local muz = g_VR.viewModelMuzzle
            if muz and muz.Ang then return muz.Ang:Forward() end
            local hand = g_VR.tracking and g_VR.tracking[false and "pose_lefthand" or "pose_righthand"]
            if hand and hand.ang then return (hand.ang + HAND_CORRECTION):Forward() end
        end
        return _GetAimVector(self)
    end
end

PatchVRAim()

-- VR tracking-based body spheres, shared by self-damage, the MP head hitbox
-- and the debug overlay so all three agree on geometry. {spine_frac, radius};
-- index 2 (frac 1.0 = HMD height) is the head sphere reused as the MP hitbox.
local SD_BODY = {{0.72, 12}, {1.0, 7}, {0.42, 10}}
local SD_HEAD = 2

if CLIENT then
    local convars = vrmod.GetConvars()
    vrmod.AddCallbackedConvar("vrmod_configversion", nil, "5")
    if convars.vrmod_configversion:GetString() ~= convars.vrmod_configversion:GetDefault() then
        timer.Simple(1, function()
            for k, v in pairs(convars) do
                pcall(function() v:Revert() end)
            end
        end)
    end

    vrmod.AddCallbackedConvar("vrmod_althead", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_althead_auto", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_autostart", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_scale", nil, "32.7")
    vrmod.AddCallbackedConvar("vrmod_heightmenu", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_floatinghands", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_desktopview", nil, "3")
    vrmod.AddCallbackedConvar("vrmod_laserpointer", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_znear", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_renderoffset", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_viewscale", nil, "1.0")
    vrmod.AddCallbackedConvar("vrmod_fovscale_x", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_fovscale_y", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_scalefactor", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_eyescale", nil, "0.5")
    vrmod.AddCallbackedConvar("vrmod_verticaloffset", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_horizontaloffset", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_characteryawblend", nil, "1.5")
    vrmod.AddCallbackedConvar("vrmod_postprocess", nil, "0", nil, nil, nil, nil, tobool, function(val) if g_VR.view then g_VR.view.dopostprocess = val end end)
    vrmod.AddCallbackedConvar("vrmod_skybox", nil, "0", nil, nil, nil, nil, tobool, function(val) RunConsoleCommand("r_3dsky", val and "1" or "0") end)
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_x", nil, "-15")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_y", nil, "-1")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_z", nil, "5")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_pitch", nil, "50")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_yaw", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_roll", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_smoothturn", "smoothTurn", "1", nil, nil, nil, nil, tobool)
    vrmod.AddCallbackedConvar("vrmod_smoothturnrate", "smoothTurnRate", "180", nil, nil, nil, nil, tonumber)
    vrmod.AddCallbackedConvar("vrmod_snapturnangle", "snapTurnAngle", "45", nil, nil, nil, nil, tonumber)
    vrmod.AddCallbackedConvar("vrmod_crouchthreshold", "crouchThreshold", "40", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_nocrouchjump", "noCrouchJump", "0", nil, nil, nil, nil, tobool)
    -- Client gameplay convars — previously only referenced by cl_settings.lua
    -- checkboxes but never explicitly created, so they reset every session.
    vrmod.AddCallbackedConvar("vr_pickup_disable_client", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_weapon_swap", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_deathcam_ragdoll", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_deathcam_ragdoll_view", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_weaponmenu_style", nil, "0")
    ----------------------------------------------------------------------------
    concommand.Add("vrmod_start", function(ply, cmd, args)
        if vgui.CursorVisible() then print("vrmod: attempting startup when game is unpaused") end
        timer.Create("vrmod_start", 0.1, 0, function()
            if not vgui.CursorVisible() then
                timer.Remove("vrmod_start")
                VRUtilClientStart()
            end
        end)
    end)

    concommand.Add("vrmod_exit", function(ply, cmd, args)
        if timer.Exists("vrmod_start") then timer.Remove("vrmod_start") end
        if isfunction(VRUtilClientExit) then VRUtilClientExit() end
    end)

    concommand.Add("vrmod_reset", function(ply, cmd, args)
        for k, v in pairs(vrmod.GetConvars()) do
            pcall(function() v:Revert() end)
        end

        hook.Call("VRMod_Reset")
    end)

    concommand.Add("vrmod_info", function()
        -- simple banner and key–value printer
        local function banner()
            print(("="):rep(72))
        end

        local function kv(label, val)
            print(string.format("| %-30s %s", label, val))
        end

        banner()
        -- General info
        kv("Addon Version:", vrmod.GetVersion())
        kv("Module Version:", vrmod.GetModuleVersion())
        kv("GMod Version:", VERSION .. " (Branch: " .. BRANCH .. ")")
        kv("Operating System:", system.IsWindows() and "Windows" or system.IsLinux() and "Linux" or system.IsOSX() and "OSX" or "Unknown")
        kv("Server Type:", game.SinglePlayer() and "Single Player" or "Multiplayer")
        kv("Server Name:", GetHostName())
        kv("Server Address:", game.GetIPAddress())
        kv("Gamemode:", GAMEMODE_NAME)
        -- Addon counts
        local wcount = 0
        for _, a in ipairs(engine.GetAddons()) do
            if a.mounted then wcount = wcount + 1 end
        end

        kv("Workshop Addons:", wcount)
        local _, folders = file.Find("addons/*", "GAME")
        local blacklist = {
            checkers = true,
            chess = true,
            common = true,
            go = true,
            hearts = true,
            spades = true
        }

        local lcount = 0
        for _, name in ipairs(folders) do
            if not blacklist[name] then lcount = lcount + 1 end
        end

        kv("Legacy Addons:", lcount)
        print("|" .. ("-"):rep(70))
        -- CRC of data/vrmod and lua/bin
        local function dumpCRC(path)
            for _, entry in ipairs(file.Find(path .. "/*", "GAME")) do
                local full = path .. "/" .. entry
                if file.IsDir(full, "GAME") then
                    dumpCRC(full)
                else
                    local crc = util.CRC(file.Read(full, "GAME") or "")
                    kv(full, string.format("%X", crc))
                end
            end
        end

        dumpCRC("data/vrmod")
        print("|" .. ("-"):rep(70))
        dumpCRC("lua/bin")
        print("|" .. ("-"):rep(70))
        -- Convar list
        local names = {}
        for _, cv in pairs(convars) do
            names[#names + 1] = cv:GetName()
        end

        table.sort(names)
        for _, n in ipairs(names) do
            local cv = GetConVar(n)
            local val = cv:GetString()
            kv(n, val .. (val ~= cv:GetDefault() and " *" or ""))
        end

        banner()
    end)

    concommand.Add("vrmod", function(ply, cmd, args)
        if vgui.CursorVisible() then print("vrmod: menu will open when game is unpaused") end
        timer.Create("vrmod_open_menu", 0.1, 0, function()
            if not vgui.CursorVisible() then
                VRUtilOpenMenu()
                timer.Remove("vrmod_open_menu")
            end
        end)
    end)

    -- ── VR hitbox size + debug overlay ─────────────────────────────────────
    -- Local size is userinfo so the server reads it per-player for self-damage.
    local cv_sdScale = CreateClientConVar("vrmod_selfdamage_scale", "1", true, true, "Scale your own VR self-damage hitbox radius", 0.1, 4)
    local cv_sdDbg   = CreateClientConVar("vrmod_selfdamage_debug", "0", true, false, "Draw VR hitbox spheres: green = your live self-damage box, red = networked, head sphere highlighted", 0, 1)
    local cv_srvScale = GetConVar("vrmod_vrhitbox_scale") -- replicated; may arrive late

    local _dbgC = Vector()
    local COL_BODY  = Color(60, 220, 60)
    local COL_HEAD  = Color(120, 255, 120)
    local COL_SBODY = Color(220, 60, 60)
    local COL_SHEAD = Color(90, 160, 255) -- the shootable MP head hitbox

    local function DrawSDBox(feetZ, cx, cy, spH, scale, bodyCol, headCol)
        for i = 1, 3 do
            local part = SD_BODY[i]
            _dbgC.x = cx; _dbgC.y = cy; _dbgC.z = feetZ + spH * part[1]
            render.DrawWireframeSphere(_dbgC, part[2] * scale, 8, 8, i == SD_HEAD and headCol or bodyCol)
        end
    end

    -- No FrameNumber gate: fires once per eye and BOTH draws are wanted.
    hook.Add("PostDrawTranslucentRenderables", "vrmod_selfdamage_debug", function(_, bSky)
        if bSky or not cv_sdDbg:GetBool() then return end
        cv_srvScale = cv_srvScale or GetConVar("vrmod_vrhitbox_scale")
        local srvScale = cv_srvScale and cv_srvScale:GetFloat() or 1

        -- Your own no-lag self-damage box from live tracking (green).
        local lp = LocalPlayer()
        if g_VR.active and g_VR.tracking and g_VR.tracking.hmd and IsValid(lp) then
            local pp = lp:GetPos()
            local h = g_VR.tracking.hmd.pos -- world space
            local spH = h.z - pp.z
            if spH >= 10 then
                DrawSDBox(pp.z, (pp.x + h.x) * 0.5, (pp.y + h.y) * 0.5, spH, cv_sdScale:GetFloat(), COL_BODY, COL_HEAD)
            end
        end

        -- Networked box the server sees for every OTHER VR player, at server
        -- scale (blue head = MP head hitbox, red body = self-damage silhouette).
        local vrnet = g_VR.net
        if not vrnet then return end
        for _, v in ipairs(player.GetHumans()) do
            local tab = v ~= lp and vrnet[v:SteamID()]
            local f = tab and (tab.lerpedFrame or tab.lastFrame)
            if f and f.hmdPos then
                local pp = v:GetPos()
                local hx, hy, hz = pp.x + f.hmdPos.x, pp.y + f.hmdPos.y, pp.z + f.hmdPos.z
                local spH = hz - pp.z
                if spH >= 10 then
                    DrawSDBox(pp.z, (pp.x + hx) * 0.5, (pp.y + hy) * 0.5, spH, srvScale, COL_SBODY, COL_SHEAD)
                end
            end
        end
    end)
elseif SERVER then
    -- Mark player on spawn
    hook.Add("PlayerSpawn", "VRMarkPlayerForEmptyWeapon", function(ply) if g_VR and g_VR[ply:SteamID()] then ply:SetNWBool("vr_switch_empty", true) end end)
    -- Switch weapon in Think hook
    hook.Add("Think", "VRSwitchToEmptyWeapon", function()
        for _, ply in ipairs(player.GetAll()) do
            if ply:GetNWBool("vr_switch_empty") and IsValid(ply) and ply:Alive() then
                if ply:HasWeapon("weapon_vrmod_empty") then
                    ply:SelectWeapon("weapon_vrmod_empty")
                    ply:SetNWBool("vr_switch_empty", false)
                end
            end
        end
    end)

    local cv_selfdmg = CreateConVar("vrmod_selfdamage", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Allow VR players to shoot themselves")

    local _sdPt, _sdEnd, _sdForce = Vector(), Vector(), Vector()
    local _sdAng0 = Angle(0, 0, 0)
    local _sdDmgCache = {} -- ammo type → resolved damage, filled once per type

    -- MP head hitbox: reuse the self-damage HEAD sphere so OTHER players can
    -- shoot a VR player where their HMD actually is (the animated model head
    -- rarely lines up). Replicated so the size is authoritative for everyone.
    local cv_vrhb      = CreateConVar("vrmod_vrhitbox", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "VR players get a tracking-based head hitbox others can shoot in MP", 0, 1)
    local cv_vrhbScale = CreateConVar("vrmod_vrhitbox_scale", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Scale the VR head hitbox radius for ALL players", 0.1, 4)
    local cv_vrhbMult  = CreateConVar("vrmod_vrhitbox_dmgmult", "2", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Damage multiplier for VR head-hitbox hits", 0, 10)

    -- Shared by self-damage and the head hitbox: HL2 C++ weapons set Damage=0,
    -- so fall back to the ammo type's sk_plr_dmg_* convar (resolved once/type).
    local function ResolveBulletDamage(data)
        local d = data.Damage
        if d > 0 then return d end
        local at = data.AmmoType or 0
        if _sdDmgCache[at] == nil then
            local id = isnumber(at) and at or game.GetAmmoID(tostring(at)) or 0
            local name = id > 0 and (game.GetAmmoData(id) or {}).name
            local cv = name and GetConVar("sk_plr_dmg_" .. name:lower())
            local v = cv and cv:GetFloat() or 0
            _sdDmgCache[at] = v > 0 and v or 10
        end
        return _sdDmgCache[at]
    end

    -- Self-damage: DistanceToLine against body spheres from VR tracking frame.
    -- Does NOT modify bullet data — won't eat other EntityFireBullets hooks.
    hook.Add("EntityFireBullets", "VRMod_SelfDamage", function(ent, data)
        if not cv_selfdmg:GetBool() then return end
        local ply = ent:IsPlayer() and ent
            or IsValid(data.Attacker) and data.Attacker:IsPlayer() and data.Attacker
            or ent.GetOwner and ent:GetOwner()
        if not IsValid(ply) or not ply:IsPlayer() then return end
        local vrd = g_VR[ply:SteamID()]
        if not vrd or not vrd.latestFrame or not vrd.latestFrame.hmdPos then return end
        local pp, hmd = ply:GetPos(), vrd.latestFrame.hmdPos
        local hx, hy, hz = pp.x + hmd.x, pp.y + hmd.y, pp.z + hmd.z
        if ply:InVehicle() then
            local veh = ply:GetVehicle()
            if not IsValid(veh) then return end
            local wp = LocalToWorld(hmd, _sdAng0, pp, veh:GetAngles())
            hx, hy, hz = wp.x, wp.y, wp.z
        end
        local spH = hz - pp.z
        if spH < 10 then return end
        -- Per-player local size: userinfo client convar, read server-side.
        local sdScale = math.Clamp(ply:GetInfoNum("vrmod_selfdamage_scale", 1), 0.1, 4)
        local src, dir, maxD = data.Src, data.Dir, data.Distance or 56756
        _sdEnd.x = src.x + dir.x * maxD; _sdEnd.y = src.y + dir.y * maxD; _sdEnd.z = src.z + dir.z * maxD
        _sdPt.x = (pp.x + hx) * 0.5; _sdPt.y = (pp.y + hy) * 0.5
        for i = 1, 3 do
            _sdPt.z = pp.z + spH * SD_BODY[i][1]
            local d, hitPt, frac = util.DistanceToLine(src, _sdEnd, _sdPt)
            if d < SD_BODY[i][2] * sdScale and frac * maxD > 1.5 then
                local dmgAmt = ResolveBulletDamage(data)
                local dmg = DamageInfo()
                dmg:SetAttacker(ply)
                local wep = ply:GetActiveWeapon()
                dmg:SetInflictor(IsValid(wep) and wep or ply)
                dmg:SetDamage(dmgAmt)
                dmg:SetDamageType(DMG_BULLET)
                dmg:SetDamagePosition(hitPt)
                local f = data.Force or 1
                _sdForce.x = dir.x * f; _sdForce.y = dir.y * f; _sdForce.z = dir.z * f
                dmg:SetDamageForce(_sdForce)
                ply:TakeDamageInfo(dmg)
                return
            end
        end
    end)

    -- MP head hitbox — nearest OTHER VR player's HEAD sphere along the ray wins.
    local _hbEnd, _hbC, _hbForce = Vector(), Vector(), Vector()
    hook.Add("EntityFireBullets", "VRMod_VRHeadHitbox", function(ent, data)
        if not cv_vrhb:GetBool() then return end
        local ply = ent:IsPlayer() and ent
            or IsValid(data.Attacker) and data.Attacker:IsPlayer() and data.Attacker
            or ent.GetOwner and ent:GetOwner()
        if not IsValid(ply) or not ply:IsPlayer() then return end
        local src, dir, maxD = data.Src, data.Dir, data.Distance or 56756
        _hbEnd.x = src.x + dir.x * maxD; _hbEnd.y = src.y + dir.y * maxD; _hbEnd.z = src.z + dir.z * maxD
        local headR = SD_BODY[SD_HEAD][2] * cv_vrhbScale:GetFloat()
        local best, bestFrac, bestPt
        for _, v in ipairs(player.GetHumans()) do
            local vrd = v ~= ply and v:Alive() and g_VR[v:SteamID()]
            local f = vrd and vrd.latestFrame
            if f and f.hmdPos then
                local pp, hmd = v:GetPos(), f.hmdPos
                local hx, hy, hz = pp.x + hmd.x, pp.y + hmd.y, pp.z + hmd.z
                if v:InVehicle() then
                    local veh = v:GetVehicle()
                    if IsValid(veh) then
                        local wp = LocalToWorld(hmd, _sdAng0, pp, veh:GetAngles())
                        hx, hy, hz = wp.x, wp.y, wp.z
                    end
                end
                local spH = hz - pp.z
                if spH >= 10 then
                    _hbC.x = (pp.x + hx) * 0.5; _hbC.y = (pp.y + hy) * 0.5; _hbC.z = pp.z + spH
                    local d, hitPt, frac = util.DistanceToLine(src, _hbEnd, _hbC)
                    if d < headR and frac * maxD > 1.5 and (not best or frac < bestFrac) then
                        best, bestFrac, bestPt = v, frac, hitPt
                    end
                end
            end
        end
        if not best then return end
        local dmg = DamageInfo()
        dmg:SetAttacker(ply)
        local wep = ply:GetActiveWeapon()
        dmg:SetInflictor(IsValid(wep) and wep or ply)
        dmg:SetDamage(ResolveBulletDamage(data) * cv_vrhbMult:GetFloat())
        dmg:SetDamageType(DMG_BULLET)
        dmg:SetDamagePosition(bestPt)
        local force = data.Force or 1
        _hbForce.x = dir.x * force; _hbForce.y = dir.y * force; _hbForce.z = dir.z * force
        dmg:SetDamageForce(_hbForce)
        best:TakeDamageInfo(dmg)
    end)

    hook.Add("EntityFireBullets", "VRMod_NoShootOwnVehicle", function(ply, data)
        if not ply:IsPlayer() or not ply:InVehicle() then return end
        local veh = ply:GetVehicle()
        if not IsValid(veh) then return end
        while IsValid(veh:GetParent()) do veh = veh:GetParent() end
        local ignore = {veh}
        for _, c in ipairs(veh:GetChildren()) do ignore[#ignore + 1] = c end
        if constraint then
            for _, c in ipairs(constraint.GetTable(veh) or {}) do
                if IsValid(c.Ent1) then ignore[#ignore + 1] = c.Ent1 end
                if IsValid(c.Ent2) then ignore[#ignore + 1] = c.Ent2 end
            end
        end
        local ig = data.IgnoreEntity
        if not ig then
            data.IgnoreEntity = ignore
        else
            if not istable(ig) then ig = {ig} data.IgnoreEntity = ig end
            for _, e in ipairs(ignore) do ig[#ig + 1] = e end
        end
        return true, data
    end)
end