#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir A_ScriptDir
SendMode "Input"
SetKeyDelay -1, -1
SetMouseDelay -1
CoordMode "Mouse", "Screen"
CoordMode "Pixel", "Screen"

; ============================================================================
; MacroForge - Natro-style preset + TinyTask-style record/play, all in one.
;
; File layout:
;   MacroForge.ahk      - this file: main window, glue, hotkey routing
;   lib/Constants.ahk   - Cfg static class: step types + paths + app strings
;   lib/JSON.ahk        - parser/serializer
;   lib/Logger.ahk      - daily file + UI sink logger
;   lib/PresetManager.ahk
;   lib/Player.ahk
;   lib/HotkeyManager.ahk
;   lib/Recorder.ahk
;   lib/StepEditor.ahk  - per-step + step-list modals
;   presets/*.json      - user + example presets (3 built-ins are read-only)
;   logs/YYYY-MM-DD.log - daily logs
;   images/*.png        - reference images for ifImage
; ============================================================================

#Include lib\Constants.ahk
#Include lib\JSON.ahk
#Include lib\Logger.ahk
#Include lib\Theme.ahk
#Include lib\Button.ahk
#Include lib\PresetManager.ahk
#Include lib\Player.ahk
#Include lib\HotkeyManager.ahk
#Include lib\Recorder.ahk
#Include lib\StepEditor.ahk
#Include lib\OCR.ahk
#Include lib\WebView2.ahk

global App := MacroForgeApp()
App.Show()


class MacroForgeApp {
    gui := ""
    preset := ""
    player := ""
    recorder := ""
    hotkeys := ""
    presetList := ""
    stepList := ""
    logBox := ""
    statusBar := ""
    nameEdit := ""
    descEdit := ""
    tabs := ""
    recBtn := ""
    saveBtn := ""
    deleteBtn := ""
    renameBtn := ""
    addStepBtn := ""
    editStepBtn := ""
    removeStepBtn := ""
    upStepBtn := ""
    downStepBtn := ""
    dupStepBtn := ""
    clearStepBtn := ""
    applyHkBtn := ""
    settingsBtn := ""
    ; Extra control references used by the responsive layout engine so every
    ; tab (not just Board) grows to fill the window when maximized / fullscreen.
    nameLabel := ""
    descLabel := ""
    stepListLabel := ""
    stepBtns := []        ; Add/Edit/Remove/Up/Down/Dup/Clear row
    playBtns := []        ; Record / Start / Pause / Stop row
    logBtns := []         ; Clear / Open Log Folder row
    settingsCtrls := Map()
    hotkeyCtrls := Map()
    ; All controls that should be disabled when a built-in (read-only) preset
    ; is loaded. Filled in _buildGui() and toggled by _setEditable().
    _editableCtrls := []
    dirty := false
    wvController := ""
    wvCore := ""
    wvReady := false
    boardContainer := ""
    boardHint := ""
    _prevTab := 1
    _boardRect := Map()
    ; Deferred board re-measure used to make the WebView snap to the final
    ; client size after a maximize / fullscreen frame change. _boardRemeasureCb
    ; is a bound method created in __New so SetTimer can add/remove it.
    _boardRemeasureCb := ""
    ; Signature (WxH) of the board container at the last re-measure, used to
    ; detect when an animated maximize has finished settling.
    _lastBoardSig := ""
    ; Name of the preset currently loaded into the visual board, plus a flag
    ; that becomes true whenever Steps change outside the board. Together they
    ; let us push steps into the board only when they actually changed, instead
    ; of clobbering the user's node layout on every tab switch.
    _boardPresetName := ""
    _boardNeedsReload := true
    ; Guard: true only while we are importing steps FROM the board, so the
    ; live Steps->Board push in _refreshStepList does not echo back and clobber
    ; the user's node layout.
    _importingFromBoard := false

    __New() {
        for d in [Cfg.PRESETS_DIR, Cfg.LOGS_DIR, Cfg.IMAGES_DIR]
            if !DirExist(d)
                DirCreate(d)
        ; Lay down canonical bodies for the 3 built-ins on every startup.
        ; They are guaranteed to be present and unchanged on disk.
        PresetManager.EnsureBuiltins()
        this.player := Player()
        this.player.SetStateCallback(ObjBindMethod(this, "_onPlayerState"))
        this.player.SetProgressCallback(ObjBindMethod(this, "_onPlayerProgress"))
        this.recorder := Recorder()
        this.recorder.SetStateCallback(ObjBindMethod(this, "_onRecorderState"))

        handlers := Map(
            "start", ObjBindMethod(this, "_hkStart"),
            "stop",  ObjBindMethod(this, "_hkStop"),
            "pause", ObjBindMethod(this, "_hkPause"),
            "panic", ObjBindMethod(this, "_hkPanic")
        )
        this.hotkeys := HotkeyManager(handlers)
        this._boardRemeasureCb := ObjBindMethod(this, "_doBoardRemeasure")
        Theme.Load()  ; restore last chosen theme (dark/light) before building UI
        this._buildGui()
        Logger.SetSink(ObjBindMethod(this, "_appendLog"))
        this._refreshPresetList()
        this._maybeAutoSelectFirst()
        ; Lazy-init WebView2 when Board tab is first selected
        this.tabs.OnEvent("Change", (*) => this._onTabChange())
    }

    Show() {
        this.gui.Show("w1100 h750")
        ; Apply the responsive layout once on first show so the board
        ; container is positioned inside the tab (not under the presets).
        this._layoutBoard()
    }

    _onTabChange() {
        tabIdx := this.tabs.Value
        Logger.Info("TabChange: tabIdx=" tabIdx " prevTab=" (this.HasOwnProp("_prevTab")?this._prevTab:"?") " wvReady=" this.wvReady)
        ; Leaving the Board tab: pull the current graph back into the preset
        ; so Steps and Board stay synchronized in both directions.
        if (this._prevTab = 2 && tabIdx != 2 && this.wvReady)
            this._requestBoardSave()
        if tabIdx = 2 {  ; Board tab
            try this.boardContainer.Visible := true
            if !this.wvReady
                this._initWebView()
            else {
                this.wvController.IsVisible := true
                this._layoutBoard()
                this._updateBoardBounds()
                ; Entering Board while already maximized: schedule a trailing
                ; re-measure so the WebView fills the final client size without
                ; needing a second Steps->Board toggle.
                this._scheduleBoardRemeasure()
                try this.wvController.MoveFocus(0)
                ; Only repopulate the board when the steps changed elsewhere,
                ; so we never wipe the user's node layout on a plain tab toggle.
                if this._boardNeedsReload || this._boardPresetName != this._currentPresetName()
                    this._sendStepsToBoard()
            }
        } else {
            if this.wvReady
                this.wvController.IsVisible := false
            try this.boardContainer.Visible := false
        }
        this._prevTab := tabIdx
    }

    _requestBoardSave() {
        if !this.wvReady
            return
        msg := JSON.stringify(Map("action", "requestSave"))
        try this.wvCore.PostWebMessageAsJson(msg)
    }

    _initWebView() {
        if this.wvReady
            return
        try {
            dllPath := A_ScriptDir "\lib\WebView2Loader.dll"
            ; Parent the WebView to the board CONTAINER control, not the main
            ; GUI. The container is positioned by _layoutBoard (AHK-managed and
            ; DPI-correct), so the WebView just fills it with no manual coordinate
            ; or DPI math. This stops the board landing on the presets panel or
            ; disappearing off-screen.
            this._layoutBoard()
            Logger.Info("WebView2: creating controller for board container hwnd")
            this.wvController := WebView2.create(this.boardContainer.Hwnd, , , , , , dllPath)
            Logger.Info("WebView2: controller created. GUI hwnd=" this.gui.Hwnd " type=" Type(this.wvController))
            this.wvCore := this.wvController.CoreWebView2
            try {
                s := this.wvCore.Settings
                s.IsZoomControlEnabled := false
                s.AreBrowserAcceleratorKeysEnabled := false
                s.IsStatusBarEnabled := false
                s.AreDefaultContextMenusEnabled := false
            }
            this._layoutBoard()
            this._updateBoardBounds()
            this.wvController.IsVisible := true
            ; Load nodeboard HTML content directly via NavigateToString
            htmlPath := A_ScriptDir "\lib\nodeboard.html"
            htmlContent := FileRead(htmlPath, "UTF-8")
            Logger.Info("WebView2: loading nodeboard HTML (" StrLen(htmlContent) " chars)")
            this.wvCore.NavigateToString(htmlContent)
            ; Listen for messages from JavaScript
            this.wvCore.add_WebMessageReceived(ObjBindMethod(this, "_onWebViewMessage"))
            ; Listen for navigation completion
            this.wvCore.add_NavigationCompleted(ObjBindMethod(this, "_onWebViewNavCompleted"))
            ; Handle JavaScript dialogs (confirm/alert) - auto-accept
            this.wvCore.add_ScriptDialogOpening(ObjBindMethod(this, "_onScriptDialog"))
            Logger.Info("InitWebView done: wvController type=" Type(this.wvController) " IsVisible=" this.wvController.IsVisible)
            this.wvReady := true
            Logger.Info("WebView2 Board initialized")
        } catch as e {
            Logger.Warn("WebView2 init failed: " e.Message)
            MsgBox "WebView2 Board failed to initialize.`n`n" e.Message, "Board Error", 0x30
        }
    }

    ; Fill the WebView to its parent container. The WebView is parented to the
    ; boardContainer control, so its bounds are simply (0, 0, containerW,
    ; containerH) in the container client area. No DPI math is needed because
    ; the container client size is already in physical pixels.
    _updateBoardBounds() {
        if !this.wvController || !this.boardContainer
            return
        try {
            ; Make sure the container is positioned first.
            this._layoutBoard()
            try this.wvController.NotifyParentWindowPositionChanged()
            ; The WebView is parented to the board CONTAINER, so its bounds are
            ; the container client area in LOCAL coordinates (0,0,w,h). The
            ; container itself is positioned by _layoutBoard, so the board moves
            ; and resizes with it - embedded like a screen, not floating on top.
            rc := Buffer(16)
            if !DllCall("User32\GetClientRect", "ptr", this.boardContainer.Hwnd, "ptr", rc)
                return
            w := NumGet(rc, 8, "int")
            h := NumGet(rc, 12, "int")
            rect := Buffer(16)
            NumPut("int", 0, "int", 0, "int", w, "int", h, rect)
            this.wvController.Bounds := rect
            Logger.Info("UpdateBoardBounds: container-local bounds w=" w " h=" h " visible=" this.wvController.IsVisible)
            this._raiseWebView()
        } catch as e {
            Logger.Warn("UpdateBoardBounds error: " e.Message)
        }
    }


    ; The WebView lives INSIDE boardContainer. The container is a direct child
    ; of the main GUI and overlaps the Tab3 control, so we raise the CONTAINER
    ; (with its embedded WebView) above the tab in z-order. This keeps the board
    ; embedded like a screen inside the Board tab, while still receiving input.
    _raiseWebView() {
        try {
            if !this.boardContainer
                return
            hostHwnd := this.boardContainer.Hwnd
            ; HWND_TOP=0, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE=0x13
            DllCall("User32\SetWindowPos", "ptr", hostHwnd, "ptr", 0, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x13)
            Logger.Info("RaiseWebView: raised board container hwnd=" hostHwnd " above tab")
        } catch as e {
            Logger.Warn("RaiseWebView error: " e.Message)
        }
    }
    _onScriptDialog(sender, args) {
        ; Auto-accept all JavaScript dialogs (confirm, alert, prompt)
        try args.Accept()
    }

    _onWebViewNavCompleted(sender, args) {
        try {
            Logger.Info("WebView2 navigation completed")
            this._updateBoardBounds()
            try {
                this.wvController.MoveFocus(0)
                Logger.Info("NavCompleted: MoveFocus ok, bounds re-applied")
                this._raiseWebView()
            } catch as fe {
                Logger.Warn("NavCompleted: MoveFocus failed: " fe.Message)
            }
            this._pushThemeToBoard(Theme.current)
            this._sendStepsToBoard()
        } catch as e {
            Logger.Warn("NavigationCompleted error: " e.Message)
        }
    }

    _onGuiSize(guiObj, minMax, width, height) {
        ; AHK v2 Size event MinMax: -1 = minimized, 0 = restored/normal,
        ; 1 = MAXIMIZED. The previous code skipped on 1 thinking it was
        ; "minimized", which is exactly why maximizing / going fullscreen did
        ; NOT relayout the board until a tab toggle forced it. Only skip when
        ; actually minimized (the client size is 0 then).
        if minMax = -1  ; minimized
            return
        ; Reflow every tab's content to the new size, not just the board.
        this._layoutBoard(width, height)
        if this.wvReady && this.wvController {
            this._updateBoardBounds()
            ; When the window is maximized / restored / dragged to fullscreen,
            ; Windows finishes the frame change AFTER this Size event returns.
            ; Re-measuring the WebView on the next message loop guarantees the
            ; board snaps to the final client size live, with no need to
            ; toggle Steps->Board to force a refresh.
            this._scheduleBoardRemeasure()
        }
    }

    ; Re-measure the board AFTER Windows finishes the frame change. A maximize
    ; or drag-to-fullscreen finalizes the client size only after this Size event
    ; returns, so a single synchronous bounds update lands on the OLD size. We
    ; fire several staggered one-shot timers; each one re-reads the live client
    ; rect, so the WebView snaps to the final size with no Steps<->Board toggle.
    ; The timer is negative (one-shot) and re-armed every Size event; re-arming
    ; the SAME bound callback simply reschedules it, which is exactly what we
    ; want during an animated maximize.
    _scheduleBoardRemeasure() {
        SetTimer(this._boardRemeasureCb, -1)
    }

    _doBoardRemeasure() {
        if !(this.wvReady && this.wvController)
            return
        if this.tabs.Value != 2
            return
        ; Re-read the CURRENT client size and re-apply both the AHK container
        ; layout and the WebView bounds from those fresh numbers.
        this._layoutBoard()
        this._updateBoardBounds()
        ; The size may still be settling (animated maximize). If the container
        ; client size changed since last tick, schedule one more pass.
        rc := Buffer(16, 0)
        if this.boardContainer && DllCall("User32\GetClientRect", "ptr", this.boardContainer.Hwnd, "ptr", rc) {
            w := NumGet(rc, 8, "int"), h := NumGet(rc, 12, "int")
            sig := w "x" h
            if (sig != this._lastBoardSig) {
                this._lastBoardSig := sig
                SetTimer(this._boardRemeasureCb, -50)
            }
        }
    }

    ; Single source of truth for positioning the tab and ALL tab content. Called
    ; on resize AND right before the WebView is measured, so the board never
    ; ends up sitting on top of the presets panel and every tab fills the window.
    _layoutBoard(width := 0, height := 0) {
        if (width = 0 || height = 0) {
            this.gui.GetClientPos(, , &cw, &ch)
            width := cw, height := ch
        }
        leftPanelW := 180
        margin := 8
        statusH := 22
        tabHdrH := 30
        ; Pin the settings gear to the bottom-left corner, just above the status
        ; bar, so it stays anchored on resize / maximize.
        if this.settingsBtn
            try this.settingsBtn.Move(margin, height - statusH - 30, 34, 26)
        tabX := leftPanelW + margin * 3
        tabY := margin
        tabW := width - tabX - margin
        tabH := height - tabY - margin - statusH
        try this.tabs.Move(tabX, tabY, tabW, tabH)
        contentX := tabX + margin
        contentY := tabY + tabHdrH
        contentW := tabW - margin * 2
        contentH := tabH - tabHdrH - margin

        ; --- Board tab ---
        boardW := contentW
        boardH := contentH - 30
        ; Remember the board rectangle (client coords of the main GUI) so the
        ; WebView can be positioned from the SAME numbers, never from GetPos.
        this._boardRect := Map("x", contentX, "y", contentY, "w", boardW, "h", boardH)
        if this.boardContainer {
            try this.boardContainer.Move(contentX, contentY, boardW, boardH)
            try this.boardHint.Move(contentX, contentY + boardH + margin, boardW, 20)
        }

        ; --- Log tab ---
        if this.logBox {
            logBtnH := 28
            logH := contentH - logBtnH - margin
            try this.logBox.Move(contentX, contentY, contentW, logH)
            bx := contentX, by := contentY + logH + 5
            for btn in this.logBtns {
                try btn.Move(bx, by)
                bx += 95
            }
        }

        ; --- Steps tab (native controls scale with the window too) ---
        ; Derive the Steps content rectangle from the tab control's ACTUAL
        ; display area (TCM_ADJUSTRECT), so controls always land exactly inside
        ; the tab body regardless of theme / DPI. Falls back to the computed
        ; content rect if the message fails.
        sx := contentX, sy := contentY, sw := contentW, sh := contentH
        try {
            r := Buffer(16, 0)
            ; tab body in GUI-client coords = (tabX, tabY, tabX+tabW, tabY+tabH)
            NumPut("int", tabX, "int", tabY, "int", tabX + tabW, "int", tabY + tabH, r)
            ; TCM_ADJUSTRECT = 0x1304; wParam FALSE = rect display->content
            DllCall("User32\SendMessage", "ptr", this.tabs.Hwnd, "uint", 0x1304, "ptr", 0, "ptr", r)
            ax := NumGet(r, 0, "int"), ay := NumGet(r, 4, "int")
            ar := NumGet(r, 8, "int"), ab := NumGet(r, 12, "int")
            if (ar - ax > 100 && ab - ay > 100) {
                pad := 6
                sx := ax + pad, sy := ay + pad
                sw := (ar - ax) - pad * 2, sh := (ab - ay) - pad * 2
            }
        }
        this._layoutStepsTab(sx, sy, sw, sh)
    }

    ; Reflow the Steps tab so the preset name/description/step-list and the
    ; button rows grow with the window instead of staying at their build-time
    ; fixed widths. This is what makes Steps look right in fullscreen.
    _layoutStepsTab(x, y, w, h) {
        if !this.stepList
            return
        ; Guard against tiny / transient sizes that would push controls to
        ; negative coordinates and corrupt their painting.
        if (w < 200 || h < 200)
            return
        margin := 8
        cy := y
        labelH := 18
        editH := 23
        ; Preset name row: label + edit on one line.
        if this.nameLabel {
            try this.nameLabel.Move(x, cy + 3, 90, labelH)
            try this.nameEdit.Move(x + 95, cy, w - 95, editH)
        }
        cy += editH + margin
        ; Description label + multiline edit.
        descH := 70
        if this.descLabel {
            try this.descLabel.Move(x, cy, 200, labelH)
            cy += labelH + 3
            try this.descEdit.Move(x, cy, w, descH)
            cy += descH + margin
        }
        ; Button rows are anchored to the BOTTOM so the step list takes all the
        ; remaining vertical space.
        btnH := 28
        rowGap := 10
        playY := y + h - btnH
        stepBtnY := playY - btnH - rowGap
        listBottom := stepBtnY - margin
        listH := listBottom - cy
        if listH < 80
            listH := 80
        ; Move the ListView, then resize its Summary column from its ACTUAL
        ; client width (minus the fixed columns and the vertical scrollbar) and
        ; force a full repaint. Without the redraw, AHK leaves a stale header,
        ; which shows up as missing columns and the "Type" label only painting
        ; on hover.
        this.stepList.Opt("-Redraw")
        try this.stepList.Move(x, cy, w, listH)
        col1 := 40, col2 := 90
        ; SM_CXVSCROLL (=2): width of a vertical scrollbar. AHK v2 has no
        ; SysGet command, so call GetSystemMetrics directly.
        sbW := DllCall("User32\GetSystemMetrics", "int", 2, "int")
        summaryW := w - col1 - col2 - sbW - 6
        if summaryW < 120
            summaryW := 120
        try this.stepList.ModifyCol(1, col1)
        try this.stepList.ModifyCol(2, col2)
        try this.stepList.ModifyCol(3, summaryW)
        this.stepList.Opt("+Redraw")
        try this.stepList.Redraw()
        ; Step action button row.
        bx := x
        for btn in this.stepBtns {
            try btn.Move(bx, stepBtnY, , btnH)
            btn.GetPos(, , &bw)
            bx += bw + 5
        }
        ; Record / Start / Pause / Stop row.
        bx := x
        for btn in this.playBtns {
            try btn.Move(bx, playY, , btnH)
            btn.GetPos(, , &bw)
            bx += bw + 8
        }
    }

    _onWebViewMessage(sender, args) {
        try {
            msg := args.WebMessageAsJson
            Logger.Info("WebView msg from JS: " SubStr(msg, 1, 120))
            data := JSON.parse(msg)
            if data["action"] = "save" && data.Has("steps") {
                ; Prevent cross-preset contamination during rapid tab switching
                if this.preset is Map && this._currentPresetName() == this._boardPresetName {
                    this.preset["steps"] := data["steps"]
                    this._importingFromBoard := true
                    try this._refreshStepList()
                    this._importingFromBoard := false
                    this._markDirty()
                    ; The board is the source of truth for these steps now, so
                    ; re-entering it must not overwrite the existing node layout.
                    this._boardPresetName := this._currentPresetName()
                    this._boardNeedsReload := false
                    Logger.Info("Board: imported " data["steps"].Length " steps from visual board")
                } else {
                    Logger.Warn("Board: discarded save message because preset changed (expected " this._boardPresetName ", got " this._currentPresetName() ")")
                }
            } else if data["action"] = "requestLoad" {
                this._sendStepsToBoard()
            } else if data["action"] = "pick" {
                this._onBoardPick(data.Has("kind") ? data["kind"] : "")
            }
        } catch as e {
            Logger.Warn("WebView message error: " e.Message)
        }
    }

    ; Perform a native pick requested by the visual board and post the captured
    ; value(s) back as a pickResult message. Mirrors StepEditor pickers but is
    ; standalone (no GUI fields) and returns data to the WebView.
    _onBoardPick(kind) {
        Logger.Info("Board pick requested: " kind)
        res := Map("cancelled", true)
        try {
            if (kind = "key") {
                res := this._pickKeyValue()
            } else if (kind = "window" || kind = "windowOcr") {
                res := this._pickWindowValue()
            } else if (kind = "region" || kind = "ocrRegion") {
                res := this._pickRegionValue()
            } else if (kind = "browse") {
                res := this._pickImageValue()
            } else if (kind = "pixel") {
                res := this._pickPointValue(true)
            } else {
                res := this._pickPointValue(false)
            }
        } catch as e {
            Logger.Warn("Board pick error: " e.Message)
            res := Map("cancelled", true)
        }
        try this.wvCore.PostWebMessageAsJson(JSON.stringify(Map("action", "pickResult", "result", res)))
    }
    ; Capture cursor position (and pixel colour when wantColor is true).
    _pickPointValue(wantColor) {
        this.gui.Hide()
        Sleep 250
        out := Map("cancelled", true)
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                break
            }
            MouseGetPos(&mx, &my)
            clr := ""
            if wantColor
                try clr := PixelGetColor(mx, my, "RGB")
            ToolTip (wantColor ? "🎯 Pixel  X: " mx "  Y: " my "  " clr : "🎯 XY  X: " mx "  Y: " my) "`nLMB = capture, Esc = cancel"
            if GetKeyState("LButton", "P") {
                out := Map("x", mx, "y", my)
                if wantColor
                    out["color"] := clr
                KeyWait "LButton"
                break
            }
            Sleep 30
        }
        ToolTip
        this.gui.Show()
        try this._updateBoardBounds()
        return out
    }
    ; Capture a window under the cursor as ahk_exe ProcessName.
    _pickWindowValue() {
        this.gui.Hide()
        Sleep 250
        out := Map("cancelled", true)
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                break
            }
            MouseGetPos(, , &hwnd)
            procName := ""
            try procName := WinGetProcessName("ahk_id " hwnd)
            ToolTip "🎯 Window: " procName "`nLMB = capture, Esc = cancel"
            if GetKeyState("LButton", "P") {
                if procName != ""
                    out := Map("title", "ahk_exe " procName)
                KeyWait "LButton"
                break
            }
            Sleep 30
        }
        ToolTip
        this.gui.Show()
        try this._updateBoardBounds()
        return out
    }
    ; Capture a rectangular region by click-drag.
    _pickRegionValue() {
        this.gui.Hide()
        Sleep 250
        sx := 0, sy := 0, ex := 0, ey := 0
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                ToolTip
                this.gui.Show()
                try this._updateBoardBounds()
                return Map("cancelled", true)
            }
            MouseGetPos(&mx, &my)
            ToolTip "🎯 Region  X: " mx "  Y: " my "`nHold LMB at first corner, Esc = cancel"
            if GetKeyState("LButton", "P") {
                sx := mx, sy := my
                break
            }
            Sleep 30
        }
        loop {
            if !GetKeyState("LButton", "P") {
                MouseGetPos(&ex, &ey)
                break
            }
            MouseGetPos(&cx, &cy)
            ToolTip "🎯 Region  (" sx "," sy ") to (" cx "," cy ")`nRelease LMB to finish"
            Sleep 30
        }
        ToolTip
        this.gui.Show()
        try this._updateBoardBounds()
        return Map("x1", Min(sx, ex), "y1", Min(sy, ey), "x2", Max(sx, ex), "y2", Max(sy, ey))
    }
    ; Capture a single keypress.
    _pickKeyValue() {
        this.gui.Hide()
        Sleep 250
        ToolTip "🎯 Key: press any key (Esc cancels, 15s timeout)"
        ih := InputHook("L0 T15")
        ih.KeyOpt("{All}", "E")
        ih.Start()
        ih.Wait()
        out := Map("cancelled", true)
        if ih.EndReason = "EndKey" && ih.EndKey != "Escape"
            out := Map("key", ih.EndKey)
        ToolTip
        this.gui.Show()
        try this._updateBoardBounds()
        return out
    }
    ; Browse for an image file.
    _pickImageValue() {
        path := FileSelect(3, , "Select image", "Images (*.png; *.jpg; *.jpeg; *.bmp)")
        if path = ""
            return Map("cancelled", true)
        return Map("image", path)
    }

    _sendStepsToBoard() {
        if !this.wvReady || !(this.preset is Map)
            return
        steps := this.preset["steps"]
        payload := Map("action", "loadSteps", "steps", steps)
        msg := JSON.stringify(payload)
        try this.wvCore.PostWebMessageAsJson(msg)
        ; The board now mirrors this preset's steps; do not reload until they
        ; change again outside the board.
        this._boardPresetName := this._currentPresetName()
        this._boardNeedsReload := false
    }

    _buildGui() {
        g := Gui("+Resize", Cfg.APP_NAME " " Cfg.APP_VERSION)
        g.SetFont("s9", "Segoe UI")
        g.MarginX := 8, g.MarginY := 8
        g.OnEvent("Close", (*) => this._onClose())

        ; ---- Theme ----
        ; Colors come from the Theme class (dark/light). We tag controls into
        ; buckets (_themeButtons, _themeFields, _themeLabels) as they are created
        ; so a single _applyTheme() call can recolor the whole window live.
        this._themeButtons := []
        this._themeFields := []
        this._themeLabels := []
        this._themeHints := []
        pal := Theme.Palette()
        g.BackColor := pal["bg"]
        g.SetFont("c" pal["text"])

        this._themeLabels.Push(g.AddText("xm ym w180", "Presets:"))
        this.presetList := g.AddListBox("xm y+3 w180 h420 vPresetList")
        this.presetList.OnEvent("Change", (*) => this._onPresetPick())

        newBtn := g.AddButton("xm y+8 w85 h28", "New")
        newBtn.OnEvent("Click", (*) => this._newPreset())
        this.deleteBtn := g.AddButton("x+10 yp w85 h28", "Delete")
        this.deleteBtn.OnEvent("Click", (*) => this._deletePreset())
        this.renameBtn := g.AddButton("xm y+6 w85 h28", "Rename")
        this.renameBtn.OnEvent("Click", (*) => this._renamePreset())
        reloadBtn := g.AddButton("x+10 yp w85 h28", "Reload")
        reloadBtn.OnEvent("Click", (*) => this._reloadPreset())
        this.saveBtn := g.AddButton("xm y+6 w180 h28", "Save Preset")
        this.saveBtn.OnEvent("Click", (*) => this._savePreset())
        importBtn := g.AddButton("xm y+6 w85 h28", "Import .json")
        importBtn.OnEvent("Click", (*) => this._importPreset())
        openFolderBtn := g.AddButton("x+10 yp w85 h28", "Open Folder")
        openFolderBtn.OnEvent("Click", (*) => Run('explorer.exe "' Cfg.PRESETS_DIR '"'))
        this._themeButtons.Push(newBtn, this.deleteBtn, this.renameBtn, reloadBtn, this.saveBtn, importBtn, openFolderBtn)

        this._editableCtrls.Push(this.deleteBtn, this.renameBtn, this.saveBtn)

        this.tabs := g.AddTab3("x+15 ym w870 h700 vMainTabs", ["Steps","Board","Settings","Hotkeys","Log"])

        ; ---------------- Steps tab ----------------
        this.tabs.UseTab("Steps")
        this.nameLabel := g.AddText("w200 Section", "Preset name:")
        this._themeLabels.Push(this.nameLabel)
        this.nameEdit := g.AddEdit("x+5 yp-3 w300")
        this.nameEdit.OnEvent("Change", (*) => this._markDirty())
        this._editableCtrls.Push(this.nameEdit)

        this.descLabel := g.AddText("xs y+10 w300", "Description:")
        this._themeLabels.Push(this.descLabel)
        this.descEdit := g.AddEdit("xs y+3 w580 h70 +Multi")
        this.descEdit.OnEvent("Change", (*) => this._markDirty())
        this._editableCtrls.Push(this.descEdit)

        this.stepList := g.AddListView("xs y+10 w580 h290 Grid", ["#","Type","Summary"])
        this.stepList.ModifyCol(1, 40)
        this.stepList.ModifyCol(2, 90)
        this.stepList.ModifyCol(3, 440)
        this.stepList.OnEvent("DoubleClick", (ctrl, row) => row > 0 ? this._editStep(row) : "")

        this.addStepBtn := g.AddButton("xs y+8 w70", "Add")
        this.addStepBtn.OnEvent("Click", (*) => this._addStep())
        this.editStepBtn := g.AddButton("x+5 yp w70", "Edit")
        this.editStepBtn.OnEvent("Click", (*) => this._editStepSelected())
        this.removeStepBtn := g.AddButton("x+5 yp w70", "Remove")
        this.removeStepBtn.OnEvent("Click", (*) => this._removeStep())
        this.upStepBtn := g.AddButton("x+5 yp w70", "Up")
        this.upStepBtn.OnEvent("Click", (*) => this._moveStep(-1))
        this.downStepBtn := g.AddButton("x+5 yp w70", "Down")
        this.downStepBtn.OnEvent("Click", (*) => this._moveStep(1))
        this.dupStepBtn := g.AddButton("x+5 yp w70", "Dup")
        this.dupStepBtn.OnEvent("Click", (*) => this._duplicateStep())
        this.clearStepBtn := g.AddButton("x+5 yp w90", "Clear All")
        this.clearStepBtn.OnEvent("Click", (*) => this._clearSteps())

        this._editableCtrls.Push(
            this.addStepBtn, this.editStepBtn, this.removeStepBtn,
            this.upStepBtn, this.downStepBtn, this.dupStepBtn, this.clearStepBtn
        )
        this.stepBtns := [
            this.addStepBtn, this.editStepBtn, this.removeStepBtn,
            this.upStepBtn, this.downStepBtn, this.dupStepBtn, this.clearStepBtn
        ]
        for b in this.stepBtns
            this._themeButtons.Push(b)

        this.recBtn := g.AddButton("xs y+12 w120", "Record (F4)")
        this.recBtn.OnEvent("Click", (*) => this._toggleRecord())
        startBtn := g.AddButton("x+10 yp w100", "Start")
        startBtn.OnEvent("Click", (*) => this._hkStart())
        pauseBtn := g.AddButton("x+5 yp w100", "Pause")
        pauseBtn.OnEvent("Click", (*) => this._hkPause())
        stopBtn := g.AddButton("x+5 yp w100", "Stop")
        stopBtn.OnEvent("Click", (*) => this._hkStop())
        this.playBtns := [this.recBtn, startBtn, pauseBtn, stopBtn]
        for b in this.playBtns
            this._themeButtons.Push(b)
        this._editableCtrls.Push(this.recBtn)

        ; ---------------- Board tab ----------------
        this.tabs.UseTab("Board")
        ; Container for WebView2. Use a custom Static control as the host window.
        ; (WebView host moved outside the Tab3 control - created after UseTab())
        this.boardHint := g.AddText("xm cGray", "Visual node editor. Right-click to add nodes. Drag pins to connect. Double-click a connection to remove it.")
        this._themeHints.Push(this.boardHint)

        ; ---------------- Settings tab ----------------
        this.tabs.UseTab("Settings")
        this._themeLabels.Push(g.AddText("w560 Section", "Per-preset playback settings (saved with the preset):"))
        this._addSettingRow(g, "speedMultiplier", "Speed multiplier:",     "1.0",  "Divides every sleep. 2.0 = twice as fast.")
        this._addSettingRow(g, "repeatCount",     "Repeat count (0=inf):", "1",    "How many times to play the whole preset.")
        this._addSettingRow(g, "startDelayMs",    "Start delay (ms):",     "1000", "Delay before playback begins; lets you alt-tab.")
        this._addSettingRow(g, "targetWindow",    "Target window title:",  "",     "AHK WinTitle, e.g. 'ahk_exe RobloxPlayerBeta.exe'.")
        this._addSettingRow(g, "focusOnStart",    "Focus on start (0/1):", "0",    "Activate target window before playback.")
        this._addSettingRow(g, "stopOnError",     "Stop on error (0/1):",  "1",    "Halt playback if a step throws.")

        ; ---------------- Hotkeys tab ----------------
        this.tabs.UseTab("Hotkeys")
        this._themeLabels.Push(g.AddText("w560 Section", "Hotkey strings use AHK v2 modifier syntax. Examples: F1, ^F1 (Ctrl), !s (Alt), +Esc (Shift). Apply Hotkeys to test without saving."))
        this._addHotkeyRow(g, "start", "Start:")
        this._addHotkeyRow(g, "stop",  "Stop:")
        this._addHotkeyRow(g, "pause", "Pause/Resume:")
        this._addHotkeyRow(g, "panic", "Panic (stop + release keys):")
        this.applyHkBtn := g.AddButton("xs y+15 w180 h28", "Apply Hotkeys")
        this.applyHkBtn.OnEvent("Click", (*) => this._applyHotkeysFromUi())
        this._themeButtons.Push(this.applyHkBtn)
        this._editableCtrls.Push(this.applyHkBtn)

        ; ---------------- Log tab ----------------
        this.tabs.UseTab("Log")
        this.logBox := g.AddEdit("w870 h640 Section +ReadOnly +Multi +WantReturn")
        logClearBtn := g.AddButton("xs y+5 w90 h28", "Clear")
        logClearBtn.OnEvent("Click", (*) => (this.logBox.Value := "", Logger.Clear()))
        logOpenBtn := g.AddButton("x+5 yp w90 h28", "Open Log Folder")
        logOpenBtn.OnEvent("Click", (*) => Run('explorer.exe "' Cfg.LOGS_DIR '"'))
        this.logBtns := [logClearBtn, logOpenBtn]
        for b in this.logBtns
            this._themeButtons.Push(b)

        this.tabs.UseTab()

        ; WebView2 host parented directly to the main GUI (NOT inside Tab3).
        ; A host inside Tab3 renders but never receives mouse/keyboard input,
        ; which looks exactly like a frozen screenshot. Positioned by _layoutBoard.
        this.boardContainer := g.AddCustom("x0 y0 w870 h640 vBoardContainer ClassStatic Background0x" pal["bg"])
        this.boardContainer.Visible := false

        ; Settings gear (bottom-left). Opens a small popup menu to switch theme.
        this.settingsBtn := g.AddButton("x8 y700 w34 h26 vSettingsBtn", Chr(0x2699))
        this.settingsBtn.SetFont("s12")
        this.settingsBtn.OnEvent("Click", (*) => this._showSettingsMenu())
        this._themeButtons.Push(this.settingsBtn)

        ; Status bar: part1 = preset status, part2 = player state, part3 = recorder state.
        this.statusBar := g.AddStatusBar(, " Idle")
        this.statusBar.SetParts(320, 160)

        Hotkey "F4", (*) => this._toggleRecord(), "On"

        ; Handle window resize for responsive layout
        g.OnEvent("Size", ObjBindMethod(this, "_onGuiSize"))

        this.gui := g
        ; Convert every native button into an owner-drawn ThemedButton so the
        ; palette, hover/pressed states and rounded corners actually render.
        this._skinButtons()
        ; Paint the whole window with the active theme (dark/light) once every
        ; control exists, then push the matching palette to the WebView board.
        this._applyTheme(Theme.current)
    }

    ; Assign a visual role to each button and hand them to ThemedButton, which
    ; owner-draws them. Roles drive the accent: primary = main action,
    ; success = playback start/record, danger = destructive, secondary = rest.
    _skinButtons() {
        ThemedButton.Init()
        roles := Map()
        for b in [this.saveBtn, this.applyHkBtn]
            if (b is Gui.Control)
                roles[b.Hwnd] := "primary"
        success := [this.recBtn]
        danger  := [this.deleteBtn, this.clearStepBtn]
        if (this.playBtns.Length >= 4) {
            success.Push(this.playBtns[2])   ; Start
            danger.Push(this.playBtns[4])    ; Stop
        }
        for b in success
            if (b is Gui.Control)
                roles[b.Hwnd] := "success"
        for b in danger
            if (b is Gui.Control)
                roles[b.Hwnd] := "danger"
        for b in this._themeButtons {
            try {
                role := roles.Has(b.Hwnd) ? roles[b.Hwnd] : "secondary"
                ThemedButton.Attach(b, role)
            }
        }
    }

    ; ======================= THEMING =======================
    ; Recolor the entire native window for the named theme and persist + sync.
    _applyTheme(name) {
        if !Theme.Has(name)
            name := "dark"
        Theme.current := name
        pal := Theme.Palette(name)

        ; Window background + default font color.
        try this.gui.BackColor := pal["bg"]

        ; Data-entry surfaces (Edit / ListBox / ListView): raised surface color.
        for ctrl in [this.nameEdit, this.descEdit, this.logBox, this.presetList, this.stepList] {
            try {
                ctrl.Opt("Background" pal["surface"])
                ctrl.SetFont("c" pal["text"])
            }
        }
        for key, ctrl in this.settingsCtrls
            this._themeField(ctrl, pal)
        for key, ctrl in this.hotkeyCtrls
            this._themeField(ctrl, pal)

        ; Primary text labels.
        for lbl in this._themeLabels {
            try lbl.SetFont("c" pal["text"])
            try lbl.Opt("Background" pal["bg"])
        }
        ; Dimmed hint labels.
        for lbl in this._themeHints {
            try lbl.SetFont("c" pal["textDim"])
            try lbl.Opt("Background" pal["bg"])
        }
        ; Buttons: tinted surface + readable text. AHK buttons are owner-light
        ; by default, so we give them the alt surface tone for contrast.
        for btn in this._themeButtons {
            try {
                btn.Opt("Background" pal["surfaceAlt"])
                btn.SetFont("c" pal["text"])
            }
        }

        ; Apply the OS-level dark/light control theme so native widgets (button
        ; faces, list borders, scrollbars, combo dropdowns) render dark instead
        ; of staying system-light. This is what makes the dark theme look polished
        ; rather than half-applied.
        dark := (pal["titleDark"] = "1")
        for ctrl in this._themeButtons
            this._setCtrlDarkMode(ctrl, dark)
        for ctrl in [this.nameEdit, this.descEdit, this.logBox, this.presetList, this.stepList]
            this._setCtrlDarkMode(ctrl, dark)
        for key, ctrl in this.settingsCtrls
            this._setCtrlDarkMode(ctrl, dark)
        for key, ctrl in this.hotkeyCtrls
            this._setCtrlDarkMode(ctrl, dark)
        try this._setCtrlDarkMode(this.tabs, dark)

        ; Board host background.
        try this.boardContainer.Opt("Background" pal["bg"])

        ; Immersive dark/light title bar.
        this._setTitleBarDark(this.gui.Hwnd, pal["titleDark"] = "1")

        ; Force a repaint so color changes show immediately.
        try {
            this.gui.Opt("+Redraw")
            WinRedraw("ahk_id " this.gui.Hwnd)
        }

        ; Repaint owner-drawn buttons so they adopt the new palette.
        try ThemedButton.RefreshAll()

        ; Keep the board in sync (no-op until the WebView is ready).
        this._pushThemeToBoard(name)
        Theme.Save()
        Logger.Info("Theme applied: " name)
    }

    _themeField(ctrl, pal) {
        try {
            ctrl.Opt("Background" pal["surface"])
            ctrl.SetFont("c" pal["text"])
        }
    }

    ; DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (or 19 on Win10 1809-1909). Switches the
    ; title bar between dark and light to match the client area.
    _setTitleBarDark(hwnd, dark) {
        flag := dark ? 1 : 0
        for attr in [20, 19] {
            try {
                if DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "Int", attr
                    , "Int*", flag, "Int", 4) = 0
                    break
            }
        }
        ; Nudge the frame so the title bar repaints without a manual resize.
        try {
            WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
            DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", x, "Int", y
                , "Int", w, "Int", h, "UInt", 0x0027) ; SWP_NOZORDER|NOACTIVATE|FRAMECHANGED|DRAWFRAME
        }
    }

    ; Apply the per-control OS theme. "DarkMode_Explorer" makes Win10 1809+
    ; render native controls (buttons, edits, lists, scrollbars) dark; the
    ; empty theme restores the default light look. WM_THEMECHANGED forces an
    ; immediate repaint.
    _setCtrlDarkMode(ctrl, dark) {
        if !(ctrl is Gui.Control)
            return
        try {
            sub := dark ? "DarkMode_Explorer" : ""
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctrl.Hwnd, "Str", sub, "Ptr", 0)
            DllCall("SendMessage", "Ptr", ctrl.Hwnd, "UInt", 0x031A, "Ptr", 0, "Ptr", 0) ; WM_THEMECHANGED
        }
    }

    ; Post the active palette to the WebView so the node board matches.
    _pushThemeToBoard(name := "") {
        if !(this.wvReady && this.wvCore)
            return
        try {
            msg := JSON.stringify(Theme.WebPayload(name))
            this.wvCore.PostWebMessageAsJson(msg)
        } catch as e {
            Logger.Warn("pushThemeToBoard failed: " e.Message)
        }
    }

    ; Small popup anchored to the gear button: pick a theme.
    _showSettingsMenu() {
        m := Menu()
        m.Add("Настройки", (*) => "")
        m.Disable("Настройки")
        m.Add()
        m.Add("Тёмная тема", (*) => this._applyTheme("dark"))
        m.Add("Светлая тема", (*) => this._applyTheme("light"))
        ; Mark the active theme with a checkmark.
        try m.Check(Theme.current = "light" ? "Светлая тема" : "Тёмная тема")
        ; Pop up just above the gear button (convert its client pos to screen).
        try {
            this.settingsBtn.GetPos(&bx, &by, &bw, &bh)
            pt := Buffer(8, 0)
            NumPut("int", bx, "int", by, pt)
            DllCall("ClientToScreen", "Ptr", this.gui.Hwnd, "Ptr", pt)
            sx := NumGet(pt, 0, "int"), sy := NumGet(pt, 4, "int")
            m.Show(sx, sy - 80)
        } catch {
            m.Show()
        }
    }

    _addSettingRow(g, key, label, def, hint) {
        this._themeLabels.Push(g.AddText("xs y+12 w180", label))
        edit := g.AddEdit("x+5 yp-3 w180", def)
        this._themeHints.Push(g.AddText("x+10 yp+2 w220 cGray", hint))
        edit.OnEvent("Change", (*) => this._markDirty())
        this.settingsCtrls[key] := edit
        this._editableCtrls.Push(edit)
    }

    _addHotkeyRow(g, key, label) {
        this._themeLabels.Push(g.AddText("xs y+12 w180", label))
        edit := g.AddEdit("x+5 yp-3 w160", "")
        this.hotkeyCtrls[key] := edit
        this._editableCtrls.Push(edit)
    }

    _refreshPresetList() {
        prevName := this._currentPresetName()
        this.presetList.Delete()
        names := PresetManager.List()
        if names.Length > 0
            this.presetList.Add(names)
        if prevName != "" {
            for i, n in names {
                if n = prevName {
                    this.presetList.Choose(i)
                    break
                }
            }
        }
    }

    _currentPresetName() {
        if this.preset is Map
            return this.preset["name"]
        return ""
    }

    _selectPresetByName(name) {
        for i, n in PresetManager.List() {
            if n = name {
                this.presetList.Choose(i)
                return
            }
        }
    }

    _maybeAutoSelectFirst() {
        names := PresetManager.List()
        if names.Length = 0
            return
        this.presetList.Choose(1)
        this._loadPresetByName(names[1])
    }

    _onPresetPick() {
        name := this.presetList.Text
        if name = ""
            return
        if this.dirty && this.preset is Map && name != this.preset["name"] {
            r := MsgBox("Discard unsaved changes in '" this.preset["name"] "'?", "Unsaved changes", 0x4)
            if r = "No" {
                this._selectPresetByName(this.preset["name"])
                return
            }
        }
        this._loadPresetByName(name)
    }

    _loadPresetByName(name) {
        try {
            this.preset := PresetManager.Load(name)
        } catch as e {
            MsgBox "Failed to load: " e.Message
            return
        }
        this._populateFromPreset()
        this._applyHotkeysFromPreset()
        ro := this._isReadOnly()
        this._setEditable(!ro)
        this._setStatus("Loaded: " name (ro ? "  [built-in / read-only]" : ""))
        this.dirty := false
    }

    _populateFromPreset() {
        p := this.preset
        this.nameEdit.Value := p["name"]
        this.descEdit.Value := p["description"]
        for k, ctrl in this.settingsCtrls
            ctrl.Value := p["settings"].Has(k) ? p["settings"][k] : ""
        for k, ctrl in this.hotkeyCtrls
            ctrl.Value := p["hotkeys"].Has(k) ? p["hotkeys"][k] : ""
        this._refreshStepList()
    }

    _refreshStepList() {
        this.stepList.Delete()
        if !(this.preset is Map)
            return
        for i, s in this.preset["steps"]
            this.stepList.Add(, i, s.Has("type") ? s["type"] : "?", StepListEditor.Summary(s))
        ; Steps changed somewhere. Mark the board for reload, and if the user is
        ; CURRENTLY viewing the Board tab, push the new steps immediately so Steps
        ; and Board stay in sync live. Skip the push while importing FROM the board
        ; to avoid an echo loop that would wipe the node layout.
        this._boardNeedsReload := true
        if (!this._importingFromBoard && this.wvReady && this.tabs.Value = 2) {
            this._sendStepsToBoard()
            Logger.Info("Steps to Board live sync pushed " this.preset["steps"].Length " steps")
        }
    }

    ; ---- Read-only / built-in helpers ----

    _isReadOnly() {
        if this.preset is Map
            return PresetManager.IsBuiltin(this.preset["name"])
        return false
    }

    _setEditable(b) {
        for c in this._editableCtrls {
            try c.Enabled := b
        }
    }

    _blockIfReadOnly() {
        if this._isReadOnly() {
            MsgBox "This is a built-in (read-only) preset. Create a copy with 'New' to modify."
            return true
        }
        return false
    }

    ; ---- Preset CRUD ----

    _newPreset() {
        ib := InputBox("Preset name:", "New preset", "w300 h130", "MyPreset")
        if ib.Result != "OK" || Trim(ib.Value) = ""
            return
        nm := Trim(ib.Value)
        if PresetManager.IsBuiltin(nm) {
            MsgBox "Имя '" nm "' зарезервировано встроенным пресетом. Выберите другое."
            return
        }
        if FileExist(PresetManager.PathFor(nm)) {
            MsgBox("Пресет с именем '" nm "' уже существует. Выберите другое имя.", "Ошибка", "Icon! 0x1000")
            return
        }
        this.preset := PresetManager.NewPreset(nm)
        this._populateFromPreset()
        try PresetManager.Save(this.preset)
        catch as e {
            MsgBox "Save failed: " e.Message
            return
        }
        this.dirty := false
        this._refreshPresetList()
        this._selectPresetByName(this.preset["name"])
        this._applyHotkeysFromPreset()
        this._setEditable(true)
    }

    _deletePreset() {
        if !(this.preset is Map)
            return
        if this._blockIfReadOnly()
            return
        if MsgBox("Delete preset '" this.preset["name"] "'?", "Confirm", 0x4) != "Yes"
            return
        try PresetManager.Delete(this.preset["name"])
        catch as e {
            MsgBox "Delete failed: " e.Message
            return
        }
        this.preset := ""
        this._refreshPresetList()
        this.stepList.Delete()
        this.nameEdit.Value := ""
        this.descEdit.Value := ""
        this.hotkeys.UnbindAll()
    }

    _renamePreset() {
        if !(this.preset is Map)
            return
        if this._blockIfReadOnly()
            return
        ib := InputBox("New name:", "Rename", "w300 h130", this.preset["name"])
        if ib.Result != "OK" || Trim(ib.Value) = ""
            return
        old := this.preset["name"]
        newName := Trim(ib.Value)
        if PresetManager.IsBuiltin(newName) {
            MsgBox "Имя '" newName "' зарезервировано встроенным пресетом."
            return
        }
        if newName != old && FileExist(PresetManager.PathFor(newName)) {
            MsgBox("Пресет с именем '" newName "' уже существует. Выберите другое имя.", "Ошибка", "Icon! 0x1000")
            return
        }
        try PresetManager.Rename(old, newName)
        catch as e {
            MsgBox "Rename failed: " e.Message
            return
        }
        this._loadPresetByName(newName)
        this._refreshPresetList()
        this._selectPresetByName(newName)
    }

    _reloadPreset() {
        if !(this.preset is Map)
            return
        this._loadPresetByName(this.preset["name"])
    }

    _savePreset() {
        if !(this.preset is Map) {
            MsgBox "No preset loaded."
            return
        }
        if this._blockIfReadOnly()
            return
        this._collectFromUi()
        try PresetManager.Save(this.preset)
        catch as e {
            MsgBox "Save failed: " e.Message
            return
        }
        this.dirty := false
        this._refreshPresetList()
        this._selectPresetByName(this.preset["name"])
        this._setStatus("Saved: " this.preset["name"])
        this._applyHotkeysFromPreset()
    }

    _collectFromUi() {
        p := this.preset
        nm := Trim(this.nameEdit.Value)
        if nm != ""
            p["name"] := nm
        p["description"] := this.descEdit.Value
        for k, ctrl in this.settingsCtrls {
            v := ctrl.Value
            if k = "speedMultiplier" {
                v := IsNumber(v) ? Float(v) : 1.0
            } else if k = "repeatCount" || k = "startDelayMs" || k = "focusOnStart" || k = "stopOnError" {
                v := IsNumber(v) ? Integer(v) : 0
            }
            p["settings"][k] := v
        }
        for k, ctrl in this.hotkeyCtrls
            p["hotkeys"][k] := Trim(ctrl.Value)
    }

    _markDirty() {
        ; Disabled edit controls don't fire Change for user input, but guard
        ; here too in case something programmatic sets Value while read-only.
        if this._isReadOnly()
            return
        this.dirty := true
    }

    ; ---- Step CRUD ----

    _addStep() {
        if !this._ensurePreset()
            return
        if this._blockIfReadOnly()
            return
        ib := InputBox("Step type (one of: " StepListEditor._joinTypes() ")", "Add step", "w360 h130", "sleep")
        if ib.Result != "OK"
            return
        t := Trim(ib.Value)
        if !StepListEditor._validType(t) {
            MsgBox "Unknown step type."
            return
        }
        edited := StepEditor.Open(Map("type", t), this.gui)
        if edited is Map {
            this.preset["steps"].Push(edited)
            this._refreshStepList()
            this._markDirty()
            this.stepList.Modify(this.preset["steps"].Length, "Select Focus Vis")
        }
    }

    _editStep(row) {
        if !this._ensurePreset()
            return
        if this._blockIfReadOnly()
            return
        if row < 1 || row > this.preset["steps"].Length
            return
        edited := StepEditor.Open(this.preset["steps"][row], this.gui)
        if edited is Map {
            this.preset["steps"][row] := edited
            this._refreshStepList()
            this._markDirty()
            this.stepList.Modify(row, "Select Focus Vis")
        }
    }

    _editStepSelected() {
        r := this.stepList.GetNext(0)
        if r > 0
            this._editStep(r)
        else
            MsgBox "Сначала выделите шаг кликом в списке перед нажатием Edit!"
    }

    _removeStep() {
        if !this._ensurePreset()
            return
        if this._blockIfReadOnly()
            return
        r := this.stepList.GetNext(0)
        if r <= 0
            return
        this.preset["steps"].RemoveAt(r)
        this._refreshStepList()
        this._markDirty()
    }

    _moveStep(delta) {
        if !this._ensurePreset()
            return
        if this._blockIfReadOnly()
            return
        r := this.stepList.GetNext(0)
        nr := r + delta
        steps := this.preset["steps"]
        if r <= 0 || nr < 1 || nr > steps.Length
            return
        tmp := steps[r]
        steps[r] := steps[nr]
        steps[nr] := tmp
        this._refreshStepList()
        this._markDirty()
        this.stepList.Modify(nr, "Select Focus Vis")
    }

    _duplicateStep() {
        if !this._ensurePreset()
            return
        if this._blockIfReadOnly()
            return
        r := this.stepList.GetNext(0)
        if r <= 0
            return
        this.preset["steps"].InsertAt(r + 1, StepEditor._deepClone(this.preset["steps"][r]))
        this._refreshStepList()
        this._markDirty()
        this.stepList.Modify(r + 1, "Select Focus Vis")
    }

    _clearSteps() {
        if !this._ensurePreset()
            return
        if this._blockIfReadOnly()
            return
        if MsgBox("Remove all steps from '" this.preset["name"] "'?", "Confirm", 0x4) != "Yes"
            return
        this.preset["steps"] := []
        this._refreshStepList()
        this._markDirty()
    }

    _ensurePreset() {
        if this.preset is Map
            return true
        MsgBox "Create or load a preset first."
        return false
    }

    ; ---- Hotkeys ----

    _applyHotkeysFromPreset() {
        if !(this.preset is Map)
            return
        this.hotkeys.Rebind(this.preset["hotkeys"])
        for k, ctrl in this.hotkeyCtrls
            ctrl.Value := this.preset["hotkeys"].Has(k) ? this.preset["hotkeys"][k] : ""
    }

    _applyHotkeysFromUi() {
        if !(this.preset is Map)
            return
        if this._blockIfReadOnly()
            return
        failed := []
        for k, ctrl in this.hotkeyCtrls {
            hk := Trim(ctrl.Value)
            this.preset["hotkeys"][k] := hk
            ; Validate by trying a dry-bind
            if hk != "" && hk != "-" {
                try {
                    Hotkey hk, (*) => "", "On"
                    Hotkey hk, "Off"
                } catch {
                    failed.Push(k " ? '" hk "'")
                }
            }
        }
        this.hotkeys.Rebind(this.preset["hotkeys"])
        this._markDirty()
        if failed.Length > 0 {
            msg := "Invalid hotkey strings (skipped):`n"
            for f in failed
                msg .= "  � " f "`n"
            MsgBox msg, "Hotkey Warning", 0x30
            this._setStatus("Hotkeys applied (" failed.Length " invalid)")
        } else {
            this._setStatus("Hotkeys reapplied")
        }
    }

    ; ---- Play / record ----

    _hkStart(*) {
        if !(this.preset is Map) {
            this._setStatus("No preset")
            return
        }
        if this.player.state = "running" || this.player.state = "paused"
            return
        ; Read-only is fine for playback: we just don't write changes back.
        if !this._isReadOnly()
            this._collectFromUi()
        SetTimer(ObjBindMethod(this, "_runDeferred"), -10)
    }

    _runDeferred() {
        try this.player.Run(this.preset)
        catch as e
            Logger.Error("Run failed: " e.Message)
    }

    _hkStop(*) {
        this.player.Stop()
    }

    _hkPause(*) {
        this.player.Pause()
    }

    _hkPanic(*) {
        ; Request a normal stop first (lets the Run loop unwind cleanly).
        this.player.Stop()
        ; The Run loop may be blocked inside a long sleep / wait when Esc is
        ; pressed, so release every key the player is currently HOLDING right
        ; now instead of waiting for the loop to reach _releaseHeldKeys().
        ; This is what stops the in-game character running forever after a
        ; keyDown step (W/A/S/D) is interrupted mid-hold.
        try this.player._releaseHeldKeys()
        ; Belt-and-suspenders: force-release the common system modifiers and
        ; mouse buttons even if they were not tracked in keysHeld.
        for k in ["Shift","Ctrl","Alt","LShift","RShift","LCtrl","RCtrl"
                ,"LAlt","RAlt","LWin","RWin","LButton","RButton","MButton"]
            try Send "{" k " up}"
    }

    _onPlayerState(s) {
        this.statusBar.SetText(" Player: " s, 2)
        ; Clear the live progress readout (part 1) when playback ends.
        if s = "idle"
            try this.statusBar.SetText(" Ready", 1)
    }

    ; Live playback status, e.g. "Repeat 3/10 | Step 7/24 | 00:02:15".
    _onPlayerProgress(p) {
        try {
            rep := p["totalRepeats"] = 0
                ? "Repeat " p["repeat"] "/inf"
                : "Repeat " p["repeat"] "/" p["totalRepeats"]
            stp := "Step " p["step"] "/" p["totalSteps"]
            this.statusBar.SetText(" " rep " | " stp " | " this._fmtElapsed(p["elapsedMs"]), 1)
        }
    }

    ; Format ms as HH:MM:SS for the status bar.
    _fmtElapsed(ms) {
        total := ms // 1000
        h := total // 3600
        m := Mod(total // 60, 60)
        sec := Mod(total, 60)
        return Format("{:02}:{:02}:{:02}", h, m, sec)
    }

    _onRecorderState(s) {
        this.recBtn.Text := (s = "recording") ? "Stop Rec (F4)" : "Record (F4)"
        this.statusBar.SetText(" Rec: " s, 3)
    }

    _toggleRecord(*) {
        ; Built-in presets are read-only — recording into them is blocked.
        ; Without a preset we spin up a scratch non-builtin so TinyTask flow
        ; still works (press F4, record, press F4 again).
        if this.preset && PresetManager.IsBuiltin(this.preset["name"]) {
            MsgBox "'" this.preset["name"] "' — это встроенный пресет, поэтому в него нельзя записывать.`n`nСоздайте новый пресет через 'New' для записи."
            return
        }
        if !(this.preset is Map) {
            this.preset := PresetManager.NewPreset("Recording_" FormatTime(, "yyyyMMdd_HHmmss"))
            this._populateFromPreset()
            try PresetManager.Save(this.preset)
            this._refreshPresetList()
            this._selectPresetByName(this.preset["name"])
            this._applyHotkeysFromPreset()
            this._setEditable(true)
        }
        if this.recorder.active {
            rawTimeline := this.recorder.GetRawTimeline()
            steps := this.recorder.Stop()
            if steps.Length > 0 {
                r := MsgBox("Recorded " steps.Length " steps. Append to '" this.preset["name"] "'? (No = replace)", "Recording done", 0x3)
                if r = "Cancel"
                    return
                if r = "Yes" {
                    for s in steps
                        this.preset["steps"].Push(s)
                    ; Append raw events to existing timeline
                    if !this.preset.Has("_rawTimeline")
                        this.preset["_rawTimeline"] := []
                    ; Offset timestamps for appended events
                    offset := 0
                    if this.preset["_rawTimeline"].Length > 0
                        offset := this.preset["_rawTimeline"][this.preset["_rawTimeline"].Length]["t"] + 100
                    for ev in rawTimeline {
                        evCopy := Map()
                        for k, v in ev
                            evCopy[k] := v
                        evCopy["t"] := ev["t"] + offset
                        this.preset["_rawTimeline"].Push(evCopy)
                    }
                } else {
                    this.preset["steps"] := steps
                    this.preset["_rawTimeline"] := rawTimeline
                }
                this._refreshStepList()
                this._markDirty()
                ; Autosave after recording so steps aren't lost
                try {
                    this._collectFromUi()
                    PresetManager.Save(this.preset)
                    this.dirty := false
                    this._setStatus("Recorded & saved: " this.preset["name"])
                } catch as e {
                    Logger.Warn("Autosave after recording failed: " e.Message)
                }
            }
        } else {
            this.recorder.Start()
        }
    }

    _appendLog(line) {
        this.logBox.Value .= line "`r`n"
        ; Truncate UI log box if it exceeds ~64KB to prevent slowdown
        if StrLen(this.logBox.Value) > 65000 {
            text := this.logBox.Value
            ; Keep last ~48KB
            this.logBox.Value := SubStr(text, StrLen(text) - 48000)
        }
        try {
            len := StrLen(this.logBox.Value)
            SendMessage(0xB1, len, len, , this.logBox.Hwnd)  ; EM_SETSEL
            SendMessage(0xB7, 0, 0, , this.logBox.Hwnd)      ; EM_SCROLLCARET
        }
    }

    _importPreset() {
        path := FileSelect(1, Cfg.PRESETS_DIR, "Import a preset .json file", "JSON (*.json)")
        if path = ""
            return
        try {
            name := PresetManager.Import(path)
            this._refreshPresetList()
            this._selectPresetByName(name)
            this._loadPresetByName(name)
            this._setStatus("Imported: " name)
        } catch as e {
            MsgBox "Import failed: " e.Message
        }
    }

    _setStatus(msg) {
        this.statusBar.SetText(" " msg, 1)
    }

    _onClose() {
        if this.dirty {
            r := MsgBox("Unsaved changes. Save before exit?", "Quit", 0x3)
            if r = "Cancel"
                return
            if r = "Yes"
                this._savePreset()
        }
        if this.player.state != "idle"
            this.player.Stop()
        if this.recorder.active
            this.recorder.Stop()
        ; Explicitly tear down the WebView2 controller before exiting. Without
        ; this, the background msedgewebview2.exe host processes can linger for
        ; a moment after ExitApp; closing the controller first guarantees the
        ; WebView is disposed immediately.
        try {
            if this.wvController {
                this.wvController.Close()
                this.wvController := ""
                this.wvCore := ""
                this.wvReady := false
            }
        } catch as e {
            Logger.Warn("WebView2 controller close failed: " e.Message)
        }
        ExitApp
    }
}
