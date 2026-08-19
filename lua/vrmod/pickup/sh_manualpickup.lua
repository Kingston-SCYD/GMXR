local vrmod_manualpickup = CreateConVar("vrmod_manualpickups", 1, {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "vrmod manual pickup toggle")
local debug_arcvr = CreateConVar("vrmod_debug_arcvr_ammo", "0", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Debug ArcticVR ammo stasis")
local arcvr_always_loaded = CreateConVar("vrmod_arcvr_always_loaded", "0", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "If 1, picking up an ArcVR weapon will always fully load it with its default magazine.")

-- Per-player states
local PickupDisabled = {}
local PickupDisabledWeapons = {}

-- Initialize pickup states on spawn
hook.Add("PlayerSpawn", "SpawnSetPickupState", function(ply)
	local id = ply:EntIndex()
	PickupDisabled[id] = true
	PickupDisabledWeapons[id] = true
end)

-- Set player as VR when entering VRMod
hook.Add("VRMod_Start", "VRModPickupStartState", function(ply)
	ply:SetNWBool("IsVR", true)
	local id = ply:EntIndex()
	PickupDisabled[id] = true
	PickupDisabledWeapons[id] = true
end)

-- Clear VR state when exiting VRMod
hook.Add("VRMod_Exit", "VRModPickupResetState", function(ply)
	ply:SetNWBool("IsVR", false)
	local id = ply:EntIndex()
	PickupDisabled[id] = nil
	PickupDisabledWeapons[id] = nil
end)

-- Fix VR state loss after respawn
timer.Create("VRModManualPickup_RespawnFixTimer", 1, 0, function()
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() and ply:GetNWBool("IsVR", false) then
			local id = ply:EntIndex()
			if PickupDisabled[id] == nil then
				PickupDisabled[id] = true
				PickupDisabledWeapons[id] = true
			end
		end
	end
end)

-- Handle item drop to allow manual pickup
hook.Add("VRMod_Drop", "ManualItemPickupDropHook", function(ply, ent)
	if not IsValid(ent) then return end
	if ent:GetClass() == "prop_physics" then return end
	local id = ply:EntIndex()
	PickupDisabled[id] = false
	PickupDisabledWeapons[id] = false
	timer.Simple(0.3, function()
		if IsValid(ply) then
			PickupDisabled[id] = true
			PickupDisabledWeapons[id] = true
		end
	end)
end)

-- Handle weapon pickup by hand
hook.Add("VRMod_Pickup", "ManualWeaponPickupHook", function(ply, ent)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	if not IsValid(ent) or not ent:IsWeapon() then return end
	if not ply.PickupWeapon then return end

-- ── ArcticVR ammo stasis ─────────────────────────────────────────────────
	local avrState = nil
	local ignoreStasis = arcvr_always_loaded:GetBool()
	
	if SERVER and ent.VRMod_ArcVR_Stasis ~= nil then
		if not ignoreStasis then
			avrState = {
				LoadedRounds = ent.VRMod_ArcVR_Stasis.LoadedRounds,
				Chambered    = ent.VRMod_ArcVR_Stasis.Chambered or 0,
				Magazine     = ent.VRMod_ArcVR_Stasis.Magazine,      -- may be nil
			}
			
			if debug_arcvr:GetBool() then
				print("[VRMod ArcVR Debug] Picked up weapon: " .. ent:GetClass())
				print("[VRMod ArcVR Debug] Read Stamped State - LoadedRounds: " .. tostring(avrState.LoadedRounds) .. " Chambered: " .. tostring(avrState.Chambered) .. " Mag: " .. tostring(avrState.Magazine))
			end
		else
			if debug_arcvr:GetBool() then
				print("[VRMod ArcVR Debug] Picked up weapon: " .. ent:GetClass() .. " (IGNORING STASIS - Always Loaded is ON)")
			end
		end

		-- Clear these to prevent ArcVR from spawning a floating magazine on Remove()
		ent.LoadedRounds = 0
		ent.Chambered = 0
		ent.Magazine = nil
	end

	-- ─────────────────────────────────────────────────────────────────────────
	local wepClass = ent:GetClass()
	-- Temporarily disable pickup protection
	hook.Call("VRMod_Drop", nil, ply, ent)
	-- Try to replace with VR weapon
	local replacement = vrmod.utils.ReplaceWeapon and vrmod.utils.ReplaceWeapon(ply, ent)
	if replacement then wepClass = replacement end
	
local isDuplicate = ply:HasWeapon(wepClass)
     if SERVER and ArcticVR and ArcticVR.InterceptPickup then
         if ArcticVR.InterceptPickup(ply, ent, wepClass, isDuplicate, avrState) then
             
             -- Release from x64 pickup system so DW can take over
             if IsValid(ent) then
                 local sid = ply:SteamID()
                 if g_VR[sid] and g_VR[sid].heldItems then
                     for slot = 1, 2 do
                         local held = g_VR[sid].heldItems[slot]
                         if held and held.ent == ent then
                             pcall(vrmod.Drop, sid, held.left)
                             break
                         end
                     end
                 end
             end
             return
         end
     end


if isDuplicate then
    local ammoType = ent:GetPrimaryAmmoType()
    if ammoType < 0 then
        local p = ent.Primary
        ammoType = p and p.Ammo and game.GetAmmoID(p.Ammo) or -1
    end

    if avrState then
        -- Restore stasis directly to the existing weapon's ArcVR fields.
        -- Do NOT GiveAmmo — that adds to reserve on top of existing rounds,
        -- causing infinite ammo on every holster grab cycle.
        local existingWep = ply:GetWeapon(wepClass)
        if IsValid(existingWep) and existingWep.ArcticVR then
            existingWep.LoadedRounds = avrState.LoadedRounds
            existingWep.Chambered    = avrState.Chambered
            existingWep.Magazine     = avrState.Magazine
            if existingWep.SendWeapon then existingWep:SendWeapon(true, true) end
        end
    elseif ammoType >= 0 then
        -- Clip1() is -1 on a weapon entity that was never deployed -- spawnmenu
        -- dupes and ents.Create both -- so the old `clip > 0` test silently gave
        -- nothing on the two paths that actually matter. Fall back to whatever
        -- the SWEP declares it ships with.
        local clip = ent:Clip1()
        if clip < 0 then
            local p = ent.Primary
            clip = p and (p.DefaultClip or p.ClipSize) or ent:GetMaxClip1()
        end
        if clip and clip > 0 then ply:GiveAmmo(clip, ammoType, true) end
    end

    ply:SelectWeapon(wepClass)
	else
		ply:Give(wepClass, true)
		timer.Simple(0, function() if IsValid(ply) then ply:SelectWeapon(wepClass) end end)
	end

	ent:Remove()

	-- ── ArcticVR ammo stasis restore ─────────────────────────────────────────
	if SERVER and not isDuplicate then
		timer.Simple(0, function()
			if not IsValid(ply) then return end
			local newWep = ply:GetWeapon(wepClass)
			
			if IsValid(newWep) then
				if debug_arcvr:GetBool() then
					print("[VRMod ArcVR Debug] Restoring to new weapon: " .. wepClass)
				end
				
				if newWep.ArcticVR or newWep.LoadedRounds ~= nil then
					if ignoreStasis then
						-- Force the weapon to be fully loaded with its default magazine
						local defMag = newWep.DefaultMagazine
						if defMag and ArcticVR and ArcticVR.MagazineTable and ArcticVR.MagazineTable[defMag] then
							newWep.Magazine = defMag
							newWep.LoadedRounds = ArcticVR.MagazineTable[defMag].Capacity or 0
							newWep.Chambered = 1
							if debug_arcvr:GetBool() then
								print("[VRMod ArcVR Debug] Forced Fully Loaded with mag: " .. tostring(defMag))
							end
						end
					elseif avrState then
						newWep.LoadedRounds = avrState.LoadedRounds
						newWep.Chambered = avrState.Chambered
						newWep.Magazine = avrState.Magazine
					end
					
					-- Network sync 1 (Immediately after setup)
					if newWep.SendWeapon then
					    newWep:SendWeapon(true, true)
					end
					
					-- Network sync 2 (Delayed to handle client ping & entity creation)
					local wepID = newWep:EntIndex()
					timer.Create("VRMod_ArcVR_Sync_" .. tostring(wepID), 0.25, 4, function()
					    if IsValid(newWep) and newWep.SendWeapon then
					        newWep:SendWeapon(true, true)
					    end
					end)
					
					if debug_arcvr:GetBool() then
						print("[VRMod ArcVR Debug] Successfully synced ammo state to client over 1s.")
					end
				end
			end
		end)
	end
	-- ─────────────────────────────────────────────────────────────────────────
end)

-- ── Manual item consumption (ammo, health, armor) ────────────────────────
if SERVER then
	hook.Add("VRMod_Pickup", "ManualItemPickupHook", function(ply, ent)
		if not IsValid(ply) or not IsValid(ent) or ent:IsWeapon() then return end
		local class = ent:GetClass()
		if class:sub(1, 5) ~= "item_" and class:sub(1, 5) ~= "ammo_" and class:sub(1, 4) ~= "hl1_" then return end
		if ent.Pickable == false then return end -- HL1 item respawning
		local id = ply:EntIndex()
		PickupDisabled[id] = false
		if ent.Pickup then
			ent:Pickup(ply)
		else
			ent:Use(ply, ply, USE_ON, 1)
		end
		PickupDisabled[id] = true
	end)
end

-- Disable touch-based item pickup
hook.Add("PlayerCanPickupItem", "ItemTouchPickupDisablerVR", function(ply, item)
	local id = ply:EntIndex()
	if vrmod_manualpickup:GetBool() and item:GetClass() ~= "item_suit" and PickupDisabled[id] and ply:GetNWBool("IsVR", false) then return false end
end)

-- Disable touch-based weapon pickup.
--
-- PlayerCanPickupWeapon fires for Player:Give as well as for walking over a
-- weapon, so blocking it unconditionally also rejected every scripted give.
-- SpawnSetPickupState re-arms the block on every PlayerSpawn while the IsVR
-- flag survives death, so respawning in VR had its entire loadout refused --
-- the "dying in VR empties the inventory" bug. Scripted gives are let through
-- via an explicit flag where we can hook the caller, and otherwise by age: a
-- weapon Give creates and equips the entity in the same tick, while a weapon
-- lying on the floor was created at least one tick before you touched it.
local ScriptedGive = {}
local function FlagGive(ply)
	local id = ply:EntIndex()
	ScriptedGive[id] = true
	timer.Simple(0, function() ScriptedGive[id] = nil end)
end

hook.Add("PlayerGiveSWEP", "VRModManualPickup_SpawnFlag", FlagGive)
hook.Add("PlayerLoadout", "VRModManualPickup_LoadoutFlag", FlagGive)

hook.Add("PlayerCanPickupWeapon", "WeaponTouchPickupDisablerVR", function(ply, wep)
	if not vrmod_manualpickup:GetBool() then return end
	if not IsValid(wep) or wep:GetClass() == "weapon_vrmod_empty" then return end
	-- Ahead of every exemption below. A weapon you just threw is both freshly
	-- created (so the give-age test lets it through) and dropped inside the
	-- VRMod_Drop window that clears PickupDisabledWeapons, so it was picked
	-- straight back up off your own hand. Stamped by sh_dropweapon.
	local cd = wep.vrmod_dropCooldown
	if cd then
		if cd > CurTime() then return false end
		wep.vrmod_dropCooldown = nil
	end
	local id = ply:EntIndex()
	if ScriptedGive[id] then return end
	if not PickupDisabledWeapons[id] or not ply:GetNWBool("IsVR", false) then return end
	if CurTime() - wep:GetCreationTime() < 0.05 then return end
	return false
end)

-- ── Visual Debug Overlay ─────────────────────────────────────────────────
if SERVER then
	hook.Add("Think", "VRMod_ArcVR_Debug_FloatingText", function()
		if not debug_arcvr:GetBool() then return end
		
		for _, ent in ipairs(ents.GetAll()) do
			if not IsValid(ent) then continue end
			
			local pos = ent:GetPos() + Vector(0, 0, 15)
			
			if ent.VRMod_ArcVR_Stasis then
				local txt = string.format("STAMPED - Loaded: %d, Chambered: %d, Mag: %s",
					ent.VRMod_ArcVR_Stasis.LoadedRounds or 0,
					ent.VRMod_ArcVR_Stasis.Chambered or 0,
					tostring(ent.VRMod_ArcVR_Stasis.Magazine)
				)
				debugoverlay.Text(pos, txt, 0.1, false)
			elseif ent.ArcticVR and ent.LoadedRounds ~= nil then
				local txt = string.format("ACTIVE - Loaded: %d, Chambered: %d, Mag: %s",
					ent.LoadedRounds or 0,
					ent.Chambered or 0,
					tostring(ent.Magazine)
				)
				debugoverlay.Text(pos + Vector(0, 0, 5), txt, 0.1, false)
			end
		end
	end)
end
-- ─────────────────────────────────────────────────────────────────────────