if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")

local Trove                  = require(ReplicatedStorage.Packages.Trove)
local EventController        = require(ReplicatedStorage.Controllers.EventController)
local NotificationController = require(ReplicatedStorage.Controllers.NotificationController)

local EVENT_NAME  = "North Pole"
local LocalPlayer = Players.LocalPlayer

local TRAIN_SPEED          = 150
local CUTSCENE_DURATION    = 5
local BOARDING_WINDOW      = 10
local MAX_GIFTS            = 10
local CONVEYOR_SPEED       = 10
local CONVEYOR_BR_SIZE     = 6
local ELF_WALK_SPEED       = 10
local ELF_ATTACK_INTERVAL  = 30
local ELF_ATTACK_RANGE     = 14
local ELF_DOOR_OUT         = 10
local ELF_DOOR_ANIM        = 0.45
local ELF_CHASE_TIME       = 10
local ELF_TURN_SPEED       = 8
local SANTA_HEIGHT         = 200
local SANTA_SPEED          = 70
local SANTA_BOB            = 3
local SANTA_ARRIVE_TIME    = 10
local SNOW_DROP_INTERVAL   = 5
local SNOW_PRESENT_FALL    = 5
local SNOW_PRESENT_LIFETIME = 180
local BRAINROT_LIST = {
    "Cocoa Assassino",
    "Ballerina Peppermintina",
    "Giftini Spyderini",
    "Naughty Naughty",
    "Festive Lucky Block",
}

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove     = Trove.new()
local isActive       = true
local northPoleMap   = nil
local activeTrain    = nil
local deliveredGifts = 0
local sleighFull     = false
local activeElf      = nil
local snowSanta      = nil
local snowGifts      = {}
local snowGeneration = 0
local grabbableItems = {}
local boardedPlayers = {}

-- ─── Asset loading ────────────────────────────────────────────────────────────

local function loadMap()
    local obj = game:GetObjects("rbxassetid://113790446555299")[1]
    if obj then
        obj.Name   = "MainNorthPoleMap"
        obj.Parent = workspace
        northPoleMap = obj
    end
end

local function loadTrain()
    local obj = game:GetObjects("rbxassetid://85773105247523")[1]
    if obj then
        obj.Name   = "BrainrotExpress"
        obj.Parent = workspace
        activeTrain = obj
    end
end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local poleGroundParams = nil
local function snapToPoleGround(position)
    if not northPoleMap then return CFrame.new(position + Vector3.new(0, 4, 0)) end
    if not poleGroundParams then
        poleGroundParams = RaycastParams.new()
        poleGroundParams.FilterType = Enum.RaycastFilterType.Include
        poleGroundParams.IgnoreWater = true
        poleGroundParams.FilterDescendantsInstances = { northPoleMap }
    end
    local origin = position + Vector3.new(0, 20, 0)
    local result = workspace:Raycast(origin, Vector3.new(0, -200, 0), poleGroundParams)
    local y = result and result.Position.Y or position.Y
    return CFrame.new(position.X, y + 4, position.Z)
end

local function getWanderParts()
    local events = workspace:FindFirstChild("Events")
    local folder = events and events:FindFirstChild("Wander")
    local parts  = {}
    if folder then
        for _, p in folder:GetChildren() do
            if p:IsA("BasePart") then table.insert(parts, p) end
        end
    end
    return parts
end

local function randomPointInPart(part, lift)
    local lx = (math.random() - 0.5) * part.Size.X
    local lz = (math.random() - 0.5) * part.Size.Z
    local p  = (part.CFrame * CFrame.new(lx, 0, lz)).Position
    return p + Vector3.new(0, lift or 0, 0)
end

local function getNorthPoleSpawnCFrame()
    if not northPoleMap then return nil end
    local spawns = northPoleMap:FindFirstChild("Spawns")
    if not spawns then return nil end
    local points = {}
    for _, part in spawns:GetChildren() do
        if part.Name == "Spawn" and part:IsA("BasePart") then
            table.insert(points, part)
        end
    end
    if #points == 0 then return nil end
    return points[math.random(#points)].CFrame
end

local function safeTeleport(character, targetCFrame)
    if not character then return end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
    if not hrp then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid.Sit = false
        pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        local deadline = os.clock() + 0.5
        while (humanoid.Sit or humanoid:GetState() == Enum.HumanoidStateType.Seated)
            and os.clock() < deadline do
            humanoid.Sit = false
            RunService.Heartbeat:Wait()
        end
    end
    local placeCF = snapToPoleGround(targetCFrame.Position)
    hrp.Anchored  = true
    character:PivotTo(placeCF)
    hrp.AssemblyLinearVelocity  = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    task.spawn(function()
        for i = 1, 21 do
            RunService.Heartbeat:Wait()
            if not (hrp and hrp.Parent) then return end
            if i % 5 == 0 then
                character:PivotTo(placeCF)
                hrp.AssemblyLinearVelocity  = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end
        end
        if hrp and hrp.Parent then hrp.Anchored = false end
    end)
end

local function updateBillboard()
    if not northPoleMap then return end
    local overhead   = northPoleMap:FindFirstChild("Overhead")
    local billboard  = overhead and overhead:FindFirstChild("BillboardGui")
    local giftsText  = billboard and billboard:FindFirstChild("Gifts")
    if giftsText and giftsText:IsA("TextLabel") then
        giftsText.Text = string.format("%d/%d", deliveredGifts, MAX_GIFTS)
    end
end

local function revealGift(number)
    if not northPoleMap then return end
    local sleigh = northPoleMap:FindFirstChild("SantaSleigh")
    local folder = sleigh and sleigh:FindFirstChild("Gifts")
    if not folder then return end
    local giftModel = folder:FindFirstChild(tostring(number))
    if not giftModel then return end
    for _, d in giftModel:GetDescendants() do
        if d:IsA("BasePart") then d.Transparency = 0 end
    end
end

-- ─── Gift delivery ────────────────────────────────────────────────────────────

local function handleDelivery()
    if not isActive or sleighFull then return end
    if not LocalPlayer:GetAttribute("Stealing") then return end
    deliveredGifts += 1
    revealGift(deliveredGifts)
    updateBillboard()
    if deliveredGifts >= MAX_GIFTS then
        sleighFull = true
        NotificationController:Notify(
            "<font color='#FFD700'>Santa's Sleigh</font> is full! Departing soon.",
            8,
            ReplicatedStorage.Sounds.Sfx.Success
        )
    end
end

local deliveryOverlapParams = OverlapParams.new()
deliveryOverlapParams.FilterType = Enum.RaycastFilterType.Include
deliveryOverlapParams.MaxParts   = 1

local function watchDeliveryHitbox()
    if not northPoleMap then return end
    local hitbox = northPoleMap:FindFirstChild("DeliveryHitbox")
    if not hitbox then return end
    deliveryOverlapParams.FilterDescendantsInstances = { hitbox }
    local accum = 0
    eventTrove:Add(RunService.PostSimulation:Connect(function(dt)
        accum += dt
        if accum < 0.05 then return end
        accum = 0
        if not LocalPlayer:GetAttribute("Stealing") then return end
        local character = LocalPlayer.Character
        if not character then return end
        local pos = character:GetPivot().Position
        if #workspace:GetPartBoundsInBox(CFrame.new(pos), Vector3.new(4, 4, 2), deliveryOverlapParams) > 0 then
            handleDelivery()
        end
    end))
end

-- ─── Grabbing ─────────────────────────────────────────────────────────────────

local function setupGrabPrompt(mainModel)
    local prompt = Instance.new("ProximityPrompt")
    prompt.Name               = "ProximityPrompt"
    prompt.ActionText         = "Grab"
    prompt.HoldDuration       = 0.5
    prompt.RequiresLineOfSight = false
    prompt.Enabled            = true
    prompt.Parent             = mainModel

    prompt.Triggered:Connect(function()
        local character = LocalPlayer.Character
        local hrp       = character and character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        if (hrp.Position - mainModel.Position).Magnitude > 18 then return end
        if grabbableItems[mainModel.Name] then
            grabbableItems[mainModel.Name] = nil
            LocalPlayer:SetAttribute("Stealing", true)
            mainModel:Destroy()
        end
    end)
end

-- ─── Conveyor path ────────────────────────────────────────────────────────────

local function startPathLoop()
    if not northPoleMap then return end
    local pathFolder = northPoleMap:FindFirstChild("Path")
    if not pathFolder then return end
    local pathPoints = {}
    for i = 1, 6 do
        local p = pathFolder:FindFirstChild(tostring(i))
        if not p or not p:IsA("BasePart") then return end
        pathPoints[i] = p
    end

    eventTrove:Add(task.spawn(function()
        while isActive and northPoleMap and northPoleMap.Parent do
            local brainrot = BRAINROT_LIST[math.random(#BRAINROT_LIST)]

            local mainModel = Instance.new("Part")
            mainModel.Name        = HttpService:GenerateGUID(false)
            mainModel.Size        = Vector3.new(1, 1, 1)
            mainModel.Transparency = 1
            mainModel.Anchored    = true
            mainModel.CanCollide  = false
            mainModel.CanQuery    = false
            mainModel.CanTouch    = false
            mainModel.CFrame      = pathPoints[1].CFrame
            mainModel.Parent      = workspace

            grabbableItems[mainModel.Name] = { model = mainModel, brainrot = brainrot }

            task.spawn(function()
                local gift = nil
                for i = 2, #pathPoints do
                    if not isActive or not mainModel.Parent then break end
                    local targetCF = pathPoints[i].CFrame
                    local distance = (targetCF.Position - mainModel.Position).Magnitude
                    local duration = distance / CONVEYOR_SPEED
                    local tween    = TweenService:Create(
                        mainModel,
                        TweenInfo.new(duration, Enum.EasingStyle.Linear),
                        { CFrame = targetCF }
                    )
                    tween:Play()
                    tween.Completed:Wait()

                    if i == 2 and not gift then
                        gift = ReplicatedStorage.Models.Events["North Pole"].Gift:Clone()
                        gift.Name = "Gift"
                        gift:PivotTo(mainModel.CFrame)
                        gift.Parent = mainModel
                        local giftRoot = gift:FindFirstChild("RootPart")
                        if giftRoot and giftRoot:IsA("BasePart") then
                            giftRoot.Anchored = false
                            local weld = Instance.new("Weld")
                            weld.Part0  = giftRoot
                            weld.Part1  = mainModel
                            weld.C0     = CFrame.new()
                            weld.Parent = mainModel
                        end
                        task.wait(1.2)
                        setupGrabPrompt(mainModel)
                    end
                end
                if mainModel and mainModel.Parent then mainModel:Destroy() end
                grabbableItems[mainModel.Name] = nil
            end)

            task.wait(5)
        end
    end))
end

-- ─── Elf ──────────────────────────────────────────────────────────────────────

local elfGroundParams = nil
local function elfGroundY(x, z, fromY)
    if not northPoleMap then return nil end
    if not elfGroundParams then
        elfGroundParams = RaycastParams.new()
        elfGroundParams.FilterType = Enum.RaycastFilterType.Include
        elfGroundParams.IgnoreWater = true
        elfGroundParams.FilterDescendantsInstances = { northPoleMap }
    end
    local origin = Vector3.new(x, fromY + 20, z)
    local result = workspace:Raycast(origin, Vector3.new(0, -200, 0), elfGroundParams)
    return result and result.Position.Y or nil
end

local function stepElf(elf, newXZ, flatDir, dt, yStand)
    local groundY = elfGroundY(newXZ.X, newXZ.Z, elf.hrp.Position.Y)
    local y       = groundY and (groundY + yStand) or elf.hrp.Position.Y
    local newPos  = Vector3.new(newXZ.X, y, newXZ.Z)
    if flatDir.Magnitude < 1e-4 then
        local look = elf.hrp.CFrame.LookVector
        flatDir = Vector3.new(look.X, 0, look.Z)
        if flatDir.Magnitude < 1e-4 then flatDir = Vector3.new(0, 0, 1) end
    end
    flatDir = flatDir.Unit
    local targetCF = CFrame.new(newPos, newPos + flatDir)
    local alpha    = math.min(1, ELF_TURN_SPEED * dt)
    local eased    = CFrame.new(newPos) * (elf.hrp.CFrame - elf.hrp.CFrame.Position):Lerp(
        targetCF - targetCF.Position, alpha
    )
    elf.model:PivotTo(eased)
end

local function elfWalkTo(elf, targetPos, maxTime, shouldStop)
    local startClock = os.clock()
    while isActive and elf.model.Parent do
        if shouldStop and shouldStop() then return false end
        if maxTime and (os.clock() - startClock) > maxTime then return false end
        local current = elf.hrp.Position
        local flatVec = Vector3.new(targetPos.X - current.X, 0, targetPos.Z - current.Z)
        if flatVec.Magnitude <= 2 then break end
        local dt      = RunService.Heartbeat:Wait()
        local moveAmt = math.min(ELF_WALK_SPEED * dt, flatVec.Magnitude)
        local flatDir = flatVec.Unit
        stepElf(elf, current + flatDir * moveAmt, flatDir, dt, elf.yStand)
    end
    return true
end

local function createElfRig(position)
    local model = Instance.new("Model")
    model.Name  = "Elf"
    local hrp   = Instance.new("Part")
    hrp.Name         = "HumanoidRootPart"
    hrp.Size         = Vector3.new(2, 2, 1)
    hrp.Transparency = 1
    hrp.Anchored     = true
    hrp.CanCollide   = false
    hrp.CanQuery     = false
    hrp.CanTouch     = false
    hrp.CFrame       = CFrame.new(position)
    hrp.Parent       = model
    model.PrimaryPart = hrp
    model.Parent      = workspace
    model:AddTag("Elf")
    return model, hrp
end

local function pickElfHouse()
    if not northPoleMap then return nil end
    local houses = northPoleMap:FindFirstChild("Houses")
    if not houses then return nil end
    local valid = {}
    for _, house in houses:GetChildren() do
        local spawn = house:FindFirstChild("ElfSpawn", true)
        local door  = house:FindFirstChild("Door")
        if spawn and spawn:IsA("BasePart") and door then
            table.insert(valid, house)
        end
    end
    if #valid == 0 then return nil end
    return valid[math.random(#valid)]
end

local function chaseAndStrike(elf, character)
    local deadline = os.clock() + ELF_CHASE_TIME
    local reached  = false
    elf.model:SetAttribute("IsRunning", true)
    while isActive and elf.model.Parent and os.clock() < deadline do
        local targetHrp = character and character:FindFirstChild("HumanoidRootPart")
        if not targetHrp then break end
        local current = elf.hrp.Position
        local tp      = targetHrp.Position
        local flat    = Vector3.new(tp.X - current.X, 0, tp.Z - current.Z)
        if flat.Magnitude <= ELF_ATTACK_RANGE then
            reached = true
            break
        end
        local dt      = RunService.Heartbeat:Wait()
        local dir     = flat.Unit
        local moveAmt = math.min(ELF_WALK_SPEED * dt, flat.Magnitude)
        stepElf(elf, current + dir * moveAmt, dir, dt, elf.yStand)
    end
    elf.model:SetAttribute("IsRunning", false)
    if reached and character and character.Parent and isActive and elf.model.Parent then
        local elfPos = elf.hrp.Position
        local tHrp   = character:FindFirstChild("HumanoidRootPart")
        if tHrp then
            elf.model:PivotTo(CFrame.lookAt(elfPos, Vector3.new(tHrp.Position.X, elfPos.Y, tHrp.Position.Z)))
        end
        elf.model:SetAttribute("AttackAnimation", (elf.model:GetAttribute("AttackAnimation") or 0) + 1)
        task.wait(0.35)
        NotificationController:Notify(
            "An <font color='#ff4545'>Elf</font> knocked you down!",
            4,
            ReplicatedStorage.Sounds.Sfx.Damage
        )
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid:ChangeState(Enum.HumanoidStateType.Physics)
            task.delay(ELF_RAGDOLL_DURATION, function()
                if humanoid and humanoid.Parent then
                    humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end)
        end
    end
end

local function runHouseElf()
    local house = pickElfHouse()
    if not house then return end
    local spawnPart = house:FindFirstChild("ElfSpawn", true)
    local door      = house:FindFirstChild("Door")
    if not spawnPart or not door then return end
    local spawnPos   = spawnPart.Position
    local doorPos    = door:GetPivot().Position
    local flatOut    = Vector3.new(doorPos.X - spawnPos.X, 0, doorPos.Z - spawnPos.Z)
    if flatOut.Magnitude < 0.1 then
        local look = door:GetPivot().LookVector
        flatOut = Vector3.new(look.X, 0, look.Z)
    end
    if flatOut.Magnitude < 0.1 then flatOut = Vector3.new(0, 0, 1) end
    local outsidePos = doorPos + flatOut.Unit * ELF_DOOR_OUT
    local yStand     = 3
    local groundY    = elfGroundY(spawnPos.X, spawnPos.Z, spawnPos.Y) or spawnPos.Y
    local model, hrp = createElfRig(Vector3.new(spawnPos.X, groundY + yStand, spawnPos.Z))
    local elf        = { model = model, hrp = hrp, yStand = yStand, door = door }
    activeElf        = elf

    door:SetAttribute("Open", true)
    task.wait(ELF_DOOR_ANIM)

    if isActive and elf.model.Parent then
        elf.model:SetAttribute("IsRunning", true)
        elfWalkTo(elf, outsidePos, 8)
    end
    door:SetAttribute("Open", false)

    if isActive and elf.model.Parent then
        local character = LocalPlayer.Character
        if character then chaseAndStrike(elf, character) end
    end

    if isActive and elf.model.Parent then
        elf.model:SetAttribute("IsRunning", true)
        elfWalkTo(elf, outsidePos, 12)
        door:SetAttribute("Open", true)
        task.wait(ELF_DOOR_ANIM)
        if isActive and elf.model.Parent then
            elfWalkTo(elf, spawnPos, 8)
        end
        elf.model:SetAttribute("IsRunning", false)
    end

    pcall(function() door:SetAttribute("Open", false) end)
    if elf.model then elf.model:Destroy() end
    if activeElf == elf then activeElf = nil end
end

local function startElves()
    activeElf     = nil
    elfGroundParams = nil
    eventTrove:Add(task.spawn(function()
        while isActive and northPoleMap and northPoleMap.Parent do
            task.wait(ELF_ATTACK_INTERVAL)
            if not (isActive and northPoleMap and northPoleMap.Parent) then break end
            if activeElf then continue end
            task.spawn(runHouseElf)
        end
    end))
end

local function stopElves()
    if activeElf then
        if activeElf.door then pcall(function() activeElf.door:SetAttribute("Open", false) end) end
        if activeElf.model and activeElf.model.Parent then activeElf.model:Destroy() end
        activeElf = nil
    end
    elfGroundParams = nil
end

-- ─── Snow sleigh ──────────────────────────────────────────────────────────────

local function clearSnowGifts()
    for giftId, data in pairs(snowGifts) do
        if data.model and data.model.Parent then data.model:Destroy() end
    end
    table.clear(snowGifts)
end

local function dropSnowGift(myGen, fromPos, brainrot)
    local wanderParts = getWanderParts()
    if #wanderParts == 0 then return end
    local landPos = randomPointInPart(wanderParts[math.random(#wanderParts)], 3)
    local giftId  = HttpService:GenerateGUID(false)

    local giftModel = ReplicatedStorage.Models.Events["North Pole"].WrappedGift:Clone()
    giftModel.Name   = giftId
    giftModel.Parent = workspace

    local giftRoot = giftModel.PrimaryPart or giftModel:FindFirstChild("Handle")
    if giftRoot then
        giftRoot.Anchored = true
        giftRoot.CFrame   = CFrame.new(fromPos)

        local tween = TweenService:Create(
            giftRoot,
            TweenInfo.new(SNOW_PRESENT_FALL, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
            { CFrame = CFrame.new(landPos) }
        )
        tween:Play()
        tween.Completed:Connect(function()
            if not snowGifts[giftId] then return end
            local prompt = Instance.new("ProximityPrompt")
            prompt.ActionText          = "Open"
            prompt.HoldDuration        = 0.5
            prompt.RequiresLineOfSight = false
            prompt.Parent              = giftRoot
            prompt.Triggered:Connect(function()
                if not snowGifts[giftId] then return end
                snowGifts[giftId] = nil
                giftModel:Destroy()
                NotificationController:Notify(
                    "You opened a <font color='#FFD700'>Snow Gift</font>! You received a <font color='#ff69af'>" .. brainrot .. "</font>!",
                    6,
                    ReplicatedStorage.Sounds.Sfx.Success
                )
            end)
        end)
    end

    snowGifts[giftId] = { model = giftModel, landPos = landPos, brainrot = brainrot }

    task.delay(SNOW_PRESENT_LIFETIME, function()
        if myGen == snowGeneration and snowGifts[giftId] then
            snowGifts[giftId] = nil
            if giftModel and giftModel.Parent then giftModel:Destroy() end
        end
    end)
end

local function startSnowSleigh(count)
    snowGeneration += 1
    local myGen = snowGeneration
    count = math.clamp(math.floor(tonumber(count) or 0), 0, SNOW_MAX_PRESENTS)
    if count <= 0 then return end

    local wanderParts = getWanderParts()
    if #wanderParts == 0 then return end

    if snowSanta then snowSanta:Destroy() snowSanta = nil end
    clearSnowGifts()

    local giftQueue = table.create(count)
    for i = 1, count do
        giftQueue[i] = BRAINROT_LIST[math.random(#BRAINROT_LIST)]
    end

    local santa = Instance.new("Part")
    santa.Name        = "SnowSanta"
    santa.Size        = Vector3.new(6, 3, 12)
    santa.Transparency = 1
    santa.Anchored    = true
    santa.CanCollide  = false
    santa.CanQuery    = false
    santa.CanTouch    = false
    santa.CFrame      = CFrame.new(randomPointInPart(wanderParts[math.random(#wanderParts)], SANTA_HEIGHT))
    santa.Parent      = workspace
    santa:AddTag("NorthPoleSantaSleign")
    snowSanta = santa

    local delivering = true
    eventTrove:Add(task.spawn(function()
        while delivering and myGen == snowGeneration and santa.Parent do
            local dest = randomPointInPart(wanderParts[math.random(#wanderParts)], SANTA_HEIGHT)
            local from = santa.Position
            local dur  = math.max((dest - from).Magnitude / SANTA_SPEED, 0.1)
            local t0   = os.clock()
            while delivering and myGen == snowGeneration and santa.Parent do
                local a   = math.clamp((os.clock() - t0) / dur, 0, 1)
                local pos = from:Lerp(dest, a)
                local bob = math.sin(os.clock() * 2) * SANTA_BOB
                local flat = Vector3.new(dest.X - from.X, 0, dest.Z - from.Z)
                if flat.Magnitude < 1e-3 then flat = santa.CFrame.LookVector end
                santa.CFrame = CFrame.lookAt(
                    pos + Vector3.new(0, bob, 0),
                    pos + Vector3.new(0, bob, 0) + flat.Unit
                )
                if a >= 1 then break end
                RunService.Heartbeat:Wait()
            end
            task.wait(math.random(1, 2))
        end
    end))

    eventTrove:Add(task.spawn(function()
        NotificationController:Notify(
            "<font color='#ff4545'>Santa</font> arrives in " .. SANTA_ARRIVE_TIME .. " seconds!",
            SANTA_ARRIVE_TIME,
            ReplicatedStorage.Sounds.Sfx.Bell
        )
        task.wait(SANTA_ARRIVE_TIME)
        if myGen ~= snowGeneration or not santa.Parent then return end

        while #giftQueue > 0 and myGen == snowGeneration and santa.Parent do
            local brainrot = table.remove(giftQueue, 1)
            dropSnowGift(myGen, santa.Position, brainrot)
            task.wait(SNOW_DROP_INTERVAL)
        end

        if myGen ~= snowGeneration or not santa.Parent then return end
        delivering = false

        local dir  = santa.CFrame.LookVector
        local from = santa.Position
        local away = from + dir * 8000 + Vector3.new(0, 1500, 0)
        local t0   = os.clock()
        while myGen == snowGeneration and santa.Parent do
            local a = math.clamp((os.clock() - t0) / 5, 0, 1)
            santa.CFrame = CFrame.lookAt(from:Lerp(away, a), from:Lerp(away, a) + dir)
            if a >= 1 then break end
            RunService.Heartbeat:Wait()
        end

        if snowSanta == santa then snowSanta = nil end
        if santa and santa.Parent then santa:Destroy() end
    end))
end

-- ─── Train cutscene ───────────────────────────────────────────────────────────

local function tweenModelAlongPath(model, fromCF, toCF, speed)
    local distance = (toCF.Position - fromCF.Position).Magnitude
    local duration = distance / speed
    local cfValue  = Instance.new("CFrameValue")
    cfValue.Value  = fromCF
    local tween = TweenService:Create(
        cfValue,
        TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
        { Value = toCF }
    )
    local conn = RunService.Heartbeat:Connect(function()
        if model and model.Parent then model:PivotTo(cfValue.Value) end
    end)
    tween:Play()
    tween.Completed:Wait()
    conn:Disconnect()
    cfValue:Destroy()
end

local function startTrainCutscene()
    loadTrain()
    if not activeTrain then return end

    local road           = workspace:FindFirstChild("Road")
    local startGround    = road and road:FindFirstChild("StartGround")
    local mapCenterGround = workspace:FindFirstChild("MapCenterGround")
    if not startGround or not mapCenterGround then
        if activeTrain then activeTrain:Destroy() activeTrain = nil end
        return
    end

    if not activeTrain.PrimaryPart then
        activeTrain.PrimaryPart = activeTrain:FindFirstChildWhichIsA("BasePart")
        if not activeTrain.PrimaryPart then
            activeTrain:Destroy() activeTrain = nil
            return
        end
    end

    for _, part in activeTrain:GetDescendants() do
        if part:IsA("BasePart") then
            part.Anchored = true
            if part:IsA("Seat") then
                part.Disabled     = true
                part.Transparency = 1
            end
        end
    end

    local startCF  = CFrame.lookAt(startGround.Position, mapCenterGround.Position)
    local dir      = (mapCenterGround.Position - startGround.Position).Unit
    local endCF    = CFrame.lookAt(mapCenterGround.Position, mapCenterGround.Position + dir)
    activeTrain:PivotTo(startCF)

    tweenModelAlongPath(activeTrain, startCF, endCF, TRAIN_SPEED)

    -- boarding window
    for _, seat in activeTrain:GetDescendants() do
        if seat:IsA("Seat") then
            seat.Disabled     = false
            seat.Transparency = 0.4
            seat.CanCollide   = true
            seat.CanTouch     = true
        end
    end

    NotificationController:Notify(
        "<font color='#ff4545'>Brainrot Express</font> departs in " .. BOARDING_WINDOW .. " seconds — board now!",
        BOARDING_WINDOW,
        ReplicatedStorage.Sounds.Sfx.Bell
    )

    local boarded = false
    local boardConn = RunService.Heartbeat:Connect(function()
        local character = LocalPlayer.Character
        if not character then return end
        local humanoid  = character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.SeatPart then
            boarded = true
        end
    end)

    task.wait(BOARDING_WINDOW)
    boardConn:Disconnect()

    for _, seat in activeTrain:GetDescendants() do
        if seat:IsA("Seat") then seat.Transparency = 1 end
    end

    local endTrack = road and road:FindFirstChild("EndTrain")
    if endTrack and activeTrain and activeTrain.Parent then
        local currentCF = activeTrain:GetPivot()
        local endDir    = (endTrack.Position - currentCF.Position).Unit
        local finalCF   = CFrame.lookAt(endTrack.Position, endTrack.Position + endDir)
        tweenModelAlongPath(activeTrain, currentCF, finalCF, TRAIN_SPEED)
    end

    task.wait(CUTSCENE_DURATION)
    if activeTrain then activeTrain:Destroy() activeTrain = nil end

    if boarded then
        loadMap()
        poleGroundParams = nil
        elfGroundParams  = nil
        for _ = 1, 3 do RunService.Heartbeat:Wait() end

        local cf = getNorthPoleSpawnCFrame()
        if cf then
            local character = LocalPlayer.Character
            if character then safeTeleport(character, cf) end
        end

        deliveredGifts = 0
        sleighFull     = false
        updateBillboard()
        startPathLoop()
        startElves()
        watchDeliveryHitbox()

        NotificationController:Notify(
            "Welcome to the <font color='#ff4545'>North Pole</font>! Deliver gifts to Santa's Sleigh.",
            8,
            ReplicatedStorage.Sounds.Sfx.Success
        )
    end
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    NotificationController:Notify(
        "<font color='#ff4545'>Brainrot Express</font> arrives in 10 seconds!",
        10,
    )
    task.wait(10)
    if not isActive then return end

    startTrainCutscene()

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait() end

    isActive = false
    stopElves()
    clearSnowGifts()
    if snowSanta then snowSanta:Destroy() snowSanta = nil end
    if activeTrain then activeTrain:Destroy() activeTrain = nil end
    if northPoleMap then northPoleMap:Destroy() northPoleMap = nil end
    table.clear(grabbableItems)
    table.clear(boardedPlayers)
    eventTrove:Destroy()
end

task.spawn(main)
