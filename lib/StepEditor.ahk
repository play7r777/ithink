#Requires AutoHotkey v2.0

; Dependencies (guarded by AHK against double-inclusion when run via MacroForge.ahk)
#Include Constants.ahk
#Include PresetManager.ahk

; StepEditor       - modal form to edit ONE step.
;                    Uses a layout engine that dynamically repositions only
;                    the visible fields to the top of the window, so every
;                    step type looks compact and all fields are reachable.
;
; StepListEditor   - modal window to edit an Array of steps.
;
; "" = pending; "cancel" = dismissed; Map/Array = OK.

class StepEditor {
    static Open(step, parentGui := "", isCondition := false, forceType := "") {
        return StepEditor(step, parentGui, isCondition, forceType)._run()
    }

    __New(step, parentGui, isCondition := false, forceType := "") {
        this.original := step is Map ? step : Map("type", forceType ? forceType : "sleep", "ms", 500)
        this.parent := parentGui
        this.isCondition := isCondition
        this.forceType := forceType
        this.result := ""
        this._guiShown := false
        this.nestedSteps := step is Map && step.Has("steps")     ? StepEditor._deepClone(step["steps"])     : []
        this.thenSteps   := step is Map && step.Has("thenSteps") ? StepEditor._deepClone(step["thenSteps"]) : []
        this.elseSteps   := step is Map && step.Has("elseSteps") ? StepEditor._deepClone(step["elseSteps"]) : []
        this.conditions  := step is Map && step.Has("conditions") ? StepEditor._deepClone(step["conditions"]) : []
        this.fields := Map()
        this._layout := []
        this._contentH := 200
        this._buildGui()
        this._populate()
        this._applyType(this._currentType())
    }

    _run() {
        this._guiShown := true
        this.gui.Show("w470 h" this._contentH)
        while this.result == ""
            Sleep 30
        try this.gui.Destroy()
        return this.result == "cancel" ? "" : this.result
    }

    _buildGui() {
        ownerOpt := (this.parent != "" && this.parent.HasProp("Hwnd")) ? " +Owner" this.parent.Hwnd : ""
        g := Gui("+ToolWindow" ownerOpt, "Edit Step")
        g.SetFont("s9", "Segoe UI")
        g.MarginX := 10, g.MarginY := 10
        g.OnEvent("Close",  (*) => this.result := "cancel")
        g.OnEvent("Escape", (*) => this.result := "cancel")

        this.typeLbl := g.AddText("xm w120 Section", "Type:")
        types := []
        for t in Cfg.STEP_TYPES
            types.Push(t)
        this.typeCombo := g.AddDropDownList("ys-3 w160", types)
        this.typeCombo.OnEvent("Change", (*) => this._applyType(this._currentType()))
        if this.isCondition {
            this.typeLbl.Visible := false
            this.typeCombo.Visible := false
        }

        ; ======= Fields (order matters for layout) =======
        ; _row() pushes {kind:"field"} into _layout
        ; _pickRow() pushes {kind:"pick"} (same row as prev field)

        this._row(g, "key",        "Key:",            "Edit",      "w160", ["key","keyDown","keyUp"])
        this._pickRow(g, "🎯 Pick Key",       "w100", ["key","keyDown","keyUp"], (*) => this._pickKey())

        this._row(g, "button",     "Button:",         "Combo",     "w120", ["click","drag"], ["left","right","middle"])
        this._row(g, "count",      "Count:",          "Edit",      "w80",  ["click"])

        this._row(g, "x",          "X:",              "Edit",      "w80",  ["click","move","ifPixel","waitForPixel","loopUntilPixel"])
        this._row(g, "y",          "Y:",              "Edit",      "w80",  ["click","move","ifPixel","waitForPixel","loopUntilPixel"])
        this._pickRow(g, "🎯 Pick XY",        "w110", ["click","move","ifPixel","waitForPixel","loopUntilPixel"], (*) => this._pickXY())

        this._row(g, "speed",      "Speed:",          "Edit",      "w80",  ["move","drag"])

        this._row(g, "fromX",      "From X:",         "Edit",      "w80",  ["drag"])
        this._row(g, "fromY",      "From Y:",         "Edit",      "w80",  ["drag"])
        this._pickRow(g, "🎯 Pick Start",     "w110", ["drag"], (*) => this._pickDragPoint("fromX", "fromY"))

        this._row(g, "toX",        "To X:",           "Edit",      "w80",  ["drag"])
        this._row(g, "toY",        "To Y:",           "Edit",      "w80",  ["drag"])
        this._pickRow(g, "🎯 Pick End",        "w110", ["drag"], (*) => this._pickDragPoint("toX", "toY"))

        this._row(g, "direction",  "Direction:",      "Combo",     "w100", ["scroll"], ["up","down"])
        this._row(g, "amount",     "Amount:",         "Edit",      "w80",  ["scroll"])

        this._row(g, "duration",   "Hold (ms):",      "Edit",      "w100", ["key"])

        this._row(g, "ms",         "Sleep (ms):",     "Edit",      "w120", ["sleep"])
        this._row(g, "jitter",     "Jitter ±%:",      "Edit",      "w80",  ["sleep"])

        this._row(g, "text",       "Text:",           "EditMulti", "w260 h60", ["send"])
        this._row(g, "mode",       "Mode:",           "Combo",     "w140", ["send"], ["send","sendText","sendInput"])

        this._row(g, "image",      "Image:",          "Edit",      "w200", ["ifImage","waitForImage","loopWhileImage"])
        this._pickRow(g, "Browse...",          "w70",  ["ifImage","waitForImage","loopWhileImage"], (*) => this._browseImage())
        this._row(g, "variation",  "Variation:",      "Edit",      "w80",  ["ifImage","waitForImage","loopWhileImage"])
        this._row(g, "x1",         "Search x1:",      "Edit",      "w80",  ["ifImage","waitForImage","loopWhileImage"])
        this._row(g, "y1",         "Search y1:",      "Edit",      "w80",  ["ifImage","waitForImage","loopWhileImage"])
        this._row(g, "x2",         "Search x2:",      "Edit",      "w80",  ["ifImage","waitForImage","loopWhileImage"])
        this._row(g, "y2",         "Search y2:",      "Edit",      "w80",  ["ifImage","waitForImage","loopWhileImage"])
        this._pickRow(g, "🎯 Pick Region",     "w130", ["ifImage","waitForImage","loopWhileImage"], (*) => this._pickRegion())

        this._row(g, "color",      "Color (0xRRGGBB):","Edit",     "w120", ["ifPixel","waitForPixel","loopUntilPixel"])
        this._row(g, "tolerance",  "Tolerance:",      "Edit",      "w80",  ["ifPixel","waitForPixel","loopUntilPixel"])
        this._pickRow(g, "🎯 Pick Pixel+XY",  "w150", ["ifPixel","waitForPixel","loopUntilPixel"], (*) => this._pickPixel())

        this._row(g, "searchText",  "Search Text:",    "Edit",      "w260", ["ifText"])
        this._row(g, "language",    "Language:",       "Combo",     "w100", ["ifText"], ["Auto", "eng", "ru", "ua"])
        this._row(g, "captureMode", "Capture Mode:",   "Combo",     "w140", ["ifText"], ["auto","desktop","dx","window"])
        this._row(g, "windowTitle", "Window Title:",   "Edit",      "w200", ["ifText"])
        this._pickRow(g, "🎯 Pick Window",    "w120", ["ifText"], (*) => this._pickWindowOcr())
        this._row(g, "ocrScale",    "OCR Scale (1-3):","Edit",      "w80",  ["ifText"])
        this._row(g, "ocrX1",       "Region X1:",      "Edit",      "w80",  ["ifText"])
        this._row(g, "ocrY1",       "Region Y1:",      "Edit",      "w80",  ["ifText"])
        this._row(g, "ocrX2",       "Region X2:",      "Edit",      "w80",  ["ifText"])
        this._row(g, "ocrY2",       "Region Y2:",      "Edit",      "w80",  ["ifText"])

        this._row(g, "title",      "Window title:",   "Edit",      "w200", ["focusWindow","ifWindow"])
        this._pickRow(g, "🎯 Pick Window",    "w120", ["focusWindow","ifWindow"], (*) => this._pickWindow())

        this._row(g, "timeout",    "Timeout (ms):",   "Edit",      "w100", ["waitForImage","waitForPixel"])
        this._row(g, "poll",       "Poll interval (ms):","Edit",   "w100", ["waitForImage","waitForPixel"])

        this._row(g, "name",       "Label name:",     "Edit",      "w260", ["label"])
        this._row(g, "message",    "Message:",        "Edit",      "w260", ["log"])
        this._row(g, "loopCount",  "Count (0=inf):",  "Edit",      "w100", ["loop"])

        this._row(g, "varName",    "Variable Name:",  "Edit",      "w160", ["setVar","ifVar","loopWhileVar"])
        this._row(g, "operator",   "Operator:",       "Combo",     "w100", ["setVar","ifVar","loopWhileVar"], ["=","+=","-=","!=","<",">","<=",">="])
        this._row(g, "varValue",   "Value:",          "Edit",      "w160", ["setVar","ifVar","loopWhileVar"])
        this._row(g, "scope",      "Scope:",          "Combo",     "w120", ["setVar","ifVar"], ["local","global"])

        this._row(g, "presetName", "Preset Name:",    "Edit",      "w200", ["call"])

        this._row(g, "webhookUrl",     "Webhook URL:", "Edit",      "w260", ["webhook"])
        this._row(g, "webhookPayload", "Content:",     "Edit",      "w260", ["webhook"])

        ; ======= Conditions (multi-condition ifText) =======
        this.addCondBtn := g.AddButton("xm w220", "Add Condition (if-elseif)")
        this.addCondBtn.OnEvent("Click", (*) => this._addCondition())
        this._layout.Push({kind: "btn", btn: this.addCondBtn, forTypes: ["ifImage","ifPixel","ifText","ifVar","ifWindow","waitForImage","waitForPixel"]})

        this.editCondBtn := g.AddButton("xm w220", "Edit Conditions...")
        this.editCondBtn.OnEvent("Click", (*) => this._editConditions())
        this._layout.Push({kind: "btn", btn: this.editCondBtn, forTypes: ["ifImage","ifPixel","ifText","ifVar","ifWindow","waitForImage","waitForPixel"]})

        this.condCountLbl := g.AddText("xm w220 cGray", "Conditions: 0 (single branch mode)")
        this._layout.Push({kind: "lbl", lbl: this.condCountLbl, forTypes: ["ifImage","ifPixel","ifText","ifVar","ifWindow","waitForImage","waitForPixel"]})

        ; ======= Special buttons (own rows) =======
        this.editNestedBtn := g.AddButton("xm w220", "Edit nested steps...")
        this.editNestedBtn.OnEvent("Click", (*) => this._editChildren("nestedSteps", "Loop steps"))
        this._layout.Push({kind: "btn", btn: this.editNestedBtn, forTypes: ["loop","loopWhileImage","loopUntilPixel","loopWhileVar"]})

        this.editThenBtn := g.AddButton("xm w220", "Edit then-steps...")
        this.editThenBtn.OnEvent("Click", (*) => this._editChildren("thenSteps", "Then-steps"))
        this._layout.Push({kind: "btn", btn: this.editThenBtn, forTypes: ["ifImage","ifPixel","ifText","ifVar","ifWindow","waitForImage","waitForPixel"]})

        this.editElseBtn := g.AddButton("xm w220", "Edit else-steps...")
        this.editElseBtn.OnEvent("Click", (*) => this._editChildren("elseSteps", "Else-steps"))
        this._layout.Push({kind: "btn", btn: this.editElseBtn, forTypes: ["ifImage","ifPixel","ifText","ifVar","ifWindow","waitForImage","waitForPixel"]})

        ; ======= OK / Cancel =======
        this.okBtn := g.AddButton("xm w80 Default", "OK")
        this.okBtn.OnEvent("Click", (*) => this._onOk())
        this.cancelBtn := g.AddButton("x+5 yp w80", "Cancel")
        this.cancelBtn.OnEvent("Click", (*) => this.result := "cancel")

        this.gui := g
    }

    ; Create a field row and register it in the layout
    _row(g, name, label, kind, opts, types, items := "") {
        lbl := g.AddText("xm w130", label)
        ctrl := ""
        switch kind {
            case "Edit":      ctrl := g.AddEdit("x+5 yp-3 " opts)
            case "EditMulti": ctrl := g.AddEdit("x+5 yp-3 +Multi " opts)
            case "Combo":     ctrl := g.AddDropDownList("x+5 yp-3 " opts, items is Array ? items : [])
            default:          ctrl := g.AddEdit("x+5 yp-3 " opts)
        }
        ; Parse width and height from options string
        w := 80
        if RegExMatch(opts, "(?:^|\s)w(\d+)", &mw)
            w := Integer(mw[1])
        h := 22
        if RegExMatch(opts, "(?:^|\s)h(\d+)", &mh)
            h := Integer(mh[1])
        this.fields[name] := { ctrl: ctrl, lbl: lbl, types: types, width: w, height: h }
        this._layout.Push({kind: "field", name: name})
    }

    ; Create a pick button and register it in the layout (same row as previous field)
    _pickRow(g, text, opts, forTypes, callback) {
        btn := g.AddButton("x+5 yp " opts, text)
        btn.OnEvent("Click", callback)
        this._layout.Push({kind: "pick", btn: btn, forTypes: forTypes})
    }

    _currentType() {
        return this.isCondition ? this.forceType : this.typeCombo.Text
    }

    _applyType(t) {
        this._relayout(t)
        if this._guiShown {
            try {
                this.gui.GetPos(&gx, &gy)
                this.gui.Show("x" gx " y" gy " w470 h" this._contentH)
            }
        }
    }

    ; ==================== LAYOUT ENGINE ====================
    ; Iterates through _layout in order, shows only controls matching the
    ; current type, and stacks them from the top of the window with no gaps.
    _relayout(t) {
        yPos := this.isCondition ? 10 : 38          ; Below the Type combo
        xLbl := 10          ; Label x
        xCtrl := 145        ; Control x (to the right of 130px label + gap)
        prevRowY := yPos
        prevFieldW := 80

        for item in this._layout {
            switch item.kind {
                case "field":
                    f := this.fields[item.name]
                    vis := false
                    for nt in f.types {
                        if nt = t {
                            vis := true
                            break
                        }
                    }
                    f.ctrl.Visible := vis
                    f.lbl.Visible := vis
                    if vis {
                        f.lbl.Move(xLbl, yPos + 3)
                        f.ctrl.Move(xCtrl, yPos)
                        prevRowY := yPos
                        prevFieldW := f.width
                        yPos += Max(f.height, 22) + 6
                    }

                case "pick":
                    vis := false
                    for ft in item.forTypes {
                        if ft = t {
                            vis := true
                            break
                        }
                    }
                    item.btn.Visible := vis
                    if vis
                        item.btn.Move(xCtrl + prevFieldW + 10, prevRowY)

                case "btn":
                    if this.isCondition && (item.btn = this.addCondBtn || item.btn = this.editCondBtn || item.btn = this.editElseBtn)
                        continue
                    vis := false
                    for ft in item.forTypes {
                        if ft = t {
                            vis := true
                            break
                        }
                    }
                    item.btn.Visible := vis
                    if vis {
                        item.btn.Move(xLbl, yPos)
                        yPos += 30
                    }

                case "lbl":
                    if this.isCondition && item.lbl = this.condCountLbl
                        continue
                    vis := false
                    for ft in item.forTypes {
                        if ft = t {
                            vis := true
                            break
                        }
                    }
                    item.lbl.Visible := vis
                    if vis {
                        item.lbl.Move(xLbl, yPos + 3)
                        yPos += 22
                    }
            }
        }

        ; OK / Cancel at bottom
        this.okBtn.Move(xLbl, yPos + 8)
        this.cancelBtn.Move(xLbl + 85, yPos + 8)
        yPos += 45

        this._contentH := Max(yPos, 100)
    }

    _populate() {
        s := this.original
        this.typeCombo.Choose(s.Has("type") ? s["type"] : "sleep")
        for name, f in this.fields {
            key := (name = "loopCount") ? "count" : name
            if s.Has(key) {
                v := s[key]
                if f.ctrl.Type = "Edit"
                    f.ctrl.Value := v
                else
                    try f.ctrl.Choose(String(v))
            }
        }
        if !s.Has("button") && this.fields.Has("button")
            try this.fields["button"].ctrl.Choose("left")
        if !s.Has("mode") && this.fields.Has("mode")
            try this.fields["mode"].ctrl.Choose("send")
        if !s.Has("direction") && this.fields.Has("direction")
            try this.fields["direction"].ctrl.Choose("down")
        if !s.Has("operator") && this.fields.Has("operator")
            try this.fields["operator"].ctrl.Choose("=")
        if !s.Has("scope") && this.fields.Has("scope")
            try this.fields["scope"].ctrl.Choose("local")
        if !s.Has("language") && this.fields.Has("language")
            try this.fields["language"].ctrl.Choose("Auto")
        if !s.Has("captureMode") && this.fields.Has("captureMode")
            try this.fields["captureMode"].ctrl.Choose("auto")
        this._updateCondLabel()
    }

    _browseImage() {
        path := FileSelect(1, Cfg.IMAGES_DIR, "Choose an image", "Images (*.png; *.bmp; *.jpg)")
        if path != ""
            this.fields["image"].ctrl.Value := path
    }

    _editChildren(slotName, title) {
        edited := StepListEditor.Open(this.%slotName%, title, this.gui)
        if edited is Array
            this.%slotName% := edited
    }

    ; ==================== PICKER TOOLS ====================

    _pickXY() {
        this.gui.Hide()
        Sleep 200
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                break
            }
            MouseGetPos(&mx, &my)
            ToolTip "🎯  X: " mx "   Y: " my "`nКликните ЛКМ для выбора  |  Esc — отмена"
            if GetKeyState("LButton", "P") {
                this.fields["x"].ctrl.Value := mx
                this.fields["y"].ctrl.Value := my
                KeyWait "LButton"
                break
            }
            Sleep 30
        }
        ToolTip
        this.gui.Show()
    }

    _pickDragPoint(xField, yField) {
        this.gui.Hide()
        Sleep 200
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                break
            }
            MouseGetPos(&mx, &my)
            ToolTip "🎯  X: " mx "   Y: " my "`nКликните ЛКМ для выбора  |  Esc — отмена"
            if GetKeyState("LButton", "P") {
                this.fields[xField].ctrl.Value := mx
                this.fields[yField].ctrl.Value := my
                KeyWait "LButton"
                break
            }
            Sleep 30
        }
        ToolTip
        this.gui.Show()
    }

    _pickPixel() {
        this.gui.Hide()
        Sleep 200
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                break
            }
            MouseGetPos(&mx, &my)
            clr := ""
            try clr := PixelGetColor(mx, my, "RGB")
            ToolTip "🎯  X: " mx "   Y: " my "   Color: " clr "`nКликните ЛКМ для захвата  |  Esc — отмена"
            if GetKeyState("LButton", "P") {
                this.fields["x"].ctrl.Value := mx
                this.fields["y"].ctrl.Value := my
                this.fields["color"].ctrl.Value := clr
                KeyWait "LButton"
                break
            }
            Sleep 30
        }
        ToolTip
        this.gui.Show()
    }

    _pickRegion() {
        this.gui.Hide()
        Sleep 200
        sx := 0, sy := 0, ex := 0, ey := 0
        ; Phase 1: wait for mouse-down (first corner)
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                ToolTip
                this.gui.Show()
                return
            }
            MouseGetPos(&mx, &my)
            ToolTip "🎯  X: " mx "   Y: " my "`nЗажмите ЛКМ в углу области  |  Esc — отмена"
            if GetKeyState("LButton", "P") {
                sx := mx, sy := my
                break
            }
            Sleep 30
        }
        ; Phase 2: dragging — show live rectangle size
        loop {
            if !GetKeyState("LButton", "P") {
                MouseGetPos(&ex, &ey)
                break
            }
            MouseGetPos(&cx, &cy)
            w := Abs(cx - sx), h := Abs(cy - sy)
            ToolTip "🎯  Start: (" sx ", " sy ")  →  (" cx ", " cy ")`nОбласть: " w " x " h "`nОтпустите ЛКМ для завершения"
            Sleep 30
        }
        this.fields["x1"].ctrl.Value := Min(sx, ex)
        this.fields["y1"].ctrl.Value := Min(sy, ey)
        this.fields["x2"].ctrl.Value := Max(sx, ex)
        this.fields["y2"].ctrl.Value := Max(sy, ey)
        ToolTip
        this.gui.Show()
    }

    _pickWindow() {
        this.gui.Hide()
        Sleep 200
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                break
            }
            MouseGetPos(, , &hwnd)
            procName := ""
            try procName := WinGetProcessName("ahk_id " hwnd)
            ToolTip "🎯  Window: " procName "`nКликните ЛКМ для выбора  |  Esc — отмена"
            if GetKeyState("LButton", "P") {
                if procName != ""
                    this.fields["title"].ctrl.Value := "ahk_exe " procName
                KeyWait "LButton"
                break
            }
            Sleep 30
        }
        ToolTip
        this.gui.Show()
    }

    _pickWindowOcr() {
        this.gui.Hide()
        Sleep 200
        loop {
            if GetKeyState("Escape", "P") {
                KeyWait "Escape"
                break
            }
            MouseGetPos(, , &hwnd)
            procName := ""
            try procName := WinGetProcessName("ahk_id " hwnd)
            ToolTip "🎯  Window: " procName "`nКликните ЛКМ для выбора  |  Esc — отмена"
            if GetKeyState("LButton", "P") {
                if procName != ""
                    this.fields["windowTitle"].ctrl.Value := "ahk_exe " procName
                KeyWait "LButton"
                break
            }
            Sleep 30
        }
        ToolTip
        this.gui.Show()
    }

    _pickKey() {
        this.gui.Hide()
        Sleep 200
        ToolTip "🎯  Нажмите любую клавишу для захвата`n(Esc — отмена, таймаут 15 сек)"
        ih := InputHook("L0 T15")
        ih.KeyOpt("{All}", "E")
        ih.Start()
        ih.Wait()
        if ih.EndReason = "EndKey" && ih.EndKey != "Escape"
            this.fields["key"].ctrl.Value := ih.EndKey
        ToolTip
        this.gui.Show()
    }

    ; ==================== CONDITIONS (multi-condition ifText) ====================

    _getConditionCount() {
        return this.conditions.Length
    }

    _updateCondLabel() {
        cnt := this.conditions.Length
        if cnt = 0
            this.condCountLbl.Value := "Conditions: 0 (single branch mode)"
        else
            this.condCountLbl.Value := "Conditions: " cnt " (multi-branch mode)"
    }

    _addCondition() {
        this.conditions.Push(Map("thenSteps", []))
        this._updateCondLabel()
        this._editConditions()
    }

    _editConditions() {
        edited := ConditionListEditor.Open(this.conditions, this._currentType(), "Edit Conditions", this.gui)
        if edited is Array
            this.conditions := edited
        this._updateCondLabel()
    }

    ; ==================== OK / CLONE ====================

    _onOk() {
        out := Map("type", this._currentType())
        numericKeys := Map(
            "count",1, "x",1, "y",1, "speed",1, "amount",1, "duration",1, "ms",1,
            "variation",1, "x1",1, "y1",1, "x2",1, "y2",1, "tolerance",1,
            "fromX",1, "fromY",1, "toX",1, "toY",1, "loopCount",1,
            "jitter",1, "timeout",1, "poll",1,
            "ocrX1",1, "ocrY1",1, "ocrX2",1, "ocrY2",1, "ocrScale",1
        )
        ; Coordinates can be negative on multi-monitor setups.
        nonNegativeKeys := Map(
            "count",1, "speed",1, "amount",1, "duration",1, "ms",1,
            "variation",1, "tolerance",1, "loopCount",1,
            "jitter",1, "timeout",1, "poll",1, "ocrScale",1
        )
        ; Validate numeric fields up front so bad input (e.g. a letter in x/y/ms)
        ; is rejected with a clear message instead of being silently stored as a
        ; string that later breaks playback.
        errors := []
        for name, f in this.fields {
            if !f.ctrl.Visible
                continue
            key := (name = "loopCount") ? "count" : name
            v := f.ctrl.Type = "DDL" ? f.ctrl.Text : f.ctrl.Value
            if v = ""
                continue
            if numericKeys.Has(name) {
                if !IsNumber(v) {
                    errors.Push(name ": '" v "' is not a number")
                    continue
                }
                v := InStr(v, ".") ? Float(v) : Integer(v)
                ; Only restrict non-coordinate fields from being negative
                if nonNegativeKeys.Has(name) && v < 0 {
                    errors.Push(name ": must be >= 0 (got " v ")")
                    continue
                }
            }
            out[key] := v
        }
        if errors.Length > 0 {
            msg := "Please fix the following field(s):`n`n"
            for e in errors
                msg .= "  - " e "`n"
            MsgBox(msg, "Invalid input", "Icon! 0x1000")
            return   ; keep the editor open; result stays ""
        }
        t := out["type"]
        if t = "loop" || t = "loopWhileImage" || t = "loopUntilPixel" || t = "loopWhileVar"
            out["steps"] := this.nestedSteps
        if t = "ifImage" || t = "ifPixel" || t = "ifText" || t = "ifVar" || t = "ifWindow" || t = "waitForImage" || t = "waitForPixel" {
            out["thenSteps"] := this.thenSteps
            if !this.isCondition
                out["elseSteps"] := this.elseSteps
        }
        if !this.isCondition && (t = "ifImage" || t = "ifPixel" || t = "ifText" || t = "ifVar" || t = "ifWindow" || t = "waitForImage" || t = "waitForPixel") && this.conditions.Length > 0
            out["conditions"] := this.conditions
        if this.isCondition
            out.Delete("type")
        this.result := out
    }

    static _deepClone(v) {
        if v is Map {
            m := Map()
            for k, vv in v
                m[k] := StepEditor._deepClone(vv)
            return m
        }
        if v is Array {
            a := []
            for vv in v
                a.Push(StepEditor._deepClone(vv))
            return a
        }
        return v
    }
}


class StepListEditor {
    static Open(steps, title := "Edit Steps", parentGui := "") {
        return StepListEditor(steps, title, parentGui)._run()
    }

    __New(steps, title, parentGui) {
        this.steps := StepEditor._deepClone(steps)
        this.title := title
        this.parent := parentGui
        this.result := ""
        ; Undo/redo: snapshots of the full step list. _histIdx points at the
        ; snapshot currently on screen. Branching after an undo truncates redo.
        this._history := [StepEditor._deepClone(this.steps)]
        this._histIdx := 1
        ; Search filter. _rowMap maps a visible ListView row -> real step index
        ; so edit/remove/move operate on the correct underlying step.
        this._filter := ""
        this._rowMap := []
        this._build()
        this._refresh()
    }

    ; Snapshot the current steps onto the undo stack (call AFTER a mutation).
    _pushHistory() {
        ; Drop any redo branch beyond the current position.
        while this._history.Length > this._histIdx
            this._history.Pop()
        this._history.Push(StepEditor._deepClone(this.steps))
        this._histIdx := this._history.Length
        ; Cap history depth so long sessions don't grow unbounded.
        if this._history.Length > 100 {
            this._history.RemoveAt(1)
            this._histIdx -= 1
        }
    }

    _undo() {
        if this._histIdx <= 1 {
            this._setStatus("Nothing to undo")
            return
        }
        this._histIdx -= 1
        this.steps := StepEditor._deepClone(this._history[this._histIdx])
        this._refresh()
        this._setStatus("Undo")
    }

    _redo() {
        if this._histIdx >= this._history.Length {
            this._setStatus("Nothing to redo")
            return
        }
        this._histIdx += 1
        this.steps := StepEditor._deepClone(this._history[this._histIdx])
        this._refresh()
        this._setStatus("Redo")
    }

    _setStatus(txt) {
        if this.HasProp("statusBar") && this.statusBar
            try this.statusBar.Text := txt
    }

    _run() {
        this.gui.Show()
        while this.result == ""
            Sleep 30
        this._removeHotkeys()
        try this.gui.Destroy()
        return this.result == "cancel" ? "" : this.result
    }

    _build() {
        ownerOpt := (this.parent != "" && this.parent.HasProp("Hwnd")) ? " +Owner" this.parent.Hwnd : ""
        g := Gui("+Resize +ToolWindow" ownerOpt, this.title)
        g.SetFont("s9", "Segoe UI")
        g.MarginX := 10, g.MarginY := 10
        g.OnEvent("Close",  (*) => this.result := "cancel")
        g.OnEvent("Escape", (*) => this.result := "cancel")

        ; --- Search bar: live-filters the list by type or summary text. ---
        g.AddText("xm ym", "Search:")
        this.searchEdit := g.AddEdit("x+5 yp-3 w300")
        this.searchEdit.OnEvent("Change", (*) => this._onSearch())
        g.AddButton("x+5 yp w70", "Clear").OnEvent("Click", (*) => (this.searchEdit.Value := "", this._onSearch()))

        this.lv := g.AddListView("xm y+8 w520 h300 Grid Section", ["#","Type","Summary"])
        this.lv.ModifyCol(1, 40)
        this.lv.ModifyCol(2, 90)
        this.lv.ModifyCol(3, 380)
        this.lv.OnEvent("DoubleClick", (ctrl, row) => row > 0 ? this._edit(this._realIdx(row)) : "")

        g.AddButton("ys w90", "Add").OnEvent("Click", (*) => this._add())
        g.AddButton("xp y+5  w90", "Edit").OnEvent("Click", (*) => this._editSelected())
        g.AddButton("xp y+5  w90", "Remove").OnEvent("Click", (*) => this._removeSelected())
        g.AddButton("xp y+15 w90", "Move Up").OnEvent("Click", (*) => this._move(-1))
        g.AddButton("xp y+5  w90", "Move Down").OnEvent("Click", (*) => this._move(1))
        g.AddButton("xp y+15 w90", "Duplicate").OnEvent("Click", (*) => this._duplicate())
        g.AddButton("xp y+5  w90", "Undo").OnEvent("Click", (*) => this._undo())
        g.AddButton("xp y+5  w90", "Redo").OnEvent("Click", (*) => this._redo())
        g.AddButton("xp y+15 w90", "Import Preset").OnEvent("Click", (*) => this._importPreset())

        okBtn := g.AddButton("xm w80 Default", "OK")
        okBtn.OnEvent("Click", (*) => this.result := this.steps)
        cancelBtn := g.AddButton("x+5 yp w80", "Cancel")
        cancelBtn.OnEvent("Click", (*) => this.result := "cancel")

        ; Status line: shows count, undo/redo feedback and shortcut hints.
        this.statusBar := g.AddText("xm y+8 w520", "")
        g.AddText("xm y+2 w520 cGray", "Shortcuts: Enter=Edit  Delete=Remove  Ctrl+Z/Y=Undo/Redo  Ctrl+S=OK  Ctrl+F=Search")

        this.gui := g
        this._installHotkeys()
    }

    ; GUI-scoped accelerators. We bind on the ListView via a context that only
    ; fires while this window is active, using HotIfWinActive on its title.
    _installHotkeys() {
        this._hkCtx := "ahk_id " this.gui.Hwnd
        HotIfWinActive(this._hkCtx)
        ; Enter/Delete only act when the step list (not the search box) has
        ; focus, so they don't interfere with typing a search query. The `~`
        ; prefix lets the native keystroke through, so other controls keep
        ; their default behaviour and we never need to re-send the key.
        Hotkey("~Enter",  (*) => this._onListKey("edit"),   "On")
        Hotkey("~Delete", (*) => this._onListKey("remove"), "On")
        Hotkey("^z",     (*) => this._undo(), "On")
        Hotkey("^y",     (*) => this._redo(), "On")
        Hotkey("^s",     (*) => this.result := this.steps, "On")
        Hotkey("^f",     (*) => this.searchEdit.Focus(), "On")
        HotIfWinActive()
    }

    ; Route Enter/Delete to list actions only when the ListView is focused;
    ; otherwise pass the key through (e.g. Enter/Delete while in the search box).
    _onListKey(action) {
        focused := ""
        try focused := this.gui.FocusedCtrl
        ; Only act on the list; the native key already passed through (~ prefix).
        if !(focused is Gui.ListView)
            return
        if action = "edit"
            this._editSelected()
        else
            this._removeSelected()
    }

    _removeHotkeys() {
        if !this.HasProp("_hkCtx")
            return
        HotIfWinActive(this._hkCtx)
        for k in ["~Enter","~Delete","^z","^y","^s","^f"]
            try Hotkey(k, "Off")
        HotIfWinActive()
    }

    _refresh() {
        this.lv.Delete()
        this._rowMap := []
        flt := this._filter
        shown := 0
        for i, st in this.steps {
            type := st.Has("type") ? st["type"] : "?"
            summary := StepListEditor.Summary(st)
            if flt != "" && !InStr(type, flt) && !InStr(summary, flt)
                continue
            this.lv.Add(, i, type, summary)
            this._rowMap.Push(i)
            shown++
        }
        if flt != ""
            this._setStatus(shown " of " this.steps.Length " step(s) match '" flt "'")
        else
            this._setStatus(this.steps.Length " step(s)")
    }

    ; Translate a visible ListView row to the underlying steps[] index.
    _realIdx(row) {
        if row < 1 || row > this._rowMap.Length
            return 0
        return this._rowMap[row]
    }

    _onSearch() {
        this._filter := Trim(this.searchEdit.Value)
        this._refresh()
    }

    ; Select the visible row that maps to real step index `idx` (if visible).
    _selectReal(idx) {
        for row, real in this._rowMap {
            if real = idx {
                this.lv.Modify(row, "Select Focus Vis")
                return
            }
        }
    }

    _selectedRow() {
        return this._realIdx(this.lv.GetNext(0))
    }

    _add() {
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
            this.steps.Push(edited)
            this._pushHistory()
            this._refresh()
            this._selectReal(this.steps.Length)
        }
    }

    _edit(row) {
        if row < 1 || row > this.steps.Length
            return
        edited := StepEditor.Open(this.steps[row], this.gui)
        if edited is Map {
            this.steps[row] := edited
            this._pushHistory()
            this._refresh()
            this._selectReal(row)
        }
    }

    _editSelected() {
        r := this._selectedRow()
        if r > 0
            this._edit(r)
        else
            MsgBox "Сначала выделите шаг кликом в списке перед нажатием Edit!"
    }

    _removeSelected() {
        r := this._selectedRow()
        if r <= 0
            return
        this.steps.RemoveAt(r)
        this._pushHistory()
        this._refresh()
        this._selectReal(Min(r, this.steps.Length))
    }

    _move(delta) {
        r := this._selectedRow()
        nr := r + delta
        if r <= 0 || nr < 1 || nr > this.steps.Length
            return
        ; Reordering is disabled while a search filter hides rows, otherwise
        ; an adjacent swap could jump across hidden steps unexpectedly.
        if this._filter != "" {
            this._setStatus("Clear the search filter to reorder steps")
            return
        }
        tmp := this.steps[r]
        this.steps[r] := this.steps[nr]
        this.steps[nr] := tmp
        this._pushHistory()
        this._refresh()
        this._selectReal(nr)
    }

    _duplicate() {
        r := this._selectedRow()
        if r <= 0
            return
        this.steps.InsertAt(r + 1, StepEditor._deepClone(this.steps[r]))
        this._pushHistory()
        this._refresh()
        this._selectReal(r + 1)
    }

    _importPreset() {
        ; Get all available presets
        names := PresetManager.List()
        if names.Length = 0 {
            MsgBox "No presets available to import."
            return
        }

        ; Create a simple selection dialog
        selGui := Gui("+ToolWindow +Owner" this.gui.Hwnd, "Import Preset Steps")
        selGui.SetFont("s9", "Segoe UI")
        selGui.MarginX := 10, selGui.MarginY := 10
        selGui.AddText("xm", "Select a preset to import its steps:")
        lb := selGui.AddListBox("xm w300 h200 r10", names)

        chosen := ""
        selGui.AddButton("xm w80 Default", "Import").OnEvent("Click", (*) => (chosen := lb.Text, selGui.Destroy()))
        selGui.AddButton("x+5 yp w80", "Cancel").OnEvent("Click", (*) => selGui.Destroy())
        selGui.OnEvent("Close", (*) => selGui.Destroy())
        selGui.OnEvent("Escape", (*) => selGui.Destroy())

        selGui.Show()
        WinWaitClose(selGui)

        if chosen = ""
            return

        ; Load the selected preset and import its steps
        try {
            importedPreset := PresetManager.Load(chosen)
            if !importedPreset.Has("steps") || importedPreset["steps"].Length = 0 {
                MsgBox "The selected preset has no steps to import."
                return
            }

            ; Deep-clone and append all steps
            for step in importedPreset["steps"]
                this.steps.Push(StepEditor._deepClone(step))

            this._pushHistory()
            this._refresh()
            ; Select the last imported step
            if this.steps.Length > 0
                this._selectReal(this.steps.Length)
        } catch as e {
            MsgBox "Failed to import preset: " e.Message
        }
    }

    static _joinTypes() {
        out := ""
        for i, t in Cfg.STEP_TYPES
            out .= (i = 1 ? "" : ", ") t
        return out
    }

    static _validType(t) {
        for tt in Cfg.STEP_TYPES
            if tt = t
                return true
        return false
    }

    static Summary(s) {
        if !(s is Map) || !s.Has("type")
            return "?"
        t := s["type"]
        get(k, d) => s.Has(k) ? s[k] : d
        switch t {
            case "click":
                xy := s.Has("x") && s.Has("y") ? " (" s["x"] "," s["y"] ")" : " at cursor"
                return get("button","left") xy " x" get("count",1)
            case "move":
                return "(" get("x","?") "," get("y","?") ") speed=" get("speed",2)
            case "drag":
                return "(" get("fromX","?") "," get("fromY","?") ") -> (" get("toX","?") "," get("toY","?") ")"
            case "scroll":
                return get("direction","down") " x" get("amount",3)
            case "key":
                return get("key","?") (s.Has("duration") && s["duration"] > 0 ? " hold " s["duration"] "ms" : " tap")
            case "keyDown":
                return get("key","?") " down"
            case "keyUp":
                return get("key","?") " up"
            case "send":
                v := get("text","")
                return "send(" StrLen(v) " chars)" (s.Has("mode") ? " via " s["mode"] : "")
            case "sleep":
                j := s.Has("jitter") && s["jitter"] > 0 ? " ±" s["jitter"] "%" : ""
                return get("ms","?") "ms" j
            case "loop":
                inner := s.Has("steps") ? s["steps"].Length : 0
                return "x" get("count",1) " (" inner " steps)"
            case "ifImage":
                t1 := s.Has("thenSteps") ? s["thenSteps"].Length : 0
                t2 := s.Has("elseSteps") ? s["elseSteps"].Length : 0
                return get("image","?") " then=" t1 " else=" t2
            case "ifPixel":
                t1 := s.Has("thenSteps") ? s["thenSteps"].Length : 0
                t2 := s.Has("elseSteps") ? s["elseSteps"].Length : 0
                return "(" get("x","?") "," get("y","?") ")=" get("color","?") " then=" t1 " else=" t2
            case "ifText":
                if s.Has("conditions") && s["conditions"] is Array && s["conditions"].Length > 0 {
                    condCount := s["conditions"].Length
                    t2 := s.Has("elseSteps") ? s["elseSteps"].Length : 0
                    return condCount " conditions, else=" t2
                }
                t1 := s.Has("thenSteps") ? s["thenSteps"].Length : 0
                t2 := s.Has("elseSteps") ? s["elseSteps"].Length : 0
                lng := get("language", "Auto")
                cm  := get("captureMode", "auto")
                return "'" get("searchText","?") "' [" lng "/" cm "] then=" t1 " else=" t2
            case "ifWindow":
                t1 := s.Has("thenSteps") ? s["thenSteps"].Length : 0
                t2 := s.Has("elseSteps") ? s["elseSteps"].Length : 0
                return "'" get("title","?") "' then=" t1 " else=" t2
            case "setVar":
                sc := s.Has("scope") && s["scope"] = "global" ? "[G] " : ""
                return sc get("varName","?") " " get("operator","=") " " get("varValue","?")
            case "ifVar":
                t1 := s.Has("thenSteps") ? s["thenSteps"].Length : 0
                t2 := s.Has("elseSteps") ? s["elseSteps"].Length : 0
                sc := s.Has("scope") && s["scope"] = "global" ? "[G] " : ""
                return sc get("varName","?") " " get("operator","=") " " get("varValue","?") " then=" t1 " else=" t2
            case "call":
                return "call preset: " get("presetName","?")
            case "webhook":
                v := get("webhookPayload","")
                return "webhook: " (StrLen(v) > 20 ? SubStr(v,1,20) "..." : v)
            case "waitForImage":
                t1 := s.Has("thenSteps") ? s["thenSteps"].Length : 0
                t2 := s.Has("elseSteps") ? s["elseSteps"].Length : 0
                return get("image","?") " timeout=" get("timeout",10000) "ms then=" t1 " else=" t2
            case "waitForPixel":
                t1 := s.Has("thenSteps") ? s["thenSteps"].Length : 0
                t2 := s.Has("elseSteps") ? s["elseSteps"].Length : 0
                return "(" get("x","?") "," get("y","?") ")=" get("color","?") " timeout=" get("timeout",10000) "ms then=" t1 " else=" t2
            case "loopWhileImage":
                inner := s.Has("steps") ? s["steps"].Length : 0
                return get("image","?") " (" inner " steps)"
            case "loopUntilPixel":
                inner := s.Has("steps") ? s["steps"].Length : 0
                return "(" get("x","?") "," get("y","?") ")=" get("color","?") " (" inner " steps)"
            case "loopWhileVar":
                inner := s.Has("steps") ? s["steps"].Length : 0
                return get("varName","?") " " get("operator","=") " " get("varValue","?") " (" inner " steps)"
            case "label":   return get("name","")
            case "log":     return get("message","")
            case "break":   return "break loop"
            case "stop":    return "stop macro"
            case "focusWindow": return get("title","")
            default:        return ""
        }
    }
}


; ============================================================================
; ConditionListEditor - modal window to edit an array of ifText conditions.
; Each condition has a searchText (supports OR) and thenSteps.
; ============================================================================

class ConditionListEditor {
    static Open(conditions, stepType, title := "Edit Conditions", parentGui := "") {
        return ConditionListEditor(conditions, stepType, title, parentGui)._run()
    }

    __New(conditions, stepType, title, parentGui) {
        this.conditions := StepEditor._deepClone(conditions)
        this.stepType := stepType
        this.title := title
        this.parent := parentGui
        this.result := ""
        this._build()
        this._refresh()
    }

    _run() {
        this.gui.Show()
        while this.result == ""
            Sleep 30
        try this.gui.Destroy()
        return this.result == "cancel" ? "" : this.result
    }

    _build() {
        ownerOpt := (this.parent != "" && this.parent.HasProp("Hwnd")) ? " +Owner" this.parent.Hwnd : ""
        g := Gui("+Resize +ToolWindow" ownerOpt, this.title)
        g.SetFont("s9", "Segoe UI")
        g.MarginX := 10, g.MarginY := 10
        g.OnEvent("Close",  (*) => this.result := "cancel")
        g.OnEvent("Escape", (*) => this.result := "cancel")

        g.AddText("xm", "Each condition is checked in order (first match wins).")

        this.lv := g.AddListView("xm y+5 w520 h250 Grid Section", ["#","Condition Summary","Steps"])
        this.lv.ModifyCol(1, 40)
        this.lv.ModifyCol(2, 340)
        this.lv.ModifyCol(3, 130)
        this.lv.OnEvent("DoubleClick", (ctrl, row) => row > 0 ? this._edit(row) : "")

        g.AddButton("ys w100", "Add").OnEvent("Click", (*) => this._add())
        g.AddButton("xp y+5  w100", "Edit").OnEvent("Click", (*) => this._editSelected())
        g.AddButton("xp y+5  w100", "Remove").OnEvent("Click", (*) => this._removeSelected())
        g.AddButton("xp y+5  w100", "Move Up").OnEvent("Click", (*) => this._move(-1))
        g.AddButton("xp y+5  w100", "Move Down").OnEvent("Click", (*) => this._move(1))
        g.AddButton("xp y+15 w100", "Edit Steps").OnEvent("Click", (*) => this._editStepsSelected())

        okBtn := g.AddButton("xm w80 Default", "OK")
        okBtn.OnEvent("Click", (*) => this.result := this.conditions)
        cancelBtn := g.AddButton("x+5 yp w80", "Cancel")
        cancelBtn.OnEvent("Click", (*) => this.result := "cancel")

        this.gui := g
    }

    _refresh() {
        this.lv.Delete()
        for i, cond in this.conditions {
            tmpCond := StepEditor._deepClone(cond)
            tmpCond["type"] := this.stepType
            st := StepListEditor.Summary(tmpCond)
            steps := cond.Has("thenSteps") ? cond["thenSteps"].Length : 0
            this.lv.Add(, i, st, steps " steps")
        }
    }

    _selectedRow() {
        return this.lv.GetNext(0)
    }

    _add() {
        edited := StepEditor.Open(Map("thenSteps", []), this.gui, true, this.stepType)
        if edited is Map {
            this.conditions.Push(edited)
            this._refresh()
            this.lv.Modify(this.conditions.Length, "Select Focus Vis")
        }
    }

    _edit(row) {
        if row < 1 || row > this.conditions.Length
            return
        edited := StepEditor.Open(this.conditions[row], this.gui, true, this.stepType)
        if edited is Map {
            this.conditions[row] := edited
            this._refresh()
            this.lv.Modify(row, "Select Focus Vis")
        }
    }

    _editSelected() {
        r := this._selectedRow()
        if r > 0
            this._edit(r)
        else
            MsgBox "Select a condition first."
    }

    _editStepsSelected() {
        r := this._selectedRow()
        if r <= 0 || r > this.conditions.Length
            return
        cond := this.conditions[r]
        steps := cond.Has("thenSteps") ? cond["thenSteps"] : []
        edited := StepListEditor.Open(steps, "Condition #" r " then-steps", this.gui)
        if edited is Array
            cond["thenSteps"] := edited
        this._refresh()
    }

    _removeSelected() {
        r := this._selectedRow()
        if r <= 0
            return
        this.conditions.RemoveAt(r)
        this._refresh()
    }

    _move(delta) {
        r := this._selectedRow()
        nr := r + delta
        if r <= 0 || nr < 1 || nr > this.conditions.Length
            return
        tmp := this.conditions[r]
        this.conditions[r] := this.conditions[nr]
        this.conditions[nr] := tmp
        this._refresh()
        this.lv.Modify(nr, "Select Focus Vis")
    }
}



