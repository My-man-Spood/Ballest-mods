local UEHelpers = require("UEHelpers")

--------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------

local MOD_NAME = "BallestSpeedDecimal"

local function Log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local loggedKeys = {}
local function LogOnce(key, message)
    if loggedKeys[key] then return end
    loggedKeys[key] = true
    Log(message)
end

--------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------

local ENABLED = true
local TICK_INTERVAL_MS = 33

-- Native HUD shows floor(rawVelocity / 50) as a two-digit integer; we show
-- the decimal remainder alongside it.
local SPEED_UNITS_PER_RAW_VELOCITY = 50

-- Our overlay widget.
local OVERLAY_TAG = "BallestSpeedDecimalOverlay"
local OVERLAY_ANCHOR = { X = 1, Y = 1 } -- bottom-right corner
local OVERLAY_OFFSET = { X = -35, Y = -65 }
local OVERLAY_SIZE = { X = 50, Y = 40 }
local OVERLAY_FONT_SIZE = 32
local OVERLAY_Z_ORDER = -100 -- behind the pause-menu blur, same layer as the native speedometer

-- UWidget ESlateVisibility values we use.
local VISIBILITY_HIDDEN = 2
local VISIBILITY_HIT_TEST_INVISIBLE = 3
local TEXT_JUSTIFY_RIGHT = 2

-- Keeps a constructed UObject alive without an explicit owner tracking it.
local KEEP_ALIVE_OBJECT_FLAGS = 0x0E000000

-- Nudging the native speedometer left to make room for our widget.
local NATIVE_PLAYER_UI_CLASS_PATH = "/Game/UI/Gameplay/WBP_PlayerUI.WBP_PlayerUI_C"
local NATIVE_TARGET_RIGHT_PADDING = 80 -- native default is 40
local SHIFT_RETRY_TICKS = 60 -- ~2s, in case the HUD isn't built yet when a race starts

-- Jump / impact pulse.
local PULSE_DURATION_TICKS = 15 -- ~0.5s
local JUMP_PEAK_SCALE = 1.3
local COLLISION_MIN_PEAK_SCALE = 1.05
local COLLISION_MAX_PEAK_SCALE = 1.3
local COLLISION_SHAKE_MAX_AMPLITUDE_PX = 10

-- Event_Collision reports two different magnitude scales depending on
-- collision type (confirmed via logged real values): landings use raw
-- numbers in the hundreds to low thousands; wall bumps use a normalized
-- ~0..1 value, occasionally clamped to exactly 1.0.
local MAGNITUDE_SCALE_BOUNDARY = 10 -- below this, treat as a bump; at/above, a landing
local BUMP_MAGNITUDE_SCALE = { min = 0.02, max = 1.0 }
local LANDING_MAGNITUDE_SCALE = { min = 300, max = 2000 }

--------------------------------------------------------------------------
-- Our overlay widget
--------------------------------------------------------------------------
-- A brand-new widget we construct and own completely -- never touches
-- anything the game itself created.
--
-- Its Outer is GameInstance, not World: World dies when a race ends, and a
-- GC-rooted object (see KEEP_ALIVE_OBJECT_FLAGS) whose Outer belongs to a
-- dying World is what Unreal's ReferenceChainSearch calls a "world leak"
-- and fatals on. GameInstance survives the whole play session.
--
-- Rebuilt fresh every race rather than reused: a reused widget stayed
-- logically valid (correct position, opacity, viewport attachment) but was
-- genuinely invisible from race 2 onward -- a render-context issue a fresh
-- construction avoids.

local overlayWidget = nil
local overlayTextBlock = nil

local function BuildOverlayWidget()
    local GameInstance = UEHelpers.GetGameInstance()
    if not GameInstance or not GameInstance:IsValid() then
        return nil, nil
    end

    local UserWidgetClass = StaticFindObject("/Script/UMG.UserWidget")
    local Tag = UEHelpers.FindOrAddFName(OVERLAY_TAG)
    local Widget = StaticConstructObject(UserWidgetClass, GameInstance, Tag, 0, KEEP_ALIVE_OBJECT_FLAGS, false, false, nil, nil, nil)
    if not Widget or not Widget:IsValid() then
        return nil, nil
    end

    local WidgetTree = Widget.WidgetTree
    if not WidgetTree or not WidgetTree:IsValid() then
        local WidgetTreeClass = StaticFindObject("/Script/UMG.WidgetTree")
        WidgetTree = StaticConstructObject(WidgetTreeClass, Widget, 0, 0, KEEP_ALIVE_OBJECT_FLAGS, false, false, nil, nil, nil)
        Widget.WidgetTree = WidgetTree
    end

    local CanvasPanelClass = StaticFindObject("/Script/UMG.CanvasPanel")
    local Canvas = StaticConstructObject(CanvasPanelClass, WidgetTree, 0, 0, KEEP_ALIVE_OBJECT_FLAGS, false, false, nil, nil, nil)
    WidgetTree.RootWidget = Canvas

    local TextBlockClass = StaticFindObject("/Script/UMG.TextBlock")
    local TextBlock = StaticConstructObject(TextBlockClass, WidgetTree, 0, 0, KEEP_ALIVE_OBJECT_FLAGS, false, false, nil, nil, nil)

    local Slot = Canvas:AddChildToCanvas(TextBlock)
    Slot:SetAnchors({ Minimum = OVERLAY_ANCHOR, Maximum = OVERLAY_ANCHOR })
    Slot:SetAlignment({ X = 1, Y = 1 })
    Slot:SetPosition(OVERLAY_OFFSET)
    Slot:SetSize(OVERLAY_SIZE)

    return Widget, TextBlock
end

local function StyleOverlayText(TextBlock)
    pcall(function()
        local Font = TextBlock.Font
        Font.Size = OVERLAY_FONT_SIZE
        TextBlock.Font = Font
    end)
    pcall(function() TextBlock.Justification = TEXT_JUSTIFY_RIGHT end)
end

local function DestroyOverlay()
    if overlayWidget then
        pcall(function()
            if overlayWidget:IsValid() then
                overlayWidget:RemoveFromParent()
            end
        end)
    end
    overlayWidget = nil
    overlayTextBlock = nil
end

local function CreateOverlay()
    if overlayWidget and overlayWidget:IsValid() then return end

    local ok, err = pcall(function()
        local Widget, TextBlock = BuildOverlayWidget()
        if not Widget then
            LogOnce("overlay_build_failed", "Could not build the overlay widget (GameInstance not ready yet?)")
            return
        end

        StyleOverlayText(TextBlock)
        pcall(function() Widget.Visibility = VISIBILITY_HIT_TEST_INVISIBLE end)
        Widget:AddToViewport(OVERLAY_Z_ORDER)

        overlayWidget = Widget
        overlayTextBlock = TextBlock
    end)
    if not ok then
        LogOnce("overlay_create_error", "CreateOverlay error: " .. tostring(err))
    end
end

-- AddToViewport() reporting no error is not proof the widget is actually on
-- screen -- confirmed by testing, it can silently no-op. Verify every tick
-- and force a genuine re-registration if it's not actually attached.
local function EnsureOverlayAttachedToViewport()
    local ok, isInViewport = pcall(function() return overlayWidget:IsInViewport() end)
    if ok and isInViewport then return end

    pcall(function() overlayWidget:RemoveFromParent() end)
    pcall(function() overlayWidget:AddToViewport(OVERLAY_Z_ORDER) end)
end

local function SetOverlayText(text)
    local KismetTextLibrary = UEHelpers.GetKismetTextLibrary()
    overlayTextBlock:SetText(KismetTextLibrary:Conv_StringToText(text))
end

--------------------------------------------------------------------------
-- Sweep away any overlay widget left over from a previous hot-reload
--------------------------------------------------------------------------

local sweepDone = false

local function SweepOrphanedOverlaysOnce()
    if sweepDone then return end
    sweepDone = true

    local ok, err = pcall(function()
        local Widgets = FindAllOf("UserWidget")
        if not Widgets then return end

        local removedCount = 0
        for _, Widget in ipairs(Widgets) do
            local nameOk, name = pcall(function() return Widget:GetFName():ToString() end)
            if nameOk and name and name:find(OVERLAY_TAG) then
                pcall(function() Widget:RemoveFromParent() end)
                removedCount = removedCount + 1
            end
        end

        if removedCount > 0 then
            Log("Swept " .. removedCount .. " orphaned overlay widget(s) from a previous load")
        end
    end)
    if not ok then
        Log("Orphan sweep error: " .. tostring(err))
    end
end

--------------------------------------------------------------------------
-- Speed formula
--------------------------------------------------------------------------

local function ComputeDisplaySpeed(Velocity)
    local rawSpeed = math.sqrt(Velocity.X ^ 2 + Velocity.Y ^ 2 + Velocity.Z ^ 2)
    return rawSpeed / SPEED_UNITS_PER_RAW_VELOCITY
end

local function FormatDecimalPart(displaySpeed)
    local wholePart = math.floor(displaySpeed)
    local decimalDigit = math.floor((displaySpeed - wholePart) * 10)
    return string.format(".%d", decimalDigit)
end

--------------------------------------------------------------------------
-- Nudging the native speedometer left to make room for our widget
--------------------------------------------------------------------------
-- Touched exactly once per race, via a plain lookup -- nothing held onto
-- afterward.

-- FindFirstOf would return whichever matching instance happens to be first
-- in the object array, which turned out to be a preview copy embedded in
-- the track editor's own UI, not the live in-race HUD. The real one's path
-- goes through RaceUIManager -- and more than one such instance can exist
-- at once (a stale leftover alongside the live one), so we pick whichever
-- candidate actually has a populated Speed_Right.
local function FindLiveRaceHud()
    local Candidates = FindAllOf("WBP_PlayerUI_C")
    if not Candidates then return nil end

    for _, Candidate in ipairs(Candidates) do
        local nameOk, fullName = pcall(function() return Candidate:GetFullName() end)
        if nameOk and fullName and fullName:find("RaceUIManager") then
            local speedOk, SpeedRight = pcall(function() return Candidate.Speed_Right end)
            if speedOk and SpeedRight and SpeedRight:IsValid() then
                return Candidate
            end
        end
    end
    return nil
end

local function ShiftNativeDigitsLeft()
    local RaceHud = FindLiveRaceHud()
    if not RaceHud then return false end

    local DigitGroup = RaceHud.Speed_Right:GetParent()
    if not DigitGroup or not DigitGroup:IsValid() then return false end

    local Slot = DigitGroup.Slot
    if not Slot or not Slot:IsValid() then return false end

    local Padding = Slot.Padding
    if not Padding then return false end

    Slot:SetPadding({
        Left = Padding.Left,
        Top = Padding.Top,
        Right = NATIVE_TARGET_RIGHT_PADDING,
        Bottom = Padding.Bottom,
    })
    return true
end

local function TryShiftNativeDigitsLeft()
    local ok, succeeded = pcall(ShiftNativeDigitsLeft)
    if not ok then
        Log("TryShiftNativeDigitsLeft error: " .. tostring(succeeded))
        return false
    end
    return succeeded
end

--------------------------------------------------------------------------
-- Jump / impact pulse animation
--------------------------------------------------------------------------
-- Mimics the native HUD's own scale-pop and impact wobble on our widget.
-- We can't reuse WBP_PlayerUI's JumpAnim/ImpactAnim WidgetAnimations
-- directly (their tracks reference objects inside that specific widget's
-- own tree), so we hook the trigger functions and drive the animation
-- manually instead.

local pulseActive = false
local pulseElapsedTicks = 0
local pulsePeakScale = JUMP_PEAK_SCALE
local pulseShakeAmplitude = 0 -- 0 for jump (scale only), >0 for collisions

local function StartPulse(peakScale, shakeAmplitude)
    pulseActive = true
    pulseElapsedTicks = 0
    pulsePeakScale = peakScale
    pulseShakeAmplitude = shakeAmplitude or 0
end

-- Returns intensity in 0..1, or nil if below the "no pulse" floor for
-- whichever magnitude scale this value belongs to.
local function CollisionIntensity(magnitude)
    local scale = magnitude < MAGNITUDE_SCALE_BOUNDARY and BUMP_MAGNITUDE_SCALE or LANDING_MAGNITUDE_SCALE
    if magnitude < scale.min then return nil end
    local t = (magnitude - scale.min) / (scale.max - scale.min)
    return math.max(0, math.min(1, t))
end

local function StartCollisionPulse(magnitude)
    local intensity = CollisionIntensity(magnitude)
    if not intensity then return end

    local peakScale = COLLISION_MIN_PEAK_SCALE + (COLLISION_MAX_PEAK_SCALE - COLLISION_MIN_PEAK_SCALE) * intensity
    local shakeAmplitude = COLLISION_SHAKE_MAX_AMPLITUDE_PX * intensity
    StartPulse(peakScale, shakeAmplitude)
end

local pulseHooksInstalled = false

local function InstallPulseHooksOnce()
    if pulseHooksInstalled then return end

    local ok, err = pcall(function()
        RegisterHook(NATIVE_PLAYER_UI_CLASS_PATH .. ":OnPlayerJumped_Handler",
            function() StartPulse(JUMP_PEAK_SCALE, 0) end,
            function() end)

        RegisterHook(NATIVE_PLAYER_UI_CLASS_PATH .. ":Event_Collision",
            function(Context, MagnitudeParam)
                local magOk, magnitude = pcall(function() return MagnitudeParam:get() end)
                if magOk and magnitude then
                    StartCollisionPulse(magnitude)
                end
            end,
            function() end)
    end)

    if ok then
        pulseHooksInstalled = true
    else
        Log("InstallPulseHooksOnce error: " .. tostring(err))
    end
end

local function LerpScale(peakScale, t)
    return peakScale - (peakScale - 1.0) * t
end

-- Decays faster than the scale so the wobble settles out before the scale
-- has fully returned to normal.
local function ShakeDecay(t)
    return (1 - t) ^ 2
end

local function ShakeOffset(elapsedTicks, amplitude, decay)
    return {
        X = math.sin(elapsedTicks * 2.4) * amplitude * decay,
        Y = math.sin(elapsedTicks * 3.1 + 1) * amplitude * decay,
    }
end

local function EndPulse()
    pulseActive = false
    pcall(function() overlayTextBlock:SetRenderScale({ X = 1, Y = 1 }) end)
    if pulseShakeAmplitude > 0 then
        pcall(function() overlayTextBlock:SetRenderTranslation({ X = 0, Y = 0 }) end)
    end
end

local function UpdatePulse()
    if not pulseActive then return end
    if not overlayTextBlock or not overlayTextBlock:IsValid() then return end

    pulseElapsedTicks = pulseElapsedTicks + 1
    local t = pulseElapsedTicks / PULSE_DURATION_TICKS

    if t >= 1 then
        EndPulse()
        return
    end

    local scale = LerpScale(pulsePeakScale, t)
    pcall(function() overlayTextBlock:SetRenderScale({ X = scale, Y = scale }) end)

    if pulseShakeAmplitude > 0 then
        local offset = ShakeOffset(pulseElapsedTicks, pulseShakeAmplitude, ShakeDecay(t))
        pcall(function() overlayTextBlock:SetRenderTranslation(offset) end)
    end
end

--------------------------------------------------------------------------
-- Race state and main loop
--------------------------------------------------------------------------
-- Pure polling, not event-driven: hooking PlayerController:ClientRestart
-- (the same event the game's own bundled mods use) produced a crash on
-- every test, even when the hook only set a boolean. Polling is the one
-- configuration that's been reliably safe.

local function IsBallPawn(Pawn)
    if not Pawn or not Pawn:IsValid() then return false end
    local ok, className = pcall(function() return Pawn:GetClass():GetFName():ToString() end)
    return ok and className ~= nil and className:find("BP_RollingBall") ~= nil
end

local wasRacing = false
local shiftApplied = false
local shiftRetriesRemaining = 0

local function HandleEnteringRace()
    shiftApplied = false
    shiftRetriesRemaining = SHIFT_RETRY_TICKS
    DestroyOverlay() -- rebuilt fresh for this race; see note on CreateOverlay
end

local function HandleNotRacing()
    if overlayWidget and overlayWidget:IsValid() then
        pcall(function() overlayWidget.Visibility = VISIBILITY_HIDDEN end)
    end
end

local function UpdateNativeShift()
    if shiftApplied or shiftRetriesRemaining <= 0 then return end
    shiftRetriesRemaining = shiftRetriesRemaining - 1
    if TryShiftNativeDigitsLeft() then
        shiftApplied = true
    end
end

local function UpdateOverlayWidget(Player)
    if not overlayWidget or not overlayWidget:IsValid() then
        CreateOverlay()
        return
    end

    EnsureOverlayAttachedToViewport()
    pcall(function() overlayWidget.Visibility = VISIBILITY_HIT_TEST_INVISIBLE end)

    local displaySpeed = ComputeDisplaySpeed(Player:GetVelocity())
    SetOverlayText(FormatDecimalPart(displaySpeed))
end

local function Tick()
    SweepOrphanedOverlaysOnce()

    local Player = UEHelpers.GetPlayer()
    local racing = Player ~= nil and Player:IsValid() and IsBallPawn(Player)

    if racing and not wasRacing then
        HandleEnteringRace()
    end
    wasRacing = racing

    if not racing then
        HandleNotRacing()
        return
    end

    UpdateNativeShift()
    InstallPulseHooksOnce()
    UpdatePulse()
    UpdateOverlayWidget(Player)
end

Log("mod loaded")

LoopAsync(TICK_INTERVAL_MS, function()
    if not ENABLED then return false end
    local ok, err = pcall(Tick)
    if not ok then Log("Tick error: " .. tostring(err)) end
    return false
end)
