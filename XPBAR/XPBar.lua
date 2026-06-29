-- XPBar.lua v2.3
-- Barre XP avancée — Tibiscui
-- Maj+Drag pour déplacer | Maj+Clic droit pour les options

local ADDON = "XPBar"

-- ══════════════════════════════════════════════════
-- DEFAULTS
-- ══════════════════════════════════════════════════
local DEFAULTS = {
    posX   = 0, posY = -120, anchor = "TOP",
    width  = 600, height = 22,
    showPlayedTime       = true,
    showSessionTime      = true,
    showLevelingTime     = true,
    showXPPerHour        = true,
    showCompletedQuests  = true,
    showRestedText       = true,
    showIncompleteBar    = false,
    showAtMaxLevel       = false,
    resetSessionOnReload = false,
    hideDefaultXPBar     = true,   -- masquée par défaut dès l'installation
    sessionStartTime     = 0,      -- epoch (time()) du début de session — persiste entre /reload
    sessionXPGained       = 0,     -- XP cumulée depuis sessionStartTime — persiste entre /reload
    barR = 0.55, barG = 0.27, barB = 0.80, barA = 1.0,
    qR   = 1.00, qG   = 0.65, qB   = 0.00, qA   = 1.0,
    rR   = 0.40, rG   = 0.70, rB   = 1.00, rA   = 1.0,
    incR = 0.60, incG = 0.60, incB = 0.60, incA = 0.4,
}

-- ══════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════
local db
local mainBar, questSegment, restedSegment, incompleteBar
local labelLeft, labelCenter, labelRight, labelBottom
local containerFrame, dragFrame, optionsFrame
local playedTimeBase      = 0   -- /played total au dernier RequestTimePlayed()
local playedTimeQueryTime = 0   -- time() epoch au moment de la requête

-- ══════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════
local function FormatTime(seconds)
    seconds = math.floor(seconds or 0)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then return string.format("%dh%02dm", h, m)
    elseif m > 0 then return string.format("%dm%02ds", m, s)
    else return string.format("%ds", s) end
end

-- Durée de session en secondes, basée sur l'horloge réelle (time()) pour
-- survivre aux /reload — contrairement à GetTime() qui repart de zéro.
local function GetSessionElapsed()
    if not db or not db.sessionStartTime or db.sessionStartTime == 0 then return 0 end
    return time() - db.sessionStartTime
end

local function GetXPPerHour()
    local elapsed = GetSessionElapsed()
    local gained  = (db and db.sessionXPGained) or 0
    if elapsed > 60 and gained > 0 then
        return gained / elapsed * 3600
    end
    return 0
end

local function GetPlayedTime()
    return playedTimeBase + (time() - playedTimeQueryTime)
end

local function GetXPData()
    local cur  = UnitXP("player")
    local max  = UnitXPMax("player")
    local rest = GetXPExhaustion() or 0
    local pct     = max > 0 and (cur / max)  or 0
    local restPct = max > 0 and (rest / max) or 0
    return cur, max, rest, pct, restPct
end

local function GetQuestData()
    local completed, total = 0, 0
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
        local n = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, n do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID then
                total = total + 1
                -- isComplete sur info peut être nil en Retail 12.x
                -- C_QuestLog.IsComplete() détecte les quêtes avec objectifs remplis
                -- même si elles ne sont pas encore rendues au PNJ
                local isComplete = info.isComplete
                    or (C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID))
                if isComplete then completed = completed + 1 end
            end
        end
    end
    local completedPct  = total > 0 and (completed / total * 100) or 0
    local incompletePct = total > 0 and ((total - completed) / total) or 0
    return completedPct, incompletePct, completed, total
end

-- ══════════════════════════════════════════════════
-- INIT DB
-- ══════════════════════════════════════════════════
local function InitDB()
    XPBarDB = XPBarDB or {}
    db = XPBarDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
end

-- ══════════════════════════════════════════════════
-- SAVE POSITION
-- ══════════════════════════════════════════════════
local function SavePosition()
    if not containerFrame then return end
    local point, _, _, x, y = containerFrame:GetPoint()
    db.anchor = point
    db.posX   = math.floor(x + 0.5)
    db.posY   = math.floor(y + 0.5)
end

-- ══════════════════════════════════════════════════
-- APPLY SIZE (redimensionnement à chaud)
-- ══════════════════════════════════════════════════
local function ApplySize()
    if not containerFrame then return end
    local w, h = db.width, db.height
    containerFrame:SetSize(w, h + 20)
    mainBar:SetSize(w, h)
    incompleteBar:SetSize(w, h)
    dragFrame:SetSize(w, h + 20)
end

-- ══════════════════════════════════════════════════
-- FORWARD DECLARATIONS (pour éviter les nil au moment des scripts)
-- ══════════════════════════════════════════════════
local UpdateBar
local CreateOptionsPanel

-- ══════════════════════════════════════════════════
-- CRÉATION UI
-- ══════════════════════════════════════════════════
local function CreateMainBar()
    -- Conteneur principal
    containerFrame = CreateFrame("Frame", "XPBarContainer", UIParent)
    containerFrame:SetFrameStrata("MEDIUM")
    containerFrame:SetSize(db.width, db.height + 20)
    containerFrame:SetPoint(db.anchor, UIParent, db.anchor, db.posX, db.posY)
    containerFrame:SetMovable(true)
    containerFrame:SetClampedToScreen(true)

    -- ── Frame invisible pour le drag (Button = supporte RegisterForDrag) ──
    -- Posé AU-DESSUS de la barre, capte Maj+drag et Maj+clic droit
    dragFrame = CreateFrame("Button", "XPBarDragFrame", containerFrame)
    dragFrame:SetAllPoints(containerFrame)
    dragFrame:SetFrameStrata("HIGH")
    dragFrame:EnableMouse(true)
    dragFrame:RegisterForDrag("LeftButton")
    dragFrame:RegisterForClicks("RightButtonUp")
    dragFrame:SetAlpha(0)   -- invisible

    dragFrame:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            containerFrame:StartMoving()
            mainBar:SetAlpha(0.6)
        end
    end)
    dragFrame:SetScript("OnDragStop", function(self)
        containerFrame:StopMovingOrSizing()
        mainBar:SetAlpha(1.0)
        SavePosition()
        print("|cffFFD700[XPBar]|r Position sauvegardée.")
    end)
    dragFrame:SetScript("OnClick", function(self, button)
        if button == "RightButton" and IsShiftKeyDown() then
            if optionsFrame and optionsFrame:IsShown() then
                optionsFrame:Hide()
            else
                CreateOptionsPanel()
            end
        end
    end)

    -- Tooltip sur le dragFrame
    dragFrame:SetScript("OnEnter", function(self)
        local cur, max, rest, pct, restPct = GetXPData()
        local elapsed   = GetSessionElapsed()
        local xpPerHour = GetXPPerHour()
        local timeToLvl = xpPerHour > 0 and ((max - cur) / xpPerHour * 3600) or 0
        local _, _, completed, total = GetQuestData()

        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("XPBar", 0.55, 0.27, 0.80)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("XP",          string.format("%d / %d", cur, max),     1,.82,0, 1,1,1)
        GameTooltip:AddDoubleLine("Progression",  string.format("%.1f%%", pct*100),       1,.82,0, 1,1,1)
        GameTooltip:AddDoubleLine("Restant",      string.format("%d XP", max-cur),        1,.82,0, 1,1,1)
        if rest > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Repos", string.format("%d XP (%.1f%%)", rest, restPct*100), 1,.82,0, .6,.8,1)
        end
        if total > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Quêtes", string.format("%d / %d", completed, total), 1,.82,0, 1,.6,0)
        end
        if elapsed > 60 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Session",    FormatTime(elapsed),               1,.82,0, 1,1,1)
            GameTooltip:AddDoubleLine("XP/heure",   string.format("%.0f", xpPerHour), 1,.82,0, 1,1,1)
            if timeToLvl > 0 then
                GameTooltip:AddDoubleLine("Temps restant", FormatTime(timeToLvl),     1,.82,0, 1,1,1)
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffFFD700Maj+Drag|r déplacer  ·  |cffFFD700Maj+Clic droit|r options", .8,.8,.8)
        GameTooltip:Show()
    end)
    dragFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Barre principale XP ───────────────────────
    mainBar = CreateFrame("StatusBar", "XPBarMain", containerFrame)
    mainBar:SetSize(db.width, db.height)
    mainBar:SetPoint("TOP", containerFrame, "TOP", 0, 0)
    mainBar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
    mainBar:SetStatusBarColor(db.barR, db.barG, db.barB, db.barA)
    mainBar:SetMinMaxValues(0, 1)
    mainBar:SetValue(0)

    local bg = mainBar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.85)

    local border = CreateFrame("Frame", nil, mainBar, "BackdropTemplate")
    border:SetAllPoints()
    border:SetBackdrop({
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 6,
        insets   = { left=1, right=1, top=1, bottom=1 },
    })
    border:SetBackdropBorderColor(0, 0, 0, 0.7)

    -- ── Barre quêtes incomplètes ──────────────────
    incompleteBar = CreateFrame("StatusBar", nil, containerFrame)
    incompleteBar:SetSize(db.width, db.height)
    incompleteBar:SetPoint("TOP", containerFrame, "TOP", 0, 0)
    incompleteBar:SetFrameLevel(mainBar:GetFrameLevel() - 1)
    incompleteBar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
    incompleteBar:SetStatusBarColor(db.incR, db.incG, db.incB, db.incA)
    incompleteBar:SetMinMaxValues(0, 1)
    incompleteBar:SetValue(0)
    incompleteBar:Hide()

    -- ── Segments orange (quêtes) / bleu (repos) ───
    questSegment = mainBar:CreateTexture(nil, "OVERLAY")
    questSegment:SetTexture("Interface/TargetingFrame/UI-StatusBar")
    questSegment:SetVertexColor(db.qR, db.qG, db.qB, db.qA)
    questSegment:SetHeight(db.height - 4)
    questSegment:Hide()

    restedSegment = mainBar:CreateTexture(nil, "OVERLAY")
    restedSegment:SetTexture("Interface/TargetingFrame/UI-StatusBar")
    restedSegment:SetVertexColor(db.rR, db.rG, db.rB, db.rA)
    restedSegment:SetHeight(db.height - 4)
    restedSegment:Hide()

    -- ── Labels ────────────────────────────────────
    labelLeft = mainBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    labelLeft:SetPoint("LEFT", mainBar, "LEFT", 8, 0)
    labelLeft:SetTextColor(1, 1, 1, 1)

    labelCenter = mainBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    labelCenter:SetPoint("CENTER", mainBar, "CENTER", 0, 0)
    labelCenter:SetTextColor(1, 1, 1, 1)

    labelRight = mainBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    labelRight:SetPoint("RIGHT", mainBar, "RIGHT", -8, 0)
    labelRight:SetTextColor(1, 1, 1, 1)

    labelBottom = containerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    labelBottom:SetPoint("TOP", mainBar, "BOTTOM", 0, -2)
    labelBottom:SetTextColor(0.7, 0.7, 0.7, 1)
end

-- ══════════════════════════════════════════════════
-- UPDATE BAR
-- ══════════════════════════════════════════════════
UpdateBar = function()
    if not mainBar or not db then return end

    local lvl    = UnitLevel("player")
    local maxLvl = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 999

    if lvl >= maxLvl and not db.showAtMaxLevel then
        containerFrame:Hide()
        return
    end
    containerFrame:Show()

    local cur, max, rest, pct, restPct             = GetXPData()
    local questPct, incompletePct, completed, total = GetQuestData()

    mainBar:SetValue(pct)
    mainBar:SetStatusBarColor(db.barR, db.barG, db.barB, db.barA)

    -- Barre quêtes incomplètes
    if db.showIncompleteBar and incompletePct > 0 then
        incompleteBar:SetValue(incompletePct)
        incompleteBar:Show()
    else
        incompleteBar:Hide()
    end

    -- Labels
    labelLeft:SetText(string.format("|cffddbbff Level %d|r", lvl))

    if max > 0 then
        labelCenter:SetText(string.format("|cffffff99%d|r / |cffffff99%d|r", cur, max))
    else
        labelCenter:SetText("")
    end

    local rightTxt = string.format("|cffffffff%.1f%%|r", pct * 100)
    if restPct > 0 then
        rightTxt = rightTxt .. string.format(" |cff99ccff(%.1f%%)|r", (pct + restPct) * 100)
    end
    labelRight:SetText(rightTxt)

    -- Segments visuels
    local barWidth = db.width - 4
    local SEG_W    = 14
    local offsetX  = math.floor(pct * barWidth) + 2

    if questPct > 0 then
        questSegment:SetWidth(SEG_W)
        questSegment:ClearAllPoints()
        questSegment:SetPoint("LEFT", mainBar, "LEFT", offsetX, 0)
        questSegment:Show()
        offsetX = offsetX + SEG_W + 2
    else
        questSegment:Hide()
    end

    if restPct > 0 then
        restedSegment:SetWidth(SEG_W)
        restedSegment:ClearAllPoints()
        restedSegment:SetPoint("LEFT", mainBar, "LEFT", offsetX, 0)
        restedSegment:Show()
    else
        restedSegment:Hide()
    end

    -- Ligne du bas
    local parts = {}
    if db.showCompletedQuests and total > 0 then
        table.insert(parts, string.format("Completed Quests: |cffff9900%.1f%%|r", questPct))
    end
    if db.showRestedText and restPct > 0 then
        table.insert(parts, string.format("Rested Experience: |cff66b3ff%.1f%%|r", restPct * 100))
    end
    if db.showPlayedTime then
        table.insert(parts, string.format("|cffccccccJoué: %s|r", FormatTime(GetPlayedTime())))
    end
    if db.showSessionTime then
        table.insert(parts, string.format("|cffccccccSession: %s|r", FormatTime(GetSessionElapsed())))
    end
    if db.showXPPerHour or db.showLevelingTime then
        local xpPerHour = GetXPPerHour()
        if db.showXPPerHour and xpPerHour > 0 then
            table.insert(parts, string.format("|cffaaffaaXP/h: %.0f|r", xpPerHour))
        end
        if db.showLevelingTime and xpPerHour > 0 and max > cur then
            table.insert(parts, string.format("|cffaaffaa~%s|r", FormatTime((max - cur) / xpPerHour * 3600)))
        end
    end

    if #parts > 0 then
        labelBottom:SetText(table.concat(parts, " - "))
        labelBottom:Show()
    else
        labelBottom:Hide()
    end

    -- Barre XP native Retail 12.x = StatusTrackingBarManager uniquement
    if db.hideDefaultXPBar then
        if StatusTrackingBarManager then
            StatusTrackingBarManager:Hide()
            StatusTrackingBarManager:SetAlpha(0)
            StatusTrackingBarManager:SetScript("OnShow", function(self)
                self:Hide()
                self:SetAlpha(0)
            end)
            -- Masquer aussi chaque barre enfant
            for i = 1, StatusTrackingBarManager:GetNumChildren() do
                local child = select(i, StatusTrackingBarManager:GetChildren())
                if child then
                    child:Hide()
                    child:SetScript("OnShow", function(self) self:Hide() end)
                end
            end
        end
    else
        if StatusTrackingBarManager then
            StatusTrackingBarManager:SetScript("OnShow", nil)
            StatusTrackingBarManager:SetAlpha(1)
            StatusTrackingBarManager:Show()
            for i = 1, StatusTrackingBarManager:GetNumChildren() do
                local child = select(i, StatusTrackingBarManager:GetChildren())
                if child then
                    child:SetScript("OnShow", nil)
                    child:Show()
                end
            end
        end
    end
end

-- ══════════════════════════════════════════════════
-- PANEL D'OPTIONS
-- ══════════════════════════════════════════════════
local function MakeCheckbox(parent, lbl, x, y, getF, setF)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetChecked(getF())
    cb:SetScript("OnClick", function(self)
        setF(self:GetChecked() and true or false)
        UpdateBar()
    end)
    local txt = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    txt:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    txt:SetText(lbl)
    return cb
end

CreateOptionsPanel = function()
    if optionsFrame then
        optionsFrame:Show()
        return
    end

    optionsFrame = CreateFrame("Frame", "XPBarOptions", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(500, 400)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    optionsFrame:SetScript("OnDragStop",  function(f) f:StopMovingOrSizing() end)
    optionsFrame:SetBackdrop({
        bgFile   = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        edgeSize = 24,
        insets   = { left=6, right=6, top=6, bottom=6 },
    })
    optionsFrame:SetBackdropColor(0.1, 0.1, 0.15, 0.97)
    optionsFrame:SetScript("OnHide", function() SavePosition() end)

    -- ── Titre ─────────────────────────────────────
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", optionsFrame, "TOP", 0, -16)
    title:SetText("|cffddbbffXPBar|r — Options")

    -- ── Bandeau "Custom Options" ──────────────────
    local tabBg = optionsFrame:CreateTexture(nil, "BACKGROUND")
    tabBg:SetColorTexture(0.15, 0.10, 0.25, 0.8)
    tabBg:SetPoint("TOPLEFT",  optionsFrame, "TOPLEFT",  10, -44)
    tabBg:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -10, -44)
    tabBg:SetHeight(20)
    local tabLbl = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tabLbl:SetPoint("CENTER", tabBg, "CENTER")
    tabLbl:SetText("Custom Options")
    tabLbl:SetTextColor(1, 0.82, 0)

    -- ── Hint raccourcis (ligne dédiée, bien séparée) ──
    local hint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 14, -70)
    hint:SetText("|cffFFD700Maj+Drag|r pour déplacer   |cffFFD700Maj+Clic droit|r pour ouvrir/fermer")
    hint:SetTextColor(0.75, 0.75, 0.75)

    -- ── Séparateur ────────────────────────────────
    local sep1 = optionsFrame:CreateTexture(nil, "BACKGROUND")
    sep1:SetColorTexture(0.4, 0.4, 0.4, 0.4)
    sep1:SetPoint("TOPLEFT",  optionsFrame, "TOPLEFT",  10, -84)
    sep1:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -10, -84)
    sep1:SetHeight(1)

    -- ── Sliders (Y=-92 depuis le haut du panel) ───
    -- Largeur
    local capW = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    capW:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 14, -96)
    capW:SetText("Largeur :")

    local valW = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valW:SetPoint("LEFT", capW, "RIGHT", 8, 0)
    valW:SetTextColor(1, 0.82, 0)
    valW:SetText(tostring(db.width))

    local slW = CreateFrame("Slider", nil, optionsFrame)
    slW:SetSize(210, 16)
    slW:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 14, -114)
    slW:SetOrientation("HORIZONTAL")
    slW:SetMinMaxValues(200, 1200)
    slW:SetValueStep(10)
    slW:SetObeyStepOnDrag(true)
    slW:SetValue(db.width)
    slW:SetThumbTexture("Interface/Buttons/UI-SliderBar-Button-Horizontal")
    slW:GetThumbTexture():SetSize(16, 16)
    local trW = slW:CreateTexture(nil, "BACKGROUND")
    trW:SetTexture("Interface/Buttons/UI-SliderBar-Background")
    trW:SetPoint("TOPLEFT", slW, "TOPLEFT", 0, -4)
    trW:SetPoint("BOTTOMRIGHT", slW, "BOTTOMRIGHT", 0, 4)
    trW:SetHorizTile(true)
    local slWminL = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slWminL:SetPoint("TOPLEFT", slW, "BOTTOMLEFT", 0, -2)
    slWminL:SetText("200") ; slWminL:SetTextColor(0.6,0.6,0.6)
    local slWmaxL = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slWmaxL:SetPoint("TOPRIGHT", slW, "BOTTOMRIGHT", 0, -2)
    slWmaxL:SetText("1200") ; slWmaxL:SetTextColor(0.6,0.6,0.6)
    slW:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val/10+0.5)*10
        db.width = val ; valW:SetText(tostring(val))
        ApplySize() ; UpdateBar()
    end)

    -- Hauteur
    local capH = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    capH:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 270, -96)
    capH:SetText("Hauteur :")

    local valH = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valH:SetPoint("LEFT", capH, "RIGHT", 8, 0)
    valH:SetTextColor(1, 0.82, 0)
    valH:SetText(tostring(db.height))

    local slH = CreateFrame("Slider", nil, optionsFrame)
    slH:SetSize(210, 16)
    slH:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 270, -114)
    slH:SetOrientation("HORIZONTAL")
    slH:SetMinMaxValues(10, 60)
    slH:SetValueStep(1)
    slH:SetObeyStepOnDrag(true)
    slH:SetValue(db.height)
    slH:SetThumbTexture("Interface/Buttons/UI-SliderBar-Button-Horizontal")
    slH:GetThumbTexture():SetSize(16, 16)
    local trH = slH:CreateTexture(nil, "BACKGROUND")
    trH:SetTexture("Interface/Buttons/UI-SliderBar-Background")
    trH:SetPoint("TOPLEFT", slH, "TOPLEFT", 0, -4)
    trH:SetPoint("BOTTOMRIGHT", slH, "BOTTOMRIGHT", 0, 4)
    trH:SetHorizTile(true)
    local slHminL = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slHminL:SetPoint("TOPLEFT", slH, "BOTTOMLEFT", 0, -2)
    slHminL:SetText("10") ; slHminL:SetTextColor(0.6,0.6,0.6)
    local slHmaxL = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slHmaxL:SetPoint("TOPRIGHT", slH, "BOTTOMRIGHT", 0, -2)
    slHmaxL:SetText("60") ; slHmaxL:SetTextColor(0.6,0.6,0.6)
    slH:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val+0.5)
        db.height = val ; valH:SetText(tostring(val))
        ApplySize() ; UpdateBar()
    end)

    -- ── Séparateur ────────────────────────────────
    local sep2 = optionsFrame:CreateTexture(nil, "BACKGROUND")
    sep2:SetColorTexture(0.4, 0.4, 0.4, 0.4)
    sep2:SetPoint("TOPLEFT",  optionsFrame, "TOPLEFT",  10, -146)
    sep2:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -10, -146)
    sep2:SetHeight(1)

    -- ── Checkboxes (Y=-155 depuis le haut) ────────
    local C1, C2 = 14, 260
    local Y0, DY = -155, -32

    MakeCheckbox(optionsFrame, "Played Time Text",    C1, Y0,
        function() return db.showPlayedTime end,
        function(v) db.showPlayedTime = v end)

    MakeCheckbox(optionsFrame, "Session Time Text",   C2, Y0,
        function() return db.showSessionTime end,
        function(v) db.showSessionTime = v end)

    MakeCheckbox(optionsFrame, "Leveling Time & XP/Hour Text", C1, Y0+DY,
        function() return db.showLevelingTime end,
        function(v) db.showLevelingTime = v ; db.showXPPerHour = v end)

    MakeCheckbox(optionsFrame, "Completed & Rested Text", C2, Y0+DY,
        function() return db.showCompletedQuests end,
        function(v) db.showCompletedQuests = v ; db.showRestedText = v end)

    MakeCheckbox(optionsFrame, "Show Incomplete Quests Bar", C1, Y0+DY*2,
        function() return db.showIncompleteBar end,
        function(v) db.showIncompleteBar = v end)

    MakeCheckbox(optionsFrame, "Show Bar at Max Level", C2, Y0+DY*2,
        function() return db.showAtMaxLevel end,
        function(v) db.showAtMaxLevel = v end)

    MakeCheckbox(optionsFrame, "Reset Session Time and XP/Hour on Reload UI", C1, Y0+DY*3,
        function() return db.resetSessionOnReload end,
        function(v) db.resetSessionOnReload = v end)

    MakeCheckbox(optionsFrame, "Hide Default Experience Bar (Retail)", C1, Y0+DY*4,
        function() return db.hideDefaultXPBar end,
        function(v)
            db.hideDefaultXPBar = v
            UpdateBar()
        end)

    -- ── Boutons bas ───────────────────────────────
    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(110, 26)
    closeBtn:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -16, 14)
    closeBtn:SetText("Fermer")
    closeBtn:SetScript("OnClick", function() optionsFrame:Hide() end)

    local resetBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetBtn:SetSize(160, 26)
    resetBtn:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 16, 14)
    resetBtn:SetText("Réinitialiser position")
    resetBtn:SetScript("OnClick", function()
        db.posX = 0 ; db.posY = -120 ; db.anchor = "TOP"
        containerFrame:ClearAllPoints()
        containerFrame:SetPoint("TOP", UIParent, "TOP", 0, -120)
        print("|cffFFD700[XPBar]|r Position réinitialisée.")
    end)

    -- Fermeture via la touche Échap (standard Blizzard)
    tinsert(UISpecialFrames, "XPBarOptions")

    optionsFrame:Show()
end

-- ══════════════════════════════════════════════════
-- SLASH  →  /xpbar  ouvre les options
-- ══════════════════════════════════════════════════
SLASH_XPBAR1 = "/xpbar"
SLASH_XPBAR2 = "/xpbardebug"
SlashCmdList["XPBAR"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "" or msg == "config" or msg == "options" then
        CreateOptionsPanel()
    elseif msg == "hide" then
        containerFrame:Hide()
        print("|cffFFD700[XPBar]|r Masqué. /xpbar show pour ré-afficher.")
    elseif msg == "show" then
        containerFrame:Show() ; UpdateBar()
    elseif msg == "reset" then
        XPBarDB = nil ; ReloadUI()
    elseif msg == "debug" then
        -- Liste tous les frames XP visibles pour identifier le bon
        local candidates = {
            "MainMenuExpBar", "ExhaustionTick", "MainMenuBarMaxLevelBar",
            "StatusTrackingBarManager", "MainMenuBar",
            "MainMenuBarArtFrame", "ReputationWatchBar",
            "MainMenuExpBar_ExhaustionTick",
        }
        print("|cffFFD700[XPBar DEBUG]|r Frames XP détectés :")
        for _, name in ipairs(candidates) do
            local f = _G[name]
            if f then
                local shown = f:IsShown() and "|cff00ff00VISIBLE|r" or "|cffff4444caché|r"
                local alpha = string.format("alpha=%.1f", f:GetAlpha())
                print(string.format("  |cffffff99%s|r : %s %s", name, shown, alpha))
            else
                print(string.format("  |cff888888%s|r : inexistant", name))
            end
        end
        -- Aussi lister les enfants de MainMenuBar
        if MainMenuBar then
            print("|cffFFD700Enfants de MainMenuBar :|r")
            local i = 1
            local child = select(i, MainMenuBar:GetChildren())
            while child do
                local n = child:GetName() or ("(sans nom) "..tostring(child))
                local shown = child:IsShown() and "VISIBLE" or "caché"
                print(string.format("  %s : %s", n, shown))
                i = i + 1
                child = select(i, MainMenuBar:GetChildren())
            end
        end
    else
        print("|cffFFD700[XPBar]|r  /xpbar — options  |  /xpbar hide/show  |  /xpbar reset")
        print("  /xpbar debug — identifier les frames XP natifs")
    end
end

-- ══════════════════════════════════════════════════
-- EVENTS
-- ══════════════════════════════════════════════════
local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("ADDON_LOADED")
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:RegisterEvent("PLAYER_XP_UPDATE")
evFrame:RegisterEvent("PLAYER_LEVEL_UP")
evFrame:RegisterEvent("UPDATE_EXHAUSTION")
evFrame:RegisterEvent("QUEST_LOG_UPDATE")
evFrame:RegisterEvent("QUEST_TURNED_IN")
evFrame:RegisterEvent("QUEST_COMPLETE")
evFrame:RegisterEvent("TIME_PLAYED_MSG")

evFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        InitDB()
        CreateMainBar()

    elseif event == "PLAYER_LOGIN" then
        -- Session : redémarre si demandé (option) ou si c'est la 1ère connexion jamais enregistrée.
        -- Sinon la session précédente est conservée (sessionStartTime/sessionXPGained persistés
        -- dans XPBarDB) pour survivre à un /reload.
        if db.resetSessionOnReload or db.sessionStartTime == 0 then
            db.sessionStartTime = time()
            db.sessionXPGained  = 0
        end
        db.lastXP = UnitXP("player")
        if RequestTimePlayed then RequestTimePlayed() end
        UpdateBar()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Rappel après chargement de zone : force le masquage de la barre native
        UpdateBar()

    elseif event == "PLAYER_XP_UPDATE" then
        if db then
            local newXP = UnitXP("player")
            local delta = newXP - (db.lastXP or newXP)
            if delta > 0 then db.sessionXPGained = (db.sessionXPGained or 0) + delta end
            db.lastXP = newXP
        end
        UpdateBar()

    elseif event == "PLAYER_LEVEL_UP" then
        -- Le compteur d'XP repart de 0 à chaque niveau, mais la session
        -- (XP cumulée, durée) continue à courir à travers les niveaux.
        if db then db.lastXP = 0 end
        UpdateBar()

    elseif event == "TIME_PLAYED_MSG" then
        -- arg1 = temps de jeu total (secondes), arg2 = temps sur le niveau actuel
        playedTimeBase      = arg1 or playedTimeBase
        playedTimeQueryTime = time()
        UpdateBar()

    elseif event == "UPDATE_EXHAUSTION"
        or  event == "QUEST_LOG_UPDATE"
        or  event == "QUEST_TURNED_IN"
        or  event == "QUEST_COMPLETE"
    then
        UpdateBar()
    end
end)
