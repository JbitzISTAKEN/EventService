local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local AnimalController = require(ReplicatedStorage.Controllers.AnimalController)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local Trove            = require(ReplicatedStorage.Packages.Trove)
local VFX              = require(ReplicatedStorage.Shared.VFX)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

-- ─── Constants ────────────────────────────────────────────────────────────────

local EVENT_NAME      = "Winter Hour"
local SANTA_HAT_TRAIT = "Santa Hat"
local COOLDOWN_TIME   = 15
local STRIKE_RANGE    = 50
local STRIKE_MIN      = 6
local STRIKE_MAX      = 12
local STRIKE_DELAY    = 0.5

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local EventFolder = ReplicatedStorage.Controllers.EventController.Events["Winter Hour"]

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local isActive         = true
local recentlyTargeted = {}

local winterModel = workspace:WaitForChild("Events")
    :WaitForChild("Winter Hour")
    :WaitForChild("Model")

local hatIdleAnim    = nil
local sequenceAnim   = nil

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getTraits(animal: Model): ({string}, {[string]: boolean})
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasSantaHat(animal: Model): boolean
    local _, set = getTraits(animal)
    return set[SANTA_HAT_TRAIT] == true
end

local function getAnimator(): Animator?
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

-- ─── Animations ───────────────────────────────────────────────────────────────

local function setupIdleAnimation()
    local animator = getAnimator()
    if not animator then return end
    local anim = EventFolder:FindFirstChild("HatIdle")
    if not anim or not anim:IsA("Animation") then return end
    if hatIdleAnim then hatIdleAnim:Stop() end
    hatIdleAnim = animator:LoadAnimation(anim)
    hatIdleAnim.Looped = true
    hatIdleAnim.Priority = Enum.AnimationPriority.Idle
    hatIdleAnim:Play()
end

local function playSequenceAnimation()
    local animator = getAnimator()
    if not animator then return end
    local anim = EventFolder:FindFirstChild("Sequence")
    if not anim or not anim:IsA("Animation") then return end
    if hatIdleAnim then hatIdleAnim:Stop() end
    if sequenceAnim then sequenceAnim:Stop() end
    sequenceAnim = animator:LoadAnimation(anim)
    sequenceAnim.Looped = false
    sequenceAnim.Priority = Enum.AnimationPriority.Action
    sequenceAnim:Play()
    sequenceAnim.Stopped:Once(function()
        setupIdleAnimation()
    end)
end

-- ─── Santa hat visibility ─────────────────────────────────────────────────────

local function setSantaHatVisibility(visible: boolean)
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

local function grantSantaHat(animal: Model)
    if not animal or not animal.Parent then return end
    local traits, set = getTraits(animal)
    if set[SANTA_HAT_TRAIT] then return end
    table.insert(traits, SANTA_HAT_TRAIT)
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(animal: Model)
    local animalData = AnimalController:GetAnimals()[animal.Name]
    local pos: Vector3
    if animalData then
        local mdl = animalData.AnimalModel
        pos = (mdl.PrimaryPart and mdl.PrimaryPart.CFrame.Position)
            or mdl:GetPivot().Position
    else
        pos = animal.PrimaryPart and animal.PrimaryPart.Position
            or Vector3.new(0, 0, 0)
    end

    task.spawn(function()
        SoundController:PlaySound(
            ReplicatedStorage.Sounds.Events["Winter Hour"].Hit,
            pos
        )
    end)

    local burst = EventFolder.Burst:Clone()
    burst:PivotTo(CFrame.new(pos))
    burst.Anchored = false
    local weld  = Instance.new("WeldConstraint")
    weld.Part0  = burst
    weld.Part1  = animal.PrimaryPart
    weld.Parent = burst
    burst.Parent = workspace
    VFX.emit(burst)
    task.delay(5, function() burst:Destroy() end)
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

        -- 1:1 to server: carpet check before commit
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

    -- Cleanup watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    setSantaHatVisibility(false)
    if hatIdleAnim then hatIdleAnim:Stop() end
    if sequenceAnim then sequenceAnim:Stop() end
    winterModel:PivotTo(CFrame.new(0, 100000, 0))
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
