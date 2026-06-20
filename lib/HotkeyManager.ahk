#Requires AutoHotkey v2.0

; Dependencies (guarded by AHK against double-inclusion when run via MacroForge.ahk)
#Include Logger.ahk

; Owns the global hotkeys for Start / Stop / Pause / Panic.
; Rebind() turns off whatever was registered before and registers the new
; mapping. Bad hotkey strings are skipped with a warning, not thrown.

class HotkeyManager {
    bindings := Map()
    handlers := ""

    __New(handlers) {
        this.handlers := handlers
    }

    Rebind(hotkeys) {
        this.UnbindAll()
        for action, key in hotkeys {
            if !this.handlers.Has(action)
                continue
            if !(key is String) || key = "" || key = "-"
                continue
            handler := this.handlers[action]
            try {
                Hotkey key, handler, "On"
                this.bindings[key] := action
                Logger.Info("Bound " action " -> " key)
            } catch as e {
                Logger.Warn("Failed to bind " action " to '" key "': " e.Message)
            }
        }
    }

    UnbindAll() {
        for key, _ in this.bindings.Clone() {
            try Hotkey key, "Off"
        }
        this.bindings := Map()
    }
}
