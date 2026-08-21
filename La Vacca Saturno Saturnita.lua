if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local Trove            = require(ReplicatedStorage.Packages.Trove)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local AnimalController = require(ReplicatedStorage.Controllers.AnimalController)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local ShakePresets     = require(ReplicatedStorage.Shared.ShakePresets)

local EVENT_NAME   = "La Vacca Saturno Saturnita"
local EVENT_SCRIPT = ReplicatedStorage:WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("La Vacca Saturno Saturnita")

-- ─── Constants (1:1 server) ───────────────────────────────────────────────────

local BLOCKING_TRAIT    = "Galactic"
local COMET_TRAVEL_TIME = 1
local COMET_HEIGHT      = 200
local SHAKE_RANGE       = 70
local BURST_CLEANUP     = 2
local ATTACK_LOOP_MIN   = 5
local ATTACK_LOOP_MAX   = 10
local COOLDOWN_WINDOW   = 20
local ACTIVATION_DELAY  = 15

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local burstAsset = EVENT_SCRIPT:WaitForChild("CometBurst")

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove      = Trove.new()
local recentlyTargeted = {}
local isActive        = true
local rng             = Random.new()
local currentCamera   = workspace.CurrentCamera

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

local function hasBlockingTrait(animal: Model): boolean
    local _, set = getTraits(animal)
    return set[BLOCKING_TRAIT] == true
end

local function getAnimalPosition(animal: Model): Vector3?
    if not animal or not animal.PrimaryPart then return nil end
    return animal.PrimaryPart.Position + Vector3.new(0, animal:GetExtentsSize().Y * 0.5, 0)
end

-- ─── Comet ────────────────────────────────────────────────────────────────────

local function fireComet(animal: Model)
    if not animal or not animal.PrimaryPart then return end

    local cometStart = (ReplicatedStorage:GetAttribute("LaVaccaCenter") or workspace.MapCenter.Position)
        + Vector3.new(0, COMET_HEIGHT, 0)

    local startCFrame = CFrame.new(cometStart)

    SoundController:PlaySound(
        ReplicatedStorage.Sounds.Events["La Vacca Saturno Saturnita"].CommetActivation,
        getAnimalPosition(animal)
    )

    local comet = EVENT_SCRIPT:WaitForChild("Comet"):Clone()
    comet:PivotTo(startCFrame)
    comet.Parent = workspace

    local elapsed  = 0
    local cometConn

    cometConn = RunService.PreRender:Connect(function(dt)
        if not cometConn or not cometConn.Connected then return end

        elapsed += dt
        local animalPos = getAnimalPosition(animal)
        if not animalPos then
            cometConn:Disconnect()
            comet:Destroy()
            return
        end

        local t = math.clamp(elapsed / COMET_TRAVEL_TIME, 0, 1)
        comet:PivotTo(startCFrame:Lerp(CFrame.new(animalPos), t))

        if t >= 1 then
            cometConn:Disconnect()

            SoundController:PlaySound(
                ReplicatedStorage.Sounds.Events["La Vacca Saturno Saturnita"].CommetHit,
                animalPos
            )

            if (currentCamera.CFrame.Position - animalPos).Magnitude <= SHAKE_RANGE then
                local shake = ShakePresets.Bump:Clone()
                eventTrove:Add(shake)
                shake.Sustain = true
                eventTrove:Add(ShakePresets.BindShakeToCamera(shake, currentCamera))
                shake:Start()
                eventTrove:Add(task.delay(0.3, function()
                    shake:StopSustain()
                end))
            end

            ClientEventUtils.playBurst(burstAsset, animal.PrimaryPart, {
                ReplicatedStorage.Sounds.Events["La Vacca Saturno Saturnita"].CommetHit,
            })

            task.delay(BURST_CLEANUP, function()
                comet:Destroy()
            end)
        end
    end)

    eventTrove:Add(cometConn)
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    local elapsed   = workspace:GetServerTimeNow() - startedAt
    local remaining = math.max(0, ACTIVATION_DELAY - elapsed)
    if remaining > 0 then task.wait(remaining) end
    if not isActive then return end

    local cachedAnimals = CollectionService:GetTagged("Animal")
    eventTrove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
        table.insert(cachedAnimals, inst)
    end))
    eventTrove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
        for i = #cachedAnimals, 1, -1 do
            if cachedAnimals[i] == inst then
                table.remove(cachedAnimals, i)
                break
            end
        end
    end))

    -- Attack loop
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(rng:NextNumber(ATTACK_LOOP_MIN, ATTACK_LOOP_MAX))
            if not isActive then break end

            local currentTime = workspace:GetServerTimeNow()
            for name, lastTime in pairs(recentlyTargeted) do
                if (currentTime - lastTime) > COOLDOWN_WINDOW then
                    recentlyTargeted[name] = nil
                end
            end

            local candidates = {}
            for _, animal in ipairs(cachedAnimals) do
                if animal.PrimaryPart
                    and not recentlyTargeted[animal.Name]
                    and not hasBlockingTrait(animal)
                then
                    table.insert(candidates, animal)
                end
            end

            if #candidates == 0 then continue end

            local selected = candidates[rng:NextInteger(1, #candidates)]
            recentlyTargeted[selected.Name] = currentTime
            fireComet(selected)
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
