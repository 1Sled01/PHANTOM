--[[
    PHANTOM | Roblox Studio
    Location: StarterPlayer > StarterPlayerScripts

    UI:
    - Wide purple sci-fi interface
    - Animated intro logo and menu opening
    - Falling stars and comet trails
    - Smooth buttons, toggles and sliders
    - Draggable window; position persists while this script runs
    - RightShift toggles the menu

    Features:
    - Cached NPC tracking
    - Player/NPC ESP, colors, distance, HP
    - Aim Assist with FOV and target lock while holding RMB
    - JumpPower and WalkSpeed sliders with numeric inputs
    - JSON import/export
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

-- This interface must run on the client as a LocalScript (StarterPlayerScripts).
-- Avoid a cryptic nil-index error if it was accidentally inserted as a server Script.
local player = Players.LocalPlayer
if not player then
    warn("[PHANTOM] This file is client-only. Insert it as a LocalScript in StarterPlayer > StarterPlayerScripts.")
    return
end
local playerGui = player:WaitForChild("PlayerGui")

local TAG_NAME = "PHANTOM_Target"
local RENDER_NAME = "PHANTOM_TrainingAim"

local old = playerGui:FindFirstChild("PHANTOM")
if old then old:Destroy() end

pcall(function()
    RunService:UnbindFromRenderStep(RENDER_NAME)
end)

local S = {
    PlayerESP = false,
    BotESP = false,
    PlayerWalls = false,
    BotWalls = false,
    HP = false,

    PlayerColor = Color3.fromRGB(0, 0, 0),
    BotColor = Color3.fromRGB(255, 45, 70),

    PlayerDistance = 100,
    BotDistance = 100,

    AimEnabled = false,
    AimBots = false,
    AimPart = "Head",
    FOV = 200,
    Smoothness = 8,

    JumpPower = 50,
    WalkSpeed = 16,

    CameraFOVEnabled = false,
    CameraFOV = 80,
    InfiniteJump = false,
    Fullbright = false,
    NoFog = false,
    Crosshair = false,
    ThirdPerson = false,
    ThirdPersonDistance = 12,
    SpinTest = false,
    SpinSpeed = 6, -- decorative logo rotation only
    CharacterSpinEnabled = false,
    CharacterSpinSpeed = 6,
    CharacterSpinDirection = 1, -- 1 = clockwise, -1 = counterclockwise
    CharacterSpinSmooth = true,
    LocalTestMode = false,
    UILanguage = "English",
    UIScale = 1,
    SavedWindowWidth = 850,
    SavedWindowHeight = 560,
}

local espObjects = {}
local trackedModels = {}
local localTestDummy
local lockedTarget
local rightMouseHeld = false
local menuOpen = false
local dragging = false
local resizing = false
local resizeStartSize
local resizeStartInput
local dragStart
local dragPosition
local sliderState
local espElapsed = 0

local jumpPowerCustomized = false
local walkSpeedCustomized = false
local applyMovementSettings

local camera = Workspace.CurrentCamera
local rng = Random.new()

--==================================================
-- HELPERS
--==================================================

local function make(class, props, parent)
    local obj = Instance.new(class)

    for key, value in pairs(props or {}) do
        obj[key] = value
    end

    obj.Parent = parent
    return obj
end

local function corner(obj, radius)
    return make("UICorner", {
        CornerRadius = UDim.new(0, radius or 10),
    }, obj)
end

-- Four-point PHANTOM mark built from native UI shapes (no font glyph,
-- black outline, or external image asset required).
local function starMark(parent, size, color, zIndex)
    local mark = make("Frame", {
        Name = "PhantomStar",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(size, size),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = zIndex or 8,
    }, parent)
    local armSize = size * 0.43
    local points = {{0.5, 0.08, 0}, {0.92, 0.5, 90}, {0.5, 0.92, 0}, {0.08, 0.5, 90}}
    for _, point in ipairs(points) do
        local arm = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(point[1], point[2]),
            Size = UDim2.fromOffset(armSize * 0.58, armSize),
            Rotation = point[3],
            BackgroundColor3 = color,
            BorderSizePixel = 0,
            ZIndex = (zIndex or 8) + 1,
        }, mark)
        corner(arm, armSize)
    end
    local center = make("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(size * 0.32, size * 0.32),
        Rotation = 45,
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        ZIndex = (zIndex or 8) + 2,
    }, mark)
    corner(center, 2)
    return mark
end

local function stroke(obj, color, thickness, transparency)
    return make("UIStroke", {
        Color = color or Color3.fromRGB(145, 90, 240),
        Thickness = thickness or 1,
        Transparency = transparency or 0,
    }, obj)
end

local function tween(obj, props, duration, style)
    if not obj or not obj.Parent then return end

    local ok, tw = pcall(function()
        return TweenService:Create(
            obj,
            TweenInfo.new(
                duration or 0.18,
                style or Enum.EasingStyle.Quint,
                Enum.EasingDirection.Out
            ),
            props
        )
    end)

    if ok and tw then tw:Play() end
    return tw
end

local function round(n)
    return math.floor(n + 0.5)
end

local function clampNumber(value, minimum, maximum, fallback)
    value = tonumber(value)
    if not value then return fallback end
    return math.clamp(round(value), minimum, maximum)
end

local function addHover(button, normal, hovered)
    button.MouseEnter:Connect(function()
        tween(button, {
            BackgroundColor3 = hovered,
        }, 0.14)
    end)

    button.MouseLeave:Connect(function()
        tween(button, {
            BackgroundColor3 = normal,
        }, 0.18)
    end)
end

--==================================================
-- CHARACTER HELPERS
--==================================================

local function isPlayerCharacter(model)
    return model ~= nil
        and model:IsA("Model")
        and Players:GetPlayerFromCharacter(model) ~= nil
end

local function getHumanoid(model)
    if not model or not model:IsA("Model") then return nil end
    return model:FindFirstChildOfClass("Humanoid")
end

local function getRoot(model)
    if not model or not model:IsA("Model") then return nil end

    return model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Torso")
        or model.PrimaryPart
        or model:FindFirstChild("Head")
end

local function isValidCharacterModel(model)
    if not model or not model:IsA("Model") then return false end
    if not model:IsDescendantOf(Workspace) then return false end
    if model == player.Character then return false end

    local humanoid = getHumanoid(model)
    local head = model:FindFirstChild("Head")
    local root = getRoot(model)

    return humanoid ~= nil
        and humanoid.Health > 0
        and head ~= nil
        and head:IsA("BasePart")
        and root ~= nil
        and root:IsA("BasePart")
end

--==================================================
-- CACHED NPC TRACKING
--==================================================

local function clearESP(model)
    local info = espObjects[model]
    if not info then return end

    if info.Highlight then info.Highlight:Destroy() end
    if info.Billboard then info.Billboard:Destroy() end

    espObjects[model] = nil
end

local function untrackModel(model)
    if not model or not model:IsA("Model") then return end

    trackedModels[model] = nil
    clearESP(model)

    if lockedTarget and lockedTarget.Model == model then
        lockedTarget = nil
    end
end

local function findModelAncestor(instance)
    local current = instance

    while current and current ~= Workspace do
        if current:IsA("Model") then return current end
        current = current.Parent
    end

    return nil
end

local function trackModel(model)
    if not model or not model:IsA("Model") then return end
    if model == player.Character or isPlayerCharacter(model) then return end
    if not model:IsDescendantOf(Workspace) then return end

    if getHumanoid(model) then
        trackedModels[model] = true
    end
end

-- One initial scan; afterwards update the cache through events.
for _, instance in ipairs(Workspace:GetDescendants()) do
    if instance:IsA("Model") then
        trackModel(instance)
    end
end

Workspace.DescendantAdded:Connect(function(instance)
    if instance:IsA("Model") then
        trackModel(instance)
    elseif instance:IsA("Humanoid") then
        local model = findModelAncestor(instance)
        if model then trackModel(model) end
    end
end)

Workspace.DescendantRemoving:Connect(function(instance)
    if instance:IsA("Model") then
        untrackModel(instance)
    end
end)

--==================================================
-- GUI ROOT
--==================================================

local gui = make("ScreenGui", {
    Name = "PHANTOM",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

-- Full-screen dimmer for the initial intro.
local dimmer = make("Frame", {
    Name = "IntroOverlay",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.fromRGB(7, 4, 16),
    BackgroundTransparency = 0,
    BorderSizePixel = 0,
    Visible = true,
    ZIndex = 50,
}, gui)

local introGlow = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.43),
    Size = UDim2.fromOffset(150, 150),
    BackgroundColor3 = Color3.fromRGB(117, 49, 220),
    BackgroundTransparency = 0.7,
    BorderSizePixel = 0,
    ZIndex = 51,
}, dimmer)
corner(introGlow, 100)

local introIconHolder = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.39),
    Size = UDim2.fromOffset(0, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 52,
}, dimmer)
local introIcon = starMark(introIconHolder, 82, Color3.fromRGB(179, 105, 255), 53)

local introTitle = make("TextLabel", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.49),
    Size = UDim2.fromOffset(500, 70),
    BackgroundTransparency = 1,
    Text = "PHANTOM",
    TextColor3 = Color3.fromRGB(241, 229, 255),
    TextTransparency = 1,
    Font = Enum.Font.GothamBlack,
    TextSize = 42,
    ZIndex = 52,
}, dimmer)

local introSubtitle = make("TextLabel", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.56),
    Size = UDim2.fromOffset(500, 28),
    BackgroundTransparency = 1,
    Text = "INITIALIZING INTERFACE",
    TextColor3 = Color3.fromRGB(170, 137, 214),
    TextTransparency = 1,
    Font = Enum.Font.GothamMedium,
    TextSize = 12,
    ZIndex = 52,
}, dimmer)

local introTrack = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.62),
    Size = UDim2.fromOffset(280, 5),
    BackgroundColor3 = Color3.fromRGB(45, 31, 65),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 52,
}, dimmer)
corner(introTrack, 5)

local introFill = make("Frame", {
    Size = UDim2.new(0, 0, 1, 0),
    BackgroundColor3 = Color3.fromRGB(179, 113, 255),
    BorderSizePixel = 0,
    ZIndex = 53,
}, introTrack)
corner(introFill, 5)

--==================================================
-- MAIN WINDOW: WIDE LAYOUT
--==================================================

local WINDOW_WIDTH = 850
local WINDOW_HEIGHT = 560

local main = make("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.fromOffset(WINDOW_WIDTH - 30, WINDOW_HEIGHT - 30),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundColor3 = Color3.fromRGB(15, 10, 27),
    BorderSizePixel = 0,
    Visible = false,
    ClipsDescendants = true,
    ZIndex = 2,
}, gui)

corner(main, 18)
stroke(main, Color3.fromRGB(135, 76, 220), 1.5, 0.08)
local uiScaleObject = Instance.new("UIScale")
uiScaleObject.Name = "PHANTOM_UIScale"
uiScaleObject.Scale = S.UIScale
uiScaleObject.Parent = main


local mainGradient = make("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 14, 43)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(15, 10, 27)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(31, 13, 47)),
    }),
    Rotation = 25,
}, main)

-- Background stars are kept separate from the controls.
local starLayer = make("Frame", {
    Name = "StarLayer",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    ZIndex = 2,
}, main)

local stars = {}

for i = 1, 24 do
    local size = rng:NextInteger(2, 4)
    local comet = rng:NextInteger(1, 5) == 1

    local star = make("Frame", {
        Name = comet and "Comet" or "Star",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(
            rng:NextNumber(0, 1), 0,
            rng:NextNumber(0, 1), 0
        ),
        Size = comet
            and UDim2.fromOffset(size * 2, size * 10)
            or UDim2.fromOffset(size, size),
        Rotation = -25,
        BackgroundColor3 = comet
            and Color3.fromRGB(190, 128, 255)
            or Color3.fromRGB(215, 188, 255),
        BackgroundTransparency = rng:NextNumber(0.1, 0.5),
        BorderSizePixel = 0,
        ZIndex = 2,
    }, starLayer)

    corner(star, 5)

    if comet then
        make("UIGradient", {
            Rotation = 90,
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.1),
                NumberSequenceKeypoint.new(1, 1),
            }),
        }, star)
    end

    stars[#stars + 1] = {
        Object = star,
        Speed = rng:NextNumber(0.035, 0.12),
        Drift = rng:NextNumber(-0.025, 0.025),
        Comet = comet,
    }
end

-- Header
local header = make("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 70),
    BackgroundColor3 = Color3.fromRGB(28, 17, 47),
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Active = true,
    ZIndex = 5,
}, main)

make("Frame", {
    Position = UDim2.new(0, 0, 1, -1),
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = Color3.fromRGB(125, 73, 196),
    BackgroundTransparency = 0.4,
    BorderSizePixel = 0,
    ZIndex = 6,
}, header)

local logo = make("Frame", {
    Position = UDim2.fromOffset(18, 13),
    Size = UDim2.fromOffset(43, 43),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 7,
}, header)
local logoStar = starMark(logo, 34, Color3.fromRGB(179, 105, 255), 8)

make("TextLabel", {
    Position = UDim2.fromOffset(72, 8),
    Size = UDim2.fromOffset(300, 32),
    BackgroundTransparency = 1,
    Text = "PHANTOM",
    TextColor3 = Color3.fromRGB(243, 230, 255),
    Font = Enum.Font.GothamBlack,
    TextSize = 23,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, header)

make("TextLabel", {
    Position = UDim2.fromOffset(73, 39),
    Size = UDim2.fromOffset(330, 18),
    BackgroundTransparency = 1,
    Text = "CONTROL CENTER  /  STUDIO",
    TextColor3 = Color3.fromRGB(166, 137, 202),
    Font = Enum.Font.GothamMedium,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, header)

local onlineDot = make("Frame", {
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(1, -145, 0.5, 0),
    Size = UDim2.fromOffset(7, 7),
    BackgroundColor3 = Color3.fromRGB(123, 255, 178),
    BorderSizePixel = 0,
    ZIndex = 7,
}, header)
corner(onlineDot, 8)

make("TextLabel", {
    Position = UDim2.new(1, -132, 0, 0),
    Size = UDim2.fromOffset(90, 70),
    BackgroundTransparency = 1,
    Text = "SYSTEM ONLINE",
    TextColor3 = Color3.fromRGB(188, 170, 213),
    Font = Enum.Font.GothamMedium,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, header)

local close = make("TextButton", {
    Size = UDim2.fromOffset(34, 34),
    Position = UDim2.new(1, -47, 0, 18),
    BackgroundColor3 = Color3.fromRGB(71, 38, 94),
    Text = "×",
    TextColor3 = Color3.fromRGB(255, 244, 255),
    Font = Enum.Font.GothamBold,
    TextSize = 24,
    AutoButtonColor = false,
    ZIndex = 8,
}, header)
corner(close, 10)
addHover(close, Color3.fromRGB(71, 38, 94), Color3.fromRGB(174, 58, 107))

-- Resize grip for Roblox GUI windows.
local resizeGrip = make("TextButton", {
    Name = "ResizeGrip", AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -5, 1, -5), Size = UDim2.fromOffset(20, 20),
    BackgroundColor3 = Color3.fromRGB(91, 57, 128), Text = "◢",
    TextColor3 = Color3.fromRGB(225, 202, 255), Font = Enum.Font.GothamBold,
    TextSize = 12, AutoButtonColor = false, ZIndex = 20,
}, main)
corner(resizeGrip, 5)

--==================================================
-- SIDEBAR / PAGES
--==================================================

local sidebar = make("Frame", {
    Name = "Sidebar",
    Position = UDim2.fromOffset(12, 82),
    Size = UDim2.new(0, 142, 1, -94),
    BackgroundColor3 = Color3.fromRGB(20, 14, 34),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    ZIndex = 5,
}, main)
corner(sidebar, 13)
stroke(sidebar, Color3.fromRGB(86, 55, 119), 1, 0.55)

make("TextLabel", {
    Position = UDim2.fromOffset(14, 13),
    Size = UDim2.new(1, -24, 0, 20),
    BackgroundTransparency = 1,
    Text = "NAVIGATION",
    TextColor3 = Color3.fromRGB(132, 107, 165),
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 6,
}, sidebar)

local pages = {}
local tabButtons = {}

local function newPage(name)
    local page = make("ScrollingFrame", {
        Name = name,
        Position = UDim2.fromOffset(166, 82),
        Size = UDim2.new(1, -178, 1, -94),
        BackgroundColor3 = Color3.fromRGB(20, 14, 34),
        BackgroundTransparency = 0.08,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Color3.fromRGB(157, 101, 232),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = false,
        ZIndex = 5,
    }, main)

    corner(page, 13)
    stroke(page, Color3.fromRGB(86, 55, 119), 1, 0.55)

    pages[name] = page
    return page
end

local espPage = newPage("ESP")
local aimPage = newPage("AIMBOT")
local playerPage = newPage("PLAYER")
local importPage = newPage("IMPORT")
local settingsPage = newPage("SETTINGS")
local macrosPage = newPage("MACROS")

local tabNames = {
    {"ESP", "◈", "ESP"},
    {"AIMBOT", "⌖", "AIM"},
    {"PLAYER", "♟", "PLAYER"},
    {"IMPORT", "↔", "CONFIG"},
    {"SETTINGS", "⚙", "SETTINGS"},
    {"MACROS", "⌘", "MACROS"},
}

local function showTab(name)
    for pageName, page in pairs(pages) do
        page.Visible = pageName == name
    end

    for tabName, button in pairs(tabButtons) do
        local active = tabName == name

        tween(button, {
            BackgroundColor3 = active
                and Color3.fromRGB(93, 51, 145)
                or Color3.fromRGB(29, 21, 43),
        }, 0.18)

        local indicator = button:FindFirstChild("Indicator")
        if indicator then
            tween(indicator, {
                BackgroundTransparency = active and 0 or 1,
                Size = active
                    and UDim2.new(0, 3, 0, 27)
                    or UDim2.new(0, 3, 0, 10),
            }, 0.18)
        end
    end
end

for i, item in ipairs(tabNames) do
    local name, symbol, label = item[1], item[2], item[3]

    local button = make("TextButton", {
        Name = name,
        Position = UDim2.fromOffset(8, 43 + (i - 1) * 43),
        Size = UDim2.new(1, -16, 0, 41),
        BackgroundColor3 = Color3.fromRGB(29, 21, 43),
        Text = "",
        AutoButtonColor = false,
        ZIndex = 7,
    }, sidebar)
    corner(button, 9)

    local indicator = make("Frame", {
        Name = "Indicator",
        Position = UDim2.new(0, 0, 0.5, -13),
        Size = UDim2.new(0, 3, 0, 10),
        BackgroundColor3 = Color3.fromRGB(211, 164, 255),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 8,
    }, button)
    corner(indicator, 4)

    make("TextLabel", {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.fromOffset(25, 41),
        BackgroundTransparency = 1,
        Text = symbol,
        TextColor3 = Color3.fromRGB(211, 174, 255),
        Font = Enum.Font.GothamBold,
        TextSize = 17,
        ZIndex = 8,
    }, button)

    make("TextLabel", {
        Position = UDim2.fromOffset(40, 0),
        Size = UDim2.new(1, -45, 1, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Color3.fromRGB(240, 231, 255),
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 8,
    }, button)

    button.Activated:Connect(function()
        showTab(name)
    end)

    addHover(
        button,
        Color3.fromRGB(29, 21, 43),
        Color3.fromRGB(57, 36, 80)
    )

    tabButtons[name] = button
end

make("TextLabel", {
    Position = UDim2.new(0, 12, 1, -47),
    Size = UDim2.new(1, -24, 0, 30),
    BackgroundTransparency = 1,
    Text = "PHANTOM  •  V2",
    TextColor3 = Color3.fromRGB(116, 93, 145),
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 6,
}, sidebar)

--==================================================
-- UI ELEMENT HELPERS
--==================================================

local toggleControls = {}
local toggleCallbacks = {}
local sliderSetters = {}
local valueSetters = {}

local function section(parent, text, y)
    return make("TextLabel", {
        Size = UDim2.new(1, -28, 0, 27),
        Position = UDim2.fromOffset(14, y),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Color3.fromRGB(211, 176, 255),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 7,
    }, parent)
end

local function toggle(parent, text, y, key, callback)
    local row = make("Frame", {
        Size = UDim2.new(1, -28, 0, 40),
        Position = UDim2.fromOffset(14, y),
        BackgroundColor3 = Color3.fromRGB(32, 23, 48),
        BorderSizePixel = 0,
        ZIndex = 7,
    }, parent)
    corner(row, 9)
    stroke(row, Color3.fromRGB(91, 61, 120), 1, 0.7)

    make("TextLabel", {
        Size = UDim2.new(1, -90, 1, 0),
        Position = UDim2.fromOffset(13, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Color3.fromRGB(242, 235, 255),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 8,
    }, row)

    local switch = make("TextButton", {
        Size = UDim2.fromOffset(46, 25),
        Position = UDim2.new(1, -59, 0.5, -12),
        BackgroundColor3 = S[key]
            and Color3.fromRGB(151, 85, 235)
            or Color3.fromRGB(66, 54, 80),
        Text = "",
        AutoButtonColor = false,
        ZIndex = 8,
    }, row)
    corner(switch, 15)

    local dot = make("Frame", {
        Size = UDim2.fromOffset(19, 19),
        Position = S[key]
            and UDim2.new(1, -22, 0.5, -9)
            or UDim2.new(0, 3, 0.5, -9),
        BackgroundColor3 = Color3.fromRGB(255, 250, 255),
        BorderSizePixel = 0,
        ZIndex = 9,
    }, switch)
    corner(dot, 12)

    local function refresh()
        tween(switch, {
            BackgroundColor3 = S[key]
                and Color3.fromRGB(151, 85, 235)
                or Color3.fromRGB(66, 54, 80),
        }, 0.2)

        tween(dot, {
            Position = S[key]
                and UDim2.new(1, -22, 0.5, -9)
                or UDim2.new(0, 3, 0.5, -9),
        }, 0.2)
    end

    toggleControls[key] = refresh
    toggleCallbacks[key] = callback

    switch.Activated:Connect(function()
        S[key] = not S[key]
        if callback then callback(S[key]) end
        refresh()
    end)

end

local function slider(parent, text, y, key, minValue, maxValue)
    local label = make("TextLabel", {
        Size = UDim2.new(1, -28, 0, 20),
        Position = UDim2.fromOffset(14, y),
        BackgroundTransparency = 1,
        TextColor3 = Color3.fromRGB(241, 233, 255),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 7,
    }, parent)

    local track = make("Frame", {
        Size = UDim2.new(1, -42, 0, 8),
        Position = UDim2.fromOffset(21, y + 29),
        BackgroundColor3 = Color3.fromRGB(62, 49, 80),
        BorderSizePixel = 0,
        Active = true,
        ZIndex = 7,
    }, parent)
    corner(track, 6)

    local fill = make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(168, 103, 255),
        BorderSizePixel = 0,
        ZIndex = 8,
    }, track)
    corner(fill, 6)

    local knob = make("Frame", {
        Size = UDim2.fromOffset(17, 17),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        BackgroundColor3 = Color3.fromRGB(255, 250, 255),
        BorderSizePixel = 0,
        ZIndex = 9,
    }, track)
    corner(knob, 12)
    stroke(knob, Color3.fromRGB(190, 142, 255), 1, 0.1)

    local function setValue(value)
        S[key] = clampNumber(value, minValue, maxValue, S[key])

        local alpha = (S[key] - minValue) / (maxValue - minValue)
        tween(fill, {Size = UDim2.new(alpha, 0, 1, 0)}, 0.06)
        tween(knob, {Position = UDim2.new(alpha, 0, 0.5, 0)}, 0.06)

        label.Text = text .. ": " .. tostring(S[key])
        if key:find("Distance") then label.Text ..= " m" end
    end

    local function updateFromX(x)
        local width = math.max(track.AbsoluteSize.X, 1)
        local alpha = math.clamp(
            (x - track.AbsolutePosition.X) / width, 0, 1
        )
        setValue(minValue + alpha * (maxValue - minValue))
    end

    sliderSetters[key] = setValue

    local function begin(input)
        sliderState = {Update = updateFromX}
        updateFromX(input.Position.X)
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            begin(input)
        end
    end)

    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            begin(input)
        end
    end)

    setValue(S[key])
end

local function movementControl(parent, title, y, key, minimum, maximum)
    local valueBox = make("TextBox", {
        Size = UDim2.fromOffset(82, 29),
        Position = UDim2.new(1, -108, 0, y - 2),
        BackgroundColor3 = Color3.fromRGB(45, 31, 65),
        TextColor3 = Color3.fromRGB(255, 250, 255),
        Text = tostring(S[key]),
        ClearTextOnFocus = false,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        ZIndex = 8,
    }, parent)
    corner(valueBox, 8)
    stroke(valueBox, Color3.fromRGB(112, 72, 154), 1, 0.5)

    make("TextLabel", {
        Size = UDim2.new(1, -130, 0, 25),
        Position = UDim2.fromOffset(14, y),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Color3.fromRGB(241, 233, 255),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 8,
    }, parent)

    local track = make("Frame", {
        Size = UDim2.new(1, -42, 0, 8),
        Position = UDim2.fromOffset(21, y + 39),
        BackgroundColor3 = Color3.fromRGB(62, 49, 80),
        BorderSizePixel = 0,
        Active = true,
        ZIndex = 7,
    }, parent)
    corner(track, 6)

    local fill = make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(168, 103, 255),
        BorderSizePixel = 0,
        ZIndex = 8,
    }, track)
    corner(fill, 6)

    local knob = make("Frame", {
        Size = UDim2.fromOffset(17, 17),
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.fromRGB(255, 250, 255),
        BorderSizePixel = 0,
        ZIndex = 9,
    }, track)
    corner(knob, 12)
    stroke(knob, Color3.fromRGB(190, 142, 255), 1, 0.1)

    local function setValue(value, userChange)
        S[key] = clampNumber(value, minimum, maximum, S[key])

        local alpha = (S[key] - minimum) / (maximum - minimum)
        tween(fill, {Size = UDim2.new(alpha, 0, 1, 0)}, 0.06)
        tween(knob, {Position = UDim2.new(alpha, 0, 0.5, 0)}, 0.06)

        valueBox.Text = tostring(S[key])

        if userChange then
            if key == "JumpPower" then
                jumpPowerCustomized = true
            else
                walkSpeedCustomized = true
            end

            if applyMovementSettings then
                applyMovementSettings(player.Character)
            end
        end
    end

    local function updateFromX(x)
        local width = math.max(track.AbsoluteSize.X, 1)
        local alpha = math.clamp(
            (x - track.AbsolutePosition.X) / width, 0, 1
        )
        setValue(minimum + alpha * (maximum - minimum), true)
    end

    valueSetters[key] = function(value)
        setValue(value, false)
    end

    valueBox.FocusLost:Connect(function()
        local number = tonumber(valueBox.Text)
        if number then
            setValue(number, true)
        else
            valueBox.Text = tostring(S[key])
        end
    end)

    local function begin(input)
        sliderState = {Update = updateFromX}
        updateFromX(input.Position.X)
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            begin(input)
        end
    end)

    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            begin(input)
        end
    end)

    setValue(S[key], false)
end

local function makeCard(parent, y, height)
    local card = make("Frame", {
        Position = UDim2.fromOffset(12, y),
        Size = UDim2.new(1, -24, 0, height),
        BackgroundColor3 = Color3.fromRGB(26, 19, 40),
        BorderSizePixel = 0,
        ZIndex = 6,
    }, parent)
    corner(card, 11)
    stroke(card, Color3.fromRGB(91, 62, 119), 1, 0.65)
    return card
end

-- Play launches the synthetic local test mode (no server or other players involved).
local playStatus = make("TextLabel", {
    Size = UDim2.new(0.55, -16, 0, 32), Position = UDim2.fromOffset(14, 12),
    BackgroundTransparency = 1, Text = "PLAY STATUS: READY",
    TextColor3 = Color3.fromRGB(183, 164, 210), Font = Enum.Font.GothamBold,
    TextSize = 10, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8,
}, playerPage)
local playButton = make("TextButton", {
    Name = "PlayButton", Size = UDim2.new(0.4, -16, 0, 36), Position = UDim2.new(0.6, 0, 0, 10),
    BackgroundColor3 = Color3.fromRGB(105, 59, 166), Text = "▶  PLAY LOCAL TEST",
    TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 11,
    AutoButtonColor = false, ZIndex = 8,
}, playerPage)
corner(playButton, 9)
addHover(playButton, Color3.fromRGB(105, 59, 166), Color3.fromRGB(136, 79, 205))
local playBusy = false

--==================================================
-- PLAYER MOVEMENT
--==================================================

section(playerPage, "MOVEMENT SETTINGS", 65)

make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 42),
    Position = UDim2.fromOffset(14, 40),
    BackgroundTransparency = 1,
    Text = "Настраивай движение с помощью ползунка или введи число справа. Исходные значения сохраняются, пока ты сам их не изменишь.",
    TextColor3 = Color3.fromRGB(183, 164, 210),
    TextWrapped = true,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 7,
}, playerPage)

local movementCard = makeCard(playerPage, 143, 220)

section(movementCard, "JUMP POWER", 10)
movementControl(movementCard, "Jump Power (0–1000)", 43, "JumpPower", 0, 1000)

section(movementCard, "WALK SPEED", 116)
movementControl(movementCard, "Walk Speed (0–300)", 149, "WalkSpeed", 0, 300)

make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 48),
    Position = UDim2.fromOffset(14, 324),
    BackgroundTransparency = 1,
    Text = "Важно: высокие значения могут конфликтовать с другими скриптами игры. Изменения применяются только после ручного изменения настройки.",
    TextColor3 = Color3.fromRGB(166, 145, 193),
    TextWrapped = true,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 7,
}, playerPage)

applyMovementSettings = function(character)
    character = character or player.Character
    if not character then return end

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 10)
        if not humanoid or not humanoid:IsA("Humanoid") then return end

        if not jumpPowerCustomized then
            if humanoid.UseJumpPower then
                S.JumpPower = clampNumber(
                    humanoid.JumpPower, 0, 1000, S.JumpPower
                )
            end

            if valueSetters.JumpPower then
                valueSetters.JumpPower(S.JumpPower)
            end
        else
            humanoid.UseJumpPower = true
            humanoid.JumpPower = S.JumpPower
        end

        if not walkSpeedCustomized then
            S.WalkSpeed = clampNumber(
                humanoid.WalkSpeed, 0, 300, S.WalkSpeed
            )

            if valueSetters.WalkSpeed then
                valueSetters.WalkSpeed(S.WalkSpeed)
            end
        else
            humanoid.WalkSpeed = S.WalkSpeed
        end
    end)
end

player.CharacterAdded:Connect(function(character)
    applyMovementSettings(character)
end)

-- Extra local test utilities. These are client-side visual/movement options only.
local lightingSnapshot, fogSnapshot
local originalCameraMinZoom = player.CameraMinZoomDistance
local originalCameraMaxZoom = player.CameraMaxZoomDistance
local originalCameraMode = player.CameraMode
local crosshairGui
local jumpConnection
local spinAngle = 0
section(playerPage, "TEST UTILITIES", 442)
local utilityCard = makeCard(playerPage, 477, 355)
toggle(utilityCard, "Infinite Jump", 10, "InfiniteJump")
toggle(utilityCard, "Fullbright (local)", 53, "Fullbright", function(enabled)
    local Lighting = game:GetService("Lighting")
    if enabled then
        if not lightingSnapshot then
            lightingSnapshot = {
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
            }
        end
        Lighting.Brightness = 3
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
        Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
    elseif lightingSnapshot then
        Lighting.Brightness = lightingSnapshot.Brightness
        Lighting.ClockTime = lightingSnapshot.ClockTime
        Lighting.GlobalShadows = lightingSnapshot.GlobalShadows
        Lighting.Ambient = lightingSnapshot.Ambient
        Lighting.OutdoorAmbient = lightingSnapshot.OutdoorAmbient
        lightingSnapshot = nil
    end
end)
toggle(utilityCard, "No Fog (local)", 96, "NoFog", function(enabled)
    local Lighting = game:GetService("Lighting")
    if enabled then
        if not fogSnapshot then
            fogSnapshot = {FogStart = Lighting.FogStart, FogEnd = Lighting.FogEnd}
        end
        Lighting.FogStart = 0
        Lighting.FogEnd = 100000
    elseif fogSnapshot then
        Lighting.FogStart = fogSnapshot.FogStart
        Lighting.FogEnd = fogSnapshot.FogEnd
        fogSnapshot = nil
    end
end)
toggle(utilityCard, "Crosshair", 139, "Crosshair")
toggle(utilityCard, "Third Person", 182, "ThirdPerson", function(enabled)
    local cam = Workspace.CurrentCamera
    if not cam then return end
    if enabled then
        player.CameraMode = Enum.CameraMode.Classic
        player.CameraMinZoomDistance = 8
        player.CameraMaxZoomDistance = math.max(player.CameraMaxZoomDistance, S.ThirdPersonDistance)
    else
        player.CameraMinZoomDistance = originalCameraMinZoom
        player.CameraMaxZoomDistance = originalCameraMaxZoom
        player.CameraMode = originalCameraMode
    end
end)
toggle(utilityCard, "Logo Spin (decorative)", 225, "SpinTest")
slider(utilityCard, "Logo Spin Speed", 270, "SpinSpeed", 1, 20)

-- Character rotation is intentionally separate from GUI animation.
local characterSpinStatus
local spinCharacter, spinRoot, spinHumanoid
local spinBaseYaw, characterSpinAngle, characterSpinCurrentSpeed = nil, 0, 0
local spinPreviousAutoRotate

local function restoreSpinHumanoid()
    if spinHumanoid and spinHumanoid.Parent and spinPreviousAutoRotate ~= nil then
        pcall(function()
            spinHumanoid.AutoRotate = spinPreviousAutoRotate
        end)
    end
    spinCharacter, spinRoot, spinHumanoid = nil, nil, nil
    spinBaseYaw, spinPreviousAutoRotate = nil, nil
    characterSpinAngle, characterSpinCurrentSpeed = 0, 0
end

local function setCharacterSpin(enabled)
    S.CharacterSpinEnabled = enabled == true
    if not S.CharacterSpinEnabled then
        restoreSpinHumanoid()
        if characterSpinStatus and characterSpinStatus.Parent then
            characterSpinStatus.Text = "STATUS: OFF • standard character control restored"
            characterSpinStatus.TextColor3 = Color3.fromRGB(183, 164, 210)
        end
        return
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and getRoot(character)
    if not character or not humanoid or humanoid.Health <= 0 or not root then
        if characterSpinStatus and characterSpinStatus.Parent then
            characterSpinStatus.Text = "STATUS: WAITING FOR CHARACTER"
            characterSpinStatus.TextColor3 = Color3.fromRGB(255, 205, 120)
        end
        return
    end

    if characterSpinStatus and characterSpinStatus.Parent then
        characterSpinStatus.Text = "STATUS: ACTIVE • local character root"
        characterSpinStatus.TextColor3 = Color3.fromRGB(145, 255, 190)
    end
end

section(playerPage, "CHARACTER SPIN", 842)
local characterSpinCard = makeCard(playerPage, 876, 246)
toggle(characterSpinCard, "Enable Character Spin", 8, "CharacterSpinEnabled", setCharacterSpin)
slider(characterSpinCard, "Spin Speed (scale 1–20)", 52, "CharacterSpinSpeed", 1, 20)

local spinDirectionButton = make("TextButton", {
    Size = UDim2.new(0.5, -20, 0, 32),
    Position = UDim2.fromOffset(12, 104),
    BackgroundColor3 = Color3.fromRGB(63, 43, 88),
    Text = "DIRECTION: CLOCKWISE",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    AutoButtonColor = false,
    ZIndex = 8,
}, characterSpinCard)
corner(spinDirectionButton, 8)
addHover(spinDirectionButton, Color3.fromRGB(63, 43, 88), Color3.fromRGB(89, 59, 120))

local resetSpinButton = make("TextButton", {
    Size = UDim2.new(0.5, -20, 0, 32),
    Position = UDim2.new(0.5, 8, 0, 104),
    BackgroundColor3 = Color3.fromRGB(95, 43, 65),
    Text = "RESET ROTATION",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    AutoButtonColor = false,
    ZIndex = 8,
}, characterSpinCard)
corner(resetSpinButton, 8)
addHover(resetSpinButton, Color3.fromRGB(95, 43, 65), Color3.fromRGB(135, 53, 83))

toggle(characterSpinCard, "Smooth Rotation", 145, "CharacterSpinSmooth")
characterSpinStatus = make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 30),
    Position = UDim2.fromOffset(12, 196),
    BackgroundTransparency = 1,
    Text = "STATUS: OFF • standard character control",
    TextColor3 = Color3.fromRGB(183, 164, 210),
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 8,
}, characterSpinCard)

local function refreshSpinDirection()
    spinDirectionButton.Text = S.CharacterSpinDirection == 1
        and "DIRECTION: CLOCKWISE" or "DIRECTION: COUNTERCLOCKWISE"
end

spinDirectionButton.Activated:Connect(function()
    S.CharacterSpinDirection = -S.CharacterSpinDirection
    refreshSpinDirection()
end)

resetSpinButton.Activated:Connect(function()
    setCharacterSpin(false)
    if toggleControls.CharacterSpinEnabled then
        toggleControls.CharacterSpinEnabled()
    end
end)

local function updateCharacterSpin(dt)
    if not S.CharacterSpinEnabled then return end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and getRoot(character)

    if not character or not humanoid or humanoid.Health <= 0 or not root then
        restoreSpinHumanoid()
        if characterSpinStatus and characterSpinStatus.Parent then
            characterSpinStatus.Text = "STATUS: WAITING FOR CHARACTER"
            characterSpinStatus.TextColor3 = Color3.fromRGB(255, 205, 120)
        end
        return
    end

    if spinCharacter ~= character or spinRoot ~= root or spinHumanoid ~= humanoid then
        restoreSpinHumanoid()
        spinCharacter, spinRoot, spinHumanoid = character, root, humanoid
        local _, yaw, _ = root.CFrame:ToOrientation()
        spinBaseYaw = yaw
        characterSpinAngle = 0
        characterSpinCurrentSpeed = 0
        spinPreviousAutoRotate = humanoid.AutoRotate
        humanoid.AutoRotate = false
    end

    local desiredSpeed = S.CharacterSpinSpeed * 36
    if S.CharacterSpinSmooth then
        characterSpinCurrentSpeed += (desiredSpeed - characterSpinCurrentSpeed) * math.clamp(dt * 8, 0, 1)
    else
        characterSpinCurrentSpeed = desiredSpeed
    end

    characterSpinAngle += math.rad(characterSpinCurrentSpeed) * dt * S.CharacterSpinDirection
    -- Preserve world position and rotate only the local character's root yaw.
    -- No GUI or camera properties are changed by this feature.
    root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, spinBaseYaw + characterSpinAngle, 0)

    if characterSpinStatus and characterSpinStatus.Parent then
        characterSpinStatus.Text = "STATUS: ACTIVE • local character root"
        characterSpinStatus.TextColor3 = Color3.fromRGB(145, 255, 190)
    end
end

--==================================================
-- ESP PAGE
--==================================================

section(espPage, "ESP SETTINGS", 12)

local espCard = makeCard(espPage, 47, 240)

toggle(espCard, "ESP игроков", 12, "PlayerESP")
toggle(espCard, "Игроки сквозь стены", 55, "PlayerWalls")
toggle(espCard, "ESP ботов / NPC", 98, "BotESP")
toggle(espCard, "Боты сквозь стены", 141, "BotWalls")
toggle(espCard, "Показывать HP", 184, "HP")

section(espPage, "DISTANCE", 302)

local distanceCard = makeCard(espPage, 337, 115)
slider(distanceCard, "Дистанция игроков", 9, "PlayerDistance", 25, 500)
slider(distanceCard, "Дистанция ботов", 58, "BotDistance", 25, 500)

section(espPage, "COLORS", 470)

local colorCard = makeCard(espPage, 504, 90)

local colorNames = {
    {"Чёрный", Color3.fromRGB(0, 0, 0)},
    {"Красный", Color3.fromRGB(255, 45, 70)},
    {"Зелёный", Color3.fromRGB(40, 255, 120)},
    {"Синий", Color3.fromRGB(50, 130, 255)},
    {"Жёлтый", Color3.fromRGB(255, 225, 30)},
    {"Фиолетовый", Color3.fromRGB(185, 80, 255)},
    {"Белый", Color3.fromRGB(255, 255, 255)},
    {"Голубой", Color3.fromRGB(40, 240, 255)},
}

local selectedColorTarget = "Players"

local targetSelect = make("TextButton", {
    Size = UDim2.new(1, -20, 0, 27),
    Position = UDim2.fromOffset(10, 7),
    BackgroundColor3 = Color3.fromRGB(63, 43, 88),
    Text = "Цвет для: Игроки — нажми, чтобы сменить",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.Gotham,
    TextSize = 10,
    AutoButtonColor = false,
    ZIndex = 8,
}, colorCard)
corner(targetSelect, 7)

targetSelect.Activated:Connect(function()
    selectedColorTarget = selectedColorTarget == "Players" and "Bots" or "Players"
    targetSelect.Text = "Цвет для: "
        .. (selectedColorTarget == "Players" and "Игроки" or "Боты")
        .. " — нажми, чтобы сменить"
end)

for i, item in ipairs(colorNames) do
    local col = (i - 1) % 4
    local row = math.floor((i - 1) / 4)

    local swatch = make("TextButton", {
        Size = UDim2.fromOffset(52, 20),
        Position = UDim2.fromOffset(11 + col * 59, 42 + row * 24),
        BackgroundColor3 = item[2],
        Text = "",
        AutoButtonColor = false,
        ZIndex = 8,
    }, colorCard)
    corner(swatch, 5)
    stroke(swatch, Color3.fromRGB(205, 185, 225), 1, 0.65)

    swatch.Activated:Connect(function()
        if selectedColorTarget == "Players" then
            S.PlayerColor = item[2]
        else
            S.BotColor = item[2]
        end

        tween(swatch, {
            Size = UDim2.fromOffset(56, 22),
        }, 0.08)

        task.delay(0.09, function()
            if swatch.Parent then
                tween(swatch, {
                    Size = UDim2.fromOffset(52, 20),
                }, 0.12)
            end
        end)
    end)
end

--==================================================
-- AIM PAGE
--==================================================

section(aimPage, "AIM ASSIST", 12)

local aimCard = makeCard(aimPage, 47, 130)
local aimStatusLabel = make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 18), Position = UDim2.fromOffset(12, 103),
    BackgroundTransparency = 1, Text = "Aim Assist: Disabled (local test only)",
    TextColor3 = Color3.fromRGB(183, 164, 210), Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8,
}, aimCard)
local function refreshAimStatus()
    local active = S.AimEnabled and S.AimBots
    aimStatusLabel.Text = "Aim Assist: "..(active and "Enabled" or "Disabled").." • local test only"
    aimStatusLabel.TextColor3 = active and Color3.fromRGB(145,255,190) or Color3.fromRGB(183,164,210)
end
toggle(aimCard, "Включить Aim Assist", 12, "AimEnabled", function(value)
    if not value then lockedTarget = nil end
    refreshAimStatus()
end)

toggle(aimCard, "Target local test dummy", 59, "AimBots", function(value)
    if not value then lockedTarget = nil end
    refreshAimStatus()
end)
refreshAimStatus()

section(aimPage, "TARGET SETTINGS", 183)

local targetCard = makeCard(aimPage, 218, 145)

local aimPartButton = make("TextButton", {
    Size = UDim2.new(1, -24, 0, 34),
    Position = UDim2.fromOffset(12, 10),
    BackgroundColor3 = Color3.fromRGB(69, 43, 96),
    Text = "ТОЧКА НАВЕДЕНИЯ: HEAD",
    TextColor3 = Color3.fromRGB(255, 248, 255),
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    AutoButtonColor = false,
    ZIndex = 8,
}, targetCard)
corner(aimPartButton, 8)

aimPartButton.Activated:Connect(function()
    S.AimPart = S.AimPart == "Head" and "Body" or "Head"
    aimPartButton.Text = "ТОЧКА НАВЕДЕНИЯ: "
        .. (S.AimPart == "Head" and "HEAD" or "BODY")
    lockedTarget = nil
end)

slider(targetCard, "Размер круга FOV (px)", 55, "FOV", 50, 900)
slider(targetCard, "Скорость наведения", 102, "Smoothness", 1, 20)

make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 75),
    Position = UDim2.fromOffset(14, 377),
    BackgroundTransparency = 1,
    Text = "Удерживай ПКМ, чтобы захватить цель. После захвата цель сохраняется, даже если временно выходит из FOV или за препятствие. Отпусти ПКМ, чтобы сбросить захват.",
    TextColor3 = Color3.fromRGB(183, 164, 210),
    TextWrapped = true,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 7,
}, aimPage)

-- Additional camera FOV controls (separate from the Aim Assist FOV circle).
section(aimPage, "CAMERA FIELD OF VIEW", 465)
local cameraFovCard = makeCard(aimPage, 497, 95)
local originalCameraFOV = camera and camera.FieldOfView or 70
local cameraFOVCustomized = false
toggle(cameraFovCard, "Включить Camera FOV", 8, "CameraFOVEnabled", function(enabled)
    camera = Workspace.CurrentCamera
    if not camera then return end
    if enabled then
        originalCameraFOV = camera.FieldOfView
        cameraFOVCustomized = true
        tween(camera, {FieldOfView = S.CameraFOV}, 0.25)
    else
        tween(camera, {FieldOfView = originalCameraFOV}, 0.25)
    end
end)
slider(cameraFovCard, "Camera FOV", 51, "CameraFOV", 50, 110)

--==================================================
-- FOV CIRCLE
--==================================================

local fovCircle = make("Frame", {
    Name = "FOVCircle",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(S.FOV * 2, S.FOV * 2),
    BackgroundTransparency = 1,
    Visible = false,
    ZIndex = 40,
}, gui)
corner(fovCircle, 500)
stroke(fovCircle, Color3.fromRGB(185, 115, 255), 1.5, 0.15)

--==================================================
-- IMPORT / EXPORT
--==================================================

section(importPage, "CONFIGURATION", 12)

make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 38),
    Position = UDim2.fromOffset(14, 42),
    BackgroundTransparency = 1,
    Text = "Вставь JSON настроек и нажми IMPORT. EXPORT подготовит JSON текущих настроек.",
    TextColor3 = Color3.fromRGB(183, 164, 210),
    TextWrapped = true,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, importPage)

local importBox = make("TextBox", {
    Size = UDim2.new(1, -28, 0, 180),
    Position = UDim2.fromOffset(14, 87),
    BackgroundColor3 = Color3.fromRGB(12, 8, 20),
    TextColor3 = Color3.fromRGB(230, 220, 255),
    PlaceholderText = '{"PlayerESP": true}',
    PlaceholderColor3 = Color3.fromRGB(125, 110, 145),
    Text = "",
    ClearTextOnFocus = false,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    Font = Enum.Font.Code,
    TextSize = 12,
    MultiLine = true,
    ZIndex = 8,
}, importPage)
corner(importBox, 9)
stroke(importBox, Color3.fromRGB(91, 62, 119), 1, 0.5)

local importButton = make("TextButton", {
    Size = UDim2.new(0.5, -20, 0, 38),
    Position = UDim2.fromOffset(14, 280),
    BackgroundColor3 = Color3.fromRGB(105, 59, 166),
    Text = "IMPORT SETTINGS",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    AutoButtonColor = false,
    ZIndex = 8,
}, importPage)
corner(importButton, 9)
addHover(importButton, Color3.fromRGB(105, 59, 166), Color3.fromRGB(136, 79, 205))

local exportButton = make("TextButton", {
    Size = UDim2.new(0.5, -20, 0, 38),
    Position = UDim2.new(0.5, 6, 0, 280),
    BackgroundColor3 = Color3.fromRGB(63, 43, 88),
    Text = "EXPORT SETTINGS",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    AutoButtonColor = false,
    ZIndex = 8,
}, importPage)
corner(exportButton, 9)
addHover(exportButton, Color3.fromRGB(63, 43, 88), Color3.fromRGB(89, 59, 120))

local importStatus = make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 45),
    Position = UDim2.fromOffset(14, 331),
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = Color3.fromRGB(190, 160, 255),
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, importPage)

-- Local-only test controls: all sample entities are clearly labelled and removable.
section(importPage, "OFFLINE / LOCAL TEST MODE", 390)
local localTestCard = makeCard(importPage, 423, 112)
local localTestStatus = make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 30),
    Position = UDim2.fromOffset(12, 8),
    BackgroundTransparency = 1,
    Text = "LOCAL TEST MODE: OFF  •  no server data",
    TextColor3 = Color3.fromRGB(183, 164, 210),
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 8,
}, localTestCard)

local localTestStart = make("TextButton", {
    Size = UDim2.new(0.5, -18, 0, 34),
    Position = UDim2.fromOffset(10, 58),
    BackgroundColor3 = Color3.fromRGB(105, 59, 166),
    Text = "START LOCAL TEST",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    AutoButtonColor = false,
    ZIndex = 8,
}, localTestCard)
corner(localTestStart, 8)
addHover(localTestStart, Color3.fromRGB(105, 59, 166), Color3.fromRGB(136, 79, 205))

local localTestStop = make("TextButton", {
    Size = UDim2.new(0.5, -18, 0, 34),
    Position = UDim2.new(0.5, 8, 0, 58),
    BackgroundColor3 = Color3.fromRGB(63, 43, 88),
    Text = "STOP / CLEAN UP",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    AutoButtonColor = false,
    ZIndex = 8,
}, localTestCard)
corner(localTestStop, 8)
addHover(localTestStop, Color3.fromRGB(63, 43, 88), Color3.fromRGB(89, 59, 120))

--==================================================
-- SETTINGS: language, UI scale, and size
--==================================================
section(settingsPage, "SETTINGS / APPEARANCE", 12)
local settingsCard = makeCard(settingsPage, 47, 224)
local langLabel = make("TextLabel", {
    Position = UDim2.fromOffset(12, 12), Size = UDim2.new(1, -24, 0, 24),
    BackgroundTransparency = 1, Text = "Interface language", TextColor3 = Color3.fromRGB(241,233,255),
    Font = Enum.Font.GothamBold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8,
}, settingsCard)
local langButton = make("TextButton", {
    Position = UDim2.fromOffset(12, 40), Size = UDim2.new(1, -24, 0, 34),
    BackgroundColor3 = Color3.fromRGB(63,43,88), Text = "English  ▾",
    TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamBold, TextSize = 11, ZIndex = 8,
}, settingsCard)
corner(langButton, 8)
local languageList = {"English", "Русский", "Deutsch", "Українська", "中文"}
local languageIndex = 1
local scaleLabel = make("TextLabel", {
    Position = UDim2.fromOffset(12, 84), Size = UDim2.new(1, -24, 0, 22),
    BackgroundTransparency = 1, Text = "UI Scale: 100%", TextColor3 = Color3.fromRGB(241,233,255),
    Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8,
}, settingsCard)
local scaleMinus = make("TextButton", {
    Position = UDim2.fromOffset(12, 111), Size = UDim2.fromOffset(42, 32),
    BackgroundColor3 = Color3.fromRGB(63,43,88), Text = "−", TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.GothamBold, TextSize = 18, ZIndex = 8,
}, settingsCard)
local scalePlus = make("TextButton", {
    Position = UDim2.fromOffset(62, 111), Size = UDim2.fromOffset(42, 32),
    BackgroundColor3 = Color3.fromRGB(105,59,166), Text = "+", TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.GothamBold, TextSize = 18, ZIndex = 8,
}, settingsCard)
corner(scaleMinus, 7); corner(scalePlus, 7)
local sizeInfo = make("TextLabel", {
    Position = UDim2.fromOffset(12, 154), Size = UDim2.new(1, -24, 0, 46),
    BackgroundTransparency = 1, Text = "Resize: drag the small ◢ grip at the bottom-right. Settings are included in JSON export.",
    TextColor3 = Color3.fromRGB(183,164,210), Font = Enum.Font.Gotham, TextSize = 10,
    TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8,
}, settingsCard)

-- A shared dictionary updates the same UI tree rather than duplicating pages.
local localization = {
    ["English"] = {
        ["NAVIGATION"]="NAVIGATION", ["SETTINGS"]="SETTINGS", ["MACROS"]="MACROS", ["CONFIG"]="CONFIG",
        ["Interface language"]="Interface language", ["UI Scale"]="UI Scale", ["PLAY STATUS: READY"]="PLAY STATUS: READY",
        ["▶  PLAY LOCAL TEST"]="▶  PLAY LOCAL TEST", ["Ready"]="Ready", ["Starting"]="Starting", ["Running"]="Running", ["Error"]="Error",
        ["Create Macro"]="Create Macro", ["Save Macro"]="Save Macro", ["Delete Macro"]="Delete Macro", ["Set Keybind"]="Set Keybind",
        ["Clear Keybind"]="Clear Keybind", ["Macro name"]="Macro name", ["Description"]="Description", ["Action"]="Action",
        ["Feature"]="Feature", ["Text / sequence"]="Text / sequence", ["Enabled"]="Enabled", ["Disabled"]="Disabled",
    },
    ["Русский"] = {
        ["NAVIGATION"]="НАВИГАЦИЯ", ["SETTINGS"]="НАСТРОЙКИ", ["MACROS"]="МАКРОСЫ", ["CONFIG"]="КОНФИГ",
        ["Interface language"]="Язык интерфейса", ["UI Scale"]="Масштаб интерфейса", ["PLAY STATUS: READY"]="СОСТОЯНИЕ PLAY: ГОТОВ",
        ["▶  PLAY LOCAL TEST"]="▶  ЗАПУСТИТЬ ТЕСТ", ["Ready"]="Готово", ["Starting"]="Запуск", ["Running"]="Работает", ["Error"]="Ошибка",
        ["Create Macro"]="Создать макрос", ["Save Macro"]="Сохранить макрос", ["Delete Macro"]="Удалить макрос", ["Set Keybind"]="Назначить клавишу",
        ["Clear Keybind"]="Очистить клавишу", ["Macro name"]="Название макроса", ["Description"]="Описание", ["Action"]="Действие",
        ["Feature"]="Функция", ["Text / sequence"]="Текст / последовательность", ["Enabled"]="Включено", ["Disabled"]="Выключено",
        ["Включить Aim Assist"]="Включить Aim Assist", ["MOVEMENT SETTINGS"]="НАСТРОЙКИ ДВИЖЕНИЯ", ["TEST UTILITIES"]="ТЕСТОВЫЕ ФУНКЦИИ",
        ["CHARACTER SPIN"]="ВРАЩЕНИЕ ПЕРСОНАЖА", ["ESP SETTINGS"]="НАСТРОЙКИ ESP", ["AIM ASSIST"]="ПОМОЩЬ ПРИ НАВЕДЕНИИ",
    },
    ["Deutsch"] = {
        ["NAVIGATION"]="NAVIGATION", ["SETTINGS"]="EINSTELLUNGEN", ["MACROS"]="MAKROS", ["CONFIG"]="KONFIG",
        ["Interface language"]="Oberflächensprache", ["UI Scale"]="UI-Skalierung", ["PLAY STATUS: READY"]="PLAY-STATUS: BEREIT",
        ["▶  PLAY LOCAL TEST"]="▶  LOKALEN TEST STARTEN", ["Ready"]="Bereit", ["Starting"]="Startet", ["Running"]="Läuft", ["Error"]="Fehler",
        ["Create Macro"]="Makro erstellen", ["Save Macro"]="Makro speichern", ["Delete Macro"]="Makro löschen", ["Set Keybind"]="Taste zuweisen",
        ["Clear Keybind"]="Taste löschen", ["Macro name"]="Makroname", ["Description"]="Beschreibung", ["Action"]="Aktion",
        ["Feature"]="Funktion", ["Text / sequence"]="Text / Sequenz", ["Enabled"]="Aktiviert", ["Disabled"]="Deaktiviert",
    },
    ["Українська"] = {
        ["NAVIGATION"]="НАВІГАЦІЯ", ["SETTINGS"]="НАЛАШТУВАННЯ", ["MACROS"]="МАКРОСИ", ["CONFIG"]="КОНФІГ",
        ["Interface language"]="Мова інтерфейсу", ["UI Scale"]="Масштаб інтерфейсу", ["PLAY STATUS: READY"]="СТАН PLAY: ГОТОВО",
        ["▶  PLAY LOCAL TEST"]="▶  ЗАПУСТИТИ ТЕСТ", ["Ready"]="Готово", ["Starting"]="Запуск", ["Running"]="Працює", ["Error"]="Помилка",
        ["Create Macro"]="Створити макрос", ["Save Macro"]="Зберегти макрос", ["Delete Macro"]="Видалити макрос", ["Set Keybind"]="Призначити клавішу",
        ["Clear Keybind"]="Очистити клавішу", ["Macro name"]="Назва макросу", ["Description"]="Опис", ["Action"]="Дія",
        ["Feature"]="Функція", ["Text / sequence"]="Текст / послідовність", ["Enabled"]="Увімкнено", ["Disabled"]="Вимкнено",
    },
    ["中文"] = {
        ["NAVIGATION"]="导航", ["SETTINGS"]="设置", ["MACROS"]="宏", ["CONFIG"]="配置",
        ["Interface language"]="界面语言", ["UI Scale"]="界面缩放", ["PLAY STATUS: READY"]="播放状态：就绪",
        ["▶  PLAY LOCAL TEST"]="▶ 运行本地测试", ["Ready"]="就绪", ["Starting"]="正在启动", ["Running"]="运行中", ["Error"]="错误",
        ["Create Macro"]="创建宏", ["Save Macro"]="保存宏", ["Delete Macro"]="删除宏", ["Set Keybind"]="设置快捷键",
        ["Clear Keybind"]="清除快捷键", ["Macro name"]="宏名称", ["Description"]="描述", ["Action"]="操作",
        ["Feature"]="功能", ["Text / sequence"]="文本 / 序列", ["Enabled"]="已启用", ["Disabled"]="已禁用",
    },
}
local extraTranslations = {
    ["Русский"] = {
        ["PLAYER"] = "ИГРОК",
        ["ESP"] = "ESP",
        ["AIM"] = "НАВЕДЕНИЕ",
        ["MOVEMENT SETTINGS"] = "НАСТРОЙКИ ДВИЖЕНИЯ",
        ["JUMP POWER"] = "СИЛА ПРЫЖКА",
        ["WALK SPEED"] = "СКОРОСТЬ ХОДЬБЫ",
        ["Jump Power (0–1000)"] = "Сила прыжка (0–1000)",
        ["Walk Speed (0–300)"] = "Скорость ходьбы (0–300)",
        ["TEST UTILITIES"] = "ТЕСТОВЫЕ ФУНКЦИИ",
        ["Infinite Jump"] = "Бесконечный прыжок",
        ["Fullbright (local)"] = "Полная яркость (локально)",
        ["No Fog (local)"] = "Без тумана (локально)",
        ["Crosshair"] = "Прицел",
        ["Third Person"] = "Вид от третьего лица",
        ["Logo Spin (decorative)"] = "Вращение логотипа (декор)",
        ["Logo Spin Speed"] = "Скорость вращения логотипа",
        ["CHARACTER SPIN"] = "ВРАЩЕНИЕ ПЕРСОНАЖА",
        ["Enable Character Spin"] = "Включить вращение персонажа",
        ["Spin Speed (scale 1–20)"] = "Скорость вращения (1–20)",
        ["Smooth Rotation"] = "Плавное вращение",
        ["RESET ROTATION"] = "СБРОСИТЬ ВРАЩЕНИЕ",
        ["ESP SETTINGS"] = "НАСТРОЙКИ ESP",
        ["ESP игроков"] = "ESP игроков",
        ["Игроки сквозь стены"] = "Игроки сквозь стены",
        ["ESP ботов / NPC"] = "ESP ботов / NPC",
        ["Боты сквозь стены"] = "Боты сквозь стены",
        ["Показывать HP"] = "Показывать здоровье",
        ["DISTANCE"] = "ДИСТАНЦИЯ",
        ["Дистанция игроков"] = "Дистанция игроков",
        ["Дистанция ботов"] = "Дистанция ботов",
        ["COLORS"] = "ЦВЕТА",
        ["AIM ASSIST"] = "ПОМОЩЬ ПРИ НАВЕДЕНИИ",
        ["Включить Aim Assist"] = "Включить Aim Assist",
        ["Наведение на игроков / ботов"] = "Наведение на тестовую цель",
        ["TARGET SETTINGS"] = "НАСТРОЙКИ ЦЕЛИ",
        ["Размер круга FOV (px)"] = "Размер круга FOV (px)",
        ["Скорость наведения"] = "Скорость наведения",
        ["CAMERA FIELD OF VIEW"] = "УГОЛ ОБЗОРА КАМЕРЫ",
        ["LOCAL TEST MODE"] = "ЛОКАЛЬНЫЙ ТЕСТОВЫЙ РЕЖИМ",
        ["START LOCAL TEST"] = "ЗАПУСТИТЬ ЛОКАЛЬНЫЙ ТЕСТ",
        ["STOP / CLEAN UP"] = "ОСТАНОВИТЬ / ОЧИСТИТЬ",
        ["IMPORT SETTINGS"] = "ИМПОРТ НАСТРОЕК",
        ["EXPORT SETTINGS"] = "ЭКСПОРТ НАСТРОЕК",
        ["Interface language"] = "Язык интерфейса",
        ["Create Macro"] = "Создать макрос",
        ["Save Macro"] = "Сохранить макрос",
        ["Delete Macro"] = "Удалить макрос",
        ["Set Keybind"] = "Назначить клавишу",
        ["Clear Keybind"] = "Очистить клавишу",
    },
    ["Deutsch"] = {
        ["PLAYER"] = "SPIELER",
        ["AIM"] = "ZIELEN",
        ["MOVEMENT SETTINGS"] = "BEWEGUNGSEINSTELLUNGEN",
        ["JUMP POWER"] = "SPRUNGKRAFT",
        ["WALK SPEED"] = "LAUFTEMPO",
        ["TEST UTILITIES"] = "TESTWERKZEUGE",
        ["Infinite Jump"] = "Unbegrenzter Sprung",
        ["Fullbright (local)"] = "Volle Helligkeit (lokal)",
        ["No Fog (local)"] = "Kein Nebel (lokal)",
        ["Crosshair"] = "Fadenkreuz",
        ["Third Person"] = "Dritte Person",
        ["Logo Spin (decorative)"] = "Logo-Drehung (dekorativ)",
        ["Logo Spin Speed"] = "Logo-Drehgeschwindigkeit",
        ["CHARACTER SPIN"] = "CHARAKTERDREHUNG",
        ["Enable Character Spin"] = "Charakterdrehung aktivieren",
        ["Smooth Rotation"] = "Sanfte Drehung",
        ["RESET ROTATION"] = "DREHUNG ZURÜCKSETZEN",
        ["ESP SETTINGS"] = "ESP-EINSTELLUNGEN",
        ["DISTANCE"] = "ENTFERNUNG",
        ["COLORS"] = "FARBEN",
        ["AIM ASSIST"] = "ZIELHILFE",
        ["Включить Aim Assist"] = "Zielhilfe aktivieren",
        ["TARGET SETTINGS"] = "ZIELEINSTELLUNGEN",
        ["CAMERA FIELD OF VIEW"] = "KAMERASICHTFELD",
        ["START LOCAL TEST"] = "LOKALEN TEST STARTEN",
        ["STOP / CLEAN UP"] = "STOPPEN / BEREINIGEN",
        ["IMPORT SETTINGS"] = "EINSTELLUNGEN IMPORTIEREN",
        ["EXPORT SETTINGS"] = "EINSTELLUNGEN EXPORTIEREN",
    },
    ["Українська"] = {
        ["PLAYER"] = "ГРАВЕЦЬ",
        ["AIM"] = "НАВЕДЕННЯ",
        ["MOVEMENT SETTINGS"] = "НАЛАШТУВАННЯ РУХУ",
        ["JUMP POWER"] = "СИЛА СТРИБКА",
        ["WALK SPEED"] = "ШВИДКІСТЬ ХОДЬБИ",
        ["TEST UTILITIES"] = "ТЕСТОВІ ФУНКЦІЇ",
        ["Infinite Jump"] = "Нескінченний стрибок",
        ["Fullbright (local)"] = "Повна яскравість (локально)",
        ["No Fog (local)"] = "Без туману (локально)",
        ["Crosshair"] = "Приціл",
        ["Third Person"] = "Вигляд від третьої особи",
        ["Logo Spin (decorative)"] = "Обертання логотипа (декор)",
        ["CHARACTER SPIN"] = "ОБЕРТАННЯ ПЕРСОНАЖА",
        ["Enable Character Spin"] = "Увімкнути обертання персонажа",
        ["Smooth Rotation"] = "Плавне обертання",
        ["RESET ROTATION"] = "СКИНУТИ ОБЕРТАННЯ",
        ["ESP SETTINGS"] = "НАЛАШТУВАННЯ ESP",
        ["DISTANCE"] = "ВІДСТАНЬ",
        ["COLORS"] = "КОЛЬОРИ",
        ["AIM ASSIST"] = "ДОПОМОГА З ПРИЦІЛЮВАННЯМ",
        ["TARGET SETTINGS"] = "НАЛАШТУВАННЯ ЦІЛІ",
        ["START LOCAL TEST"] = "ЗАПУСТИТИ ЛОКАЛЬНИЙ ТЕСТ",
        ["STOP / CLEAN UP"] = "ЗУПИНИТИ / ОЧИСТИТИ",
        ["IMPORT SETTINGS"] = "ІМПОРТ НАЛАШТУВАНЬ",
        ["EXPORT SETTINGS"] = "ЕКСПОРТ НАЛАШТУВАНЬ",
    },
    ["中文"] = {
        ["PLAYER"] = "玩家",
        ["AIM"] = "瞄准",
        ["MOVEMENT SETTINGS"] = "移动设置",
        ["JUMP POWER"] = "跳跃力度",
        ["WALK SPEED"] = "行走速度",
        ["TEST UTILITIES"] = "测试工具",
        ["Infinite Jump"] = "无限跳跃",
        ["Fullbright (local)"] = "本地全亮",
        ["No Fog (local)"] = "本地无雾",
        ["Crosshair"] = "准星",
        ["Third Person"] = "第三人称",
        ["Logo Spin (decorative)"] = "徽标旋转（装饰）",
        ["CHARACTER SPIN"] = "角色旋转",
        ["Enable Character Spin"] = "启用角色旋转",
        ["Smooth Rotation"] = "平滑旋转",
        ["RESET ROTATION"] = "重置旋转",
        ["ESP SETTINGS"] = "ESP 设置",
        ["DISTANCE"] = "距离",
        ["COLORS"] = "颜色",
        ["AIM ASSIST"] = "瞄准辅助",
        ["Включить Aim Assist"] = "启用瞄准辅助",
        ["TARGET SETTINGS"] = "目标设置",
        ["START LOCAL TEST"] = "启动本地测试",
        ["STOP / CLEAN UP"] = "停止 / 清理",
        ["IMPORT SETTINGS"] = "导入设置",
        ["EXPORT SETTINGS"] = "导出设置",
    },
}
for language, entries in pairs(extraTranslations) do
    for key, value in pairs(entries) do
        localization[language][key] = value
    end
end
local moreTranslations = {
["Русский"] = {
["CONTROL CENTER  /  STUDIO"]="ЦЕНТР УПРАВЛЕНИЯ / STUDIO", ["SYSTEM ONLINE"]="СИСТЕМА РАБОТАЕТ",
["OFFLINE / LOCAL TEST MODE"]="ЛОКАЛЬНЫЙ ТЕСТОВЫЙ РЕЖИМ", ["LOCAL TEST MODE: OFF  •  no server data"]="ЛОКАЛЬНЫЙ ТЕСТ: ВЫКЛ. • данные сервера не используются",
["START LOCAL TEST"]="ЗАПУСТИТЬ ЛОКАЛЬНЫЙ ТЕСТ", ["STOP / CLEAN UP"]="ОСТАНОВИТЬ / ОЧИСТИТЬ",
["Target local test dummy"]="Цель локального теста", ["CAMERA FIELD OF VIEW"]="УГОЛ ОБЗОРА КАМЕРЫ",
["DIRECTION: CLOCKWISE"]="НАПРАВЛЕНИЕ: ПО ЧАСОВОЙ", ["DIRECTION: COUNTERCLOCKWISE"]="НАПРАВЛЕНИЕ: ПРОТИВ ЧАСОВОЙ",
["STATUS: OFF • standard character control"]="СТАТУС: ВЫКЛ. • обычное управление", ["STATUS: ACTIVE • local character root"]="СТАТУС: АКТИВНО • локальный персонаж",
["STATUS: WAITING FOR CHARACTER"]="СТАТУС: ОЖИДАНИЕ ПЕРСОНАЖА", ["RESET ROTATION"]="СБРОСИТЬ ВРАЩЕНИЕ",
["PLAY STATUS: RUNNING • local dummy created"]="PLAY: РАБОТАЕТ • локальная цель создана",
["PLAY STATUS: STARTING"]="PLAY: ЗАПУСК", ["IMPORT SETTINGS"]="ИМПОРТ НАСТРОЕК", ["EXPORT SETTINGS"]="ЭКСПОРТ НАСТРОЕК",
},
["Deutsch"] = {
["CONTROL CENTER  /  STUDIO"]="STEUERZENTRUM / STUDIO", ["SYSTEM ONLINE"]="SYSTEM AKTIV",
["OFFLINE / LOCAL TEST MODE"]="OFFLINE-/LOKALER TESTMODUS", ["LOCAL TEST MODE: OFF  •  no server data"]="LOKALER TEST: AUS • keine Serverdaten",
["START LOCAL TEST"]="LOKALEN TEST STARTEN", ["STOP / CLEAN UP"]="STOPPEN / BEREINIGEN",
["Target local test dummy"]="Lokales Testziel", ["CAMERA FIELD OF VIEW"]="KAMERASICHTFELD",
["RESET ROTATION"]="DREHUNG ZURÜCKSETZEN", ["IMPORT SETTINGS"]="EINSTELLUNGEN IMPORTIEREN", ["EXPORT SETTINGS"]="EINSTELLUNGEN EXPORTIEREN",
},
["Українська"] = {
["CONTROL CENTER  /  STUDIO"]="ЦЕНТР КЕРУВАННЯ / STUDIO", ["SYSTEM ONLINE"]="СИСТЕМА ПРАЦЮЄ",
["OFFLINE / LOCAL TEST MODE"]="ЛОКАЛЬНИЙ ТЕСТОВИЙ РЕЖИМ", ["LOCAL TEST MODE: OFF  •  no server data"]="ЛОКАЛЬНИЙ ТЕСТ: ВИМК. • без даних сервера",
["START LOCAL TEST"]="ЗАПУСТИТИ ЛОКАЛЬНИЙ ТЕСТ", ["STOP / CLEAN UP"]="ЗУПИНИТИ / ОЧИСТИТИ",
["Target local test dummy"]="Локальна тестова ціль", ["CAMERA FIELD OF VIEW"]="КУТ ОГЛЯДУ КАМЕРИ",
["RESET ROTATION"]="СКИНУТИ ОБЕРТАННЯ", ["IMPORT SETTINGS"]="ІМПОРТ НАЛАШТУВАНЬ", ["EXPORT SETTINGS"]="ЕКСПОРТ НАЛАШТУВАНЬ",
},
["中文"] = {
["CONTROL CENTER  /  STUDIO"]="控制中心 / STUDIO", ["SYSTEM ONLINE"]="系统在线",
["OFFLINE / LOCAL TEST MODE"]="离线 / 本地测试模式", ["LOCAL TEST MODE: OFF  •  no server data"]="本地测试：关闭 • 不使用服务器数据",
["START LOCAL TEST"]="启动本地测试", ["STOP / CLEAN UP"]="停止 / 清理",
["Target local test dummy"]="本地测试目标", ["CAMERA FIELD OF VIEW"]="摄像机视野",
["RESET ROTATION"]="重置旋转", ["IMPORT SETTINGS"]="导入设置", ["EXPORT SETTINGS"]="导出设置",
}
}
for language, entries in pairs(moreTranslations) do
    for key, value in pairs(entries) do localization[language][key] = value end
end

local commonTranslations = {
    ["English"] = {
        ["Настраивай движение с помощью ползунка или введи число справа. Исходные значения сохраняются, пока ты сам их не изменишь."] = "Adjust movement with the slider or enter a number on the right. Values are captured from the character until changed.",
        ["Важно: высокие значения могут конфликтовать с другими скриптами игры. Изменения применяются только после ручного изменения настройки."] = "High values may conflict with other game scripts. Changes apply only after you manually change a setting.",
        ["Цвет для: Игроки — нажми, чтобы сменить"] = "Color target: Players — click to switch",
        ["Цвет для: "] = "Color target: ",
        ["ТОЧКА НАВЕДЕНИЯ: HEAD"] = "AIM PART: HEAD",
        ["ТОЧКА НАВЕДЕНИЯ: "] = "AIM PART: ",
        ["Удерживай ПКМ, чтобы захватить цель. После захвата цель сохраняется, даже если временно выходит из FOV или за препятствие. Отпусти ПКМ, чтобы сбросить захват."] = "Hold RMB to acquire the local test target. Release RMB to drop the lock.",
        ["Вставь JSON настроек и нажми IMPORT. EXPORT подготовит JSON текущих настроек."] = "Paste settings JSON and press IMPORT. EXPORT prepares the current settings JSON.",
        ["Ошибка: проверь JSON."] = "Error: check the JSON.",
        ["Ошибка: неподдерживаемая версия конфигурации."] = "Error: unsupported config version.",
        ["Настройки импортированы."] = "Settings imported.",
        ["JSON готов. Скопируй его из поля."] = "JSON ready. Copy it from the field.",
        ["Не удалось создать JSON."] = "Could not create JSON.",
        ["ESP игроков"] = "Player ESP (local test only)",
        ["Игроки сквозь стены"] = "Players through walls (local test only)",
        ["ESP ботов / NPC"] = "NPC ESP",
        ["Боты сквозь стены"] = "NPCs through walls",
        ["Показывать HP"] = "Show HP",
        ["Включить Aim Assist"] = "Enable Aim Assist",
        ["Дистанция игроков"] = "Player distance",
        ["Дистанция ботов"] = "NPC distance",
        ["Размер круга FOV (px)"] = "FOV circle size (px)",
        ["Скорость наведения"] = "Aim speed",
        ["Включить Camera FOV"] = "Enable Camera FOV",
        ["Цвет для: Игроки"] = "Color target: Players",
        ["Чёрный"] = "Black",
        ["Красный"] = "Red",
        ["Зелёный"] = "Green",
        ["Синий"] = "Blue",
        ["Жёлтый"] = "Yellow",
        ["Фиолетовый"] = "Purple",
        ["Белый"] = "White",
        ["Голубой"] = "Cyan",
    },
    ["Deutsch"] = {
        ["ESP игроков"] = "Spieler-ESP (nur lokaler Test)",
        ["Игроки сквозь стены"] = "Spieler durch Wände (nur lokaler Test)",
        ["ESP ботов / NPC"] = "NPC-ESP",
        ["Боты сквозь стены"] = "NPCs durch Wände",
        ["Показывать HP"] = "Lebenspunkte anzeigen",
        ["Включить Aim Assist"] = "Zielhilfe aktivieren",
        ["Дистанция игроков"] = "Spielerentfernung",
        ["Дистанция ботов"] = "NPC-Entfernung",
        ["Размер круга FOV (px)"] = "FOV-Kreisgröße (px)",
        ["Скорость наведения"] = "Zielgeschwindigkeit",
        ["Цвет для: Игроки — нажми, чтобы сменить"] = "Farbe für Spieler — klicken zum Wechseln",
        ["ТОЧКА НАВЕДЕНИЯ: HEAD"] = "ZIELPUNKT: KOPF",
        ["Настройки импортированы."] = "Einstellungen importiert.",
        ["Ошибка: проверь JSON."] = "Fehler: JSON überprüfen.",
        ["Не удалось создать JSON."] = "JSON konnte nicht erstellt werden.",
    },
    ["Українська"] = {
        ["ESP игроков"] = "ESP гравців (лише локальний тест)",
        ["Игроки сквозь стены"] = "Гравці крізь стіни (лише локальний тест)",
        ["ESP ботов / NPC"] = "ESP NPC",
        ["Боты сквозь стены"] = "NPC крізь стіни",
        ["Показывать HP"] = "Показувати здоров’я",
        ["Включить Aim Assist"] = "Увімкнути допомогу прицілювання",
        ["Дистанция игроков"] = "Відстань до гравців",
        ["Дистанция ботов"] = "Відстань до NPC",
        ["Размер круга FOV (px)"] = "Розмір кола FOV (пікс.)",
        ["Скорость наведения"] = "Швидкість наведення",
        ["Цвет для: Игроки — нажми, чтобы сменить"] = "Колір для гравців — натисніть, щоб змінити",
        ["ТОЧКА НАВЕДЕНИЯ: HEAD"] = "ТОЧКА НАВЕДЕННЯ: ГОЛОВА",
        ["Настройки импортированы."] = "Налаштування імпортовано.",
        ["Ошибка: проверь JSON."] = "Помилка: перевірте JSON.",
        ["Не удалось создать JSON."] = "Не вдалося створити JSON.",
    },
    ["中文"] = {
        ["ESP игроков"] = "玩家 ESP（仅本地测试）",
        ["Игроки сквозь стены"] = "透视玩家（仅本地测试）",
        ["ESP ботов / NPC"] = "NPC ESP",
        ["Боты сквозь стены"] = "透视 NPC",
        ["Показывать HP"] = "显示生命值",
        ["Включить Aim Assist"] = "启用瞄准辅助",
        ["Дистанция игроков"] = "玩家距离",
        ["Дистанция ботов"] = "NPC 距离",
        ["Размер круга FOV (px)"] = "FOV 圆圈大小（像素）",
        ["Скорость наведения"] = "瞄准速度",
        ["Цвет для: Игроки — нажми, чтобы сменить"] = "玩家颜色 — 点击切换",
        ["ТОЧКА НАВЕДЕНИЯ: HEAD"] = "瞄准部位：头部",
        ["Настройки импортированы."] = "设置已导入。",
        ["Ошибка: проверь JSON."] = "错误：请检查 JSON。",
        ["Не удалось создать JSON."] = "无法生成 JSON。",
    },
}
for language, entries in pairs(commonTranslations) do
    for key, value in pairs(entries) do localization[language][key] = value end
end

local function translateTree(language)
    local dict = localization[language] or localization.English
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            local key = obj:GetAttribute("PHANTOM_OriginalText")
            if not key then
                key = obj.Text
                obj:SetAttribute("PHANTOM_OriginalText", key)
            end
            obj.Text = dict[key] or localization.English[key] or key
        end
        if obj:IsA("TextBox") then
            local key = obj:GetAttribute("PHANTOM_OriginalPlaceholder")
            if not key then key = obj.PlaceholderText; obj:SetAttribute("PHANTOM_OriginalPlaceholder", key) end
            obj.PlaceholderText = dict[key] or localization.English[key] or key
        end
    end
end
local refreshScale
local function setLanguage(language)
    if not localization[language] then language = "English" end
    S.UILanguage = language
    for i, name in ipairs(languageList) do if name == language then languageIndex = i end end
    langButton.Text = language .. "  ▾"
    translateTree(language)
    -- restore selected language control after translating the tree
    langButton.Text = language .. "  ▾"
end
langButton.Activated:Connect(function()
    languageIndex = languageIndex % #languageList + 1
    setLanguage(languageList[languageIndex])
    refreshScale()
end)
refreshScale = function()
    uiScaleObject.Scale = S.UIScale
    scaleLabel.Text = (localization[S.UILanguage] and localization[S.UILanguage]["UI Scale"] or "UI Scale") .. ": " .. tostring(math.floor(S.UIScale*100)) .. "%"
end
scaleMinus.Activated:Connect(function() S.UIScale = math.max(0.75, math.floor((S.UIScale-0.05)*100+0.5)/100); refreshScale() end)
scalePlus.Activated:Connect(function() S.UIScale = math.min(1.25, math.floor((S.UIScale+0.05)*100+0.5)/100); refreshScale() end)

--==================================================
-- MACROS / GLOBAL KEYBINDS
--==================================================
local setLocalTestMode
local macros = {}
local selectedMacroId
local nextMacroId = 0
local waitingForMacroKey = false
local macroStatus
local macroNameBox, macroDescriptionBox, macroActionButton, macroFeatureButton, macroTextBox
local macroList
local macroEnabledButton
local macroKeyButton
local macroEditorTestBox
local macroActionTypes = {"Toggle Feature", "Enable Feature", "Disable Feature", "Execute Action", "Insert Text", "Copy Text", "Sequence", "Reset Setting"}
local macroFeatures = {"AimEnabled", "AimBots", "PlayerESP", "BotESP", "PlayerWalls", "BotWalls", "HP", "InfiniteJump", "Fullbright", "NoFog", "Crosshair", "ThirdPerson", "CameraFOVEnabled", "CharacterSpinEnabled", "SpinTest"}
local actionIndex, featureIndex = 1, 1
section(macrosPage, "MACRO MANAGER", 12)
local macroCard = makeCard(macrosPage, 47, 410)
macroNameBox = make("TextBox", {Position=UDim2.fromOffset(12,10), Size=UDim2.new(0.5,-18,0,30), BackgroundColor3=Color3.fromRGB(45,31,65), TextColor3=Color3.new(1,1,1), PlaceholderText="Macro name", Text="", ClearTextOnFocus=false, Font=Enum.Font.Gotham, TextSize=11, ZIndex=8}, macroCard); corner(macroNameBox,7)
macroDescriptionBox = make("TextBox", {Position=UDim2.new(0.5,6,0,10), Size=UDim2.new(0.5,-18,0,30), BackgroundColor3=Color3.fromRGB(45,31,65), TextColor3=Color3.new(1,1,1), PlaceholderText="Description", Text="", ClearTextOnFocus=false, Font=Enum.Font.Gotham, TextSize=11, ZIndex=8}, macroCard); corner(macroDescriptionBox,7)
macroActionButton = make("TextButton", {Position=UDim2.fromOffset(12,48), Size=UDim2.new(0.5,-18,0,31), BackgroundColor3=Color3.fromRGB(63,43,88), Text="Action: Toggle Feature", TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=10, ZIndex=8}, macroCard); corner(macroActionButton,7)
macroFeatureButton = make("TextButton", {Position=UDim2.new(0.5,6,0,48), Size=UDim2.new(0.5,-18,0,31), BackgroundColor3=Color3.fromRGB(63,43,88), Text="Feature: AimEnabled", TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=10, ZIndex=8}, macroCard); corner(macroFeatureButton,7)
macroTextBox = make("TextBox", {Position=UDim2.fromOffset(12,87), Size=UDim2.new(1,-24,0,48), BackgroundColor3=Color3.fromRGB(12,8,20), TextColor3=Color3.new(1,1,1), PlaceholderText="Text / sequence (Sequence: comma-separated feature keys)", Text="", ClearTextOnFocus=false, TextWrapped=true, MultiLine=true, Font=Enum.Font.Code, TextSize=10, ZIndex=8}, macroCard); corner(macroTextBox,7)
macroKeyButton = make("TextButton", {Position=UDim2.fromOffset(12,143), Size=UDim2.new(0.5,-18,0,32), BackgroundColor3=Color3.fromRGB(63,43,88), Text="Set Keybind: NONE", TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=10, ZIndex=8}, macroCard); corner(macroKeyButton,7)
macroEnabledButton = make("TextButton", {Position=UDim2.new(0.5,6,0,143), Size=UDim2.new(0.5,-18,0,32), BackgroundColor3=Color3.fromRGB(63,43,88), Text="Enabled: YES", TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=10, ZIndex=8}, macroCard); corner(macroEnabledButton,7)
local macroCreateButton = make("TextButton", {Position=UDim2.fromOffset(12,183), Size=UDim2.new(0.33,-12,0,32), BackgroundColor3=Color3.fromRGB(105,59,166), Text="Create Macro", TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=10, ZIndex=8}, macroCard); corner(macroCreateButton,7)
local macroSaveButton = make("TextButton", {Position=UDim2.new(0.33,0,0,183), Size=UDim2.new(0.33,-6,0,32), BackgroundColor3=Color3.fromRGB(63,43,88), Text="Save Macro", TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=10, ZIndex=8}, macroCard); corner(macroSaveButton,7)
local macroDeleteButton = make("TextButton", {Position=UDim2.new(0.66,0,0,183), Size=UDim2.new(0.34,-18,0,32), BackgroundColor3=Color3.fromRGB(95,43,65), Text="Delete Macro", TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=10, ZIndex=8}, macroCard); corner(macroDeleteButton,7)
macroStatus = make("TextLabel", {Position=UDim2.fromOffset(12,220), Size=UDim2.new(1,-24,0,32), BackgroundTransparency=1, Text="Create a macro; choose a keybind to run it.", TextColor3=Color3.fromRGB(183,164,210), Font=Enum.Font.Gotham, TextSize=10, TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left, ZIndex=8}, macroCard)
macroList = make("Frame", {Position=UDim2.fromOffset(12,256), Size=UDim2.new(1,-24,0,142), BackgroundTransparency=1, ZIndex=8}, macroCard)
macroEditorTestBox = make("TextBox", {Position=UDim2.fromOffset(12,466), Size=UDim2.new(1,-24,0,52), BackgroundColor3=Color3.fromRGB(12,8,20), TextColor3=Color3.new(1,1,1), PlaceholderText="Insert Text target (local test field)", Text="", ClearTextOnFocus=false, TextWrapped=true, MultiLine=true, Font=Enum.Font.Code, TextSize=11, ZIndex=8}, macrosPage)
corner(macroEditorTestBox,8)
local macroTestLabel = make("TextLabel", {Position=UDim2.fromOffset(12,440), Size=UDim2.new(1,-24,0,22), BackgroundTransparency=1, Text="LOCAL TEST TEXT FIELD (Insert Text destination)", TextColor3=Color3.fromRGB(211,176,255), Font=Enum.Font.GothamBold, TextSize=11, TextXAlignment=Enum.TextXAlignment.Left, ZIndex=8}, macrosPage)

local function currentMacro()
    for _, m in ipairs(macros) do if m.Id == selectedMacroId then return m end end
end
local function refreshMacroList()
    for _, child in ipairs(macroList:GetChildren()) do child:Destroy() end
    for i, m in ipairs(macros) do
        local b = make("TextButton", {Position=UDim2.fromOffset(0,(i-1)*29), Size=UDim2.new(1,0,0,25), BackgroundColor3=(m.Id==selectedMacroId) and Color3.fromRGB(93,51,145) or Color3.fromRGB(32,23,48), Text=m.Name.."  ["..(m.Key or "NONE").."]  "..(m.Enabled and "ON" or "OFF"), TextColor3=Color3.new(1,1,1), Font=Enum.Font.Gotham, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left, ZIndex=9}, macroList)
        b.Activated:Connect(function()
            selectedMacroId=m.Id; macroNameBox.Text=m.Name; macroDescriptionBox.Text=m.Description or ""; macroTextBox.Text=m.Text or ""
            for j,a in ipairs(macroActionTypes) do if a==m.Action then actionIndex=j end end
            for j,f in ipairs(macroFeatures) do if f==m.Feature then featureIndex=j end end
            macroActionButton.Text="Action: "..m.Action; macroFeatureButton.Text="Feature: "..m.Feature
            macroKeyButton.Text="Set Keybind: "..(m.Key or "NONE"); macroEnabledButton.Text="Enabled: "..(m.Enabled and "YES" or "NO")
            refreshMacroList()
        end)
    end
end
local function featureSet(key, value)
    if S[key] == nil or type(S[key]) ~= "boolean" then return false end
    S[key] = value
    if toggleControls[key] then toggleControls[key]() end
    if toggleCallbacks[key] then pcall(toggleCallbacks[key], value) end
    if key == "AimEnabled" or key == "AimBots" then
        if not value then lockedTarget=nil end
        if refreshAimStatus then refreshAimStatus() end
    end
    return true
end
local function runMacro(m)
    if not m or not m.Enabled then return end
    local action, key = m.Action, m.Feature
    if action == "Toggle Feature" then
        if not featureSet(key, not S[key]) then macroStatus.Text="Unsupported toggle feature: "..tostring(key) end
    elseif action == "Enable Feature" then
        if not featureSet(key, true) then macroStatus.Text="Unsupported feature: "..tostring(key) end
    elseif action == "Disable Feature" then
        if not featureSet(key, false) then macroStatus.Text="Unsupported feature: "..tostring(key) end
    elseif action == "Reset Setting" then
        local defaults = {AimEnabled=false,AimBots=false,PlayerESP=false,BotESP=false,PlayerWalls=false,BotWalls=false,HP=false,InfiniteJump=false,Fullbright=false,NoFog=false,Crosshair=false,ThirdPerson=false,CameraFOVEnabled=false,CharacterSpinEnabled=false,SpinTest=false}
        if defaults[key] ~= nil then featureSet(key, defaults[key]); if key=="CharacterSpinEnabled" then setCharacterSpin(false) end
        else macroStatus.Text="Reset is only available for supported toggle settings." end
    elseif action == "Execute Action" then
        if m.Text == "Start Local Test" then
            setLocalTestMode(true)
        elseif m.Text == "Stop Local Test" then
            setLocalTestMode(false)
        elseif m.Text == "Reset Rotation" then
            setCharacterSpin(false); if toggleControls.CharacterSpinEnabled then toggleControls.CharacterSpinEnabled() end
        else
            macroStatus.Text="Supported actions: Start Local Test, Stop Local Test, Reset Rotation."
        end
    elseif action == "Insert Text" then
        macroEditorTestBox.Text = m.Text or ""
        macroStatus.Text="Text inserted into the local test text field."
    elseif action == "Copy Text" then
        macroStatus.Text="Copy Text is unavailable in standard Roblox LocalScripts; select and copy text manually."

    elseif action == "Sequence" then
        for item in string.gmatch(m.Text or "", "[^,]+") do
            local f = string.gsub(item, "^%s*(.-)%s*$", "%1")
            if S[f] ~= nil and type(S[f])=="boolean" then featureSet(f, not S[f]) end
        end
        macroStatus.Text="Sequence completed for supported comma-separated boolean feature keys."
    end
end
macroActionButton.Activated:Connect(function()
    actionIndex = actionIndex % #macroActionTypes + 1
    macroActionButton.Text = "Action: "..macroActionTypes[actionIndex]
end)
macroFeatureButton.Activated:Connect(function()
    featureIndex = featureIndex % #macroFeatures + 1
    macroFeatureButton.Text = "Feature: "..macroFeatures[featureIndex]
end)
macroKeyButton.Activated:Connect(function()
    local m = currentMacro()
    if m and m.Key then
        m.Key=nil; macroKeyButton.Text="Set Keybind: NONE"; macroStatus.Text="Keybind cleared."; refreshMacroList()
    else
        waitingForMacroKey=true
        macroStatus.Text="Press a keyboard key now (Esc cancels). Ctrl/Shift/Alt modifiers are included."
    end
end)
macroEnabledButton.Activated:Connect(function()
    local m=currentMacro()
    if m then m.Enabled=not m.Enabled; macroEnabledButton.Text="Enabled: "..(m.Enabled and "YES" or "NO"); refreshMacroList() end
end)
macroCreateButton.Activated:Connect(function()
    nextMacroId+=1
    local m={Id=nextMacroId,Name=(macroNameBox.Text~="" and macroNameBox.Text or ("Macro "..nextMacroId)),Description=macroDescriptionBox.Text,Action=macroActionTypes[actionIndex],Feature=macroFeatures[featureIndex],Text=macroTextBox.Text,Key=nil,Enabled=true}
    table.insert(macros,m); selectedMacroId=m.Id; macroKeyButton.Text="Set Keybind: NONE"; macroStatus.Text="Macro created."; refreshMacroList()
end)
macroSaveButton.Activated:Connect(function()
    local m=currentMacro()
    if not m then macroStatus.Text="Select a macro or create one first."; return end
    m.Name=macroNameBox.Text~="" and macroNameBox.Text or m.Name; m.Description=macroDescriptionBox.Text
    m.Action=macroActionTypes[actionIndex]; m.Feature=macroFeatures[featureIndex]; m.Text=macroTextBox.Text
    macroStatus.Text="Macro saved."; refreshMacroList()
end)
macroDeleteButton.Activated:Connect(function()
    for i,m in ipairs(macros) do if m.Id==selectedMacroId then table.remove(macros,i); selectedMacroId=nil; break end end
    macroStatus.Text="Macro deleted."; refreshMacroList()
end)

local importKeys = {
    "PlayerESP", "BotESP", "PlayerWalls", "BotWalls", "HP",
    "PlayerDistance", "BotDistance",
    "AimEnabled", "AimBots", "AimPart", "FOV", "Smoothness",
    "JumpPower", "WalkSpeed",
    "CameraFOVEnabled", "CameraFOV", "InfiniteJump", "Fullbright",
    "NoFog", "Crosshair", "ThirdPerson", "ThirdPersonDistance",
    "SpinTest", "SpinSpeed",
    "CharacterSpinEnabled", "CharacterSpinSpeed",
    "CharacterSpinDirection", "CharacterSpinSmooth",
    "UILanguage", "UIScale", "SavedWindowWidth", "SavedWindowHeight",
}

local function validateSetting(key, value)
    if key == "UILanguage" then
        if value == "English" or value == "Русский" or value == "Deutsch" or value == "Українська" or value == "中文" then return value end
        return nil
    end
    if key == "UIScale" then
        if typeof(value) == "number" then return math.clamp(value, 0.75, 1.25) end
        return nil
    end
    if key == "SavedWindowWidth" then
        if typeof(value) == "number" then return math.clamp(round(value), 650, 1400) end
        return nil
    end
    if key == "SavedWindowHeight" then
        if typeof(value) == "number" then return math.clamp(round(value), 430, 1000) end
        return nil
    end
    local booleanKeys = {
        PlayerESP = true,
        BotESP = true,
        PlayerWalls = true,
        BotWalls = true,
        HP = true,
        AimEnabled = true,
        AimBots = true,
        CameraFOVEnabled = true,
        InfiniteJump = true,
        Fullbright = true,
        NoFog = true,
        Crosshair = true,
        ThirdPerson = true,
        SpinTest = true,
        CharacterSpinEnabled = true,
        CharacterSpinSmooth = true,
    }

    if booleanKeys[key] then
        if typeof(value) == "boolean" then return value end
        return nil
    end

    if key == "PlayerDistance" or key == "BotDistance" then
        if typeof(value) == "number" then
            return clampNumber(value, 25, 500, S[key])
        end
        return nil
    end

    if key == "FOV" then
        if typeof(value) == "number" then
            return clampNumber(value, 50, 900, S.FOV)
        end
        return nil
    end

    if key == "Smoothness" then
        if typeof(value) == "number" then
            return clampNumber(value, 1, 20, S.Smoothness)
        end
        return nil
    end

    if key == "JumpPower" then
        if typeof(value) == "number" then
            return clampNumber(value, 0, 1000, S.JumpPower)
        end
        return nil
    end

    if key == "WalkSpeed" then
        if typeof(value) == "number" then
            return clampNumber(value, 0, 300, S.WalkSpeed)
        end
        return nil
    end

    if key == "CameraFOV" then
        if typeof(value) == "number" then return clampNumber(value, 50, 110, S.CameraFOV) end
        return nil
    end
    if key == "ThirdPersonDistance" then
        if typeof(value) == "number" then return clampNumber(value, 8, 30, S.ThirdPersonDistance) end
        return nil
    end
    if key == "AimPart" then
        if value == "Head" or value == "Body" then return value end
        return nil
    end

    if key == "SpinSpeed" or key == "CharacterSpinSpeed" then
        if typeof(value) == "number" then
            return clampNumber(value, 1, 20, S[key])
        end
        return nil
    end

    if key == "CharacterSpinDirection" then
        if typeof(value) == "number" and (value == 1 or value == -1) then
            return value
        end
        return nil
    end

    return nil
end

local function refreshControls()
    for _, refresh in pairs(toggleControls) do
        refresh()
    end

    for key, setValue in pairs(sliderSetters) do
        setValue(S[key])
    end

    for key, setValue in pairs(valueSetters) do
        setValue(S[key])
    end

    aimPartButton.Text = "ТОЧКА НАВЕДЕНИЯ: "
        .. (S.AimPart == "Head" and "HEAD" or "BODY")

    jumpPowerCustomized = true
    walkSpeedCustomized = true

    applyMovementSettings(player.Character)
    lockedTarget = nil
end

importButton.Activated:Connect(function()
    local ok, data = pcall(function()
        return HttpService:JSONDecode(importBox.Text)
    end)

    if not ok or type(data) ~= "table" then
        importStatus.Text = "Ошибка: проверь JSON."
        return
    end

    if data.ConfigVersion ~= nil
        and (typeof(data.ConfigVersion) ~= "number" or data.ConfigVersion > 3 or data.ConfigVersion < 1) then
        importStatus.Text = "Ошибка: неподдерживаемая версия конфигурации."
        return
    end

    for _, key in ipairs(importKeys) do
        if data[key] ~= nil then
            local validated = validateSetting(key, data[key])
            if validated ~= nil then S[key] = validated end
        end
    end

    refreshControls()
    refreshSpinDirection()
    if S.UILanguage then setLanguage(S.UILanguage) end
    if S.UIScale then refreshScale() end
    main.Size = UDim2.fromOffset(math.clamp(S.SavedWindowWidth or WINDOW_WIDTH, 650, 1400), math.clamp(S.SavedWindowHeight or WINDOW_HEIGHT, 430, 1000))
    if type(data.Macros) == "table" then
        macros = {}
        nextMacroId = 0
        for _, item in ipairs(data.Macros) do
            if type(item) == "table" and type(item.Name) == "string" and type(item.Action) == "string" then
                local validAction, validFeature = false, false
                for _, a in ipairs(macroActionTypes) do if a == item.Action then validAction = true end end
                for _, f in ipairs(macroFeatures) do if f == item.Feature then validFeature = true end end
                if validAction and validFeature then
                    nextMacroId += 1
                    table.insert(macros, {Id=nextMacroId, Name=string.sub(item.Name,1,80), Description=string.sub(tostring(item.Description or ""),1,240), Action=item.Action, Feature=item.Feature, Text=string.sub(tostring(item.Text or ""),1,1000), Key=type(item.Key)=="string" and item.Key or nil, Enabled=item.Enabled ~= false})
                end
            end
        end
        selectedMacroId = macros[1] and macros[1].Id or nil
        refreshMacroList()
    end
    for _, key in ipairs(importKeys) do
        local callback = toggleCallbacks[key]
        if callback then
            pcall(callback, S[key])
        end
    end
    jumpPowerCustomized = true
    walkSpeedCustomized = true
    if applyMovementSettings then
        applyMovementSettings(player.Character)
    end
    importStatus.Text = "Настройки импортированы."
end)

exportButton.Activated:Connect(function()
    local data = {}

    data.ConfigVersion = 3
    data.Product = "PHANTOM"
    S.SavedWindowWidth, S.SavedWindowHeight = main.Size.X.Offset, main.Size.Y.Offset
    for _, key in ipairs(importKeys) do data[key] = S[key] end
    data.Macros = {}
    for _, m in ipairs(macros) do
        table.insert(data.Macros, {Name=m.Name, Description=m.Description, Action=m.Action, Feature=m.Feature, Text=m.Text, Key=m.Key, Enabled=m.Enabled})
    end

    local ok, result = pcall(function()
        return HttpService:JSONEncode(data)
    end)

    if ok then
        importBox.Text = result
        importStatus.Text = "JSON готов. Скопируй его из поля."
    else
        importStatus.Text = "Не удалось создать JSON."
    end
end)

--==================================================
-- WINDOW DRAGGING
--==================================================

header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        dragPosition = main.Position
    end
end)

resizeGrip.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        resizing = true
        resizeStartInput = input.Position
        resizeStartSize = Vector2.new(main.Size.X.Offset, main.Size.Y.Offset)
    end
end)

UIS.InputChanged:Connect(function(input)
    if resizing and resizeStartInput and resizeStartSize and
        (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - resizeStartInput
        local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1200, 800)
        local w = math.clamp(resizeStartSize.X + delta.X, 650, math.max(650, viewport.X - 24))
        local h = math.clamp(resizeStartSize.Y + delta.Y, 430, math.max(430, viewport.Y - 24))
        main.Size = UDim2.fromOffset(w, h)
        S.SavedWindowWidth, S.SavedWindowHeight = w, h
    end
    if dragging and dragStart and dragPosition and (
        input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
    ) then
        local delta = input.Position - dragStart

        main.Position = UDim2.new(
            dragPosition.X.Scale,
            dragPosition.X.Offset + delta.X,
            dragPosition.Y.Scale,
            dragPosition.Y.Offset + delta.Y
        )
    end

    if sliderState and (
        input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
    ) then
        sliderState.Update(input.Position.X)
    end
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
        resizing = false
        resizeStartInput = nil
        resizeStartSize = nil
        dragStart = nil
        dragPosition = nil
        sliderState = nil
    end
end)

--==================================================
-- ESP
--==================================================

local function getLocalRoot()
    local character = player.Character
    return character and getRoot(character)
end

local function distanceFromPlayer(model)
    local localRoot = getLocalRoot()
    local targetRoot = getRoot(model)

    if not localRoot or not targetRoot then return math.huge end
    return (localRoot.Position - targetRoot.Position).Magnitude
end

local function applyESP(model, humanoid, isBot)
    if not model or not model:IsA("Model") then return end

    local info = espObjects[model]

    if not info then
        info = {}
        espObjects[model] = info
    end

    if not info.Highlight or not info.Highlight.Parent then
        local highlight = Instance.new("Highlight")
        highlight.Name = "PHANTOM_Highlight"
        highlight.Adornee = model
        highlight.Parent = model
        info.Highlight = highlight
    end

    local color = isBot and S.BotColor or S.PlayerColor
    local walls = isBot and S.BotWalls or S.PlayerWalls

    info.Highlight.FillColor = color
    info.Highlight.OutlineColor = color
    info.Highlight.FillTransparency = 0.82
    info.Highlight.OutlineTransparency = 0
    info.Highlight.DepthMode = walls
        and Enum.HighlightDepthMode.AlwaysOnTop
        or Enum.HighlightDepthMode.Occluded

    if S.HP then
        local adornee = model:FindFirstChild("Head") or getRoot(model)

        if adornee then
            if not info.Billboard or not info.Billboard.Parent then
                local bill = Instance.new("BillboardGui")
                bill.Name = "PHANTOM_HP"
                bill.Size = UDim2.fromOffset(120, 24)
                bill.StudsOffset = Vector3.new(0, 2.5, 0)
                bill.AlwaysOnTop = true
                bill.Adornee = adornee
                bill.Parent = adornee

                local label = Instance.new("TextLabel")
                label.Size = UDim2.fromScale(1, 1)
                label.BackgroundTransparency = 1
                label.TextColor3 = Color3.fromRGB(120, 255, 140)
                label.TextStrokeTransparency = 0.2
                label.Font = Enum.Font.GothamBold
                label.TextSize = 12
                label.Parent = bill

                info.Billboard = bill
                info.HPLabel = label
            else
                info.Billboard.Adornee = adornee
            end

            info.HPLabel.Text = "HP: "
                .. round(humanoid.Health)
                .. " / "
                .. round(humanoid.MaxHealth)
        end
    elseif info.Billboard then
        info.Billboard:Destroy()
        info.Billboard = nil
        info.HPLabel = nil
    end
end

local function updateESP()
    local seenModels = {}

    if not S.LocalTestMode then
    for _, plr in ipairs(Players:GetPlayers()) do
        local character = plr.Character

        if plr ~= player and character then
            seenModels[character] = true

            local humanoid = getHumanoid(character)
            local inRange = distanceFromPlayer(character) <= S.PlayerDistance

            if S.PlayerESP and humanoid and humanoid.Health > 0 and inRange then
                applyESP(character, humanoid, false)
            else
                clearESP(character)
            end
        end
    end
    end

    for model in pairs(trackedModels) do
        if not model.Parent or not model:IsDescendantOf(Workspace) then
            untrackModel(model)
        elseif S.LocalTestMode and model ~= localTestDummy then
            clearESP(model)
        else
            seenModels[model] = true

            local humanoid = getHumanoid(model)
            local inRange = distanceFromPlayer(model) <= S.BotDistance

            if S.BotESP and humanoid and humanoid.Health > 0 and inRange then
                applyESP(model, humanoid, true)
            else
                clearESP(model)
            end
        end
    end

    for model in pairs(espObjects) do
        if not model:IsDescendantOf(Workspace) or not seenModels[model] then
            clearESP(model)
        end
    end
end

--==================================================
-- OFFLINE / LOCAL TEST MODE
--==================================================

local function removeLocalTestDummy()
    if localTestDummy then
        untrackModel(localTestDummy)
        if localTestDummy.Parent then
            localTestDummy:Destroy()
        end
        localTestDummy = nil
    end
end

local function createLocalTestDummy()
    removeLocalTestDummy()

    local character = player.Character
    local root = character and getRoot(character)
    local basePosition = root and (root.Position + root.CFrame.LookVector * 24)
        or Vector3.new(0, 5, 0)

    local model = Instance.new("Model")
    model.Name = "PHANTOM_LOCAL_TEST_DUMMY"
    model:SetAttribute("PHANTOM_LocalTestDummy", true)

    local function makePart(name, size, offset, color)
        local part = Instance.new("Part")
        part.Name = name
        part.Size = size
        part.CFrame = CFrame.new(basePosition + offset)
        part.Anchored = true
        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = true
        part.Material = Enum.Material.Neon
        part.Color = color
        part.Parent = model
        return part
    end

    local rootPart = makePart("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0), Color3.fromRGB(120, 70, 180))
    local torso = makePart("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0), Color3.fromRGB(120, 70, 180))
    local head = makePart("Head", Vector3.new(1.25, 1.25, 1.25), Vector3.new(0, 4.65, 0), Color3.fromRGB(210, 170, 255))
    local humanoid = Instance.new("Humanoid")
    humanoid.DisplayName = "LOCAL TEST ONLY"
    humanoid.MaxHealth = 100
    humanoid.Health = 100
    humanoid.Parent = model
    model.PrimaryPart = rootPart
    model.Parent = Workspace
    localTestDummy = model
    trackModel(model)
    return model
end

setLocalTestMode = function(enabled)
    S.LocalTestMode = enabled == true
    if S.LocalTestMode then
        createLocalTestDummy()
        S.BotESP = true
        if toggleControls.BotESP then toggleControls.BotESP() end
        localTestStatus.Text = "LOCAL TEST MODE: ON  •  purple dummy is synthetic"
        localTestStatus.TextColor3 = Color3.fromRGB(185, 140, 255)
    else
        removeLocalTestDummy()
        localTestStatus.Text = "LOCAL TEST MODE: OFF  •  no server data"
        localTestStatus.TextColor3 = Color3.fromRGB(183, 164, 210)
    end
    updateESP()
end

localTestStart.Activated:Connect(function()
    setLocalTestMode(true)
end)

localTestStop.Activated:Connect(function()
    setLocalTestMode(false)
end)

playButton.Activated:Connect(function()
    if playBusy then return end
    playBusy = true
    playButton.Text = "STARTING..."
    playStatus.Text = "PLAY STATUS: STARTING"
    playStatus.TextColor3 = Color3.fromRGB(255, 205, 120)
    local ok, err = pcall(function()
        setLocalTestMode(true)
        if not localTestDummy or not localTestDummy.Parent then error("Local test dummy was not created") end
    end)
    if ok then
        playButton.Text = "▶  LOCAL TEST RUNNING"
        playStatus.Text = "PLAY STATUS: RUNNING • local dummy created"
        playStatus.TextColor3 = Color3.fromRGB(145, 255, 190)
    else
        playButton.Text = "▶  PLAY LOCAL TEST"
        playStatus.Text = "PLAY STATUS: ERROR • "..tostring(err)
        playStatus.TextColor3 = Color3.fromRGB(255, 120, 140)
    end
    task.delay(0.6, function() playBusy = false end)
end)

--==================================================
-- AIM TARGETING
--==================================================

local function getAimPart(model)
    if not model or not model:IsA("Model") then return nil end

    local humanoid = getHumanoid(model)
    if not humanoid or humanoid.Health <= 0 then return nil end

    if S.AimPart == "Head" then
        local head = model:FindFirstChild("Head")
        if head and head:IsA("BasePart") then return head end
        return nil
    end

    local body = model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Torso")
        or model:FindFirstChild("HumanoidRootPart")

    if body and body:IsA("BasePart") then return body end
    return nil
end

local function withinFOV(model)
    local activeCamera = Workspace.CurrentCamera
    if not activeCamera then return nil end

    local part = getAimPart(model)
    if not part then return nil end

    local viewport = activeCamera.ViewportSize
    local center = Vector2.new(viewport.X / 2, viewport.Y / 2)
    local point, onScreen = activeCamera:WorldToViewportPoint(part.Position)

    if not onScreen or point.Z <= 0 then return nil end

    local screenDistance =
        (Vector2.new(point.X, point.Y) - center).Magnitude

    if screenDistance > S.FOV then return nil end
    return part, screenDistance
end

local function hasLineOfSight(model, part)
    local activeCamera = Workspace.CurrentCamera
    if not activeCamera then return false end

    local origin = activeCamera.CFrame.Position
    local direction = part.Position - origin

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {player.Character}

    local result = Workspace:Raycast(origin, direction, params)
    return result == nil or result.Instance:IsDescendantOf(model)
end

local function getTrainingCandidates()
    local candidates = {}

    if not S.AimEnabled or not S.AimBots then return candidates end

    local seen = {}

    local function consider(model)
        if not model or seen[model] then return end
        seen[model] = true

        if not isValidCharacterModel(model) then return end

        local part, screenDistance = withinFOV(model)
        if part and hasLineOfSight(model, part) then
            candidates[#candidates + 1] = {
                Model = model,
                Part = part,
                Distance = screenDistance,
            }
        end
    end

    -- Aim Assist is intentionally available only against the synthetic local test dummy.
    -- It will not acquire real players or arbitrary NPCs in another experience.
    if not S.LocalTestMode or not localTestDummy or not localTestDummy.Parent then
        return candidates
    end
    consider(localTestDummy)

    table.sort(candidates, function(a, b)
        return a.Distance < b.Distance
    end)

    return candidates
end

local function targetIsValid(model, part)
    if not model or not model:IsA("Model") then return false end
    if not isValidCharacterModel(model) then return false end
    if model == player.Character then return false end
    if not part or not part:IsDescendantOf(model) then return false end
    return getAimPart(model) ~= nil
end

local function chooseTarget()
    local candidates = getTrainingCandidates()
    local best = candidates[1]

    if best then
        return {
            Model = best.Model,
            Part = best.Part,
        }
    end

    return nil
end

--==================================================
-- MENU ANIMATIONS / OPENING
--==================================================

local function setOpen(value)
    if menuOpen == value then return end
    menuOpen = value
    local targetWidth = S.SavedWindowWidth or WINDOW_WIDTH
    local targetHeight = S.SavedWindowHeight or WINDOW_HEIGHT

    if value then
        main.Visible = true
        main.Size = UDim2.fromOffset(targetWidth - 28, targetHeight - 28)

        tween(main, {
            Size = UDim2.fromOffset(targetWidth, targetHeight),
        }, 0.24, Enum.EasingStyle.Back)

        if not main:FindFirstChild("WindowFade") then
            local fade = make("Frame", {
                Name = "WindowFade",
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Color3.fromRGB(13, 8, 23),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                ZIndex = 49,
            }, main)

            tween(fade, {
                BackgroundTransparency = 1,
            }, 0.15)

            task.delay(0.2, function()
                if fade.Parent then fade:Destroy() end
            end)
        end
    else
        lockedTarget = nil

        local closeTween = tween(main, {
            Size = UDim2.fromOffset(targetWidth - 25, targetHeight - 25),
        }, 0.15)

        if closeTween then
            closeTween.Completed:Connect(function()
                if not menuOpen and main.Parent then
                    main.Visible = false
                    main.Size = UDim2.fromOffset(targetWidth, targetHeight)
                end
            end)
        else
            main.Visible = false
        end
    end
end

close.Activated:Connect(function()
    setOpen(false)
end)

local function keyModifiers()
    return UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl),
        UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift),
        UIS:IsKeyDown(Enum.KeyCode.LeftAlt) or UIS:IsKeyDown(Enum.KeyCode.RightAlt)
end
local function keyToken(input)
    local ctrl, shift, alt = keyModifiers()
    local parts = {}
    if ctrl then table.insert(parts, "Ctrl") end
    if shift then table.insert(parts, "Shift") end
    if alt then table.insert(parts, "Alt") end
    table.insert(parts, input.KeyCode.Name)
    return table.concat(parts, "+")
end
local globalInputConnection = UIS.InputBegan:Connect(function(input, processed)
    if waitingForMacroKey == true then
        if input.KeyCode == Enum.KeyCode.Escape then
            waitingForMacroKey = false; macroStatus.Text = "Key assignment cancelled."; return
        end
        if input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode ~= Enum.KeyCode.LeftControl
            and input.KeyCode ~= Enum.KeyCode.RightControl and input.KeyCode ~= Enum.KeyCode.LeftShift
            and input.KeyCode ~= Enum.KeyCode.RightShift and input.KeyCode ~= Enum.KeyCode.LeftAlt
            and input.KeyCode ~= Enum.KeyCode.RightAlt then
            local m = currentMacro()
            if m then
                local token = keyToken(input)
                local conflict
                for _, other in ipairs(macros) do if other.Id ~= m.Id and other.Key == token then conflict = other; break end end
                if conflict then
                    macroStatus.Text = "Conflict with "..conflict.Name..". Press this key again to replace; Esc cancels."
                    waitingForMacroKey = "conflict:"..token
                    return
                end
                m.Key = token; macroKeyButton.Text = "Set Keybind: "..token
                macroStatus.Text = "Keybind assigned: "..token; refreshMacroList()
            else macroStatus.Text = "Create/select a macro first." end
            waitingForMacroKey = false
        end
        return
    elseif type(waitingForMacroKey) == "string" and string.sub(waitingForMacroKey,1,9) == "conflict:" then
        if input.KeyCode == Enum.KeyCode.Escape then waitingForMacroKey=false; macroStatus.Text="Key assignment cancelled."; return end
        if input.KeyCode ~= Enum.KeyCode.Unknown then
            local expected = string.sub(waitingForMacroKey,10)
            local token = keyToken(input)
            if token == expected then
                local m=currentMacro()
                for _,other in ipairs(macros) do if other.Key==token then other.Key=nil end end
                if m then m.Key=token; macroKeyButton.Text="Set Keybind: "..token; refreshMacroList() end
                macroStatus.Text="Conflicting bind replaced."; waitingForMacroKey=false
            else macroStatus.Text="Press the same key to replace, or Esc to cancel." end
        end
        return
    end
    if input.KeyCode == Enum.KeyCode.RightShift and not processed then setOpen(not menuOpen); return end
    if not processed and not UIS:GetFocusedTextBox() and input.KeyCode ~= Enum.KeyCode.Unknown then
        local token=keyToken(input)
        for _,m in ipairs(macros) do if m.Enabled and m.Key==token then runMacro(m) end end
    end
    if input.UserInputType == Enum.UserInputType.MouseButton2 then rightMouseHeld=true; lockedTarget=nil end
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        rightMouseHeld = false
        lockedTarget = nil
    end
end)

--==================================================
-- ANIMATED STARS
--==================================================

local starUpdateElapsed = 0

RunService.RenderStepped:Connect(function(dt)
    starUpdateElapsed += dt
    if starUpdateElapsed < 1 / 30 then return end

    local step = starUpdateElapsed
    starUpdateElapsed = 0

    for _, data in ipairs(stars) do
        local obj = data.Object

        if obj and obj.Parent then
            local pos = obj.Position
            local newY = pos.Y.Scale + data.Speed * step
            local newX = pos.X.Scale + data.Drift * step

            if newY > 1.08 then
                newY = -0.08
                newX = rng:NextNumber(0, 1)
            end

            if newX < -0.08 then newX = 1.05 end
            if newX > 1.08 then newX = -0.05 end

            obj.Position = UDim2.new(newX, 0, newY, 0)
        end
    end
end)

--==================================================
-- AIM CAMERA UPDATE
--==================================================

RunService:BindToRenderStep(
    RENDER_NAME,
    Enum.RenderPriority.Camera.Value + 1,
    function(dt)
        camera = Workspace.CurrentCamera

        fovCircle.Visible = S.AimEnabled and S.AimBots
        fovCircle.Size = UDim2.fromOffset(S.FOV * 2, S.FOV * 2)

        if camera then
            local viewport = camera.ViewportSize
            fovCircle.Position = UDim2.fromOffset(
                viewport.X / 2,
                viewport.Y / 2
            )
        end

        if not camera then
            lockedTarget = nil
            return
        end

        if not S.AimEnabled or not S.AimBots or not rightMouseHeld then
            lockedTarget = nil
            return
        end

        if lockedTarget then
            local model = lockedTarget.Model
            local currentPart = getAimPart(model)

            -- Keep the lock when the target leaves FOV or is briefly obscured.
            if targetIsValid(model, currentPart) then
                lockedTarget.Part = currentPart
            else
                lockedTarget = nil
            end
        end

        if not lockedTarget then
            lockedTarget = chooseTarget()
        end

        if not lockedTarget then return end

        local model = lockedTarget.Model
        local part = getAimPart(model)

        if not targetIsValid(model, part) then
            lockedTarget = nil
            return
        end

        local origin = camera.CFrame.Position
        local destination = part.Position

        if (destination - origin).Magnitude < 0.01 then return end

        local desired = CFrame.lookAt(origin, destination)
        local speed = 21 - S.Smoothness
        local alpha = math.clamp(dt * speed, 0, 1)

        camera.CFrame = camera.CFrame:Lerp(desired, alpha)
    end
)

-- Crosshair is a single lightweight ScreenGui element; no second menu is created.
local crosshair = make("Frame", {
    Name = "PHANTOM_Crosshair",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(4, 4),
    BackgroundColor3 = Color3.fromRGB(185, 115, 255),
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 45,
}, gui)
local crosshairH = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(18, 2),
    BackgroundColor3 = Color3.fromRGB(185, 115, 255),
    BorderSizePixel = 0,
    ZIndex = 45,
}, crosshair)
local crosshairV = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(2, 18),
    BackgroundColor3 = Color3.fromRGB(185, 115, 255),
    BorderSizePixel = 0,
    ZIndex = 45,
}, crosshair)

RunService.RenderStepped:Connect(function(dt)
    updateCharacterSpin(dt)
    crosshair.Visible = S.Crosshair
    if S.CameraFOVEnabled and camera then
        local targetFOV = S.CameraFOV
        if math.abs(camera.FieldOfView - targetFOV) > 0.1 then
            camera.FieldOfView += (targetFOV - camera.FieldOfView) * math.clamp(dt * 8, 0, 1)
        end
    end
    if S.SpinTest then
        -- UI-only demo: do not rotate the character or interfere with server physics.
        spinAngle = (spinAngle + math.rad(360 * S.SpinSpeed) * dt) % (math.pi * 2)
        if logoStar and logoStar.Parent then
            logoStar.Rotation = math.deg(spinAngle)
        end
    elseif logoStar and logoStar.Parent then
        logoStar.Rotation = 0
    end
end)

UIS.JumpRequest:Connect(function()
    if not S.InfiniteJump then return end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health > 0 then
        humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

--==================================================
-- PERIODIC ESP UPDATE
--==================================================

RunService.Heartbeat:Connect(function(dt)
    espElapsed += dt

    if espElapsed >= 0.25 then
        espElapsed = 0
        updateESP()
    end
end)

--==================================================
-- PLAYER JOIN / LEAVE
--==================================================

local function onPlayerCharacterAdded(character)
    task.defer(function()
        trackModel(character)
    end)
end

local function connectPlayer(plr)
    if plr == player then return end

    plr.CharacterAdded:Connect(onPlayerCharacterAdded)

    plr.CharacterRemoving:Connect(function(character)
        clearESP(character)
    end)

    if plr.Character then
        onPlayerCharacterAdded(plr.Character)
    end
end

for _, plr in ipairs(Players:GetPlayers()) do
    connectPlayer(plr)
end

Players.PlayerAdded:Connect(connectPlayer)

Players.PlayerRemoving:Connect(function(plr)
    if plr.Character then
        clearESP(plr.Character)
    end
end)

player.CharacterRemoving:Connect(function()
    lockedTarget = nil
    rightMouseHeld = false
end)

--==================================================
setLanguage(S.UILanguage)
refreshScale()

-- INTRO SEQUENCE
--==================================================

showTab("ESP")

task.spawn(function()
    tween(introGlow, {
        BackgroundTransparency = 0.45,
        Size = UDim2.fromOffset(190, 190),
    }, 0.6)

    tween(introIconHolder, {
        Size = UDim2.fromOffset(110, 110),
        Position = UDim2.fromScale(0.5, 0.36),
    }, 0.65, Enum.EasingStyle.Back)
    introIcon.Rotation = -18
    tween(introIcon, {Rotation = 0}, 0.65, Enum.EasingStyle.Back)

    task.wait(0.25)

    tween(introTitle, {
        TextTransparency = 0,
        Position = UDim2.fromScale(0.5, 0.47),
    }, 0.55, Enum.EasingStyle.Back)

    task.wait(0.2)

    tween(introSubtitle, {TextTransparency = 0}, 0.4)
    tween(introTrack, {BackgroundTransparency = 0}, 0.3)
    tween(introFill, {Size = UDim2.new(1, 0, 1, 0)}, 1.1)

    task.wait(1.15)

    tween(introIconHolder, {Size = UDim2.fromOffset(0, 0)}, 0.25)
    tween(introTitle, {TextTransparency = 1}, 0.25)
    tween(introSubtitle, {TextTransparency = 1}, 0.2)
    tween(introTrack, {BackgroundTransparency = 1}, 0.2)
    tween(dimmer, {BackgroundTransparency = 1}, 0.4)

    task.wait(0.42)

    if dimmer.Parent then dimmer:Destroy() end

    -- Initial menu position is centered.
    main.Position = UDim2.fromScale(0.5, 0.5)
    main.Size = UDim2.fromOffset(WINDOW_WIDTH - 35, WINDOW_HEIGHT - 35)
    main.Visible = true
    menuOpen = true

    tween(main, {
        Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT),
    }, 0.38, Enum.EasingStyle.Back)
end)

--==================================================
-- CLEANUP
--==================================================

local function cleanup()
    if globalInputConnection then globalInputConnection:Disconnect(); globalInputConnection = nil end
    setCharacterSpin(false)
    removeLocalTestDummy()
    pcall(function()
        RunService:UnbindFromRenderStep(RENDER_NAME)
    end)

    local Lighting = game:GetService("Lighting")
    if lightingSnapshot then
        Lighting.Brightness = lightingSnapshot.Brightness
        Lighting.ClockTime = lightingSnapshot.ClockTime
        Lighting.GlobalShadows = lightingSnapshot.GlobalShadows
        Lighting.Ambient = lightingSnapshot.Ambient
        Lighting.OutdoorAmbient = lightingSnapshot.OutdoorAmbient
    end
    if fogSnapshot then
        Lighting.FogStart = fogSnapshot.FogStart
        Lighting.FogEnd = fogSnapshot.FogEnd
    end
    local currentCamera = Workspace.CurrentCamera or camera
    if currentCamera then
        currentCamera.FieldOfView = originalCameraFOV
    end
    player.CameraMinZoomDistance = originalCameraMinZoom
    player.CameraMaxZoomDistance = originalCameraMaxZoom
    player.CameraMode = originalCameraMode

    for model in pairs(espObjects) do
        clearESP(model)
    end
end

script.Destroying:Connect(cleanup)

applyMovementSettings(player.Character)

print("[PHANTOM] Loaded successfully.")
print("[PHANTOM] Menu: RightShift")
print("[PHANTOM] Aim: enable Aim Assist + targeting, then hold RMB.")
print("[PHANTOM] ESP uses cached models.")
print("[PHANTOM] Movement settings: PLAYER tab")