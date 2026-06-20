#Requires AutoHotkey v2.0

; Minimal JSON parser/serializer.
; - parse() returns Map for objects, Array for arrays, String/Number for primitives,
;   true/false as 1/0, null as "".
; - stringify() accepts Map/Array/String/Number, writes booleans as true/false when
;   the value is exactly the JSON.true / JSON.false sentinel, otherwise as numbers.

class JSON {
    static true  := { __json_bool: 1 }
    static false := { __json_bool: 0 }
    static null  := { __json_null: 1 }

    static parse(text) {
        ctx := { s: text, i: 1, n: StrLen(text) }
        this._skip(ctx)
        val := this._value(ctx)
        this._skip(ctx)
        if ctx.i <= ctx.n
            throw Error("JSON: trailing characters at " ctx.i)
        return val
    }

    static stringify(value, indent := "", level := 0) {
        return this._encode(value, indent, level)
    }

    static _encode(v, indent, level) {
        if v is Map
            return this._encodeObject(v, indent, level)
        if v is Array
            return this._encodeArray(v, indent, level)
        if IsObject(v) {
            if v.HasOwnProp("__json_bool")
                return v.__json_bool ? "true" : "false"
            if v.HasOwnProp("__json_null")
                return "null"
            m := Map()
            for p in v.OwnProps()
                m[p] := v.%p%
            return this._encodeObject(m, indent, level)
        }
        if v = ""
            return '""'
        if IsNumber(v)
            return v
        return this._encodeString(v)
    }

    static _encodeObject(m, indent, level) {
        if m.Count = 0
            return "{}"
        nl := indent = "" ? "" : "`n"
        outerPad := this._pad(indent, level)
        innerPad := this._pad(indent, level+1)
        parts := []
        for k, v in m {
            sep := indent = "" ? ":" : ": "
            parts.Push(innerPad this._encodeString(String(k)) sep this._encode(v, indent, level+1))
        }
        sepJoin := indent = "" ? "," : ",`n"
        body := ""
        for i, p in parts
            body .= (i = 1 ? "" : sepJoin) p
        return "{" nl body nl outerPad "}"
    }

    static _encodeArray(a, indent, level) {
        if a.Length = 0
            return "[]"
        nl := indent = "" ? "" : "`n"
        outerPad := this._pad(indent, level)
        innerPad := this._pad(indent, level+1)
        parts := []
        for v in a
            parts.Push(innerPad this._encode(v, indent, level+1))
        sepJoin := indent = "" ? "," : ",`n"
        body := ""
        for i, p in parts
            body .= (i = 1 ? "" : sepJoin) p
        return "[" nl body nl outerPad "]"
    }

    static _pad(indent, level) {
        if indent = ""
            return ""
        out := ""
        Loop level
            out .= indent
        return out
    }

    static _encodeString(s) {
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, '"', '\"')
        s := StrReplace(s, "`n", "\n")
        s := StrReplace(s, "`r", "\r")
        s := StrReplace(s, "`t", "\t")
        s := StrReplace(s, Chr(8), "\b")
        s := StrReplace(s, Chr(12), "\f")
        return '"' s '"'
    }

    static _skip(ctx) {
        while ctx.i <= ctx.n {
            c := SubStr(ctx.s, ctx.i, 1)
            if c = " " || c = "`t" || c = "`n" || c = "`r"
                ctx.i++
            else
                break
        }
    }

    static _value(ctx) {
        this._skip(ctx)
        if ctx.i > ctx.n
            throw Error("JSON: unexpected end")
        c := SubStr(ctx.s, ctx.i, 1)
        if c = "{"
            return this._object(ctx)
        if c = "["
            return this._array(ctx)
        if c = '"'
            return this._string(ctx)
        if c = "t" || c = "f"
            return this._bool(ctx)
        if c = "n"
            return this._null(ctx)
        if c = "-" || this._isDigit(c)
            return this._number(ctx)
        throw Error("JSON: unexpected char '" c "' at " ctx.i)
    }

    static _object(ctx) {
        m := Map()
        ctx.i++
        this._skip(ctx)
        if SubStr(ctx.s, ctx.i, 1) = "}" {
            ctx.i++
            return m
        }
        loop {
            this._skip(ctx)
            if SubStr(ctx.s, ctx.i, 1) != '"'
                throw Error("JSON: expected string key at " ctx.i)
            key := this._string(ctx)
            this._skip(ctx)
            if SubStr(ctx.s, ctx.i, 1) != ":"
                throw Error("JSON: expected ':' at " ctx.i)
            ctx.i++
            val := this._value(ctx)
            m[key] := val
            this._skip(ctx)
            c := SubStr(ctx.s, ctx.i, 1)
            if c = "," {
                ctx.i++
                continue
            }
            if c = "}" {
                ctx.i++
                return m
            }
            throw Error("JSON: expected ',' or '}' at " ctx.i)
        }
    }

    static _array(ctx) {
        a := []
        ctx.i++
        this._skip(ctx)
        if SubStr(ctx.s, ctx.i, 1) = "]" {
            ctx.i++
            return a
        }
        loop {
            val := this._value(ctx)
            a.Push(val)
            this._skip(ctx)
            c := SubStr(ctx.s, ctx.i, 1)
            if c = "," {
                ctx.i++
                continue
            }
            if c = "]" {
                ctx.i++
                return a
            }
            throw Error("JSON: expected ',' or ']' at " ctx.i)
        }
    }

    static _string(ctx) {
        ctx.i++
        out := ""
        while ctx.i <= ctx.n {
            c := SubStr(ctx.s, ctx.i, 1)
            if c = '"' {
                ctx.i++
                return out
            }
            if c = "\" {
                esc := SubStr(ctx.s, ctx.i + 1, 1)
                switch esc {
                    case '"': out .= '"'
                    case "\": out .= "\"
                    case "/": out .= "/"
                    case "n": out .= "`n"
                    case "r": out .= "`r"
                    case "t": out .= "`t"
                    case "b": out .= Chr(8)
                    case "f": out .= Chr(12)
                    case "u":
                        hex := SubStr(ctx.s, ctx.i + 2, 4)
                        out .= Chr(Integer("0x" hex))
                        ctx.i += 4
                    default:
                        throw Error("JSON: bad escape \\" esc " at " ctx.i)
                }
                ctx.i += 2
            } else {
                out .= c
                ctx.i++
            }
        }
        throw Error("JSON: unterminated string")
    }

    static _number(ctx) {
        start := ctx.i
        if SubStr(ctx.s, ctx.i, 1) = "-"
            ctx.i++
        while ctx.i <= ctx.n {
            c := SubStr(ctx.s, ctx.i, 1)
            if this._isDigit(c) || c = "." || c = "e" || c = "E" || c = "+" || c = "-"
                ctx.i++
            else
                break
        }
        num := SubStr(ctx.s, start, ctx.i - start)
        return InStr(num, ".") || InStr(num, "e") || InStr(num, "E") ? Float(num) : Integer(num)
    }

    static _isDigit(c) {
        return c = "0" || c = "1" || c = "2" || c = "3" || c = "4"
            || c = "5" || c = "6" || c = "7" || c = "8" || c = "9"
    }

    static _bool(ctx) {
        if SubStr(ctx.s, ctx.i, 4) = "true" {
            ctx.i += 4
            return 1
        }
        if SubStr(ctx.s, ctx.i, 5) = "false" {
            ctx.i += 5
            return 0
        }
        throw Error("JSON: bad literal at " ctx.i)
    }

    static _null(ctx) {
        if SubStr(ctx.s, ctx.i, 4) = "null" {
            ctx.i += 4
            return ""
        }
        throw Error("JSON: bad literal at " ctx.i)
    }
}
