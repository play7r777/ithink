#Requires AutoHotkey v2.0

; Dependencies (guarded by AHK against double-inclusion when run via MacroForge.ahk)
#Include Constants.ahk
#Include Logger.ahk
#Include JSON.ahk

; Disk I/O for preset files. Each preset is a JSON document under presets\.

class PresetManager {
    ; Cache of loaded+normalized presets, keyed by name. Avoids re-reading
    ; and re-parsing JSON from disk on every `call` step during playback.
    ; Invalidated whenever a preset is written, deleted, or renamed.
    static _cache := Map()

    static _cacheGet(name) {
        return PresetManager._cache.Has(name) ? PresetManager._cache[name] : ""
    }
    static _cacheInvalidate(name := "") {
        if name = ""
            PresetManager._cache := Map()
        else if PresetManager._cache.Has(name)
            PresetManager._cache.Delete(name)
    }

    static defaultHotkeys() {
        return Map("start", "F1", "stop", "F2", "pause", "F3", "panic", "^+Esc")
    }

    static defaultSettings() {
        return Map(
            "speedMultiplier", 1.0,
            "repeatCount",     1,
            "targetWindow",    "",
            "stopOnError",     1,
            "focusOnStart",    0,
            "startDelayMs",    1000
        )
    }

    static NewPreset(name := "Untitled") {
        return Map(
            "name",        name,
            "description", "",
            "hotkeys",     PresetManager.defaultHotkeys(),
            "settings",    PresetManager.defaultSettings(),
            "steps",       []
        )
    }

    static List() {
        names := []
        seen := Map()
        if !DirExist(Cfg.PRESETS_DIR)
            DirCreate(Cfg.PRESETS_DIR)
        ; Built-ins are pinned at the top of the list, always present even if
        ; their files were deleted between EnsureBuiltins() and List().
        for n in Cfg.BUILTIN_NAMES {
            names.Push(n)
            seen[n] := true
        }
        Loop Files, Cfg.PRESETS_DIR "\*.json" {
            n := StrReplace(A_LoopFileName, ".json")
            if !seen.Has(n) {
                names.Push(n)
                seen[n] := true
            }
        }
        return names
    }

    static IsBuiltin(name) {
        for n in Cfg.BUILTIN_NAMES
            if n = name
                return true
        return false
    }

    ; Write the canonical body for every built-in to disk, ALWAYS overwriting
    ; any external edits. Called once on startup; this guarantees the 3 default
    ; presets are always present and pristine, even if a user manually edited them.
    static EnsureBuiltins() {
        if !DirExist(Cfg.PRESETS_DIR)
            DirCreate(Cfg.PRESETS_DIR)
        for name in Cfg.BUILTIN_NAMES {
            try PresetManager._writeBypass(PresetManager._builtinPreset(name))
            catch as e {
                try Logger.Warn("EnsureBuiltins " name ": " e.Message)
            }
        }
    }

    static _builtinPreset(name) {
        switch name {
            case "Autoclicker":            return PresetManager._builtinAutoclicker()
            case "Roblox_WASD_Patrol":     return PresetManager._builtinRobloxWasdPatrol()
            case "Conditional_ImageCheck": return PresetManager._builtinConditionalImageCheck()
        }
        throw Error("Unknown builtin: " name)
    }

    static _builtinAutoclicker() {
        return Map(
            "name",        "Autoclicker",
            "description", "Простой автокликер. Кликает левой кнопкой каждые 100мс, пока работает (repeatCount=0). [Встроенный пресет — нельзя изменить. Сделайте копию через New, если нужно настроить.]",
            "hotkeys",     PresetManager.defaultHotkeys(),
            "settings",    Map(
                "speedMultiplier", 1.0,
                "repeatCount",     0,
                "targetWindow",    "",
                "stopOnError",     1,
                "focusOnStart",    0,
                "startDelayMs",    1000
            ),
            "steps", [
                Map("type", "click", "button", "left", "count", 1),
                Map("type", "sleep", "ms", 100)
            ]
        )
    }

    static _builtinRobloxWasdPatrol() {
        return Map(
            "name",        "Roblox_WASD_Patrol",
            "description", "Пример для любой игры с WASD-управлением (Roblox в т.ч.). Идёт квадратом: 1с W, 1с D, 1с S, 1с A, между ними короткие паузы. focusOnStart активирует окно Roblox перед запуском. [Встроенный пресет — нельзя изменить.]",
            "hotkeys",     PresetManager.defaultHotkeys(),
            "settings",    Map(
                "speedMultiplier", 1.0,
                "repeatCount",     0,
                "targetWindow",    "ahk_exe RobloxPlayerBeta.exe",
                "stopOnError",     1,
                "focusOnStart",    1,
                "startDelayMs",    1500
            ),
            "steps", [
                Map("type", "loop", "count", 0, "steps", [
                    Map("type", "key",   "key", "w", "duration", 1000),
                    Map("type", "sleep", "ms",  100),
                    Map("type", "key",   "key", "d", "duration", 1000),
                    Map("type", "sleep", "ms",  100),
                    Map("type", "key",   "key", "s", "duration", 1000),
                    Map("type", "sleep", "ms",  100),
                    Map("type", "key",   "key", "a", "duration", 1000),
                    Map("type", "sleep", "ms",  100)
                ])
            ]
        )
    }

    static _builtinConditionalImageCheck() {
        return Map(
            "name",        "Conditional_ImageCheck",
            "description", "Пример условной логики (как ветвление в NatroMacro): каждые 2 секунды ищет images/reward.png в области (0,0)-(800,600). Если найдено — кликает по (400,300) и пишет в лог; если нет — жмёт Space. Положите свой PNG в images/. [Встроенный пресет — нельзя изменить.]",
            "hotkeys",     PresetManager.defaultHotkeys(),
            "settings",    Map(
                "speedMultiplier", 1.0,
                "repeatCount",     0,
                "targetWindow",    "",
                "stopOnError",     0,
                "focusOnStart",    0,
                "startDelayMs",    1000
            ),
            "steps", [
                Map("type", "loop", "count", 0, "steps", [
                    Map("type", "ifImage",
                        "image",     "reward.png",
                        "variation", 30,
                        "x1", 0, "y1", 0, "x2", 800, "y2", 600,
                        "thenSteps", [
                            Map("type", "log",   "message", "Reward found, clicking."),
                            Map("type", "click", "button",  "left", "x", 400, "y", 300, "count", 1)
                        ],
                        "elseSteps", [
                            Map("type", "log", "message", "No reward, pressing space."),
                            Map("type", "key", "key",     "Space")
                        ]),
                    Map("type", "sleep", "ms", 2000)
                ])
            ]
        )
    }

    static PathFor(name) {
        return Cfg.PRESETS_DIR "\" PresetManager._sanitize(name) ".json"
    }

    static Load(name) {
        if (cached := PresetManager._cacheGet(name)) != ""
            return cached
        path := PresetManager.PathFor(name)
        if !FileExist(path)
            throw Error("Preset not found: " name)
        text := FileRead(path, "UTF-8")
        data := JSON.parse(text)
        preset := PresetManager._normalize(data, name)
        PresetManager._cache[name] := preset
        return preset
    }

    static Save(preset) {
        if PresetManager.IsBuiltin(preset["name"])
            throw Error("Built-in preset is read-only: " preset["name"])
        PresetManager._writeBypass(preset)
    }

    ; Internal write — used by Save() after the built-in guard and by
    ; EnsureBuiltins() to lay down canonical bodies on startup.
    static _writeBypass(preset) {
        if !DirExist(Cfg.PRESETS_DIR)
            DirCreate(Cfg.PRESETS_DIR)
        PresetManager._cacheInvalidate(preset["name"])
        path := PresetManager.PathFor(preset["name"])
        text := JSON.stringify(preset, "  ")
        tmp := path ".tmp"
        if FileExist(tmp)
            FileDelete(tmp)
        FileAppend(text, tmp, "UTF-8")
        if FileExist(path)
            FileDelete(path)
        FileMove(tmp, path)
    }

    static Delete(name) {
        if PresetManager.IsBuiltin(name)
            throw Error("Built-in preset cannot be deleted: " name)
        PresetManager._cacheInvalidate(name)
        path := PresetManager.PathFor(name)
        if FileExist(path)
            FileDelete(path)
    }

    static Import(filePath) {
        if !FileExist(filePath)
            throw Error("File not found: " filePath)
        text := FileRead(filePath, "UTF-8")
        data := JSON.parse(text)
        data := PresetManager._normalize(data, "Imported")
        name := data["name"]
        if PresetManager.IsBuiltin(name)
            name := name "_custom"
        data["name"] := name
        ; If name already exists, add suffix
        base := name
        counter := 1
        while FileExist(PresetManager.PathFor(name)) {
            counter++
            name := base "_" counter
        }
        data["name"] := name
        PresetManager._writeBypass(data)
        return name
    }

    static Rename(oldName, newName) {
        if PresetManager.IsBuiltin(oldName)
            throw Error("Built-in preset cannot be renamed: " oldName)
        if PresetManager.IsBuiltin(newName)
            throw Error("Cannot use a built-in name: " newName)
        p := PresetManager.Load(oldName)
        p["name"] := newName
        PresetManager.Save(p)
        if newName != oldName
            PresetManager.Delete(oldName)
    }

    static _sanitize(s) {
        s := Trim(s)
        for ch in ["/", "\", ":", "*", "?", '"', "<", ">", "|"]
            s := StrReplace(s, ch, "_")
        s := StrReplace(s, " ", "_")
        ; Remove trailing dots (Windows FS issue)
        while SubStr(s, -1) = "."
            s := SubStr(s, 1, -1)
        if s = ""
            s := "Untitled"
        return s
    }

    static _normalize(data, fallbackName) {
        if !(data is Map)
            throw Error("Preset must be a JSON object")
        if !data.Has("name") || data["name"] = ""
            data["name"] := fallbackName
        if !data.Has("description")
            data["description"] := ""
        if !data.Has("hotkeys") || !(data["hotkeys"] is Map)
            data["hotkeys"] := PresetManager.defaultHotkeys()
        else {
            for k, v in PresetManager.defaultHotkeys()
                if !data["hotkeys"].Has(k)
                    data["hotkeys"][k] := v
        }
        if !data.Has("settings") || !(data["settings"] is Map)
            data["settings"] := PresetManager.defaultSettings()
        else {
            for k, v in PresetManager.defaultSettings()
                if !data["settings"].Has(k)
                    data["settings"][k] := v
        }
        if !data.Has("steps") || !(data["steps"] is Array)
            data["steps"] := []
        return data
    }
}
