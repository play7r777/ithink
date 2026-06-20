#Requires AutoHotkey v2.0

; Dependencies (guarded by AHK against double-inclusion when run via MacroForge.ahk)
#Include Logger.ahk

; Input recorder. Captures keyboard/mouse events with HIGH-RESOLUTION
; timestamps and stores a raw timeline for frame-accurate playback.
;
; Two output modes:
;   1. rawTimeline  – the raw event list with ms-accurate timestamps.
;                     Used by Player for TinyTask-like exact replay.
;   2. _buildSteps  – converts timeline to editable step list for the GUI.
;
; Why pass-through hotkeys (~* prefix): we want the keystroke to still reach
; whatever app is focused while we log it.

class Recorder {
    active := false
    events := []
    startTick := 0
    minGapMs := 30
    mouseSampleMs := 15        ; faster sampling for smoother mouse paths
    moveTimer := ""
    boundKeys := []
    onStateChange := ""
    captureMouseMove := true

    SetStateCallback(cb) {
        this.onStateChange := cb
    }

    Start(options := "") {
        if this.active
            return
        this.events := []
        if options is Map && options.Has("captureMouseMove")
            this.captureMouseMove := options["captureMouseMove"]
        
        ; Use QPC for high-resolution timing
        DllCall("QueryPerformanceFrequency", "Int64*", &freq := 0)
        this._qpcFreq := freq
        DllCall("QueryPerformanceCounter", "Int64*", &startQPC := 0)
        this._qpcStart := startQPC
        this.startTick := A_TickCount

        this._bindHotkeys()
        if this.captureMouseMove {
            this.moveTimer := ObjBindMethod(this, "_sampleMouse")
            SetTimer this.moveTimer, this.mouseSampleMs
        }
        this.active := true
        if this.onStateChange is Func
            this.onStateChange.Call("recording")
        Logger.Info("Recorder started (high-res timing)")
    }

    ; Returns ms elapsed since recording started, using QPC for sub-ms accuracy
    _elapsed() {
        DllCall("QueryPerformanceCounter", "Int64*", &now := 0)
        return Integer(((now - this._qpcStart) * 1000) / this._qpcFreq)
    }

    Stop() {
        if !this.active
            return []
        this.active := false
        this._unbindHotkeys()
        if this.moveTimer != "" {
            SetTimer this.moveTimer, 0
            this.moveTimer := ""
        }
        if this.onStateChange is Func
            this.onStateChange.Call("idle")
        Logger.Info("Recorder stopped, " this.events.Length " raw events captured")
        return this._buildSteps()
    }

    ; Get the raw event timeline for precise replay
    GetRawTimeline() {
        return this.events
    }

    _bindHotkeys() {
        this.boundKeys := []
        Loop 26 {
            ch := Chr(96 + A_Index)
            this._bindKey(ch)
        }
        Loop 10 {
            this._bindKey(Chr(47 + A_Index))
        }
        for k in ["Space","Enter","Tab","Shift","Ctrl","Alt"
                ,"Left","Right","Up","Down"
                ,"F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12"
                ,"LButton","RButton","MButton","XButton1","XButton2"
                ; Punctuation / symbol keys (SC codes avoid layout ambiguity but
                ; AHK key names work for the common US set used in games/macros).
                ,"[","]",";","'","``","/",".",",","-","=","\"
                ,"Backspace","Delete","Insert","Home","End","PgUp","PgDn"
                ,"Escape","CapsLock","NumLock","PrintScreen","ScrollLock","Pause"
                ,"AppsKey","LWin","RWin"
                ,"Numpad0","Numpad1","Numpad2","Numpad3","Numpad4","Numpad5"
                ,"Numpad6","Numpad7","Numpad8","Numpad9"
                ,"NumpadDot","NumpadDiv","NumpadMult","NumpadAdd","NumpadSub","NumpadEnter"
                ; Multimedia / browser keys.
                ,"Volume_Up","Volume_Down","Volume_Mute"
                ,"Media_Play_Pause","Media_Stop","Media_Next","Media_Prev"
                ,"Browser_Back","Browser_Forward","Browser_Home","Browser_Search"
                ,"Launch_Mail","Launch_Media","Launch_App1","Launch_App2"]
            this._bindKey(k)

        ; Mouse wheel: WheelUp / WheelDown fire as single events (no up/down
        ; pair), so they map directly to a "scroll" step rather than key pairs.
        this._bindWheel("WheelUp", "up")
        this._bindWheel("WheelDown", "down")
    }

    _bindWheel(wheelKey, dir) {
        name := "~*" wheelKey
        try {
            Hotkey name, ObjBindMethod(this, "_onWheel", dir), "On"
            this.boundKeys.Push(name)
        }
    }

    _onWheel(dir, *) {
        if !this.active
            return
        MouseGetPos(&mx, &my)
        this.events.Push(Map(
            "t", this._elapsed(),
            "kind", "wheel",
            "dir", dir,
            "x", mx, "y", my
        ))
    }

    _bindKey(k) {
        downName := "~*" k
        upName   := "~*" k " up"
        try {
            Hotkey downName, ObjBindMethod(this, "_onDown", k), "On"
            this.boundKeys.Push(downName)
        }
        try {
            Hotkey upName, ObjBindMethod(this, "_onUp", k), "On"
            this.boundKeys.Push(upName)
        }
    }

    _unbindHotkeys() {
        for name in this.boundKeys
            try Hotkey name, "Off"
        this.boundKeys := []
    }

    _onDown(key, *) {
        if !this.active
            return
        if key = "F4" || key = "Escape"
            return
        MouseGetPos(&mx, &my)
        this.events.Push(Map(
            "t", this._elapsed(),
            "kind", this._isMouseBtn(key) ? "mouseDown" : "keyDown",
            "key", key,
            "x", mx, "y", my
        ))
    }

    _onUp(key, *) {
        if !this.active
            return
        if key = "F4" || key = "Escape"
            return
        MouseGetPos(&mx, &my)
        this.events.Push(Map(
            "t", this._elapsed(),
            "kind", this._isMouseBtn(key) ? "mouseUp" : "keyUp",
            "key", key,
            "x", mx, "y", my
        ))
    }

    _sampleMouse() {
        if !this.active
            return
        MouseGetPos(&mx, &my)
        this.events.Push(Map(
            "t", this._elapsed(),
            "kind", "moveSample",
            "x", mx, "y", my
        ))
    }

    _isMouseBtn(k) {
        return k = "LButton" || k = "RButton" || k = "MButton" || k = "XButton1" || k = "XButton2"
    }

    ; ============ BUILD EDITABLE STEPS (for GUI display) ============

    _buildSteps() {
        steps := []
        if this.events.Length = 0
            return steps
        lastT := 0
        lastMoveX := -1, lastMoveY := -1
        for ev in this.events {
            gap := ev["t"] - lastT
            if gap >= this.minGapMs && steps.Length > 0
                steps.Push(Map("type", "sleep", "ms", gap))
            switch ev["kind"] {
                case "moveSample":
                    if ev["x"] != lastMoveX || ev["y"] != lastMoveY {
                        steps.Push(Map("type", "move", "x", ev["x"], "y", ev["y"], "speed", 0))
                        lastMoveX := ev["x"], lastMoveY := ev["y"]
                    }
                case "mouseDown":
                    btn := this._btnName(ev["key"])
                    steps.Push(Map("type", "click", "button", btn, "x", ev["x"], "y", ev["y"], "count", 1))
                case "mouseUp":
                    ; click emitted on down; ignore release
                case "wheel":
                    ; Merge consecutive wheel ticks in the same direction into a
                    ; single scroll step (amount = number of ticks).
                    last := steps.Length > 0 ? steps[steps.Length] : ""
                    if last is Map && last["type"] = "scroll" && last["direction"] = ev["dir"]
                        last["amount"] += 1
                    else
                        steps.Push(Map("type", "scroll", "direction", ev["dir"], "amount", 1))
                case "keyDown":
                    steps.Push(Map("type", "keyDown", "key", ev["key"]))
                case "keyUp":
                    steps.Push(Map("type", "keyUp", "key", ev["key"]))
            }
            lastT := ev["t"]
        }
        return this._collapseKeyPairs(steps)
    }

    _btnName(k) {
        switch k {
            case "LButton": return "left"
            case "RButton": return "right"
            case "MButton": return "middle"
            default: return "left"
        }
    }

    _collapseKeyPairs(steps) {
        out := []
        i := 1
        while i <= steps.Length {
            s := steps[i]
            if s["type"] = "keyDown" {
                key := s["key"]
                sleepMs := 0
                j := i + 1
                if j <= steps.Length && steps[j]["type"] = "sleep" {
                    sleepMs := steps[j]["ms"]
                    j++
                }
                if j <= steps.Length && steps[j]["type"] = "keyUp" && steps[j]["key"] = key {
                    if sleepMs = 0
                        out.Push(Map("type", "key", "key", key))
                    else
                        out.Push(Map("type", "key", "key", key, "duration", sleepMs))
                    i := j + 1
                    continue
                }
            }
            out.Push(s)
            i++
        }
        return out
    }
}
