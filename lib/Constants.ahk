#Requires AutoHotkey v2.0

; All cross-module constants live as static properties on Cfg.
; (AHK v2 functions and methods are assume-local; reading a bare global from
; a method would require a `global` declaration in every method. Static
; properties bypass that problem and read as `Cfg.NAME`.)

class Cfg {
    static APP_NAME    := "MacroForge"
    static APP_VERSION := "0.3.0"

    static PRESETS_DIR := A_ScriptDir "\presets"
    static LOGS_DIR    := A_ScriptDir "\logs"
    static IMAGES_DIR  := A_ScriptDir "\images"

    ; Built-in presets are immutable: rewritten on every startup from
    ; PresetManager._builtinPreset(), and Save/Delete/Rename refuse them.
    static BUILTIN_NAMES := ["Autoclicker", "Roblox_WASD_Patrol", "Conditional_ImageCheck"]

    ; All known step types. The StepEditor uses this list to populate its type
    ; combo box, and Player switches on these strings.
    static STEP_TYPES := [
        "click",
        "move",
        "drag",
        "scroll",
        "key",
        "keyDown",
        "keyUp",
        "send",
        "sleep",
        "loop",
        "ifImage",
        "ifPixel",
        "ifText",
        "ifWindow",
        "ifVar",
        "setVar",
        "call",
        "webhook",
        "label",
        "log",
        "break",
        "stop",
        "focusWindow",
        "waitForImage",
        "waitForPixel",
        "loopWhileImage",
        "loopUntilPixel",
        "loopWhileVar"
    ]
}
