local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")

if not game:IsLoaded() then game.Loaded:Wait() end

local MathUtils         = require(ReplicatedStorage.Utils.MathUtils)
local AnimalController  = require(ReplicatedStorage.Controllers.AnimalController)
local SoundController   = require(ReplicatedStorage.Controllers.SoundController)
local EventController   = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils  = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local CreateTween       = require(ReplicatedStorage.Packages.CreateTween)
local Trove             = require(ReplicatedStorage.Packages.Trove)
local VFX               = require(ReplicatedStorage.Shared.VFX)
local SharedEventUtils  = require(ReplicatedStorage.Shared.SharedEventUtils)

-- ─── Constants ────────────────────────────────────────────────────────────────

local EVENT_NAME      = "Winter Hour"
local SANTA_HAT_TRAIT = "Santa Hat"
local COOLDOWN_TIME   = 15
local STRIKE_RANGE    = 50
local STRIKE_MIN      = 6
local STRIKE_MAX      = 12
local STRIKE_DELAY    = 0.5

local MAP_DROP_INTERVAL  = 5
local MAP_DROP_AMOUNT    = { 3, 8 }
local CANDY_FALL_TIME    = 1.5
local CANDY_BOB_SPEED    = 4
local CANDY_BOB_HEIGHT   = 0.5
local CANDY_BOB_OFFSET   = 4
local CLAIM_COOLDOWN     = 0.2
local CLAIM_ARC_TIME     = 0.4

local RaycastParams = RaycastParams.new()
RaycastParams.FilterType = Enum.RaycastFilterType.Include
RaycastParams.FilterDescendantsInstances = { workspace.Map }

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local EventFolder  = ReplicatedStorage.Controllers.EventController.Events["Winter Hour"]
local LocalPlayer  = Players.LocalPlayer

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local isActive         = true
local recentlyTargeted = {}
local candyCanes       = {}   -- [id] = model
local candyCaneCounter = 0

local winterModel = workspace:WaitForChild("Events")
    :WaitForChild("Winter Hour")
    :WaitForChild("Model")

local hatIdleAnim  = nil
local sequenceAnim = nil

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getTraits(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasSantaHat(animal)
    local _, set = getTraits(animal)
    return set[SANTA_HAT_TRAIT] == true
end

local function getAnimator()
    local sammy = winterModel:FindFirstChild("Sammy")
    if not sammy then return nil end
    local humanoid = sammy:FindFirstChildOfClass("Humanoid")
    if not humanoid then return nil end
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    return animator
end

local function getRandomMapPosition()
    local map = workspace:FindFirstChild("Map")
    if not map then return Vector3.new(0, 50, 0) end

    local groundParts = {}
    for _, obj in ipairs(map:GetDescendants()) do
        if obj:IsA("BasePart")
            and (obj.Name == "Baseplate" or obj.Name == "Ground" or obj.Name == "Carpet")
        then
            table.insert(groundParts, obj)
        end
    end

    if #groundParts == 0 then
        for _, obj in ipairs(map:GetDescendants()) do
            if obj:IsA("BasePart") then
                table.insert(groundParts, obj)
            end
        end
    end

    if #groundParts == 0 then return Vector3.new(0, 50, 0) end

    local part  = groundParts[math.random(1, #groundParts)]
    local size  = part.Size
    local pos   = part.Position
    local rx    = pos.X + math.random(-size.X / 2, size.X / 2)
    local rz    = pos.Z + math.random(-size.Z / 2, size.Z / 2)
    local above = Vector3.new(rx, pos.Y + 50, rz)
    local ray   = workspace:Raycast(above, Vector3.new(0, -100, 0), RaycastParams)
    return ray and ray.Position or above
end

-- ─── Animations ───────────────────────────────────────────────────────────────

local function setupIdleAnimation()
    local animator = getAnimator()
    if not animator then return end
    local anim = EventFolder:FindFirstChild("HatIdle")
    if not anim or not anim:IsA("Animation") then return end
    if hatIdleAnim then hatIdleAnim:Stop() end
    hatIdleAnim = animator:LoadAnimation(anim)
    hatIdleAnim.Looped   = true
    hatIdleAnim.Priority = Enum.AnimationPriority.Idle
    hatIdleAnim:Play()
end

local function playSequenceAnimation()
    local animator = getAnimator()
    if not animator then return end
    local anim = EventFolder:FindFirstChild("Sequence")
    if not anim or not anim:IsA("Animation") then return end
    if hatIdleAnim  then hatIdleAnim:Stop()  end
    if sequenceAnim then sequenceAnim:Stop() end
    sequenceAnim = animator:LoadAnimation(anim)
    sequenceAnim.Looped   = false
    sequenceAnim.Priority = Enum.AnimationPriority.Action
    sequenceAnim:Play()
    sequenceAnim.Stopped:Once(function()
        setupIdleAnimation()
    end)
end

-- ─── Santa hat visibility ─────────────────────────────────────────────────────

local function setSantaHatVisibility(visible)
    local sammy = winterModel:FindFirstChild("Sammy")
    if not sammy then return end
    local santaHat = sammy:FindFirstChild("Santa's Hat")
    if not santaHat then return end
    for _, child in ipairs(santaHat:GetDescendants()) do
        if child:IsA("BasePart") or child:IsA("MeshPart") then
            child.Transparency = visible and 0 or 1
        end
    end
end

-- ─── Trait grant ──────────────────────────────────────────────────────────────

local function grantSantaHat(animal)
    if not animal or not animal.Parent then return end
    local traits, set = getTraits(animal)
    if set[SANTA_HAT_TRAIT] then return end
    table.insert(traits, SANTA_HAT_TRAIT)
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(animal)
    ClientEventUtils.playBurst(EventFolder.Burst, animal.Name, {
        ReplicatedStorage.Sounds.Events["Winter Hour"].Hit
    })
end

-- ─── Candy cane reward animation (mirrors ClaimCandyCane handler) ─────────────

local function playCharacterAnimation(player, amount)
    local character = player.Character
    if not character then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local clone = EventFolder.Reward:Clone()
    clone.CurrencyCandyCane.Text = "+" .. amount
    clone.Parent = hrp
    TweenService:Create(clone, TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
        StudsOffset = Vector3.new(0, 2.5, 2.2)
    }):Play()
    TweenService:Create(clone.ImageLabel.ImageLabel,
        TweenInfo.new(1.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, 1.5),
        { ImageTransparency = 1 }):Play()
    TweenService:Create(clone.CurrencyCandyCane,
        TweenInfo.new(1.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, 1.5),
        { TextTransparency = 1 }):Play()
    TweenService:Create(clone.CurrencyCandyCane.UIStroke,
        TweenInfo.new(1.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, 1.5),
        { Transparency = 1 }):Play()
    task.delay(5, function() clone:Destroy() end)
end

local function playScreenCandyCaneAnimation(amount)
    local rng = Random.new()
    for _ = 1, math.min(amount, 30) do
        local clone = EventFolder.Image:Clone()
        clone.Position = UDim2.fromScale(rng:NextNumber(-0.25, 1.25), -(0.25 - rng:NextNumber(0, 0.125)))
        clone.Rotation = rng:NextNumber(-120, 120)
        local scale = rng:NextNumber(0.15, 0.2)
        clone.Size = UDim2.fromScale(scale, scale)
        clone.Parent = LocalPlayer.PlayerGui:FindFirstChild("Effects")
        CreateTween(clone,
            TweenInfo.new(rng:NextNumber(0.75, 1.3), Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
            {
                Position = clone.Position + UDim2.fromScale(0, 1.5),
                Rotation = clone.Rotation + rng:NextInteger(-3, 3) * 10
            },
            true
        ).Completed:Once(function()
            task.wait(1)
            clone:Destroy()
        end)
    end
end

-- ─── Candy cane claim (local, mirrors ClaimCandyCane remote handler) ──────────

local function claimCandyCane(id, amount)
    local model = candyCanes[id]
    if not model then return end

    local clone = model:Clone()
    model:Destroy()
    candyCanes[id] = nil
    clone.Parent = workspace

    local startPos = clone:GetPivot().Position
    local elapsed  = 0
    local conn

    conn = eventTrove:Add(RunService.PostSimulation:Connect(function(dt)
        debug.profilebegin("Winter Hour:ClaimCandyCaneAnim")
        elapsed = elapsed + dt

        local player  = LocalPlayer
        local charPos = player.Character and player.Character:GetPivot().Position
            or Vector3.new(0, 0, 0)
        local midPos  = startPos + (charPos - startPos) * 0.25 + Vector3.new(0, 10, 0)
        local t       = TweenService:GetValue(
            math.clamp(elapsed / CLAIM_ARC_TIME, 0, 1),
            Enum.EasingStyle.Sine,
            Enum.EasingDirection.In
        )

        clone:PivotTo(CFrame.new(MathUtils.quadBezier(t, startPos, midPos, charPos)))

        if t >= 1 then
            eventTrove:Remove(conn)
            clone:Destroy()
            task.spawn(function()
                SoundController:PlaySound(
                    ReplicatedStorage.Sounds.Events["North Pole"].CandyCane2,
                    charPos
                )
            end)
            playScreenCandyCaneAnimation(amount)
            playCharacterAnimation(player, amount)
        end

        debug.profileend()
    end))
end

-- ─── Candy cane spawn ─────────────────────────────────────────────────────────

local function spawnCandyCane(spawnPos, landPos, amount)
    candyCaneCounter = candyCaneCounter + 1
    local id = tostring(candyCaneCounter)

    local clone = EventFolder.Drop:Clone()
    clone.Name  = id
    candyCanes[id] = clone
    clone.Parent = workspace

    local prompt = Instance.new("ProximityPrompt")
    prompt.Name                  = "ProximityPrompt"
    prompt.ActionText            = ""
    prompt.RequiresLineOfSight   = false
    prompt.Enabled               = false
    prompt.Style                 = Enum.ProximityPromptStyle.Custom
    prompt:SetAttribute("CustomStyleDisabled", true)
    prompt.Parent = clone

    local rayResult = workspace:Raycast(landPos + Vector3.new(0, 10, 0), Vector3.new(0, -30, 0), RaycastParams)
    local finalPos  = rayResult and rayResult.Position or landPos
    local midPos    = spawnPos + (finalPos - spawnPos) * 0.5
    local bobSeed   = math.random(0, 10000)
    local promptActive = false
    local lastClaim    = 0
    local fireTime     = workspace:GetServerTimeNow()

    local conn
    conn = eventTrove:Add(RunService.PostSimulation:Connect(function()
        debug.profilebegin("Winter Hour:CandyCaneUpdate")

        local elapsed = workspace:GetServerTimeNow() - fireTime
        local raw     = CANDY_FALL_TIME ~= 0 and math.clamp(elapsed / CANDY_FALL_TIME, 0, 1) or 1
        local t       = TweenService:GetValue(raw, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
        local basePos = MathUtils.quadBezier(t, spawnPos, midPos, finalPos)

        clone:PivotTo(CFrame.new(
            basePos + Vector3.new(0, math.sin((os.clock() + bobSeed) * CANDY_BOB_SPEED) * CANDY_BOB_HEIGHT + CANDY_BOB_OFFSET, 0)
        ))

        if t >= 1 then
            prompt.Enabled = true
            local now = os.clock()
            if promptActive and (now - lastClaim) > CLAIM_COOLDOWN then
                lastClaim = now
                claimCandyCane(id, amount)
                eventTrove:Remove(conn)
            end
        end

        debug.profileend()
    end))

    clone.Destroying:Connect(function()
        eventTrove:Remove(conn)
        candyCanes[id] = nil
    end)

    prompt.PromptShown:Connect(function()  promptActive = true  end)
    prompt.PromptHidden:Connect(function() promptActive = false end)
end

local function destroyCandyCane(id)
    local model = candyCanes[id]
    if not model then return end
    model:Destroy()
    candyCanes[id] = nil
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    winterModel:PivotTo(CFrame.new(-381.939, -9.341, 8.176))
    setupIdleAnimation()
    setSantaHatVisibility(true)

    -- Strike loop
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(STRIKE_MIN * 10, STRIKE_MAX * 10) / 10)
            if not isActive then break end

            local sammy = winterModel:FindFirstChild("Sammy")
            if not sammy or not sammy.PrimaryPart then continue end

            local sammyPos = sammy.PrimaryPart.Position
            local now      = workspace:GetServerTimeNow()

            for name, lastTime in pairs(recentlyTargeted) do
                if (now - lastTime) > COOLDOWN_TIME then
                    recentlyTargeted[name] = nil
                end
            end

            local closestAnimal   = nil
            local closestDistance = math.huge

            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if not animal.PrimaryPart then continue end
                local dist = (animal.PrimaryPart.Position - sammyPos).Magnitude
                if dist <= STRIKE_RANGE
                    and not recentlyTargeted[animal.Name]
                    and not hasSantaHat(animal)
                    and dist < closestDistance
                then
                    closestAnimal   = animal
                    closestDistance = dist
                end
            end

            if not closestAnimal then continue end

            if not closestAnimal.PrimaryPart
                or not SharedEventUtils.isPointInCarpet(closestAnimal.PrimaryPart.Position)
            then
                continue
            end

            recentlyTargeted[closestAnimal.Name] = now
            playSequenceAnimation()

            task.delay(STRIKE_DELAY, function()
                if not isActive or not closestAnimal.Parent then return end
                doBurst(closestAnimal)
                grantSantaHat(closestAnimal)
            end)
        end
    end))

    -- Candy cane map drop loop
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(MAP_DROP_INTERVAL)
            if not isActive then break end

            local landPos  = getRandomMapPosition()
            local spawnPos = landPos + Vector3.new(0, CANDY_DROP_HEIGHT, 0)
            local amount   = math.random(MAP_DROP_AMOUNT[1], MAP_DROP_AMOUNT[2])
            spawnCandyCane(spawnPos, landPos, amount)
        end
    end))

    -- Cleanup watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    setSantaHatVisibility(false)
    if hatIdleAnim  then hatIdleAnim:Stop()  end
    if sequenceAnim then sequenceAnim:Stop() end
    winterModel:PivotTo(CFrame.new(0, 100000, 0))
    for id, model in pairs(candyCanes) do
        if model then model:Destroy() end
    end
    table.clear(candyCanes)
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
