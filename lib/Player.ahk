#Requires AutoHotkey v2.0

; Dependencies (guarded by AHK against double-inclusion when run via MacroForge.ahk)
#Include Constants.ahk
#Include JSON.ahk
#Include Logger.ahk
#Include PresetManager.ahk
#Include OCR.ahk

; Executes a preset. State is exposed on the Player instance so the GUI and
; hotkeys can poke `stopRequested` / `pauseRequested` without owning the
; playback loop.
;
; Threading: AHK is single-threaded; the GUI's main thread is blocked while
; Run() executes, but hotkeys interrupt as pseudo-threads, which is enough to
; flip the flags.

class Player {
    state := "idle"     ; idle | running | paused | stopping
    stopRequested := false
    pauseRequested := false
    currentPreset := ""
    onStateChange := ""
    onProgress := ""        ; cb.Call(progressMap) for live playback status
    _progress := ""
    keysHeld := Map()
    _breakLoop := false
    _callDepth := 0
    static MAX_CALL_DEPTH := 16
    static WEBHOOK_TIMEOUT_MS := 10000
    ; QueryPerformanceFrequency is a constant for the lifetime of the OS
    ; session, so we query it once and cache it instead of per _sleep() call.
    static _qpcFreqCache := 0
    ; Global variables persist across preset runs (file-backed)
    static globalVars := Map()
    static _globalsLoaded := false

    ; Returns the cached QPC tick frequency, querying the OS only once.
    ; (Defined AFTER all static property declarations so it does not split
    ; the class's static initializer block.)
    static _QpcFreq() {
        if Player._qpcFreqCache = 0
            DllCall("QueryPerformanceFrequency", "Int64*", &f := 0), Player._qpcFreqCache := f
        return Player._qpcFreqCache
    }

    SetStateCallback(cb) {
        this.onStateChange := cb
    }

    SetProgressCallback(cb) {
        this.onProgress := cb
    }

    ; Emit a progress snapshot to the GUI. Fields:
    ;   repeat, totalRepeats (0 = infinite), step, totalSteps, elapsedMs.
    _emitProgress() {
        if !(this.onProgress is Func) || !(this._progress is Map)
            return
        this._progress["elapsedMs"] := A_TickCount - this._progress["startTick"]
        try this.onProgress.Call(this._progress)
    }

    _setState(s) {
        this.state := s
        if this.onStateChange is Func
            try this.onStateChange.Call(s)
    }

    Run(preset) {
        if this.state = "running" || this.state = "paused" {
            Logger.Warn("Player.Run called while already active")
            return
        }
        
        ; Save previous SendMode so we can restore it when done
        prevSendMode := A_SendMode
        
        ; Configure AHK input for maximum game compatibility (Roblox, etc.)
        SendMode "Event"
        SetKeyDelay -1, -1
        SetMouseDelay -1

        this.currentPreset := preset
        this.stopRequested := false
        this.pauseRequested := false
        this.keysHeld := Map()
        this.variables := Map()
        this._breakLoop := false
        this._callDepth := 0
        this._topLevel := true   ; only top-level steps drive the progress bar
        this._progress := Map(
            "repeat", 0, "totalRepeats", 0,
            "step", 0, "totalSteps", 0,
            "startTick", A_TickCount, "elapsedMs", 0
        )
        this._setState("running")
        Logger.Info("=== Starting preset: " preset["name"] " ===")

        ; Load global variables from disk
        Player._loadGlobals()

        settings := preset["settings"]
        try {
            if settings["startDelayMs"] > 0
                this._sleep(settings["startDelayMs"], preset)
            if settings["focusOnStart"] && settings["targetWindow"] != "" {
                try WinActivate(settings["targetWindow"])
                catch as e
                    Logger.Warn("focusOnStart: " e.Message)
            }

            ; Decide: raw timeline replay or step-based?
            hasRaw := preset.Has("_rawTimeline") && preset["_rawTimeline"] is Array && preset["_rawTimeline"].Length > 0

            repeats := settings["repeatCount"]
            iter := 0
            this._progress["totalRepeats"] := repeats
            this._progress["totalSteps"] := hasRaw ? preset["_rawTimeline"].Length : preset["steps"].Length
            while !this.stopRequested && (repeats = 0 || iter < repeats) {
                iter++
                this._progress["repeat"] := iter
                this._progress["step"] := 0
                this._emitProgress()
                ; Reset _breakLoop at start of each repeat to prevent
                ; a top-level break from causing an infinite 0-work loop
                this._breakLoop := false
                if repeats != 0
                    Logger.Info("Repeat " iter "/" repeats)
                else
                    Logger.Info("Repeat " iter " (infinite)")

                if hasRaw
                    this._replayRawTimeline(preset["_rawTimeline"], preset)
                else
                    this._runSteps(preset["steps"], preset)
                if this.stopRequested
                    break
            }
        } catch as e {
            Logger.Error("Aborted: " e.Message)
        }
        this._releaseHeldKeys()
        ; Persist global variables to disk
        Player._saveGlobals()
        Logger.Info("=== Finished ===")
        this._setState("idle")
        this.stopRequested := false
        this.pauseRequested := false
        ; Restore previous SendMode
        try SendMode prevSendMode
    }

    Stop() {
        if this.state = "idle"
            return
        Logger.Info("Stop requested")
        this.stopRequested := true
        this._setState("stopping")
    }

    Pause() {
        if this.state = "running" {
            this.pauseRequested := true
            this._setState("paused")
            Logger.Info("Paused")
        } else if this.state = "paused" {
            this.pauseRequested := false
            this._setState("running")
            Logger.Info("Resumed")
        }
    }

    _runSteps(steps, preset) {
        ; Track step index only for the OUTERMOST step list so the status bar
        ; reflects top-level progress, not every nested loop/if iteration.
        atTop := this.HasProp("_topLevel") && this._topLevel
        if atTop
            this._topLevel := false
        idx := 0
        for step in steps {
            idx++
            if this.stopRequested
                break
            if atTop {
                this._progress["step"] := idx
                this._emitProgress()
            }
            this._waitWhilePaused()
            try {
                this._dispatch(step, preset)
            } catch as e {
                Logger.Error("Step '" (step is Map && step.Has("type") ? step["type"] : "?") "': " e.Message)
                if preset["settings"]["stopOnError"] {
                    this.stopRequested := true
                    break
                }
            }
            if this._breakLoop
                break
        }
        if atTop
            this._topLevel := true
    }

    _dispatch(step, preset) {
        if !(step is Map) || !step.Has("type")
            throw Error("Invalid step")
        t := step["type"]
        switch t {
            case "click":           this._stepClick(step)
            case "move":            this._stepMove(step)
            case "drag":            this._stepDrag(step)
            case "scroll":          this._stepScroll(step)
            case "key":             this._stepKey(step, preset)
            case "keyDown":         this._stepKeyDown(step)
            case "keyUp":           this._stepKeyUp(step)
            case "send":            this._stepSend(step)
            case "sleep":           this._stepSleep(step, preset)
            case "loop":            this._stepLoop(step, preset)
            case "ifImage":         this._stepIfImage(step, preset)
            case "ifPixel":         this._stepIfPixel(step, preset)
            case "ifText":          this._stepIfText(step, preset)
            case "ifWindow":        this._stepIfWindow(step, preset)
            case "setVar":          this._stepSetVar(step)
            case "ifVar":           this._stepIfVar(step, preset)
            case "call":            this._stepCall(step, preset)
            case "webhook":         this._stepWebhook(step)
            case "label":           Logger.Step("-- " (step.Has("name") ? step["name"] : "label") " --")
            case "log":             Logger.Step("log: " (step.Has("message") ? step["message"] : ""))
            case "break":           this._breakLoop := true
            case "stop":            this.stopRequested := true
            case "focusWindow":     this._stepFocus(step)
            case "waitForImage":    this._stepWaitForImage(step, preset)
            case "waitForPixel":    this._stepWaitForPixel(step, preset)
            case "loopWhileImage":  this._stepLoopWhileImage(step, preset)
            case "loopUntilPixel":  this._stepLoopUntilPixel(step, preset)
            case "loopWhileVar":    this._stepLoopWhileVar(step, preset)
            default:                throw Error("Unknown step type: " t)
        }
    }

    _stepClick(step) {
        btn := step.Has("button") ? step["button"] : "left"
        count := step.Has("count") ? step["count"] : 1
        x := step.Has("x") ? step["x"] : ""
        y := step.Has("y") ? step["y"] : ""
        if x != "" && y != ""
            MouseMove(x, y, 0)
        Loop count
            Click btn
    }

    _stepMove(step) {
        x := step["x"], y := step["y"]
        speed := step.Has("speed") ? step["speed"] : 2
        MouseMove(x, y, speed)
    }

    _stepDrag(step) {
        fx := step["fromX"], fy := step["fromY"]
        tx := step["toX"], ty := step["toY"]
        btn := step.Has("button") ? step["button"] : "left"
        speed := step.Has("speed") ? step["speed"] : 5
        MouseClickDrag(btn, fx, fy, tx, ty, speed)
    }

    _stepScroll(step) {
        dir := step.Has("direction") ? step["direction"] : "down"
        amount := step.Has("amount") ? step["amount"] : 3
        ; MOUSEEVENTF_WHEEL = 0x0800, WHEEL_DELTA = 120
        ; BUG FIX: Use "Int" instead of "UInt" for delta — negative values are valid
        delta := dir = "up" ? 120 : -120
        Loop amount
            DllCall("mouse_event", "UInt", 0x0800, "Int", 0, "Int", 0, "Int", delta, "UPtr", 0)
    }

    _stepKey(step, preset) {
        key := step["key"]
        duration := step.Has("duration") ? step["duration"] : 0
        if duration > 0 {
            Send "{" key " down}"
            this._sleep(duration, preset)
            Send "{" key " up}"
        } else {
            Send "{" key "}"
        }
    }

    _stepKeyDown(step) {
        key := step["key"]
        Send "{" key " down}"
        this.keysHeld[key] := true
    }

    _stepKeyUp(step) {
        key := step["key"]
        Send "{" key " up}"
        if this.keysHeld.Has(key)
            this.keysHeld.Delete(key)
    }

    _stepSend(step) {
        text := step["text"]
        mode := step.Has("mode") ? step["mode"] : "send"
        switch mode {
            case "sendText":  SendText text
            case "sendInput": SendInput text
            default:          Send text
        }
    }

    _stepSleep(step, preset) {
        ms := step["ms"]
        jitter := step.Has("jitter") ? step["jitter"] : 0
        if jitter > 0 {
            ; Jitter is a percentage: ±jitter% of ms
            range := ms * jitter / 100
            ms := ms + Random(-range, range)
            if ms < 0
                ms := 0
        }
        this._sleep(ms, preset)
    }

    _sleep(ms, preset) {
        mult := preset["settings"]["speedMultiplier"]
        if mult <= 0
            mult := 1.0
        adjusted := ms / mult
        if adjusted < 1
            return

        ; Use QPC for high-resolution timing (frequency cached once)
        freq := Player._QpcFreq()
        DllCall("QueryPerformanceCounter", "Int64*", &start := 0)
        targetTicks := Integer((adjusted * freq) / 1000)
        endTick := start + targetTicks

        loop {
            if this.stopRequested
                return
            this._waitWhilePaused()

            DllCall("QueryPerformanceCounter", "Int64*", &now := 0)
            if now >= endTick
                break

            remainingTicks := endTick - now
            remainingMs := (remainingTicks * 1000.0) / freq

            ; Adaptive wait strategy:
            if remainingMs > 15
                Sleep 1           ; yield ~1-2ms, saves CPU
            else if remainingMs > 2
                DllCall("Sleep", "UInt", 0)  ; yield timeslice (~0.5ms)
            ; else: spin-wait for sub-2ms precision
        }
    }

    _stepLoop(step, preset) {
        count := step.Has("count") ? step["count"] : 1
        steps := step["steps"]
        i := 0
        while !this.stopRequested && (count = 0 || i < count) {
            i++
            this._breakLoop := false
            this._runSteps(steps, preset)
            if this._breakLoop {
                this._breakLoop := false
                break
            }
        }
    }

    _evalIfImageCond(step) {
        img := step["image"]
        if !FileExist(img) && FileExist(Cfg.IMAGES_DIR "\" img)
            img := Cfg.IMAGES_DIR "\" img
        variation := step.Has("variation") ? step["variation"] : 30
        x1 := step.Has("x1") && step["x1"] !== "" ? step["x1"] : 0
        y1 := step.Has("y1") && step["y1"] !== "" ? step["y1"] : 0
        x2 := step.Has("x2") && step["x2"] !== "" ? step["x2"] : A_ScreenWidth
        y2 := step.Has("y2") && step["y2"] !== "" ? step["y2"] : A_ScreenHeight
        found := false
        try {
            if ImageSearch(&fx, &fy, x1, y1, x2, y2, "*" variation " " img)
                found := true
        } catch as e {
            Logger.Warn("ifImage error: " e.Message)
        }
        Logger.Step("ifImage " img " -> " (found ? "found" : "not found"))
        return found
    }

    _stepIfImage(step, preset) {
        if step.Has("conditions") && step["conditions"].Length > 0 {
            for i, cond in step["conditions"] {
                if this._evalIfImageCond(cond) {
                    if cond.Has("thenSteps")
                        this._runSteps(cond["thenSteps"], preset)
                    return
                }
            }
            if step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        } else {
            found := this._evalIfImageCond(step)
            if found && step.Has("thenSteps")
                this._runSteps(step["thenSteps"], preset)
            else if !found && step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        }
    }

    _evalIfPixelCond(step) {
        x := step["x"], y := step["y"]
        expected := step["color"]
        tol := step.Has("tolerance") ? step["tolerance"] : 0
        actual := ""
        try actual := PixelGetColor(x, y, "RGB")
        catch as e {
            Logger.Warn("ifPixel error: " e.Message)
            return false
        }
        match := this._colorsClose(actual, expected, tol)
        Logger.Step("ifPixel (" x "," y ") want=" expected " got=" actual " -> " (match ? "match" : "miss"))
        return match
    }

    _stepIfPixel(step, preset) {
        if step.Has("conditions") && step["conditions"].Length > 0 {
            for i, cond in step["conditions"] {
                if this._evalIfPixelCond(cond) {
                    if cond.Has("thenSteps")
                        this._runSteps(cond["thenSteps"], preset)
                    return
                }
            }
            if step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        } else {
            match := this._evalIfPixelCond(step)
            if match && step.Has("thenSteps")
                this._runSteps(step["thenSteps"], preset)
            else if !match && step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        }
    }

    _colorsClose(a, b, tol) {
        ai := this._toInt(a)
        bi := this._toInt(b)
        if tol = 0
            return ai = bi
        ar := (ai >> 16) & 0xFF, ag := (ai >> 8) & 0xFF, ab := ai & 0xFF
        br := (bi >> 16) & 0xFF, bg := (bi >> 8) & 0xFF, bb := bi & 0xFF
        return Abs(ar - br) <= tol && Abs(ag - bg) <= tol && Abs(ab - bb) <= tol
    }

    _toInt(v) {
        if IsInteger(v)
            return v + 0
        s := String(v)
        if SubStr(s, 1, 2) = "0x" || SubStr(s, 1, 2) = "0X"
            return Integer(s)
        return Integer("0x" s)
    }

    _stepFocus(step) {
        title := step["title"]
        Logger.Step("focusWindow " title)
        WinActivate(title)
        try WinWaitActive(title, , 2)
    }

    ; ==================== ifWindow (new) ====================
    _evalIfWindowCond(step) {
        title := step["title"]
        active := false
        try active := WinActive(title) != 0
        Logger.Step("ifWindow '" title "' -> " (active ? "active" : "inactive"))
        return active
    }

    _stepIfWindow(step, preset) {
        if step.Has("conditions") && step["conditions"].Length > 0 {
            for i, cond in step["conditions"] {
                if this._evalIfWindowCond(cond) {
                    if cond.Has("thenSteps")
                        this._runSteps(cond["thenSteps"], preset)
                    return
                }
            }
            if step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        } else {
            active := this._evalIfWindowCond(step)
            if active && step.Has("thenSteps")
                this._runSteps(step["thenSteps"], preset)
            else if !active && step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        }
    }

    ; ==================== waitForImage (new) ====================
    _evalWaitForImageCond(step, timeoutMs, pollMs, startT, preset) {
        img := step["image"]
        if !FileExist(img) && FileExist(Cfg.IMAGES_DIR "\" img)
            img := Cfg.IMAGES_DIR "\" img
        variation := step.Has("variation") ? step["variation"] : 30
        x1 := step.Has("x1") && step["x1"] !== "" ? step["x1"] : 0
        y1 := step.Has("y1") && step["y1"] !== "" ? step["y1"] : 0
        x2 := step.Has("x2") && step["x2"] !== "" ? step["x2"] : A_ScreenWidth
        y2 := step.Has("y2") && step["y2"] !== "" ? step["y2"] : A_ScreenHeight

        found := false
        try {
            if ImageSearch(&fx, &fy, x1, y1, x2, y2, "*" variation " " img) {
                found := true
            }
        }
        return found
    }

    _stepWaitForImage(step, preset) {
        timeoutMs := step.Has("timeout") && step["timeout"] !== "" ? step["timeout"] : 10000
        pollMs := step.Has("poll") && step["poll"] !== "" ? step["poll"] : 200

        startT := A_TickCount
        matchedCondIdx := -1
        foundAny := false

        Logger.Step("waitForImage checking conditions (timeout=" timeoutMs "ms)")
        
        while !this.stopRequested && (A_TickCount - startT < timeoutMs) {
            this._waitWhilePaused()
            
            if step.Has("conditions") && step["conditions"].Length > 0 {
                for i, cond in step["conditions"] {
                    if this._evalWaitForImageCond(cond, timeoutMs, pollMs, startT, preset) {
                        foundAny := true
                        matchedCondIdx := i
                        break
                    }
                }
            } else {
                if this._evalWaitForImageCond(step, timeoutMs, pollMs, startT, preset) {
                    foundAny := true
                }
            }
            
            if foundAny
                break
            
            this._sleep(pollMs, preset)
        }

        if step.Has("conditions") && step["conditions"].Length > 0 {
            if foundAny && matchedCondIdx > 0 {
                cond := step["conditions"][matchedCondIdx]
                if cond.Has("thenSteps")
                    this._runSteps(cond["thenSteps"], preset)
            } else if !foundAny && step.Has("elseSteps") {
                this._runSteps(step["elseSteps"], preset)
            }
        } else {
            if foundAny && step.Has("thenSteps")
                this._runSteps(step["thenSteps"], preset)
            else if !foundAny && step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        }
    }

    ; ==================== waitForPixel (new) ====================
    _evalWaitForPixelCond(step) {
        x := step["x"], y := step["y"]
        expected := step["color"]
        tol := step.Has("tolerance") ? step["tolerance"] : 0
        try {
            actual := PixelGetColor(x, y, "RGB")
            if this._colorsClose(actual, expected, tol) {
                return true
            }
        }
        return false
    }

    _stepWaitForPixel(step, preset) {
        timeoutMs := step.Has("timeout") && step["timeout"] !== "" ? step["timeout"] : 10000
        pollMs := step.Has("poll") && step["poll"] !== "" ? step["poll"] : 200

        startT := A_TickCount
        matchedCondIdx := -1
        foundAny := false

        Logger.Step("waitForPixel checking conditions (timeout=" timeoutMs "ms)")
        
        while !this.stopRequested && (A_TickCount - startT < timeoutMs) {
            this._waitWhilePaused()
            
            if step.Has("conditions") && step["conditions"].Length > 0 {
                for i, cond in step["conditions"] {
                    if this._evalWaitForPixelCond(cond) {
                        foundAny := true
                        matchedCondIdx := i
                        break
                    }
                }
            } else {
                if this._evalWaitForPixelCond(step) {
                    foundAny := true
                }
            }
            
            if foundAny
                break
                
            this._sleep(pollMs, preset)
        }
        
        if step.Has("conditions") && step["conditions"].Length > 0 {
            if foundAny && matchedCondIdx > 0 {
                cond := step["conditions"][matchedCondIdx]
                if cond.Has("thenSteps")
                    this._runSteps(cond["thenSteps"], preset)
            } else if !foundAny && step.Has("elseSteps") {
                this._runSteps(step["elseSteps"], preset)
            }
        } else {
            if foundAny && step.Has("thenSteps")
                this._runSteps(step["thenSteps"], preset)
            else if !foundAny && step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        }
    }

    ; ==================== loopWhileImage (new) ====================
    _stepLoopWhileImage(step, preset) {
        img := step["image"]
        if !FileExist(img) && FileExist(Cfg.IMAGES_DIR "\" img)
            img := Cfg.IMAGES_DIR "\" img
        variation := step.Has("variation") ? step["variation"] : 30
        x1 := step.Has("x1") && step["x1"] !== "" ? step["x1"] : 0
        y1 := step.Has("y1") && step["y1"] !== "" ? step["y1"] : 0
        x2 := step.Has("x2") && step["x2"] !== "" ? step["x2"] : A_ScreenWidth
        y2 := step.Has("y2") && step["y2"] !== "" ? step["y2"] : A_ScreenHeight
        steps := step.Has("steps") ? step["steps"] : []

        Logger.Step("loopWhileImage " img)
        while !this.stopRequested {
            found := false
            try {
                if ImageSearch(&fx, &fy, x1, y1, x2, y2, "*" variation " " img)
                    found := true
            }
            if !found
                break
            this._breakLoop := false
            this._runSteps(steps, preset)
            if this._breakLoop {
                this._breakLoop := false
                break
            }
        }
    }

    ; ==================== loopUntilPixel (new) ====================
    _stepLoopUntilPixel(step, preset) {
        px := step["x"], py := step["y"]
        expected := step["color"]
        tol := step.Has("tolerance") ? step["tolerance"] : 0
        steps := step.Has("steps") ? step["steps"] : []

        Logger.Step("loopUntilPixel (" px "," py ") color=" expected)
        while !this.stopRequested {
            actual := ""
            try actual := PixelGetColor(px, py, "RGB")
            if this._colorsClose(actual, expected, tol)
                break
            this._breakLoop := false
            this._runSteps(steps, preset)
            if this._breakLoop {
                this._breakLoop := false
                break
            }
        }
    }

    ; ==================== loopWhileVar (new) ====================
    _stepLoopWhileVar(step, preset) {
        vName := step["varName"]
        op := step.Has("operator") ? step["operator"] : "="
        val := step["varValue"]
        steps := step.Has("steps") ? step["steps"] : []

        Logger.Step("loopWhileVar " vName " " op " " val)
        while !this.stopRequested {
            current := this.variables.Has(vName) ? this.variables[vName] : ""
            match := this._compareVar(current, op, val)
            if !match
                break
            this._breakLoop := false
            this._runSteps(steps, preset)
            if this._breakLoop {
                this._breakLoop := false
                break
            }
        }
    }

    _toNum(v) {
        if IsNumber(v)
            return v
        try return Integer(v)
        try return Float(v)
        return 0
    }

    _isNumeric(v) {
        if IsNumber(v)
            return true
        try {
            Integer(v)
            return true
        }
        try {
            Float(v)
            return true
        }
        return false
    }

    _stepSetVar(step) {
        vName := step["varName"]
        op := step.Has("operator") ? step["operator"] : "="
        val := step["varValue"]
        scope := step.Has("scope") ? step["scope"] : "local"
        
        current := ""
        if scope = "global"
            current := Player.globalVars.Has(vName) ? Player.globalVars[vName] : 0
        else
            current := this.variables.Has(vName) ? this.variables[vName] : 0

        newVal := val
        if op = "+=" {
            cNum := this._toNum(current)
            vNum := this._toNum(val)
            newVal := cNum + vNum
        } else if op = "-=" {
            cNum := this._toNum(current)
            vNum := this._toNum(val)
            newVal := cNum - vNum
        }

        if scope = "global"
            Player.globalVars[vName] := newVal
        else
            this.variables[vName] := newVal

        Logger.Step("setVar " (scope = "global" ? "[G] " : "") vName " " op " " val " (now: " newVal ")")
    }

    _evalIfVarCond(step) {
        vName := step["varName"]
        op := step.Has("operator") ? step["operator"] : "="
        val := step["varValue"]
        scope := step.Has("scope") ? step["scope"] : "local"
        
        current := ""
        if scope = "global"
            current := Player.globalVars.Has(vName) ? Player.globalVars[vName] : ""
        else
            current := this.variables.Has(vName) ? this.variables[vName] : ""
        
        match := this._compareVar(current, op, val)
        Logger.Step("ifVar " (scope = "global" ? "[G] " : "") vName "(" current ") " op " " val " -> " (match ? "true" : "false"))
        return match
    }

    _stepIfVar(step, preset) {
        if step.Has("conditions") && step["conditions"].Length > 0 {
            for i, cond in step["conditions"] {
                if this._evalIfVarCond(cond) {
                    if cond.Has("thenSteps")
                        this._runSteps(cond["thenSteps"], preset)
                    return
                }
            }
            if step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        } else {
            match := this._evalIfVarCond(step)
            if match && step.Has("thenSteps")
                this._runSteps(step["thenSteps"], preset)
            else if !match && step.Has("elseSteps")
                this._runSteps(step["elseSteps"], preset)
        }
    }

    _compareVar(current, op, val) {
        if op = "="
            return (current == val)
        else if op = "!="
            return (current != val)
        
        if this._isNumeric(current) && this._isNumeric(val) {
            c := this._toNum(current)
            v := this._toNum(val)
            if op = "<"
                return c < v
            if op = ">"
                return c > v
            if op = "<="
                return c <= v
            if op = ">="
                return c >= v
        } else {
            if op = "<"
                return current < val
            if op = ">"
                return current > val
            if op = "<="
                return current <= val
            if op = ">="
                return current >= val
        }
        return false
    }

    _stepCall(step, preset) {
        pName := step["presetName"]
        Logger.Step("call preset: " pName)
        if (this._callDepth >= Player.MAX_CALL_DEPTH) {
            Logger.Error("call aborted: max recursion depth (" Player.MAX_CALL_DEPTH ") reached at preset (" pName ")")
            if preset["settings"]["stopOnError"]
                this.stopRequested := true
            return
        }
        this._callDepth += 1
        ; Isolate local variables across the call boundary: a called preset
        ; gets a fresh scope and cannot clobber the caller's variables.
        ; (Persistent/global vars still live on Player.globalVars.)
        savedVars := this.variables
        this.variables := Map()
        try {
            subPreset := PresetManager.Load(pName)
            this._runSteps(subPreset["steps"], preset)
        } catch as e {
            Logger.Error("Failed to call preset '" pName "': " e.Message)
            if preset["settings"]["stopOnError"]
                this.stopRequested := true
        } finally {
            this.variables := savedVars
            this._callDepth -= 1
        }
    }

    _stepIfText(step, preset) {
        text := step["searchText"]
        lng  := step.Has("language") ? step["language"] : "Auto"
        lang := lng = "eng" ? "en-US" : lng = "ru" ? "ru-RU" : lng = "ua" ? "uk-UA" : "FirstFromAvailableLanguages"

        ; captureMode:
        ;   "desktop"  = FromDesktop/FromRect (GDI BitBlt from screen DC) — MOST RELIABLE for Roblox/DirectX
        ;   "window"   = FromWindow mode:4 (PrintWindow PW_RENDERFULLCONTENT) — good for GDI windows, BLACK for DX
        ;   "dx"       = FromWindow mode:5 (Windows.Graphics.Capture) — may fail on Roblox (anti-cheat/privacy)
        ;   "auto"     = try desktop → dx → window cascade (desktop first = best for Roblox)
        captureMode := step.Has("captureMode") ? step["captureMode"] : "auto"
        winTitle    := step.Has("windowTitle") ? step["windowTitle"] : ""
        scale       := step.Has("ocrScale") ? step["ocrScale"] : 2.0

        ; Search region (optional)
        hasRegion := step.Has("ocrX1") && step["ocrX1"] !== "" && step.Has("ocrY1") && step["ocrY1"] !== "" && step.Has("ocrX2") && step["ocrX2"] !== "" && step.Has("ocrY2") && step["ocrY2"] !== ""

        ; Build base OCR options
        baseOpts := {}
        if lang != "FirstFromAvailableLanguages"
            baseOpts.lang := lang
        if scale != 1.0
            baseOpts.scale := scale
        ; Grayscale improves recognition of colored game text (only when upscaling)
        if scale >= 2.0
            baseOpts.grayscale := 1

        found := false
        usedMode := ""
        ocrResult := ""
        foundConditionIdx := -1

        ; Force Per-Monitor DPI Aware v2 for accurate coordinates with DirectX games
        prevDpiCtx := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

        try {
            ; Resolve target window:
            ; Priority: step.windowTitle > preset.settings.targetWindow > "A" (active)
            winHwnd := 0
            winX := 0, winY := 0, winW := 0, winH := 0
            wt := ""
            if winTitle != ""
                wt := winTitle
            else if preset.Has("settings") && preset["settings"].Has("targetWindow") && preset["settings"]["targetWindow"] != ""
                wt := preset["settings"]["targetWindow"]
            else
                wt := "A"
            try {
                winHwnd := WinExist(wt)
                if winHwnd
                    WinGetPos(&winX, &winY, &winW, &winH, "ahk_id " winHwnd)
            }

            ; Determine capture region:
            ;   - If user specified explicit region → use it
            ;   - If we found the target window → use its bounds (much faster than full screen)
            ;   - Otherwise → full screen
            autoRegion := false
            regionX := 0, regionY := 0, regionW := 0, regionH := 0
            if hasRegion {
                regionX := step["ocrX1"]
                regionY := step["ocrY1"]
                regionW := step["ocrX2"] - step["ocrX1"]
                regionH := step["ocrY2"] - step["ocrY1"]
            } else if winHwnd && winW > 0 && winH > 0 {
                ; Auto-region from window bounds — captures just the game, not the whole screen
                regionX := winX
                regionY := winY
                regionW := winW
                regionH := winH
                autoRegion := true
            }

            ; Build ordered capture mode list
            ; Desktop first: it uses screen DC (BitBlt from GetDC(0)) which captures
            ; EVERYTHING visible on screen including DirectX/DirectComposition content.
            ; This is the ONLY method guaranteed to work for Roblox.
            modesToTry := []
            if captureMode = "auto" {
                modesToTry.Push("desktop", "dx", "window")
            } else if captureMode = "desktop" {
                modesToTry.Push("desktop", "dx", "window")
            } else if captureMode = "dx" {
                modesToTry.Push("dx", "desktop", "window")
            } else {
                modesToTry.Push("window", "desktop", "dx")
            }

            ; Brief delay to let DWM composite the latest game frame (~one frame
            ; at 60fps). Configurable per-step via frameWaitMs; set to 0 to skip
            ; entirely when ifText runs in a tight loop and the frame is already ready.
            frameWaitMs := step.Has("frameWaitMs") ? step["frameWaitMs"] : 16
            if frameWaitMs > 0
                DllCall("Sleep", "UInt", frameWaitMs)

            for tryMode in modesToTry {
                if found
                    break

                ; Retry up to 3 times per mode - handles flip-model swapchain timing
                maxRetries := 3
                retryIdx := 0
                while retryIdx < maxRetries {
                    retryIdx++
                    try {
                        ocrResult := ""
                        if tryMode = "desktop" {
                            ; Screen DC capture — MOST RELIABLE for Roblox/DirectX games
                            ; Uses GetDC(0) + StretchBlt with CAPTUREBLT — captures DWM-composited output
                            opts := baseOpts.Clone()
                            if regionW > 0 && regionH > 0 {
                                ; Capture specific region (window bounds or user region)
                                ocrResult := OCR.FromRect(regionX, regionY, regionW, regionH, opts)
                                Logger.Step("ifText [desktop] FromRect(" regionX "," regionY "," regionW "x" regionH ") scale=" scale " text=" (ocrResult ? StrLen(ocrResult.Text) : 0) " chars")
                            } else {
                                ; Full screen capture
                                ocrResult := OCR.FromDesktop(opts)
                                Logger.Step("ifText [desktop] full screen scale=" scale " text=" (ocrResult ? StrLen(ocrResult.Text) : 0) " chars")
                            }

                        } else if tryMode = "dx" {
                            ; DirectX / Windows.Graphics.Capture — mode 5
                            ; May fail on Roblox due to anti-cheat/privacy settings
                            opts := baseOpts.Clone()
                            opts.mode := 5
                            if hasRegion {
                                ; Region is window-relative in DX mode
                                rx := step["ocrX1"], ry := step["ocrY1"]
                                if (rx > 2000 || ry > 2000) && (winX != 0 || winY != 0) {
                                    rx -= winX
                                    ry -= winY
                                }
                                opts.x := rx
                                opts.y := ry
                                opts.w := step["ocrX2"] - step["ocrX1"]
                                opts.h := step["ocrY2"] - step["ocrY1"]
                            }
                            ocrResult := OCR.FromWindow(wt, opts)
                            Logger.Step("ifText [dx] mode=5 scale=" scale " text=" (ocrResult ? StrLen(ocrResult.Text) : 0) " chars")

                        } else {
                            ; PrintWindow PW_RENDERFULLCONTENT — mode 4
                            ; Usually returns BLACK for DirectX games, but works for standard windows
                            opts := baseOpts.Clone()
                            opts.mode := 4
                            if hasRegion {
                                opts.x := step["ocrX1"]
                                opts.y := step["ocrY1"]
                                opts.w := step["ocrX2"] - step["ocrX1"]
                                opts.h := step["ocrY2"] - step["ocrY1"]
                            }
                            ocrResult := OCR.FromWindow(wt, opts)
                            Logger.Step("ifText [window] mode=4 scale=" scale " text=" (ocrResult ? StrLen(ocrResult.Text) : 0) " chars")
                        }

                        ; Evaluate match: multi-condition or single text (supports OR)
                        if ocrResult {
                            if step.Has("conditions") && step["conditions"] is Array && step["conditions"].Length > 0 {
                                evalResult := this._evalConditions(ocrResult.Text, step["conditions"])
                                if evalResult.matched {
                                    found := true
                                    usedMode := tryMode
                                    foundConditionIdx := evalResult.condIdx
                                    break
                                }
                            } else if this._matchAny(ocrResult.Text, text) {
                                found := true
                                usedMode := tryMode
                                break
                            }
                        }

                        ; If OCR returned very short text (likely failed capture), retry
                        minSearchLen := Min(StrLen(text), 3)
                        if ocrResult && StrLen(ocrResult.Text) < 3 && minSearchLen > 2 {
                            if retryIdx < maxRetries {
                                DllCall("Sleep", "UInt", 50)
                                continue  ; Retry this mode
                            }
                        }
                        break  ; Got OCR text but didn't find match, move to next mode
                    } catch as e {
                        Logger.Warn("ifText [" tryMode "] attempt " retryIdx " error: " e.Message)
                        if retryIdx < maxRetries {
                            DllCall("Sleep", "UInt", 50)
                            continue
                        }
                    }
                    break  ; Exit while loop after successful (non-retried) attempt
                }
            }

            ; Log detailed results
            if !found && ocrResult {
                sample := SubStr(ocrResult.Text, 1, 200)
                Logger.Step("ifText '" text "' [" lng "] -> not found. OCR saw: '" sample "'")
            } else if !found {
                Logger.Step("ifText '" text "' [" lng "] -> all capture modes failed (no OCR result)")
            } else if foundConditionIdx >= 0 {
                condText := step["conditions"][foundConditionIdx + 1]["searchText"]
                Logger.Step("ifText condition #" (foundConditionIdx + 1) " '" condText "' [" lng "] [" usedMode "] -> matched")
            } else {
                Logger.Step("ifText '" text "' [" lng "] [" usedMode "] -> found")
            }
        } finally {
            ; Restore previous DPI awareness context
            if prevDpiCtx
                DllCall("SetThreadDpiAwarenessContext", "ptr", prevDpiCtx, "ptr")
        }

        ; Execute matching branch
        if found && foundConditionIdx >= 0 && step.Has("conditions") {
            cond := step["conditions"][foundConditionIdx + 1]
            if cond.Has("thenSteps")
                this._runSteps(cond["thenSteps"], preset)
        } else if found && step.Has("thenSteps") {
            this._runSteps(step["thenSteps"], preset)
        } else if !found && step.Has("elseSteps") {
            this._runSteps(step["elseSteps"], preset)
        }
    }

    ; ==================== ifText condition helpers ====================

    ; Evaluate OCR text against multiple conditions (if-elseif chain).
    ; Returns {matched: true/false, condIdx: 0-based index of matched condition or -1}
    _evalConditions(ocrText, conditions) {
        for i, cond in conditions {
            condText := cond.Has("searchText") ? cond["searchText"] : ""
            if condText != "" && this._matchAny(ocrText, condText)
                return {matched: true, condIdx: i - 1}
        }
        return {matched: false, condIdx: -1}
    }

    ; Check if OCR text matches a search string (supports OR operator).
    ; Example: _matchAny(ocrText, "rare OR legendary") returns true if either word is found.
    _matchAny(ocrText, searchText) {
        parts := StrSplit(searchText, " OR ")
        for part in parts {
            trimmed := Trim(part)
            if trimmed != "" && InStr(ocrText, trimmed)
                return true
        }
        return false
    }

    _stepWebhook(step) {
        url := step["webhookUrl"]
        payload := step["webhookPayload"]
        Logger.Step("webhook send to " (StrLen(url) > 20 ? SubStr(url, 1, 20) "..." : url))
        try {
            req := ComObject("WinHttp.WinHttpRequest.5.1")
            req.Open("POST", url, true)
            req.SetRequestHeader("Content-Type", "application/json")
            ; SetTimeouts(resolve, connect, send, receive) in ms. Caps how long
            ; a slow/dead server can stall us at the protocol level.
            try req.SetTimeouts(5000, 5000, 5000, 5000)
            ; Check if payload is already a JSON object or array
            body := ""
            isJson := false
            if RegExMatch(payload, "^\s*[\{\[]") {
                try {
                    JSON.parse(payload)
                    isJson := true
                }
            }
            if isJson {
                body := payload
            } else {
                bodyMap := Map("content", payload)
                body := JSON.stringify(bodyMap)
            }
            req.Send(body)
            ; Bounded, interruptible wait instead of an open-ended
            ; WaitForResponse() that could hang the whole macro forever.
            ; WaitForResponse(seconds) returns false on timeout; we also bail
            ; out early if the user requested stop (Esc).
            deadline := A_TickCount + Player.WEBHOOK_TIMEOUT_MS
            loop {
                if this.stopRequested
                    break
                ; 1s slices keep us responsive to stop while still bounded.
                if req.WaitForResponse(1)
                    break
                if A_TickCount >= deadline {
                    Logger.Warn("Webhook timed out after " Player.WEBHOOK_TIMEOUT_MS "ms")
                    break
                }
            }
        } catch as e {
            Logger.Warn("Webhook error: " e.Message)
        }
    }

    ; ==================== RAW TIMELINE REPLAY (TinyTask-style) ====================
    ; Replays the raw event timeline with frame-accurate timing using QPC.
    ; No per-step overhead, no logging per event — just pure, tight replay.

    _replayRawTimeline(timeline, preset) {
        if timeline.Length = 0
            return

        mult := preset["settings"]["speedMultiplier"]
        if mult <= 0
            mult := 1.0

        ; Get QPC frequency for high-resolution timing (cached once)
        freq := Player._QpcFreq()

        Logger.Info("Raw timeline replay: " timeline.Length " events, speed=" mult "x")

        ; Snapshot start time
        DllCall("QueryPerformanceCounter", "Int64*", &replayStart := 0)

        evIdx := 1
        totalEvents := timeline.Length

        while evIdx <= totalEvents && !this.stopRequested {
            ; Handle pause
            this._waitWhilePaused()
            if this.stopRequested
                break

            ev := timeline[evIdx]
            targetMs := ev["t"] / mult  ; scaled timestamp

            ; Busy-wait until it's time for this event (high precision)
            loop {
                if this.stopRequested
                    return
                DllCall("QueryPerformanceCounter", "Int64*", &now := 0)
                elapsedMs := ((now - replayStart) * 1000.0) / freq
                if elapsedMs >= targetMs
                    break
                ; Yield CPU briefly if we have time to spare
                remaining := targetMs - elapsedMs
                if remaining > 15
                    Sleep 1
                else if remaining > 2
                    DllCall("Sleep", "UInt", 0)  ; yield timeslice without 15ms granularity
                ; else: spin-wait for sub-2ms precision
            }

            ; Execute the event
            this._executeRawEvent(ev)
            evIdx++
        }
        Logger.Info("Raw timeline replay complete")
    }

    _executeRawEvent(ev) {
        kind := ev["kind"]
        switch kind {
            case "moveSample":
                MouseMove(ev["x"], ev["y"], 0)

            case "mouseDown":
                MouseMove(ev["x"], ev["y"], 0)
                try SendEvent "{" ev["key"] " down}"
                this.keysHeld[ev["key"]] := true

            case "mouseUp":
                try SendEvent "{" ev["key"] " up}"
                if this.keysHeld.Has(ev["key"])
                    this.keysHeld.Delete(ev["key"])

            case "keyDown":
                try SendEvent "{" ev["key"] " down}"
                this.keysHeld[ev["key"]] := true

            case "keyUp":
                try SendEvent "{" ev["key"] " up}"
                if this.keysHeld.Has(ev["key"])
                    this.keysHeld.Delete(ev["key"])

            case "wheel":
                ; Raw replay of a single mouse-wheel tick.
                MouseMove(ev["x"], ev["y"], 0)
                delta := (ev.Has("dir") && ev["dir"] = "up") ? 120 : -120
                DllCall("mouse_event", "UInt", 0x0800, "Int", 0, "Int", 0, "Int", delta, "UPtr", 0)
        }
    }

    _waitWhilePaused() {
        while this.pauseRequested && !this.stopRequested
            Sleep 50
    }

    _releaseHeldKeys() {
        for key, _ in this.keysHeld.Clone() {
            try Send "{" key " up}"
        }
        this.keysHeld := Map()
    }

    ; ==================== GLOBAL VARIABLES PERSISTENCE ====================

    static _globalsPath() {
        return A_ScriptDir "\globals.json"
    }

    static _loadGlobals() {
        if Player._globalsLoaded
            return
        path := Player._globalsPath()
        if FileExist(path) {
            try {
                text := FileRead(path, "UTF-8")
                data := JSON.parse(text)
                if data is Map
                    Player.globalVars := data
            } catch as e {
                Logger.Warn("Failed to load global vars: " e.Message)
            }
        }
        Player._globalsLoaded := true
    }

    static _saveGlobals() {
        if Player.globalVars.Count = 0
            return
        try {
            path := Player._globalsPath()
            text := JSON.stringify(Player.globalVars, "  ")
            tmp := path ".tmp"
            if FileExist(tmp)
                FileDelete(tmp)
            FileAppend(text, tmp, "UTF-8")
            if FileExist(path)
                FileDelete(path)
            FileMove(tmp, path)
        } catch as e {
            Logger.Warn("Failed to save global vars: " e.Message)
        }
    }
}
