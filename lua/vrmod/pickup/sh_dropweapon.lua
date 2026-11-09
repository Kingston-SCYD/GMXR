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
    -- The dropped worldmodel goes where the gun was drawn. The client sends
    -- the pose of the gun's R_Hand bone as it drew it (GripPose, below);
    -- the server rebuilds the model origin around it the way Source's own
    -- Weapon_Drop does: bone pose * inverse(the bone's pose in the model).
    -- The old spawn came off the server's hand -- a network frame late and
    -- extrapolated a frame ahead, so a throw landed well out -- pushed along
    -- the server's R_Hand bone, which on the server is the idle animation's,
    -- not the VR hand's. A left-hand gun got the right bone's offset, and
    -- in worldmodel mode is bone-shifted client-side where the server can't
    -- follow at all. Trusted within 72u of the server's hand, and never
    -- past a wall between the eyes and the grip.
    local R_HAND, DROP_R2 = "ValveBiped.Bip01_R_Hand", 72 * 72
    local trOut = {}
    local trD = {mask = MASK_SOLID_BRUSHONLY, output = trOut}
    local WorldToLocal, LocalToWorld = WorldToLocal, LocalToWorld
    net.Receive("DropWeapon", function(_, ply)
        local left = net.ReadBool()
        local rp, ra = net.ReadVector(), net.ReadAngle()
        local rhandvel, rhandangvel = net.ReadVector(), net.ReadVector()
        local shouldStrip = net.ReadBool()
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) or wep.undroppable or ply:InVehicle() then return end
        local class = wep:GetClass()
        if InBlackList(class) then return end
        local hp, ha = vrmod.utils.GetHandTransform(ply, left)
        if not (hp and rp:DistToSqr(hp) <= DROP_R2) then -- NaN fails too
            if not hp then return end
            rp, ra = hp, Angle(ha.p, ha.y, ha.r + 180) -- R_Hand = hand rolled 180
        end
        trD.start, trD.endpos = ply:EyePos(), rp
        util.TraceLine(trD)
        local shift = trOut.Hit and trOut.HitPos + trOut.HitNormal * 2 - rp
        local dropEnt = ents.Create(class)
        if not IsValid(dropEnt) then return end
        dropEnt:SetModel(wep:GetModel())
        local pos, ang = rp, ra
        local m = dropEnt:GetBoneMatrix(dropEnt:LookupBone(R_HAND) or 0)
        if m then
            local lp, la = WorldToLocal(m:GetTranslation(), m:GetAngles(), dropEnt:GetPos(), dropEnt:GetAngles())
            lp, la = WorldToLocal(vector_origin, angle_zero, lp, la)
            pos, ang = LocalToWorld(lp, la, rp, ra)
        end
        if shift then pos = pos + shift end -- rp may be the hand's live pose

        -- Restore some ammo into dropped weapon if applicable
        local ammoType = wep:GetPrimaryAmmoType()
        local ammoCount = ply:GetAmmoCount(ammoType)
        local clipSize = wep:GetMaxClip1()
        local currentClip = wep:Clip1()
        if ammoCount > 0 and currentClip < clipSize then
            local ammoToGive = math.min(clipSize - currentClip, ammoCount)
            wep:SetClip1(currentClip + ammoToGive)
            ply:RemoveAmmo(ammoToGive, ammoType)
        end

        -- ── ArcticVR ammo stasis ─────────────────────────────────────────────
        local avrSnapshot = nil
        if wep.ArcticVR then
            avrSnapshot = {
                LoadedRounds = wep.LoadedRounds or 0,
                Chambered = wep.Chambered or 0,
                Magazine = wep.Magazine, -- may be nil (no mag inserted)
            }
            if debug_arcvr:GetBool() then
                print("[VRMod ArcVR Debug] Dropping weapon: " .. class)
                print("[VRMod ArcVR Debug] Stamping - LoadedRounds: " .. tostring(avrSnapshot.LoadedRounds) .. " Chambered: " .. tostring(avrSnapshot.Chambered) .. " Mag: " .. tostring(avrSnapshot.Magazine))
            end

            -- CLEAR the active weapon so it doesn't drop a physical magazine when stripped!
            wep.Magazine = nil
            wep.LoadedRounds = 0
            wep.Chambered = 0
        end

        -- ─────────────────────────────────────────────────────────────────────
        local empty = ply:GetWeapon("weapon_vrmod_empty")
        if not IsValid(empty) then empty = ply:Give("weapon_vrmod_empty") end
        ply:SelectWeapon("weapon_vrmod_empty")
        dropEnt:SetPos(pos)
        dropEnt:SetAngles(ang)
        dropEnt:Spawn()
        -- Carry the clip across: without this the spawned entity keeps the SWEP
        -- default (-1 on anything never deployed), so picking your own gun back
        -- up as a duplicate handed back no ammo at all.
        dropEnt:SetClip1(wep:Clip1())
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

        if shouldStrip then
            -- Double-check: don't strip if a DW ghost of the same class exists.
            local dw = ply._dw
            if not (dw and dw.active and dw.class == class) then
                -- Delayed-holster bases (ArcCW/ARC9/TacRP) are still active
                -- here, mid holster anim. Stripping the active weapon makes
                -- the engine switch to the next best one, so the empty hand
                -- takes over first; SetActiveWeapon skips Deploy, so the
                -- viewmodel is pointed at it too.
                if IsValid(empty) and ply:GetActiveWeapon() ~= empty then
                    ply:SetActiveWeapon(empty)
                    local vm = ply:GetViewModel()
                    if IsValid(vm) then vm:SetWeaponModel(empty:GetWeaponViewModel(), empty) end
                end
                ply:StripWeapon(class)
            end
        elseif avrSnapshot and IsValid(wep) then
            -- Not stripping — weapon stays in inventory for other copies (holster/DW).
            -- Restore the snapshot so the inventory entity isn't left zeroed.
            wep.LoadedRounds = avrSnapshot.LoadedRounds
            wep.Chambered    = avrSnapshot.Chambered
            wep.Magazine     = avrSnapshot.Magazine
        end
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

    -- Where the held gun's R_Hand bone is as drawn: the server rebuilds the
    -- dropped worldmodel around it. Worldmodel mode: the weapon's own
    -- bonemerged bone, after sh_lefthand's left-hand shift. Viewmodel mode:
    -- the viewmodel is hand * vmi offset in either hand (mirrored for the
    -- left), so undoing the offset gives the hand the gun sits in, and
    -- cl_character's R_Hand is that hand rolled 180.
    local R180, R_HAND = Angle(0, 0, 180), "ValveBiped.Bip01_R_Hand"
    local WorldToLocal, LocalToWorld = WorldToLocal, LocalToWorld
    local function GripPose(left)
        local vm = g_VR.viewModel
        if g_VR.wmActive and IsValid(vm) then
            local m = vm:GetBoneMatrix(vm:LookupBone(R_HAND) or 0)
            if m then return m:GetTranslation(), m:GetAngles() end
        end
        local pos, ang = g_VR.viewModelPos, g_VR.viewModelAng
        local vmi = g_VR.currentvmi
        if vmi then
            local ip, ia = WorldToLocal(vector_origin, angle_zero, vmi.offsetPos, vmi.offsetAng)
            pos, ang = LocalToWorld(ip, ia, pos, ang)
        end
        return LocalToWorld(vector_origin, R180, pos, ang)
    end

    -- Every weapon drop (release, left release, full holster slot). Strips
    -- the class only when no other copy exists (holster slot or other hand).
    function vrmod.SendWeaponDrop(left)
        local ply = LocalPlayer()
        local wpn = ply:GetActiveWeapon()
        if not IsValid(wpn) then return end
        local hs = vrmod_holster
        local p, a = GripPose(left)
        net.Start("DropWeapon")
        net.WriteBool(left)
        net.WriteVector(p)
        net.WriteAngle(a)
        net.WriteVector((left and vrmod.GetLeftHandVelocity or vrmod.GetRightHandVelocity)() * 2.5)
        net.WriteVector((left and vrmod.GetLeftHandAngularVelocity or vrmod.GetRightHandAngularVelocity)() * 2.5)
        net.WriteBool(not (hs and hs.CountWeapon) or hs.CountWeapon(wpn:GetClass()) <= 1)
        net.SendToServer()
    end

    local function DoDrop()
        if not dropenable:GetBool() or g_VR.antiDrop then return end
        local gf = vrmod_gripfix
        if gf and (gf.repos or gf.suppressDrop) then gf.suppressDrop = nil return end
        -- If the right hand is inside a holster zone, the holster system
        -- will handle storage; do not send the drop net message.
        local hs = vrmod_holster
        if hs and (hs.IsHandInHolster(false) or hs.IsStoreSuppressed and hs.IsStoreSuppressed(false)) then return end
        vrmod.SendWeaponDrop(false)
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