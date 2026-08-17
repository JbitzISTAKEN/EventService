-- LocalScript: Dul Dul Dul (Client-Side Replication)
-- Replicates server behavior: spawns 4 Dul characters, building, running, and random burst phases.
-- Requires the client event module to be present for visual/audio assets.
-- Place in StarterPlayerScripts or StarterCharacterScripts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
local HttpService = game:GetService("HttpService")

local EventController = require(ReplicatedStorage.Controllers.EventController)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)  -- for isPointInCarpet
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)  -- optional for burst VFX

local EVENT_NAME = "Dul Dul Dul"
local TAG_NAME = "DulDulDul"
local TRAIT_NAME = "Tie"

local BUILD_DURATION = 9
local HEIGHT_OFFSET = 5
local NUM_CHARACTERS = 4

local isActive = false
local dulCharacters = {}
local runningTasks = {}
local usedDulIndices = {}
local maindul = nil
local recentlyTargeted = {}

local eventsFolder = Workspace:FindFirstChild("Events") or Instance.new("Folder", Workspace)
eventsFolder.Name = "Events"

-- ─── WalkOver model loading ─────────────────────────────────────────────────
local function loadWalkOver()
    local obj = game:GetObjects("rbxassetid://132571131796259")[1]
    if obj then
        obj.Parent = Workspace
    end
    return obj
end

-- ─── Character creation ─────────────────────────────────────────────────────
local function createDulDulDulCharacter(index, useSpawnPos)
    local character = Instance.new("Model")
    character.Name = HttpService:GenerateGUID(false)

    local humanoidRootPart = Instance.new("Part")
    humanoidRootPart.Name = "HumanoidRootPart"
    humanoidRootPart.Size = Vector3.new(2, 2, 1)
    humanoidRootPart.CanCollide = true
    humanoidRootPart.Anchored = true
    humanoidRootPart.Transparency = 1
    humanoidRootPart.Parent = character

    local humanoid = Instance.new("Humanoid")
    humanoid.Parent = character
    humanoid.PlatformStand = false
    humanoid.WalkSpeed = 22.5

    character.PrimaryPart = humanoidRootPart

    CollectionService:AddTag(character, TAG_NAME)
    character:SetAttribute("IsBuilding", false)
    character:SetAttribute("IsRunning", false)
    character:SetAttribute("Gesture", false)
    character:SetAttribute("AttackAnimation", false)
    character:SetAttribute("FinishAttackAnimation", false)
    character:SetAttribute("Index", index)

    local dulFolder = eventsFolder:FindFirstChild(EVENT_NAME)
    if dulFolder then
        local folderName = useSpawnPos and "SpawnPositions" or "Positions"
        local posFolder = dulFolder:FindFirstChild(folderName)
        if posFolder then
            local targetPos = posFolder:FindFirstChild(tostring(index))
            if targetPos and targetPos:IsA("BasePart") then
                humanoidRootPart.CFrame = targetPos.CFrame + Vector3.new(0, HEIGHT_OFFSET, 0)
            end
        end
    end

    character.Parent = Workspace
    return character
end

-- ─── Pathfinding movement (for non-main characters) ────────────────────────
local function startPathfinding(model)
    if not model or not model.Parent then return end
    local roadEnd = Workspace:FindFirstChild("Road") and Workspace.Road:FindFirstChild("End")
    if not roadEnd then return end

    local path = PathfindingService:CreatePath({
        AgentRadius = 2,
        AgentHeight = 5,
        AgentCanJump = false,
        AgentMaxSlope = 45
    })

    local primary = model.PrimaryPart
    if not primary then return end
    path:ComputeAsync(primary.Position, roadEnd.Position)

    local waypoints = path:GetWaypoints()
    if #waypoints == 0 then return end

    model:SetAttribute("IsBuilding", nil)
    model:SetAttribute("IsRunning", true)
    primary.Anchored = true

    task.spawn(function()
        for i, waypoint in ipairs(waypoints) do
            if not model.Parent then return end
            local targetPos = waypoint.Position + Vector3.new(0, HEIGHT_OFFSET, 0)
            local currentPos = primary.Position
            local distance = (targetPos - currentPos).Magnitude
            local travelTime = distance / 15

            local facingCFrame = CFrame.lookAt(currentPos, targetPos)

            local tween = TweenService:Create(primary, TweenInfo.new(travelTime, Enum.EasingStyle.Linear), {
                CFrame = facingCFrame + (facingCFrame.LookVector * distance)
            })
            tween:Play()
            tween.Completed:Wait()
        end

        if model.Parent then
            local finalLook = CFrame.lookAt(primary.Position, roadEnd.Position)
            TweenService:Create(primary, TweenInfo.new(0.5), {CFrame = finalLook}):Play()

            model:SetAttribute("IsRunning", false)
            model:SetAttribute("Gesture", true)
            task.delay(3, function()
                if model.Parent then model:SetAttribute("Gesture", false) end
            end)
            task.wait(5)
            if model.Parent then model:Destroy() end
        end
    end)
end

-- ─── Movement for main Dul (index 1) using waypoints ──────────────────────
local function moveMainDulWithWaypoints(character, dulFolder)
    if not character or not character.Parent then return end
    local pathFolder = dulFolder:FindFirstChild("Path")
    local roadEnd = Workspace:FindFirstChild("Road") and Workspace.Road:FindFirstChild("End")
    if not pathFolder or not roadEnd then return end

    local waypoints = {}
    for i = 1, 4 do
        local wp = pathFolder:FindFirstChild(tostring(i))
        if wp and wp:IsA("BasePart") then
            table.insert(waypoints, wp.Position + Vector3.new(0, HEIGHT_OFFSET, 0))
        end
    end

    local primary = character.PrimaryPart
    primary.Anchored = true
    character:SetAttribute("IsBuilding", false)
    character:SetAttribute("IsRunning", true)

    task.spawn(function()
        for i, targetPos in ipairs(waypoints) do
            if not character.Parent then return end
            local currentPos = primary.Position
            local distance = (targetPos - currentPos).Magnitude
            local travelTime = distance / 15

            local facingCFrame = CFrame.lookAt(currentPos, targetPos)

            local tween = TweenService:Create(primary, TweenInfo.new(travelTime, Enum.EasingStyle.Linear), {
                CFrame = facingCFrame + (facingCFrame.LookVector * distance)
            })
            tween:Play()
            tween.Completed:Wait()

            if i == #waypoints then
                local finalCFrame = CFrame.lookAt(primary.Position, roadEnd.Position)
                local faceTween = TweenService:Create(primary, TweenInfo.new(0.5), {CFrame = finalCFrame})
                faceTween:Play()
                faceTween.Completed:Wait()

                character:SetAttribute("IsRunning", false)
                character:SetAttribute("Gesture", true)
                task.delay(3, function()
                    if character.Parent then character:SetAttribute("Gesture", false) end
                end)
            end
        end
    end)
end

-- ─── Spawn characters initially ───────────────────────────────────────────
local function spawnDulDulDulCharacters()
    local dulFolder = eventsFolder:FindFirstChild(EVENT_NAME)
    if not dulFolder then return end
    local posFolder = dulFolder:FindFirstChild("Positions")
    local spawnFolder = dulFolder:FindFirstChild("SpawnPositions")
    if not posFolder or not spawnFolder then return end

    local totalPositions = #posFolder:GetChildren()
    local availableIndices = {}

    for i = 1, math.min(NUM_CHARACTERS, totalPositions) do
        if not usedDulIndices[i] then table.insert(availableIndices, i) end
    end

    if #availableIndices == 0 then
        usedDulIndices = {}
        for i = 1, math.min(NUM_CHARACTERS, totalPositions) do table.insert(availableIndices, i) end
    end

    for i = 1, NUM_CHARACTERS do
        local index = availableIndices[i]
        if index then
            usedDulIndices[index] = true
            local character = createDulDulDulCharacter(index, true)
            if character then
                table.insert(dulCharacters, character)

                task.spawn(function()
                    local targetPart = posFolder:FindFirstChild(tostring(index))
                    if targetPart then
                        character:SetAttribute("IsRunning", true)
                        local primary = character.PrimaryPart
                        local targetPos = targetPart.Position + Vector3.new(0, HEIGHT_OFFSET, 0)

                        primary.CFrame = primary.CFrame * CFrame.Angles(0, math.rad(180), 0)

                        local moveTween = TweenService:Create(primary, TweenInfo.new(5, Enum.EasingStyle.Linear), {
                            Position = targetPos
                        })
                        moveTween:Play()
                        moveTween.Completed:Wait()

                        local finalCFrame = targetPart.CFrame + Vector3.new(0, HEIGHT_OFFSET, 0)

                        local lookTween = TweenService:Create(primary, TweenInfo.new(0.5), {
                            CFrame = finalCFrame
                        })
                        lookTween:Play()
                        lookTween.Completed:Wait()

                        character:SetAttribute("IsRunning", false)
                    end
                end)
            end
        end
    end
end

-- ─── Start running phase ───────────────────────────────────────────────────
local function startRunningPhase()
    if not isActive then return end

    local dulFolder = eventsFolder:FindFirstChild(EVENT_NAME)
    for i, character in ipairs(dulCharacters) do
        if character and character.Parent then
            local index = character:GetAttribute("Index")

            character:SetAttribute("IsBuilding", false)
            character:SetAttribute("IsRunning", true)

            if index == 1 then
                maindul = character
                task.spawn(function()
                    moveMainDulWithWaypoints(character, dulFolder)
                end)
            else
                task.spawn(function()
                    startPathfinding(character)
                end)
            end
        end
    end
end

-- ─── Start building phase ─────────────────────────────────────────────────
local function startBuildingPhase()
    ReplicatedStorage:SetAttribute("DulDulDulConstructionStart", Workspace:GetServerTimeNow())
    for _, character in ipairs(dulCharacters) do
        if character and character.Parent then
            character:SetAttribute("IsBuilding", true)
        end
    end

    local buildTask = task.delay(BUILD_DURATION, function()
        if not isActive then return end

        startRunningPhase()

        local dulFolder = eventsFolder:FindFirstChild(EVENT_NAME)
        if dulFolder then
            -- Load WalkOver asset and place it
            local walkOver = loadWalkOver()
            if walkOver then
                for _, child in ipairs(walkOver:GetChildren()) do
                    if child:IsA("BasePart") then
                        child.CanQuery = true
                        child.CanTouch = true
                    end
                end
                walkOver.Parent = dulFolder
            end
        end
    end)

    table.insert(runningTasks, buildTask)
end

-- ─── Trait granting ───────────────────────────────────────────────────────
local function applyTieTrait(animal)
    if not animal or not animal.Parent then return end

    local currentTraitsJson = animal:GetAttribute("Traits")
    local currentTraits = {}

    if currentTraitsJson then
        local success, decoded = pcall(function()
            return HttpService:JSONDecode(currentTraitsJson)
        end)
        if success and type(decoded) == "table" then
            currentTraits = decoded
        end
    end

    local alreadyHasTie = false
    for _, trait in ipairs(currentTraits) do
        if trait == TRAIT_NAME then
            alreadyHasTie = true
            break
        end
    end

    if not alreadyHasTie then
        table.insert(currentTraits, TRAIT_NAME)
        animal:SetAttribute("Traits", HttpService:JSONEncode(currentTraits))
    end
end

-- ─── Random burst attacks ─────────────────────────────────────────────────
local function startRandomBursts()
    if not isActive then return end

    local burstTask = task.spawn(function()
        task.wait(2.5)
        while isActive do
            local dulModel = Workspace.Events:FindFirstChild(EVENT_NAME)
            local hitbox = dulModel and dulModel:FindFirstChild("HitBox")

            if not maindul or not maindul.Parent or not hitbox then
                task.wait(1)
                continue
            end

            maindul:SetAttribute("Gesture", false)
            maindul:SetAttribute("FinishAttackAnimation", false)
            maindul:SetAttribute("AttackAnimation", not maindul:GetAttribute("AttackAnimation"))

            local attackStartTime = os.clock()
            local minAnimationDuration = 1.3

            task.wait(0.8)

            local targetAnimal = nil
            local scanStartTime = os.clock()
            local maxScanTime = 10

            while (os.clock() - scanStartTime) < maxScanTime do
                local taggedAnimals = CollectionService:GetTagged("Animal")
                for _, animal in ipairs(taggedAnimals) do
                    if animal and animal.PrimaryPart and not recentlyTargeted[animal.Name] then
                        local animalPos = animal.PrimaryPart.Position
                        local hitboxPos = hitbox.Position

                        local diffX = math.abs(animalPos.X - hitboxPos.X)
                        local diffZ = math.abs(animalPos.Z - hitboxPos.Z)

                        if diffX <= 2.5 and diffZ <= 2.5 then
                            targetAnimal = animal
                            break
                        end
                    end
                end
                if targetAnimal then break end
                task.wait(0.1)
            end

            local timeElapsed = os.clock() - attackStartTime
            if timeElapsed < minAnimationDuration then
                task.wait(minAnimationDuration - timeElapsed)
            end

            maindul:SetAttribute("FinishAttackAnimation", true)

            if targetAnimal then
                if not targetAnimal.PrimaryPart or not SharedEventUtils.isPointInCarpet(targetAnimal.PrimaryPart.Position) then
                    maindul:SetAttribute("Gesture", true)
                    task.wait(Random.new():NextNumber(10, 12))
                    continue
                end

                local animalName = targetAnimal.Name
                local animalRoot = targetAnimal.PrimaryPart

                task.wait(0.3)
                applyTieTrait(targetAnimal)

                -- Optional: play burst VFX locally
                pcall(function()
                    ClientEventUtils.playBurst(
                        script.Parent and script.Parent:FindFirstChild("Burst"),
                        animalName,
                        { ReplicatedStorage.Sounds.Events[EVENT_NAME].Burst }
                    )
                end)

                recentlyTargeted[animalName] = Workspace:GetServerTimeNow()
                task.wait(1.2)
            end

            maindul:SetAttribute("Gesture", true)
            task.wait(Random.new():NextNumber(10, 12))
        end
    end)

    table.insert(runningTasks, burstTask)
end

-- ─── Event lifecycle ───────────────────────────────────────────────────────
local function OnStart()
    if isActive then return end
    isActive = true
    ReplicatedStorage:SetAttribute("DulDulDulEvent", true)

    local dulFolder = Workspace.Events:FindFirstChild(EVENT_NAME)
    if dulFolder then
        dulFolder.HitBox.CanQuery = true
        dulFolder.HitBox.CanTouch = true
    end

    spawnDulDulDulCharacters()
    table.insert(runningTasks, task.delay(7, startBuildingPhase))

    local secondaryPhaseTask = task.delay(20, function()
        if not isActive then return end
        startRandomBursts()
    end)
    table.insert(runningTasks, secondaryPhaseTask)
end

local function OnStop()
    if not isActive then return end
    isActive = false

    local dulFolder = Workspace.Events:FindFirstChild(EVENT_NAME)
    if dulFolder then
        local existingWalkOver = dulFolder:FindFirstChild("WalkOver")
        if existingWalkOver then
            for _, child in ipairs(existingWalkOver:GetChildren()) do
                if child:IsA("BasePart") then
                    child.CanQuery = false
                    child.CanTouch = false
                end
            end
            existingWalkOver:Destroy()
        end

        dulFolder.HitBox.CanQuery = false
        dulFolder.HitBox.CanTouch = false
    end

    for _, taskThread in ipairs(runningTasks) do
        if taskThread then task.cancel(taskThread) end
    end
    runningTasks = {}

    for _, character in ipairs(dulCharacters) do
        if character and character.Parent then character:Destroy() end
    end
    dulCharacters = {}

    if maindul then maindul:Destroy() end
    maindul = nil
    usedDulIndices = {}
    ReplicatedStorage:SetAttribute("DulDulDulConstructionStart", nil)
    ReplicatedStorage:SetAttribute("DulDulDulEvent", false)
end

-- ─── Bootstrap: wait for event to become active ────────────────────────────
task.spawn(function()
    while true do
        if EventController:GetActiveEventData(EVENT_NAME) then
            OnStart()
            break
        end
        task.wait(1)
    end

    -- Watch for event end
    while EventController:GetActiveEventData(EVENT_NAME) do
        task.wait(1)
    end
    OnStop()
end)
