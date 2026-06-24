#Requires AutoHotkey v2.0

; Centralized theming for the native AHK shell + the WebView board.
;
; A theme is a Map of named colors (hex strings WITHOUT the 0x prefix so they
; can be fed straight to Gui/control .Opt("Background...") and SetFont("c...")).
; The same palette is also serialized to the WebView as an `applyTheme` message
; so the visual node board stays visually in sync with the native window.
;
; Persisted choice lives in config.json next to the script.

class Theme {
    static current := "dark"

    static _palettes := Map(
        "dark", Map(
            "name",        "dark",
            ; Neutral near-black (de-blued). Was 12131C / 1B1D2A (blue-tinted).
            "bg",          "0D0E11",
            "surface",     "15161B",
            "surfaceAlt",  "1C1E25",
            ; Thin GRAY hairline border instead of the old bright blue 2E3350.
            "border",      "3A3E48",
            "text",        "E8EAF0",
            "textDim",     "969BA8",
            "accent",      "6C8CFF",
            "accentText",  "FFFFFF",
            "success",     "3FB950",
            "warn",        "E3B341",
            "danger",      "F85149",
            "titleDark",   "1"
        ),
        "light", Map(
            "name",        "light",
            "bg",          "F4F6FB",
            "surface",     "FFFFFF",
            "surfaceAlt",  "ECEFF6",
            "border",      "D4DAE6",
            "text",        "1C2230",
            "textDim",     "5C6478",
            "accent",      "2F6BFF",
            "accentText",  "FFFFFF",
            "success",     "1E8E3E",
            "warn",        "B8860B",
            "danger",      "D93025",
            "titleDark",   "0"
        )
    )

    static Names() {
        return ["dark", "light"]
    }

    static Has(name) {
        return Theme._palettes.Has(name)
    }

    static Palette(name := "") {
        if name = ""
            name := Theme.current
        if !Theme._palettes.Has(name)
            name := "dark"
        return Theme._palettes[name]
    }

    static Color(key, name := "") {
        p := Theme.Palette(name)
        return p.Has(key) ? p[key] : "000000"
    }

    static _configPath() {
        return A_ScriptDir "\config.json"
    }

    static Load() {
        path := Theme._configPath()
        if FileExist(path) {
            try {
                data := JSON.parse(FileRead(path, "UTF-8"))
                if data is Map && data.Has("theme") && Theme._palettes.Has(data["theme"])
                    Theme.current := data["theme"]
            } catch as e {
                try Logger.Warn("Theme.Load failed: " e.Message)
            }
        }
        return Theme.current
    }

    static Save() {
        try {
            path := Theme._configPath()
            text := JSON.stringify(Map("theme", Theme.current), "  ")
            tmp := path ".tmp"
            if FileExist(tmp)
                FileDelete(tmp)
            FileAppend(text, tmp, "UTF-8")
            if FileExist(path)
                FileDelete(path)
            FileMove(tmp, path)
        } catch as e {
            try Logger.Warn("Theme.Save failed: " e.Message)
        }
    }

    static WebPayload(name := "") {
        p := Theme.Palette(name)
        out := Map("action", "applyTheme")
        for k, v in p
            out[k] := v
        return out
    }
}
