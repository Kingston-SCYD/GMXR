if SERVER then return end
-- VR halos. GMod's halo pass is screen-space and can't do stereo, so in VR
-- halo.Add feeds a list each eye draws itself. Callers fire from per-view
-- hooks (PreDrawHalos, PostDrawOpaqueRenderables), so the same entity arrives
-- once per view: entries are copied (callers reuse their tables) and deduped
-- per entity, and both eyes draw LAST frame's finished list so they match.
local curEnt, curCol, drawEnt, drawCol, seen = {}, {}, {}, {}, {}
local curN, drawN, curFrame, hooked = 0, 0, -1, false
local haloRT, haloMat, haloAdd_orig
timer.Simple(0, function() haloAdd_orig = halo.Add end)

local function Roll(fn)
	if curFrame == fn - 1 then
		curEnt, drawEnt = drawEnt, curEnt
		curCol, drawCol = drawCol, curCol
		drawN = curN
	else
		drawN = 0 -- nothing collected last frame
	end
	curN, curFrame = 0, fn
	for k in pairs(seen) do seen[k] = nil end
end

local function Draw(depth, sky)
	-- Headset eyes only: not a spectator camera that happens to sit at an
	-- eye, and not monitor views nested inside an eye pass
	if depth or sky or not g_VR.eyeRendering or EyePos() ~= g_VR.view.origin then return end
	local fn = FrameNumber()
	if fn ~= curFrame then Roll(fn) end
	if drawN == 0 then
		if curN == 0 then
			hook.Remove("PostDrawTranslucentRenderables", "vrmod_halos")
			hooked = false
		end
		return
	end
	local w, h = g_VR.view.w, g_VR.view.h
	if not haloRT then
		haloRT = GetRenderTarget("vrmod_halos_" .. w .. "x" .. h, w, h)
		if haloMat then
			haloMat:SetTexture("$basetexture", haloRT)
		else
			haloMat = CreateMaterial("vrmod_halosMat", "UnlitGeneric", { ["$basetexture"] = haloRT:GetName() })
		end
	end
	render.PushRenderTarget(haloRT)
	render.Clear(0, 0, 0, 255, true, true)
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(0xFF)
	render.SetStencilTestMask(0xFF)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
	render.SetStencilReferenceValue(1)
	for i = 1, drawN do
		local v = drawEnt[i]
		if IsValid(v) then
			render.ClearStencil()
			render.SetStencilPassOperation(STENCIL_REPLACE)
			render.SetStencilCompareFunction(STENCIL_ALWAYS)
			v:DrawModel()
			render.SetStencilPassOperation(STENCIL_KEEP)
			render.SetStencilCompareFunction(STENCIL_EQUAL)
			local c = drawCol[i]
			render.ClearBuffersObeyStencil(c.r, c.g, c.b, 255, false)
		end
	end
	render.SetStencilEnable(false)
	render.BlurRenderTarget(haloRT, 2, 2, 1)
	render.SetStencilEnable(true)
	render.ClearBuffersObeyStencil(0, 0, 0, 255, false)
	render.SetStencilEnable(false)
	render.PopRenderTarget()
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD, 0, 0, 0)
	render.OverrideDepthEnable(true, false)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(haloMat)
	surface.DrawTexturedRect(0, 0, w, h)
	surface.DrawTexturedRect(0, 0, w, h)
	render.OverrideDepthEnable(false)
	render.OverrideBlend(false)
	cam.End2D()
end

local function Add(ents, color)
	local fn = FrameNumber()
	if fn ~= curFrame then Roll(fn) end
	for _, e in pairs(ents) do
		if not seen[e] then
			seen[e] = true
			curN = curN + 1
			curEnt[curN], curCol[curN] = e, color
		end
	end
	if not hooked then
		hooked = true
		hook.Add("PostDrawTranslucentRenderables", "vrmod_halos", Draw)
	end
end

hook.Add("VRMod_Start", "halos", function(ply)
	if ply == LocalPlayer() then halo.Add = Add end
end)

hook.Add("VRMod_Exit", "halos", function(ply)
	if ply ~= LocalPlayer() then return end
	halo.Add = haloAdd_orig
	hook.Remove("PostDrawTranslucentRenderables", "vrmod_halos")
	hooked, curN, drawN, curFrame, haloRT = false, 0, 0, -1, nil
	for k in pairs(seen) do seen[k] = nil end
end)