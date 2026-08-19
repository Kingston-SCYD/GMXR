local blacklist_path = "vrmod/vrmod_drop_blacklist.txt"
-- Shared blacklist check
local function InBlackList(weaponClass)
    if weaponClass == "weapon_vrmod_empty" then return true end
    if not file.Exists(blacklist_path, "DATA") then return false end
    local content = file.Read(blacklist_path, "DATA") or ""
    for line in string.gmatch(content, "[^\r\n]+") do
        if string.Trim(line) == weaponClass then return true end
    end
    return false
end

if SERVER then
    local debug_arcvr = CreateConVar("vrmod_debug_arcvr_ammo", "0", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Debug ArcticVR ammo stasis")

    -- Create blacklist file with defaults if missing
    if not file.Exists(blacklist_path, "DATA") then
        local default_blacklist = {"weapon_fists", "piss_swep", "weapon_bsmod_punch", "weapon_vrmod_empty", "weapon_haax_vr", "alex_matrix_stopbullets", "blink", "spartan_kick", "arcticvr_nade_frag", "arcticvr_nade_flash", "arcticvr_nade_smoke"}
        file.Write(blacklist_path, table.concat(default_blacklist, "\n"))
    end

    util.AddNetworkString("ChangeWeapon")
    util.AddNetworkString("DropWeapon")
    util.AddNetworkString("SelectEmptyWeapon")
    net.Receive("ChangeWeapon", function(_, ply)
        local weaponClass = net.ReadString()
        if weaponClass and isstring(weaponClass) then ply:SelectWeapon(weaponClass) end
    end)

    net.Receive("SelectEmptyWeapon", function(_, ply) ply:SelectWeapon("weapon_vrmod_empty") end)
    net.Receive("DropWeapon", function(_, ply)
        local dropAsWeapon = net.ReadBool()
        local rhandvel = net.ReadVector()
        local rhandangvel = net.ReadVector()
        local shouldStrip = net.ReadBool()
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) or wep.undroppable or ply:InVehicle() or InBlackList(wep:GetClass()) then return end
        local modelname = wep:GetModel()
        local guninhandpos, guninhandang
        if false then
            guninhandpos = vrmod.GetLeftHandPos(ply)
            guninhandang = vrmod.GetLeftHandAng(ply)
        else
            guninhandpos = vrmod.GetRightHandPos(ply)
            guninhandang = vrmod.GetRightHandAng(ply)
        end
        local dropEnt
        if dropAsWeapon then
            dropEnt = ents.Create(wep:GetClass())
        else
            dropEnt = ents.Create("prop_physics")
        end

        -- Restore some ammo into dropped weapon if applicable
        local ammoType = wep:GetPrimaryAmmoType()
        local ammoCount = ply:GetAmmoCount(ammoType)
        local clipSize = wep:GetMaxClip1()
        local currentClip = wep:Clip1()
        if ammoCount > 0 and currentClip < clipSize then
            local ammoNeeded = clipSize - currentClip
            local ammoToGive = math.min(ammoNeeded, ammoCount)
            wep:SetClip1(currentClip + ammoToGive)
            ply:RemoveAmmo(ammoToGive, ammoType)
        end

        -- ── ArcticVR ammo stasis ─────────────────────────────────────────────
        local avrSnapshot = nil
        if dropAsWeapon and wep.ArcticVR then
            avrSnapshot = {
                LoadedRounds = wep.LoadedRounds or 0,
                Chambered = wep.Chambered or 0,
                Magazine = wep.Magazine, -- may be nil (no mag inserted)
            }
            if debug_arcvr:GetBool() then
                print("[VRMod ArcVR Debug] Dropping weapon: " .. wep:GetClass())
                print("[VRMod ArcVR Debug] Stamping - LoadedRounds: " .. tostring(avrSnapshot.LoadedRounds) .. " Chambered: " .. tostring(avrSnapshot.Chambered) .. " Mag: " .. tostring(avrSnapshot.Magazine))
            end

            -- CLEAR the active weapon so it doesn't drop a physical magazine when stripped!
            wep.Magazine = nil
            wep.LoadedRounds = 0
            wep.Chambered = 0
        end

        -- ─────────────────────────────────────────────────────────────────────
        ply:Give("weapon_vrmod_empty")
        ply:SelectWeapon("weapon_vrmod_empty")
        local boneID = ply:LookupBone("ValveBiped.Bip01_R_Hand")
        local boneAng = boneID and select(2, ply:GetBonePosition(boneID)) or guninhandang
        dropEnt:SetModel(modelname)
        dropEnt:SetPos(guninhandpos + boneAng:Forward() * 10 + boneAng:Right() * 4)
        dropEnt:SetAngles(guninhandang)
        dropEnt:Spawn()
        -- Carry the clip across: without this the spawned entity keeps the SWEP
        -- default (-1 on anything never deployed), so picking your own gun back
        -- up as a duplicate handed back no ammo at all.
        if dropAsWeapon then dropEnt:SetClip1(wep:Clip1()) end
        -- Block touch pickup on what we just threw. It spawns inside the
        -- player's hull and PlayerCanPickupWeapon exempts anything younger than
        -- a tick as a scripted give, so it was grabbed straight back.
        dropEnt.vrmod_dropCooldown = CurTime() + 1
        local phys = dropEnt:GetPhysicsObject()
        if IsValid(phys) then
            phys:Wake()
            phys:SetMass(99)
            phys:SetVelocity(ply:GetVelocity() + rhandvel)
            phys:AddAngleVelocity(-phys:GetAngleVelocity() + phys:WorldToLocalVector(rhandangvel))
        end

        -- Stamp the ArcVR snapshot onto the spawned world entity.
        if avrSnapshot then
            dropEnt.VRMod_ArcVR_Stasis = avrSnapshot
            dropEnt.AVR_LoadedRounds   = avrSnapshot.LoadedRounds
            dropEnt.AVR_Chambered      = avrSnapshot.Chambered
            dropEnt.AVR_Magazine       = avrSnapshot.Magazine
        end

        if dropAsWeapon and shouldStrip then
            -- Double-check: don't strip if a DW ghost of the same class exists.
            local dwSafe = not (ply._dw and ply._dw.active and ply._dw.class == wep:GetClass())
            if dwSafe then ply:StripWeapon(wep:GetClass()) end
        elseif avrSnapshot and IsValid(wep) then
            -- Not stripping — weapon stays in inventory for other copies (holster/DW).
            -- Restore the snapshot so the inventory entity isn't left zeroed.
            wep.LoadedRounds = avrSnapshot.LoadedRounds
            wep.Chambered    = avrSnapshot.Chambered
            wep.Magazine     = avrSnapshot.Magazine
        end
        timer.Simple(3, function() if IsValid(dropEnt) and dropEnt:GetClass() == "prop_physics" then dropEnt:Remove() end end)
    end)

    concommand.Add("vrmod_toggle_blacklist", function(ply)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) then
            ply:ChatPrint("[VRMod] No active weapon to toggle in blacklist.")
            return
        end

        local class = wep:GetClass()
        local lines = {}
        if file.Exists(blacklist_path, "DATA") then
            for line in string.gmatch(file.Read(blacklist_path, "DATA") or "", "[^\r\n]+") do
                table.insert(lines, string.Trim(line))
            end
        end

        for i, v in ipairs(lines) do
            if v == class then
                table.remove(lines, i)
                file.Write(blacklist_path, table.concat(lines, "\n"))
                ply:ChatPrint("[VRMod] Removed '" .. class .. "' from blacklist.")
                return
            end
        end

        table.insert(lines, class)
        file.Write(blacklist_path, table.concat(lines, "\n"))
        ply:ChatPrint("[VRMod] Added '" .. class .. "' to blacklist.")
    end)
end

hook.Add("WeaponEquip", "VRMod_ArcVR_RestoreStasis", function(wep, ply)
        -- Check if the weapon has a saved stasis snapshot
        if IsValid(wep) and wep.ArcticVR and wep.VRMod_ArcVR_Stasis then
            -- Restore the magazine and ammo variables
            wep.Magazine = wep.VRMod_ArcVR_Stasis.Magazine
            wep.LoadedRounds = wep.VRMod_ArcVR_Stasis.LoadedRounds
            wep.Chambered = wep.VRMod_ArcVR_Stasis.Chambered
            
            -- Clear the stasis so it doesn't trigger again
            wep.VRMod_ArcVR_Stasis = nil 

            -- Delay the sync slightly to ensure the weapon is fully equipped by the player
            timer.Simple(0.1, function()
                if IsValid(wep) and wep.SendWeapon then
                    -- The 'true' argument forces a full sync of the magazine state to the client
                    wep:SendWeapon(false, true) 
                end
            end)
        end
    end)

if CLIENT then
    local dropenable = CreateClientConVar("vrmod_weapondrop_enable", 1, true, FCVAR_ARCHIVE, "", 0, 1)
    local droprelease = CreateClientConVar("vrmod_weapondrop_release", 40, true, FCVAR_ARCHIVE, "Grip % below which the held weapon drops (5 = must let go almost fully, 90 = hair trigger)", 5, 90)

    -- Only strip from inventory if no other copy exists (holster slot or other hand).
    local function ShouldStripOnDrop()
        local ply = LocalPlayer()
        if not IsValid(ply) then return true end
        local wpn = ply:GetActiveWeapon()
        if not IsValid(wpn) then return true end
        if not vrmod_holster or not vrmod_holster.CountWeapon then return true end
        return vrmod_holster.CountWeapon(wpn:GetClass()) <= 1
    end

    local function DoDrop()
        if not dropenable:GetBool() or g_VR.antiDrop then return end
        local gf = vrmod_gripfix
        if gf and (gf.repos or gf.suppressDrop) then gf.suppressDrop = nil return end
        -- If the right hand is inside a holster zone, the holster system
        -- will handle storage; do not send the drop net message.
        local hs = vrmod_holster
        if hs and (hs.IsHandInHolster(false) or hs.IsStoreSuppressed and hs.IsStoreSuppressed(false)) then return end
        net.Start("DropWeapon")
        net.WriteBool(true)
        net.WriteVector(vrmod.GetRightHandVelocity() * 2.5)
        net.WriteVector(vrmod.GetRightHandAngularVelocity() * 2.5)
        net.WriteBool(ShouldStripOnDrop())
        net.SendToServer()
    end

    -- Analog release threshold: while squeeze data exists, this owns dropping.
    -- Arm when grip climbs past threshold + 0.1 hysteresis; drop the moment it
    -- falls back below threshold. vrmod_weapondrop_release is a percent (5-90).
    local armed = false
    hook.Add("Think", "VRMod_WeaponDropAnalog", function()
        if not g_VR.active then armed = false return end
        local inp = g_VR.input
        local grip = inp and tonumber(inp.vector1_right_squeeze)
        if not grip then return end
        local thresh = droprelease:GetInt() * 0.01
        if armed then
            if grip < thresh then
                armed = false
                DoDrop()
            end
        elseif grip >= (thresh > 0.85 and 0.95 or thresh + 0.1) then
            armed = true
        end
    end)

    hook.Add("VRMod_Input", "Weapon_Drop", function(action, state)
        if action ~= "boolean_right_pickup" or state then return end
        -- Fallback only: analog path above handles controllers with squeeze data
        local inp = g_VR.input
        if inp and tonumber(inp.vector1_right_squeeze) then return end
        DoDrop()
    end)
end