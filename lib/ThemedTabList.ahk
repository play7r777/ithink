#Requires AutoHotkey v2.0

; ============================================================================
; ThemedTab + ThemedList - owner-drawn, theme-aware tab strip and list box.
;
; Native Win32 tabs and list boxes ignore palette tinting and render with the
; system look (light tabs, white client edges, harsh selection bars). These two
; classes convert them to owner-drawn controls and paint them with the same
; GDI+ machinery as ThemedButton, so the top tabs (Steps/Board/Settings/...)
; and the preset list match the themed buttons and the WebView board.
;
; They deliberately reuse ThemedButton's static helpers (_roundFill, _argbI,
; _h, _bgr, _blend, _fillRect, _getLong, _setLong, _ensureGdip) so there is a
; single, already-proven GDI+ implementation.
;
; If a post-creation style toggle is ignored by a given Windows build, the
; control simply keeps its default (functional) drawing - nothing breaks.
; ============================================================================

class ThemedTab {
    static _byHwnd := Map()
    static _hooked := false
    static _radius := 8

    ; Static solid-rect fill (ThemedButton._fillRect is instance-only, so we
    ; provide our own that both ThemedTab and ThemedList can call statically).
    static _fill(hDC, x, y, w, h, rgb) {
        br := DllCall("gdi32\CreateSolidBrush", "UInt", ThemedButton._bgr(rgb), "Ptr")
        rc := Buffer(16, 0)
        NumPut("Int", x, "Int", y, "Int", x + w, "Int", y + h, rc)
        DllCall("user32\FillRect", "Ptr", hDC, "Ptr", rc, "Ptr", br)
        DllCall("gdi32\DeleteObject", "Ptr", br)
    }

    static Init() {
        if !ThemedTab._hooked {
            OnMessage(0x2B, ObjBindMethod(ThemedTab, "_onDrawItem"))   ; WM_DRAWITEM
            ThemedTab._hooked := true
        }
        ThemedButton._ensureGdip()
    }

    ; labels: array of tab captions in tab order (used to draw each tab text).
    static Attach(ctrl, labels) {
        if !(ctrl is Gui.Control)
            return ""
        ThemedTab.Init()
        inst := ThemedTab(ctrl, labels)
        ThemedTab._byHwnd[ctrl.Hwnd] := inst
        static GWL_STYLE := -16, TCS_OWNERDRAWFIXED := 0x2000
        style := ThemedButton._getLong(ctrl.Hwnd, GWL_STYLE)
        ThemedButton._setLong(ctrl.Hwnd, GWL_STYLE, style | TCS_OWNERDRAWFIXED)
        DllCall("InvalidateRect", "Ptr", ctrl.Hwnd, "Ptr", 0, "Int", 1)
        return inst
    }

    static RefreshAll() {
        for hwnd in ThemedTab._byHwnd
            try DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)
    }

    __New(ctrl, labels) {
        this.ctrl := ctrl
        this.labels := labels
    }

    static _onDrawItem(wParam, lParam, msg, hwnd) {
        if (NumGet(lParam, 0, "UInt") != 101)   ; CtlType != ODT_TAB
            return
        if (A_PtrSize = 8) {
            hCtl := NumGet(lParam, 24, "Ptr"), hDC := NumGet(lParam, 32, "Ptr"), rOff := 40
        } else {
            hCtl := NumGet(lParam, 20, "Ptr"), hDC := NumGet(lParam, 24, "Ptr"), rOff := 28
        }
        if !ThemedTab._byHwnd.Has(hCtl)
            return
        idx   := NumGet(lParam, 8, "UInt")     ; itemID = tab index
        state := NumGet(lParam, 16, "UInt")    ; itemState
        L := NumGet(lParam, rOff, "Int"),     T := NumGet(lParam, rOff + 4, "Int")
        R := NumGet(lParam, rOff + 8, "Int"), B := NumGet(lParam, rOff + 12, "Int")
        ThemedTab._byHwnd[hCtl]._paint(hDC, idx, L, T, R, B, state)
        return 1
    }

    _paint(hDC, idx, L, T, R, B, state) {
        pal := Theme.Palette()
        selected := (state & 0x1) ? true : false   ; ODS_SELECTED
        w := R - L, h := B - T
        if (w <= 0 || h <= 0)
            return
        ThemedTab._fill(hDC, L, T, w, h, ThemedButton._h(pal["bg"]))
        if selected {
            top := ThemedButton._blend(ThemedButton._h(pal["accent"]), 0xFFFFFF, 0.12)
            bot := ThemedButton._h(pal["accent"])
            txt := ThemedButton._h(pal["accentText"])
            brd := -1
        } else {
            top := ThemedButton._blend(ThemedButton._h(pal["surfaceAlt"]), 0xFFFFFF, 0.05)
            bot := ThemedButton._h(pal["surfaceAlt"])
            txt := ThemedButton._h(pal["textDim"])
            brd := ThemedButton._h(pal["border"])
        }
        ThemedButton._roundFill(hDC, L + 2, T + 2, w - 4, h - 3, ThemedTab._radius
            , ThemedButton._argbI(bot)
            , brd >= 0 ? ThemedButton._argbI(brd) : 0
            , ThemedButton._argbI(top))
        label := (idx + 1 <= this.labels.Length) ? this.labels[idx + 1] : ""
        ThemedTab._text(this.ctrl.Hwnd, hDC, label, L, T, R, B, txt, 0x1)
    }

    ; align: DT_LEFT (0) or DT_CENTER (0x1).
    static _text(ctrlHwnd, hDC, txt, L, T, R, B, rgb, align) {
        if (txt = "")
            return
        DllCall("gdi32\SetBkMode", "Ptr", hDC, "Int", 1)
        DllCall("gdi32\SetTextColor", "Ptr", hDC, "UInt", ThemedButton._bgr(rgb))
        hFont := DllCall("SendMessage", "Ptr", ctrlHwnd, "UInt", 0x31, "Ptr", 0, "Ptr", 0, "Ptr")
        old := hFont ? DllCall("gdi32\SelectObject", "Ptr", hDC, "Ptr", hFont, "Ptr") : 0
        rc := Buffer(16, 0)
        NumPut("Int", L, "Int", T, "Int", R, "Int", B, rc)
        ; align | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS
        DllCall("user32\DrawTextW", "Ptr", hDC, "Str", txt, "Int", -1, "Ptr", rc, "UInt", align | 0x4 | 0x20 | 0x8000)
        if old
            DllCall("gdi32\SelectObject", "Ptr", hDC, "Ptr", old)
    }
}

class ThemedList {
    static _byHwnd := Map()
    static _hooked := false
    static _radius := 7
    static _itemH  := 26

    static Init() {
        if !ThemedList._hooked {
            OnMessage(0x2B, ObjBindMethod(ThemedList, "_onDrawItem"))   ; WM_DRAWITEM
            ThemedList._hooked := true
        }
        ThemedButton._ensureGdip()
    }

    static Attach(ctrl) {
        if !(ctrl is Gui.Control)
            return ""
        ThemedList.Init()
        inst := ThemedList(ctrl)
        ThemedList._byHwnd[ctrl.Hwnd] := inst
        static GWL_STYLE := -16, LBS_OWNERDRAWFIXED := 0x10, LBS_HASSTRINGS := 0x40
        style := ThemedButton._getLong(ctrl.Hwnd, GWL_STYLE)
        ThemedButton._setLong(ctrl.Hwnd, GWL_STYLE, style | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS)
        DllCall("SendMessage", "Ptr", ctrl.Hwnd, "UInt", 0x1A0, "Ptr", 0, "Ptr", ThemedList._itemH) ; LB_SETITEMHEIGHT
        DllCall("InvalidateRect", "Ptr", ctrl.Hwnd, "Ptr", 0, "Int", 1)
        return inst
    }

    static RefreshAll() {
        for hwnd in ThemedList._byHwnd
            try DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 1)
    }

    __New(ctrl) {
        this.ctrl := ctrl
    }

    static _onDrawItem(wParam, lParam, msg, hwnd) {
        if (NumGet(lParam, 0, "UInt") != 2)    ; CtlType != ODT_LISTBOX
            return
        if (A_PtrSize = 8) {
            hCtl := NumGet(lParam, 24, "Ptr"), hDC := NumGet(lParam, 32, "Ptr"), rOff := 40
        } else {
            hCtl := NumGet(lParam, 20, "Ptr"), hDC := NumGet(lParam, 24, "Ptr"), rOff := 28
        }
        if !ThemedList._byHwnd.Has(hCtl)
            return
        idx   := NumGet(lParam, 8, "Int")      ; itemID = item index (-1 when empty)
        state := NumGet(lParam, 16, "UInt")
        L := NumGet(lParam, rOff, "Int"),     T := NumGet(lParam, rOff + 4, "Int")
        R := NumGet(lParam, rOff + 8, "Int"), B := NumGet(lParam, rOff + 12, "Int")
        ThemedList._byHwnd[hCtl]._paint(hDC, idx, L, T, R, B, state)
        return 1
    }

    _paint(hDC, idx, L, T, R, B, state) {
        pal := Theme.Palette()
        w := R - L, h := B - T
        if (w <= 0 || h <= 0)
            return
        ThemedTab._fill(hDC, L, T, w, h, ThemedButton._h(pal["surface"]))
        if (idx < 0)
            return
        selected := (state & 0x1) ? true : false   ; ODS_SELECTED
        if selected {
            top := ThemedButton._blend(ThemedButton._h(pal["accent"]), 0xFFFFFF, 0.12)
            bot := ThemedButton._h(pal["accent"])
            txt := ThemedButton._h(pal["accentText"])
            ThemedButton._roundFill(hDC, L + 3, T + 2, w - 6, h - 4, ThemedList._radius
                , ThemedButton._argbI(bot), 0, ThemedButton._argbI(top))
        } else {
            txt := ThemedButton._h(pal["text"])
        }
        len := DllCall("SendMessage", "Ptr", this.ctrl.Hwnd, "UInt", 0x18A, "Ptr", idx, "Ptr", 0, "Ptr") ; LB_GETTEXTLEN
        if (len > 0) {
            buf := Buffer((len + 1) * 2, 0)
            DllCall("SendMessage", "Ptr", this.ctrl.Hwnd, "UInt", 0x189, "Ptr", idx, "Ptr", buf) ; LB_GETTEXT
            s := StrGet(buf, "UTF-16")
            ThemedTab._text(this.ctrl.Hwnd, hDC, s, L + 12, T, R - 8, B, txt, 0x0)
        }
    }
}
