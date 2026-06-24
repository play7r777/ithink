#Requires AutoHotkey v2.0

; ============================================================================
; ThemedButton - owner-drawn, theme-aware push buttons.
;
; Native AHK/Win32 buttons ignore Background tinting and offer no hover,
; pressed, accent, or rounded-corner styling. This module converts ordinary
; Gui.Button controls into BS_OWNERDRAW buttons and paints them ourselves with
; GDI + GDI+ so they pick up the active Theme palette and render flat, rounded,
; with hover / pressed / disabled / focus states.
;
; Usage (after the GUI and all buttons exist):
;     ThemedButton.Init()                         ; once
;     ThemedButton.Attach(myBtn)                  ; secondary (default)
;     ThemedButton.Attach(saveBtn, "primary")     ; accent
;     ThemedButton.Attach(startBtn, "success")    ; green
;     ThemedButton.Attach(stopBtn, "danger")      ; red
; On a theme switch call ThemedButton.RefreshAll() to repaint every button.
;
; Roles: "secondary" (default) | "primary" | "success" | "danger".
; Colors are pulled live from Theme.Palette(), so theme changes need only an
; invalidate, never a re-attach.
; ============================================================================

class ThemedButton {
    static _byHwnd     := Map()   ; control hwnd -> ThemedButton instance
    static _gdipToken  := 0
    static _wmHooked   := false
    static _subclassCb := 0
    static _radius     := 9       ; corner radius in px

    ; ---- lifecycle -------------------------------------------------------

    static Init() {
        if !ThemedButton._wmHooked {
            OnMessage(0x2B, ObjBindMethod(ThemedButton, "_onDrawItem")) ; WM_DRAWITEM
            ThemedButton._wmHooked := true
        }
        ThemedButton._ensureGdip()
    }

    ; Convert an existing Gui.Button into an owner-drawn themed button.
    ;   role      : "secondary" | "primary" | "success" | "danger"
    ;   behindKey : palette key used to erase the control rect behind the
    ;               rounded shape (defaults to "bg"). Set to "surface" for
    ;               buttons sitting on a raised panel if corners look off.
    static Attach(ctrl, role := "secondary", behindKey := "bg") {
        if !(ctrl is Gui.Control)
            return ""
        ThemedButton._ensureGdip()
        inst := ThemedButton(ctrl, role, behindKey)
        ThemedButton._byHwnd[ctrl.Hwnd] := inst
        ThemedButton._makeOwnerDrawn(ctrl.Hwnd)
        ThemedButton._subclass(ctrl.Hwnd)
        return inst
    }

    static RefreshAll() {
        for hwnd, inst in ThemedButton._byHwnd
            try DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)
    }

    __New(ctrl, role, behindKey) {
        this.ctrl      := ctrl
        this.role      := role
        this.behindKey := behindKey
        this.hover     := false
    }

    ; ---- style + subclassing --------------------------------------------

    static _makeOwnerDrawn(hwnd) {
        static GWL_STYLE := -16, BS_OWNERDRAW := 0xB, BS_TYPEMASK := 0xF
        style := ThemedButton._getLong(hwnd, GWL_STYLE)
        style := (style & ~BS_TYPEMASK) | BS_OWNERDRAW
        ThemedButton._setLong(hwnd, GWL_STYLE, style)
        DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)
    }

    static _getLong(hwnd, idx) {
        return (A_PtrSize = 8)
            ? DllCall("GetWindowLongPtrW", "Ptr", hwnd, "Int", idx, "Ptr")
            : DllCall("GetWindowLongW",    "Ptr", hwnd, "Int", idx, "Int")
    }
    static _setLong(hwnd, idx, val) {
        return (A_PtrSize = 8)
            ? DllCall("SetWindowLongPtrW", "Ptr", hwnd, "Int", idx, "Ptr", val, "Ptr")
            : DllCall("SetWindowLongW",    "Ptr", hwnd, "Int", idx, "Int", val, "Int")
    }

    static _subclass(hwnd) {
        if !ThemedButton._subclassCb
            ThemedButton._subclassCb := CallbackCreate(ObjBindMethod(ThemedButton, "_subclassProc"), , 6)
        DllCall("comctl32\SetWindowSubclass", "Ptr", hwnd, "Ptr", ThemedButton._subclassCb, "Ptr", 1, "Ptr", 0)
    }

    static _subclassProc(hWnd, uMsg, wParam, lParam, uId, refData) {
        static WM_MOUSEMOVE := 0x200, WM_MOUSELEAVE := 0x2A3
        if ThemedButton._byHwnd.Has(hWnd) {
            inst := ThemedButton._byHwnd[hWnd]
            if (uMsg = WM_MOUSEMOVE) {
                if !inst.hover {
                    inst.hover := true
                    ThemedButton._trackLeave(hWnd)
                    DllCall("InvalidateRect", "Ptr", hWnd, "Ptr", 0, "Int", 1)
                }
            } else if (uMsg = WM_MOUSELEAVE) {
                if inst.hover {
                    inst.hover := false
                    DllCall("InvalidateRect", "Ptr", hWnd, "Ptr", 0, "Int", 1)
                }
            }
        }
        return DllCall("comctl32\DefSubclassProc", "Ptr", hWnd, "UInt", uMsg
            , "Ptr", wParam, "Ptr", lParam, "Ptr")
    }

    static _trackLeave(hwnd) {
        tme := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", tme.Size, tme, 0)   ; cbSize
        NumPut("UInt", 0x2, tme, 4)        ; dwFlags = TME_LEAVE
        NumPut("Ptr",  hwnd, tme, 8)       ; hwndTrack
        DllCall("TrackMouseEvent", "Ptr", tme)
    }

    ; ---- WM_DRAWITEM dispatch -------------------------------------------

    static _onDrawItem(wParam, lParam, msg, hwnd) {
        ; DRAWITEMSTRUCT offsets differ between 32- and 64-bit builds.
        if (NumGet(lParam, 0, "UInt") != 4)   ; CtlType != ODT_BUTTON
            return
        if (A_PtrSize = 8) {
            hCtl := NumGet(lParam, 24, "Ptr")
            hDC  := NumGet(lParam, 32, "Ptr")
            rOff := 40
        } else {
            hCtl := NumGet(lParam, 20, "Ptr")
            hDC  := NumGet(lParam, 24, "Ptr")
            rOff := 28
        }
        if !ThemedButton._byHwnd.Has(hCtl)
            return
        state := NumGet(lParam, 16, "UInt")   ; itemState
        L := NumGet(lParam, rOff,      "Int"), T := NumGet(lParam, rOff + 4,  "Int")
        R := NumGet(lParam, rOff + 8,  "Int"), B := NumGet(lParam, rOff + 12, "Int")
        ThemedButton._byHwnd[hCtl]._paint(hDC, L, T, R, B, state)
        return 1
    }

    ; ---- painting --------------------------------------------------------

    _paint(hDC, L, T, R, B, state) {
        w := R - L, h := B - T
        if (w <= 0 || h <= 0)
            return
        disabled := (state & 0x4)  ? true : false   ; ODS_DISABLED
        pressed  := (state & 0x1)  ? true : false   ; ODS_SELECTED
        focused  := (state & 0x10) ? true : false   ; ODS_FOCUS
        c   := this._colors(disabled, pressed, this.hover && !disabled)
        pal := Theme.Palette()
        behindHex := (this.behindKey != "" && pal.Has(this.behindKey)) ? pal[this.behindKey] : pal["bg"]
        behind := ThemedButton._h(behindHex)

        ; 1) erase the full rect with the parent background so the corners
        ;    outside the rounded shape blend in.
        this._fillRect(hDC, L, T, w, h, behind)
        ; 2) anti-aliased rounded fill (+ border for secondary buttons).
        ;    A subtle top-lit vertical gradient gives the buttons the same
        ;    "lit from above" feel as the board's gradient node headers.
        argbTop := 0
        if (!disabled) {
            topF := ThemedButton._blend(c.fill, 0xFFFFFF, 0.10)
            botF := ThemedButton._blend(c.fill, 0x000000, 0.08)
            argbTop := ThemedButton._argbI(topF)
            fillArgb := ThemedButton._argbI(botF)
        } else {
            fillArgb := ThemedButton._argbI(c.fill)
        }
        ThemedButton._roundFill(hDC, L, T, w, h, ThemedButton._radius
            , fillArgb
            , c.border >= 0 ? ThemedButton._argbI(c.border) : 0
            , argbTop)
        ; 3) focus ring just inside the edge.
        if (focused && !disabled)
            ThemedButton._roundFill(hDC, L + 1, T + 1, w - 2, h - 2
                , ThemedButton._radius - 1, 0, ThemedButton._argbI(ThemedButton._h(pal["accent"])))
        ; 4) caption.
        this._drawText(hDC, L, T, R, B, c.text)
    }

    _colors(disabled, pressed, hover) {
        pal := Theme.Palette()
        accent     := ThemedButton._h(pal["accent"])
        accentText := ThemedButton._h(pal["accentText"])
        success    := ThemedButton._h(pal["success"])
        danger     := ThemedButton._h(pal["danger"])
        surfaceAlt := ThemedButton._h(pal["surfaceAlt"])
        surface    := ThemedButton._h(pal["surface"])
        text       := ThemedButton._h(pal["text"])
        textDim    := ThemedButton._h(pal["textDim"])
        border     := ThemedButton._h(pal["border"])
        white := 0xFFFFFF, black := 0x000000

        brd := -1
        switch this.role {
            case "primary": fill := accent,  ftext := accentText
            case "success": fill := success, ftext := white
            case "danger":  fill := danger,  ftext := white
            default:        fill := surfaceAlt, ftext := text, brd := border
        }
        if disabled {
            return { fill: surface, text: textDim, border: border }
        }
        if pressed
            fill := ThemedButton._blend(fill, black, 0.20)
        else if hover
            fill := ThemedButton._blend(fill, white, this.role = "secondary" ? 0.12 : 0.16)
        if (this.role = "secondary" && (hover || pressed))
            brd := ThemedButton._blend(border, white, 0.25)
        return { fill: fill, text: ftext, border: brd }
    }

    _fillRect(hDC, x, y, w, h, rgb) {
        br := DllCall("gdi32\CreateSolidBrush", "UInt", ThemedButton._bgr(rgb), "Ptr")
        rc := Buffer(16, 0)
        NumPut("Int", x, "Int", y, "Int", x + w, "Int", y + h, rc)
        DllCall("user32\FillRect", "Ptr", hDC, "Ptr", rc, "Ptr", br)
        DllCall("gdi32\DeleteObject", "Ptr", br)
    }

    _drawText(hDC, L, T, R, B, rgb) {
        txt := ""
        try txt := this.ctrl.Text
        if (txt = "")
            return
        DllCall("gdi32\SetBkMode", "Ptr", hDC, "Int", 1)              ; TRANSPARENT
        DllCall("gdi32\SetTextColor", "Ptr", hDC, "UInt", ThemedButton._bgr(rgb))
        hFont := DllCall("SendMessage", "Ptr", this.ctrl.Hwnd, "UInt", 0x31, "Ptr", 0, "Ptr", 0, "Ptr") ; WM_GETFONT
        old := hFont ? DllCall("gdi32\SelectObject", "Ptr", hDC, "Ptr", hFont, "Ptr") : 0
        rc := Buffer(16, 0)
        NumPut("Int", L, "Int", T, "Int", R, "Int", B, rc)
        ; DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS
        DllCall("user32\DrawTextW", "Ptr", hDC, "Str", txt, "Int", -1, "Ptr", rc, "UInt", 0x1 | 0x4 | 0x20 | 0x8000)
        if old
            DllCall("gdi32\SelectObject", "Ptr", hDC, "Ptr", old)
    }

    ; ---- GDI+ ------------------------------------------------------------

    static _ensureGdip() {
        if ThemedButton._gdipToken
            return
        if !DllCall("GetModuleHandle", "Str", "gdiplus", "Ptr")
            DllCall("LoadLibrary", "Str", "gdiplus")
        si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", 1, si, 0)   ; GdiplusVersion
        token := 0
        DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)
        ThemedButton._gdipToken := token
    }

    ; argbTop (optional): when nonzero, the rounded shape is filled with a
    ; vertical gradient from argbTop (top) to argbFill (bottom). Otherwise a
    ; flat argbFill is used.
    static _roundFill(hDC, x, y, w, h, r, argbFill, argbBorder := 0, argbTop := 0) {
        if !ThemedButton._gdipToken
            return
        g := 0
        DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hDC, "Ptr*", &g)
        if !g
            return
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)   ; AntiAlias
        path := 0
        DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path)
        inset := 0.75
        ThemedButton._roundPath(path, x + inset, y + inset, w - inset * 2, h - inset * 2, r)
        if (argbFill && argbTop) {
            ; Vertical linear gradient brush spanning the button rect.
            rectF := Buffer(16, 0)
            NumPut("Float", x, "Float", y, "Float", (w > 0 ? w : 1), "Float", (h > 0 ? h : 1), rectF)
            lbr := 0
            ; mode 1 = LinearGradientModeVertical, wrap 1 = WrapModeTileFlipX
            DllCall("gdiplus\GdipCreateLineBrushFromRect", "Ptr", rectF, "UInt", argbTop, "UInt", argbFill, "Int", 1, "Int", 1, "Ptr*", &lbr)
            if lbr {
                DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", lbr, "Ptr", path)
                DllCall("gdiplus\GdipDeleteBrush", "Ptr", lbr)
            } else {
                br := 0
                DllCall("gdiplus\GdipCreateSolidFill", "UInt", argbFill, "Ptr*", &br)
                DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", br, "Ptr", path)
                DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
            }
        } else if argbFill {
            br := 0
            DllCall("gdiplus\GdipCreateSolidFill", "UInt", argbFill, "Ptr*", &br)
            DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", br, "Ptr", path)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
        }
        if argbBorder {
            pen := 0
            DllCall("gdiplus\GdipCreatePen1", "UInt", argbBorder, "Float", 1.2, "Int", 2, "Ptr*", &pen)
            DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", path)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    }

    static _roundPath(path, x, y, w, h, r) {
        if (r * 2 > w)
            r := w / 2
        if (r * 2 > h)
            r := h / 2
        d := r * 2
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x,         "Float", y,         "Float", d, "Float", d, "Float", 180, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y,         "Float", d, "Float", d, "Float", 270, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0,   "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x,         "Float", y + h - d, "Float", d, "Float", d, "Float", 90,  "Float", 90)
        DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
    }

    ; ---- color math ------------------------------------------------------

    static _h(hex) {
        return Integer("0x" hex)
    }
    static _bgr(rgb) {   ; RRGGBB int -> COLORREF 0x00BBGGRR
        return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
    }
    static _argbI(rgb) {   ; RRGGBB int -> opaque 0xFFRRGGBB
        return 0xFF000000 | (rgb & 0xFFFFFF)
    }
    static _blend(a, b, t) {
        ra := (a >> 16) & 0xFF, ga := (a >> 8) & 0xFF, ba := a & 0xFF
        rb := (b >> 16) & 0xFF, gb := (b >> 8) & 0xFF, bb := b & 0xFF
        r  := Round(ra + (rb - ra) * t)
        g  := Round(ga + (gb - ga) * t)
        bl := Round(ba + (bb - ba) * t)
        return (r << 16) | (g << 8) | bl
    }
}
