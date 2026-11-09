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

-- The muzzle as a bullet's source, for shots fired from the gun and nothing
-- else. Penetration, ricochet and physics-bullet steps (TacRP, ARC9) fire
-- their follow-up bullet from the exit point, from inside the parent's
-- callback, owned by the same player. Moving those to the muzzle restarted
-- them in front of the surface they'd just gone through: they hit it again,
-- penetrated again, and recursed until the stack overflowed (crash). So a
-- bullet moves only when it starts where the shooter fires from (the shoot
-- pos already sits on the muzzle; a mid-flight phys-bullet step doesn't),
-- and never while a moved bullet's callback runs. The wrapped callback is
-- xpcall'd so one that errors can't leave the depth stuck. Shared: the
-- server (VRMod_Bullets) and the client's predicted copy (sh_network).
vrmod = vrmod or {}
local MUZ_NEAR, cbDepth = 16 * 16, 0
function vrmod.MuzzleBullet(data, muz)
    local src = data.Src
    if cbDepth > 0 or not src or src:DistToSqr(muz) > MUZ_NEAR then return false end
    data.Src = muz
    local cb = data.Callback
    if cb then
        data.Callback = function(a, tr, dmg)
            cbDepth = cbDepth + 1
            local ok, r = xpcall(cb, debug.traceback, a, tr, dmg)
            cbDepth = cbDepth - 1
            if ok then return r end
            ErrorNoHalt(r, "\n")
        end
    end
    return true
end

-- VR tracking-based body spheres, shared by self-damage, the MP head hitbox
-- and the debug overlay so all three agree on geometry. {spine_frac, radius};
-- index 2 (frac 1.0 = HMD height) is the head sphere reused as the MP hitbox.
-- Body radii were 12/10: 24u/20u across on a ~14u torso swallowed a gun held
-- at chest or hip, so ordinary aiming clipped your own spheres.
local SD_BODY = {{0.72, 8}, {1.0, 7}, {0.42, 7}}
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
    vrmod.AddCallbackedConvar("vrmod_althead_auto", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_autostart", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_scale", nil, "42.546349")
    vrmod.AddCallbackedConvar("vrmod_heightmenu", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_floatinghands", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_desktopview", nil, "2")
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
    vrmod.AddCallbackedConvar("vrmod_yaw_hip_head", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_yaw_hip_arms", nil, "0.7")
    vrmod.AddCallbackedConvar("vrmod_yaw_torso_head", nil, "0.25")
    vrmod.AddCallbackedConvar("vrmod_yaw_torso_arms", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_postprocess", nil, "0", nil, nil, nil, nil, tobool, function(val) if g_VR.view then g_VR.view.dopostprocess = val end end)
    vrmod.AddCallbackedConvar("vrmod_skybox", nil, "1", nil, nil, nil, nil, tobool, function(val) RunConsoleCommand("r_3dsky", val and "1" or "0") end)
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_x", nil, "-15")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_y", nil, "-1")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_z", nil, "5")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_pitch", nil, "50")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_yaw", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_controlleroffset_roll", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_smoothturn", "smoothTurn", "1", nil, nil, nil, nil, tobool)
    vrmod.AddCallbackedConvar("vrmod_smoothturnrate", "smoothTurnRate", "190", nil, nil, nil, nil, tonumber)
    vrmod.AddCallbackedConvar("vrmod_snapturnangle", "snapTurnAngle", "45", nil, nil, nil, nil, tonumber)
    vrmod.AddCallbackedConvar("vrmod_crouchthreshold", "crouchThreshold", "40", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_nocrouchjump", "noCrouchJump", "1", nil, nil, nil, nil, tobool)
    -- Client gameplay convars — previously only referenced by cl_settings.lua
    -- checkboxes but never explicitly created, so they reset every session.
    vrmod.AddCallbackedConvar("vr_pickup_disable_client", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_weapon_swap", nil, "0")
    vrmod.AddCallbackedConvar("vrmod_deathcam_ragdoll", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_deathcam_ragdoll_view", nil, "1")
    vrmod.AddCallbackedConvar("vrmod_weaponmenu_style", nil, "1")
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

    -- Body spheres sit on the feet->HMD midline, the head sphere on the HMD
    -- itself (same as the server; see VRMod_Bullets).
    local function DrawSDBox(feetZ, hx, hy, spH, bodyScale, headScale, bodyCol, headCol)
        local fx, fy = _dbgC.x, _dbgC.y -- caller leaves the feet x/y here
        for i = 1, 3 do
            local head = i == SD_HEAD
            _dbgC.x = head and hx or (fx + hx) * 0.5
            _dbgC.y = head and hy or (fy + hy) * 0.5
            _dbgC.z = feetZ + spH * SD_BODY[i][1]
            render.DrawWireframeSphere(_dbgC, SD_BODY[i][2] * (head and headScale or bodyScale), 8, 8, head and headCol or bodyCol)
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
                _dbgC.x, _dbgC.y = pp.x, pp.y
                DrawSDBox(pp.z, h.x, h.y, spH, cv_sdScale:GetFloat(), srvScale, COL_BODY, COL_HEAD)
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
                    _dbgC.x, _dbgC.y = pp.x, pp.y
                    DrawSDBox(pp.z, hx, hy, spH, srvScale, srvScale, COL_SBODY, COL_SHEAD)
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

    local cv_selfdmg = CreateConVar("vrmod_selfdamage", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Allow VR players to shoot themselves")

    local _sdAng0 = Angle(0, 0, 0)
    local _sdDmgCache = {} -- ammo type → resolved damage, filled once per type

    -- MP head hitbox: reuse the self-damage HEAD sphere so OTHER players can
    -- shoot a VR player where their HMD actually is (the animated model head
    -- rarely lines up). Replicated so the size is authoritative for everyone.
    local cv_vrhb      = CreateConVar("vrmod_vrhitbox", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "VR players get a tracking-based head hitbox others can shoot in MP", 0, 1)
    local cv_vrhbScale = CreateConVar("vrmod_vrhitbox_scale", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Scale the VR head hitbox radius for ALL players", 0.1, 4)
    local cv_vrhbMult  = CreateConVar("vrmod_vrhitbox_dmgmult", "2", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Damage multiplier for VR head-hitbox hits", 0, 10)
    local cv_sdKnock   = CreateConVar("vrmod_selfdamage_knockback", "0.25", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Self-damage knockback scale, applied along the bullet (0 = none)", 0, 1)

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

    local _bEnd, _bC, _bForce = Vector(), Vector(), Vector()
    local function Hit(ply, victim, data, dir, pt, mult)
        local dmg = DamageInfo()
        dmg:SetAttacker(ply)
        local wep = ply:GetActiveWeapon()
        dmg:SetInflictor(IsValid(wep) and wep or ply)
        dmg:SetDamage(ResolveBulletDamage(data) * mult)
        dmg:SetDamageType(DMG_BULLET)
        dmg:SetDamagePosition(pt)
        local f = data.Force or 1
        _bForce.x, _bForce.y, _bForce.z = dir.x * f, dir.y * f, dir.z * f
        dmg:SetDamageForce(_bForce)
        if victim ~= ply then victim:TakeDamageInfo(dmg) return end
        -- Self hit: the engine's walk knockback ignores the damage force and
        -- aims from the inflictor's centre, and the carried gun doesn't sit
        -- at the hand server-side, so the shove pointed at wherever the
        -- server thought the gun was. Keep its magnitude, scale it, re-aim
        -- it down the bullet (always away from the muzzle).
        local v0 = victim:GetVelocity()
        victim:TakeDamageInfo(dmg)
        if not victim:Alive() then return end
        local v1 = victim:GetVelocity()
        local dx, dy, dz = v1.x - v0.x, v1.y - v0.y, v1.z - v0.z
        local k = (dx * dx + dy * dy + dz * dz) ^ 0.5 * cv_sdKnock:GetFloat()
        v0.x, v0.y, v0.z = v0.x + dir.x * k, v0.y + dir.y * k, v0.z + dir.z * k
        victim:SetLocalVelocity(v0)
    end

    -- ONE EntityFireBullets hook for everything VRMod does to a bullet:
    -- muzzle source, self-damage, the VR head hitbox and seated shots.
    --
    -- They used to be four hooks, and two of them return true to commit
    -- their edits. hook.Call stops at the first non-nil return and the order
    -- is undefined, so whichever committing hook happened to iterate first
    -- silently starved the rest -- self-damage and the head hitbox just never
    -- ran for some sessions. One hook, one fixed order, one return.
    --
    -- Hit test: the nearest sphere along the ray wins, over
    --  * every OTHER VR player's head (vrmod_vrhitbox, the headshot
    --    fallback), and
    --  * the shooter's own body AND head (vrmod_selfdamage). Your head is the
    --    same sphere others shoot -- centre on the HMD, vrmod_vrhitbox_scale,
    --    vrmod_vrhitbox_dmgmult -- so a self headshot counts as a headshot.
    -- The head used to sit on the feet->HMD midline like the body spheres;
    -- with the hull up to ~15u from the headset (locomotion deadzone) that
    -- put a 7u sphere beside your head, and point-blank shots at it missed.
    hook.Add("EntityFireBullets", "VRMod_Bullets", function(ent, data)
        -- Its traces may hit what it holds (sh_pickup_util's ShouldCollide).
        -- Here, not a hook of its own: this one can end the chain.
        ent.vrFiring = true
        -- own = fired by the shooter's held gun: the only bullets whose
        -- source moves to the muzzle (a player-owned SENT keeps its own).
        local ply, own = ent, true
        if not ent:IsPlayer() then
            ply = ent:GetOwner()
            if IsValid(ply) and ply:IsPlayer() then
                own = ply:GetActiveWeapon() == ent
            else
                ply, own = data.Attacker, false
                if not (IsValid(ply) and ply:IsPlayer()) then return end
            end
        end
        local vrd = g_VR[ply:SteamID()]
        -- sh_network keeps muzzlePos nil unless it is a plausible world muzzle.
        -- Moved only for shots from the gun: vrmod.MuzzleBullet.
        local mz = own and vrd and vrd.muzzlePos
        local src, dir, maxD = mz or data.Src, data.Dir, data.Distance or 56756

        local selfOn, hbOn = vrd and cv_selfdmg:GetBool(), cv_vrhb:GetBool()
        if selfOn or hbOn then
            _bEnd.x, _bEnd.y, _bEnd.z = src.x + dir.x * maxD, src.y + dir.y * maxD, src.z + dir.z * maxD
            local headR = SD_BODY[SD_HEAD][2] * cv_vrhbScale:GetFloat()
            local sdScale = selfOn and math.Clamp(ply:GetInfoNum("vrmod_selfdamage_scale", 1), 0.1, 4)
            local best, bestFrac, bestPt, bestHead
            for _, v in ipairs(player.GetHumans()) do
                local isSelf = v == ply
                local vd = (isSelf and selfOn or not isSelf and hbOn) and v:Alive() and (isSelf and vrd or g_VR[v:SteamID()])
                local f = vd and vd.latestFrame
                local hmd = f and f.hmdPos
                if hmd then
                    local pp = v:GetPos()
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
                        -- Others: head only. Self: all three.
                        for i = isSelf and 1 or SD_HEAD, isSelf and 3 or SD_HEAD do
                            local head = i == SD_HEAD
                            if head then
                                _bC.x, _bC.y = hx, hy
                            else
                                _bC.x, _bC.y = (pp.x + hx) * 0.5, (pp.y + hy) * 0.5
                            end
                            _bC.z = pp.z + spH * SD_BODY[i][1]
                            local d, pt, frac = util.DistanceToLine(src, _bEnd, _bC)
                            if d < (head and headR or SD_BODY[i][2] * sdScale) and frac * maxD > 1.5 and (not best or frac < bestFrac) then
                                best, bestFrac, bestPt, bestHead = v, frac, pt, head
                            end
                        end
                    end
                end
            end
            if best then Hit(ply, best, data, dir, bestPt, bestHead and cv_vrhbMult:GetFloat() or 1) end
        end

        local commit = mz and vrmod.MuzzleBullet(data, mz) or false
        -- Seated: don't shoot your own vehicle (or what's welded to it).
        if own and ply:InVehicle() then
            local veh = ply:GetVehicle()
            if IsValid(veh) then
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
                commit = true
            end
        end
        if not commit then return end
        -- Returning true ends the chain, so sv_physhands' hand pass-through
        -- (VRHand_PassBullets) would be starved whenever it iterates after
        -- us: point-blank rounds start inside your own hand prop and die.
        -- It's idempotent, so call it directly.
        local t = hook.GetTable().EntityFireBullets
        local pb = t and t.VRHand_PassBullets
        if pb then pb(ply, data) end
        return true
    end)
end