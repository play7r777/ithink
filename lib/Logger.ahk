#Requires AutoHotkey v2.0

; Dependencies (guarded by AHK against double-inclusion when run via MacroForge.ahk)
#Include Constants.ahk

; Lightweight logger. Writes to a daily file and pushes to an optional UI sink
; (a callback the GUI registers so log lines stream into the on-screen panel).
;
; Performance notes:
;   - File writes are BUFFERED. Each log line is appended to an in-memory
;     pending queue and flushed to disk either when the queue grows past
;     flushThreshold lines or on a periodic timer (Flush every flushIntervalMs).
;     This avoids one synchronous open/append/close per log line, which used to
;     dominate I/O during tight playback loops (e.g. an autoclicker logging a
;     step every iteration).
;   - The in-memory display buffer is a RING buffer: writes advance a head index
;     and overwrite the oldest slot once full, so appends stay O(1) instead of
;     the previous O(N) Array.RemoveAt(1).

class Logger {
    static sink := ""
    static maxBufferLines := 500

    ; Ring buffer state for the in-memory display log.
    static _ring := []
    static _ringHead := 0          ; next write index (0-based)
    static _ringCount := 0         ; number of valid entries

    ; Pending (not-yet-flushed) file lines and flush control.
    static _pending := []
    static flushThreshold := 64    ; flush early once this many lines queue up
    static flushIntervalMs := 500
    static _timerStarted := false
    static _flushBound := ""

    static SetSink(cb) {
        Logger.sink := cb
    }

    static Info(msg)  => Logger._write("INFO",  msg)
    static Warn(msg)  => Logger._write("WARN",  msg)
    static Error(msg) => Logger._write("ERROR", msg)
    static Step(msg)  => Logger._write("STEP",  msg)

    static _write(level, msg) {
        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        line := "[" ts "] [" level "] " msg

        Logger._ringPush(line)

        ; Queue for the file; flush in batches rather than per-line.
        Logger._pending.Push(line)
        Logger._ensureTimer()
        if Logger._pending.Length >= Logger.flushThreshold
            Logger.Flush()

        if Logger.sink is Func {
            try Logger.sink.Call(line)
        }
    }

    static _ringPush(line) {
        cap := Logger.maxBufferLines
        if Logger._ring.Length < cap {
            ; Still growing: simple append keeps order natural.
            Logger._ring.Push(line)
            Logger._ringCount := Logger._ring.Length
            Logger._ringHead := Mod(Logger._ring.Length, cap)
        } else {
            ; Full: overwrite oldest slot (head), advance head. O(1).
            Logger._ring[Logger._ringHead + 1] := line
            Logger._ringHead := Mod(Logger._ringHead + 1, cap)
            Logger._ringCount := cap
        }
    }

    static _ensureTimer() {
        if Logger._timerStarted
            return
        Logger._flushBound := ObjBindMethod(Logger, "Flush")
        SetTimer Logger._flushBound, Logger.flushIntervalMs
        Logger._timerStarted := true
        ; Guarantee a final flush so no buffered lines are lost on quit.
        OnExit((*) => Logger.Flush())
    }

    ; Write all pending lines to disk in a single FileAppend.
    static Flush(*) {
        if Logger._pending.Length = 0
            return
        block := ""
        for ln in Logger._pending
            block .= ln "`r`n"
        Logger._pending := []
        try {
            if !DirExist(Cfg.LOGS_DIR)
                DirCreate(Cfg.LOGS_DIR)
            FileAppend(block, Cfg.LOGS_DIR "\" FormatTime(, "yyyy-MM-dd") ".log", "UTF-8")
        }
    }

    static Clear() {
        Logger._ring := []
        Logger._ringHead := 0
        Logger._ringCount := 0
    }

    ; Returns the in-memory display buffer in chronological (oldest-first) order.
    static GetBuffer() {
        cap := Logger.maxBufferLines
        if Logger._ringCount < cap {
            ; Not wrapped yet: ring already holds lines in order.
            out := []
            for ln in Logger._ring
                out.Push(ln)
            return out
        }
        ; Wrapped: oldest entry is at head, read forward with wrap-around.
        out := []
        Loop cap {
            idx := Mod(Logger._ringHead + A_Index - 1, cap) + 1
            out.Push(Logger._ring[idx])
        }
        return out
    }
}
