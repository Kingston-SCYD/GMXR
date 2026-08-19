if CLIENT then
    local LocalPlayer, IsValid, CurTime = LocalPlayer, IsValid, CurTime
    local math_abs, math_sin, math_Clamp = math.abs, math.sin, math.Clamp
    local util_TraceLine = util.TraceLine
    local render_SetMaterial, render_DrawBeam, render_DrawSprite = render.SetMaterial, render.DrawBeam, render.DrawSprite
    -- Beam colour and its brightened hit-glow variant. Both are mutated in
    -- place by UpdateLaserColor so the render path allocates no Color at all
    -- (the old ScaleAlpha built a fresh Color every eye, every frame).
    local laserColor = Color(255, 0, 0, 255)
    local glowColor = Color(255, 0, 0, 255)
    -- Custom laser beam material with vertex color support
    local LaserMaterial = Material("cable/red") -- fallback
    do
        local success, customMat = pcall(CreateMaterial, "CustomLaserMaterial", "UnlitGeneric", {
            ["$basetexture"] = "color/white",
            ["$additive"] = "1", -- Glowing effect
            ["$vertexcolor"] = "1", -- Use per-vertex color
            ["$vertexalpha"] = "1", -- Use per-vertex alpha
            ["$nocull"] = "1", -- Make it visible from both sides
            ["$ignorez"] = "0", -- Depth-aware (optional)
        })

        if success and customMat then LaserMaterial = customMat end
    end

    -- Glow sprite material
    local GlowSprite = Material("sprites/glow04_noz")
    -- Update laserColor from convar string
    local function UpdateLaserColor(colorString)
        local r, g, b, a = string.match(colorString, "(%d+),(%d+),(%d+),(%d+)")
        if not a then return end
        r, g, b, a = tonumber(r), tonumber(g), tonumber(b), tonumber(a)
        laserColor.r, laserColor.g, laserColor.b, laserColor.a = r, g, b, a
        glowColor.r, glowColor.g, glowColor.b, glowColor.a = r, g, b, math_Clamp(a * 1.2, 0, 255)
    end

    -- ConVar listener for dynamic updates
    vrmod.AddCallbackedConvar("vrmod_laser_color", nil, "255,0,0,255", nil, "", nil, nil, nil, function(newValue) UpdateLaserColor(newValue) end)
    -- Reused trace in/out tables: TraceLine writes into `output` and returns
    -- it, so a steady-state frame allocates nothing here either.
    local trOut = {}
    local trIn = {
        output = trOut
    }

    -- Beam + glow rendering
    local function drawLaser(bDepth, bSkybox)
        -- The depth and skybox passes render the beam again for nothing; the
        -- 3D skybox pass draws it at skybox scale, which is where the stray
        -- oversized beam came from.
        if bDepth or bSkybox then return end
        local muzzle = g_VR.viewModelMuzzle
        if not muzzle or g_VR.menuFocus then return end
        local ply = LocalPlayer()
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) then return end
        -- viewModelInfo only holds classes that have a config entry. Every
        -- other weapon indexed nil here, which is the crash -- worldmodel
        -- weapons (wm_base children, forced-WM classes) never have an entry
        -- yet still publish a viewModelMuzzle, so they hit it every frame.
        local vmi = g_VR.viewModelInfo
        vmi = vmi and vmi[wep:GetClass()]
        if vmi and vmi.noLaser then return end
        local startPos = muzzle.Pos
        -- Forward() allocates; Mul/Add reuse it instead of allocating two more.
        local endPos = muzzle.Ang:Forward()
        endPos:Mul(10000)
        endPos:Add(startPos)
        trIn.start = startPos
        trIn.endpos = endPos
        trIn.filter = ply
        util_TraceLine(trIn)
        -- Draw laser beam (flicker width inlined -- one call site)
        render_SetMaterial(LaserMaterial)
        render_DrawBeam(startPos, trOut.HitPos, 0.05 + math_abs(math_sin(CurTime() * 40)) * 0.05, 0, 1, laserColor)
        -- Draw muzzle glow (slightly smaller)
        render_SetMaterial(GlowSprite)
        render_DrawSprite(startPos, 1, 1, laserColor)
        -- Draw hit glow if beam hits something
        if trOut.Hit then render_DrawSprite(trOut.HitPos + trOut.HitNormal, 8, 8, glowColor) end
    end

    local function setLaserEnabled(enabled)
        if enabled then
            hook.Add("PostDrawTranslucentRenderables", "vr_laserpointer", drawLaser)
        else
            hook.Remove("PostDrawTranslucentRenderables", "vr_laserpointer")
        end

        -- Persist state in convar
        RunConsoleCommand("vrmod_laserpointer", enabled and "1" or "0")
    end

    -- Console command to toggle laser
    concommand.Add("vrmod_togglelaserpointer", function() setLaserEnabled(not GetConVar("vrmod_laserpointer"):GetBool()) end)
    -- Activate laser if convar is set on VR start
    hook.Add("VRMod_Start", "laserOn", function()
        timer.Simple(0.1, function()
            if GetConVar("vrmod_laserpointer"):GetBool() then setLaserEnabled(true) end
            -- Force update laser color from current convar value
            local cv = GetConVar("vrmod_laser_color")
            if cv then UpdateLaserColor(cv:GetString()) end
        end)
    end)

    -- Beam must not survive the session: viewModelMuzzle is left stale on exit.
    hook.Add("VRMod_Exit", "vr_laserpointer_exit", function(ply)
        if ply == LocalPlayer() then hook.Remove("PostDrawTranslucentRenderables", "vr_laserpointer") end
    end)
end