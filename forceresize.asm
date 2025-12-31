format PE64 console
entry start

include 'win64a.inc'

STD_OUTPUT_HANDLE = -11
STD_ERROR_HANDLE  = -12

SW_RESTORE = 9

CP_UTF8 = 65001

MONITOR_DEFAULTTONEAREST = 2
MONITORINFO_SIZE = 40

GW_OWNER = 4
GW_ENABLEDPOPUP = 6

SWP_NOZORDER   = 0004h
SWP_NOACTIVATE = 0010h

TITLEBUF_LEN = 512
CLASSBUF_LEN = 256

TITLEUTF8_LEN = 2048
CLASSUTF8_LEN = 512
LINEBUF_LEN = 2048

TITLE_TRUNC_AT = 240
CLASS_TRUNC_AT = 120

section '.text' code readable executable

; ----------------------------
; helpers
; ----------------------------

proc printA h, pStr
	mov [h], rcx
	mov [pStr], rdx
	mov r8, [pStr]
	xor eax, eax
.len_loop:
	cmp byte [r8+rax], 0
	je .len_done
	inc eax
	jmp .len_loop
.len_done:
	test eax, eax
	jz .ret
	invoke WriteFile, [h], r8, eax, addr g_bytesWritten, 0
.ret:
	ret
endp

; rcx=buf, rdx=value -> rax=buf_end
proc append_hex64 buf, value
	mov r8, rcx
	mov rax, rdx

	mov byte [r8], '0'
	inc r8
	mov byte [r8], 'x'
	inc r8

	mov ecx, 16
.loop:
	mov r9, rax
	shr r9, 60
	mov r10b, r9b
	cmp r10b, 9
	jbe .digit
	add r10b, 'A' - 10
	jmp .store
.digit:
	add r10b, '0'
.store:
	mov byte [r8], r10b
	inc r8
	shl rax, 4
	dec ecx
	jnz .loop

	mov rax, r8
	ret
endp

; parse signed int64 from a WCHAR* 
; returns: rax=value, edx=1 on success else 0
proc parse_int_w pStr
	mov [pStr], rcx
	mov r8, [pStr]
	xor rax, rax
	xor edx, edx
	mov r10d, 1

	movzx r11d, word [r8]
	cmp r11w, '-'
	jne .check_plus
	mov r10d, -1
	add r8, 2
	jmp .after_sign
.check_plus:
	cmp r11w, '+'
	jne .after_sign
	add r8, 2
.after_sign:
	mov r9d, 10
	movzx r11d, word [r8]
	cmp r11w, '0'
	jne .parse_loop
	movzx r11d, word [r8+2]
	cmp r11w, 'x'
	je .hex
	cmp r11w, 'X'
	je .hex
	jmp .parse_loop
.hex:
	add r8, 4
	mov r9d, 16

.parse_loop:
	movzx r11d, word [r8]
	test r11w, r11w
	jz .done

	cmp r11w, '0'
	jb .done
	cmp r11w, '9'
	jbe .dig_0_9

	cmp r9d, 16
	jne .done

	cmp r11w, 'A'
	jb .check_lower
	cmp r11w, 'F'
	jbe .dig_A_F
.check_lower:
	cmp r11w, 'a'
	jb .done
	cmp r11w, 'f'
	ja .done
	sub r11d, 'a'
	add r11d, 10
	jmp .accum

.dig_A_F:
	sub r11d, 'A'
	add r11d, 10
	jmp .accum

.dig_0_9:
	sub r11d, '0'

.accum:
	imul rax, r9
	add rax, r11
	add r8, 2
	mov edx, 1
	jmp .parse_loop

.done:
	test edx, edx
	jz .fail
	cmp r10d, 1
	je .ok
	neg rax
.ok:
	mov edx, 1
	ret

.fail:
	xor rax, rax
	xor edx, edx
	ret
endp

; parse signed int32 from a WCHAR*
; returns: eax=value, edx=1 on success else 0
proc parse_i32_w pStr
	mov [pStr], rcx
	fastcall parse_int_w, [pStr]
	test edx, edx
	jz .fail

	movsxd r11, eax
	cmp rax, r11
	jne .fail

	mov edx, 1
	ret

.fail:
	xor eax, eax
	xor edx, edx
	ret
endp

; parse positive int32 from a WCHAR*
; returns: eax=value, edx=1 on success else 0
proc parse_positive_i32_w pStr
	mov [pStr], rcx
	fastcall parse_i32_w, [pStr]
	test edx, edx
	jz .fail
	test eax, eax
	jle .fail
	mov edx, 1
	ret
.fail:
	xor eax, eax
	xor edx, edx
	ret
endp

; Validate that hwnd is a visible window with a non-zero rectangle.
; returns: rax=hwnd on success else 0
proc validate_window hwnd
	mov [hwnd], rcx

	mov rax, [hwnd]
	test rax, rax
	jz .bad

	invoke IsWindow, rax
	test eax, eax
	jz .bad

	invoke IsWindowVisible, [hwnd]
	test eax, eax
	jz .bad

	invoke GetWindowRect, [hwnd], g_rect
	test eax, eax
	jz .bad

	mov eax, [g_rect+8]
	sub eax, [g_rect+0]
	jle .bad
	mov eax, [g_rect+12]
	sub eax, [g_rect+4]
	jle .bad

	mov rax, [hwnd]
	ret

.bad:
	xor rax, rax
	ret
endp

; Move/resize the target window so it fully fits within the nearest monitor work area.
; Uses g_haveSize/g_havePos and g_w/g_h/g_x/g_y as inputs when provided.
; returns: eax=1 success else 0
proc fit_window hwnd
	mov [hwnd], rcx

	mov dword [g_failStage], 0
	mov dword [g_failErr], 0

	invoke SetLastError, 0

	invoke GetWindowRect, [hwnd], g_rect
	test eax, eax
	jnz .rect_ok
	mov dword [g_failStage], 1
	invoke GetLastError
	mov [g_failErr], eax
	jmp .fail
.rect_ok:

	cmp dword [g_haveSize], 0
	jne .have_size
	mov eax, [g_rect+8]
	sub eax, [g_rect+0]
	mov [g_w], eax
	mov eax, [g_rect+12]
	sub eax, [g_rect+4]
	mov [g_h], eax
.have_size:

	cmp dword [g_havePos], 0
	jne .have_pos
	mov eax, [g_rect+0]
	mov [g_x], eax
	mov eax, [g_rect+4]
	mov [g_y], eax
.have_pos:

	invoke SetLastError, 0
	invoke MonitorFromWindow, [hwnd], MONITOR_DEFAULTTONEAREST
	test rax, rax
	jnz .mon_ok
	mov dword [g_failStage], 2
	invoke GetLastError
	mov [g_failErr], eax
	jmp .fail
.mon_ok:
	mov [g_hmon], rax

	mov dword [g_mi+0], MONITORINFO_SIZE
	invoke SetLastError, 0
	invoke GetMonitorInfoW, [g_hmon], g_mi
	test eax, eax
	jnz .mi_ok
	mov dword [g_failStage], 3
	invoke GetLastError
	mov [g_failErr], eax
	jmp .fail
.mi_ok:

	; Work area: g_mi + 20..35 (RECT)
	mov r8d, dword [g_mi+20] ; left
	mov r9d, dword [g_mi+24] ; top
	mov r10d, dword [g_mi+28] ; right
	mov r11d, dword [g_mi+32] ; bottom

	; workW/workH in ecx/edx
	mov ecx, r10d
	sub ecx, r8d
	mov edx, r11d
	sub edx, r9d

	; clamp size to work area
	mov eax, [g_w]
	cmp eax, ecx
	jle .w_ok
	mov [g_w], ecx
.w_ok:
	mov eax, [g_h]
	cmp eax, edx
	jle .h_ok
	mov [g_h], edx
.h_ok:

	; clamp x/y to work area bounds
	mov eax, [g_x]
	cmp eax, r8d
	jge .x_min_ok
	mov eax, r8d
	mov [g_x], eax
.x_min_ok:

	mov eax, [g_y]
	cmp eax, r9d
	jge .y_min_ok
	mov eax, r9d
	mov [g_y], eax
.y_min_ok:

	; x+w <= workRight
	mov eax, [g_x]
	add eax, [g_w]
	cmp eax, r10d
	jle .x_max_ok
	mov eax, r10d
	sub eax, [g_w]
	mov [g_x], eax
.x_max_ok:

	; y+h <= workBottom
	mov eax, [g_y]
	add eax, [g_h]
	cmp eax, r11d
	jle .y_max_ok
	mov eax, r11d
	sub eax, [g_h]
	mov [g_y], eax
.y_max_ok:

	invoke SetLastError, 0
	invoke SetWindowPos, [hwnd], 0, [g_x], [g_y], [g_w], [g_h], SWP_NOZORDER or SWP_NOACTIVATE
	test eax, eax
	jnz .setpos_ok
	mov dword [g_failStage], 4
	invoke GetLastError
	mov [g_failErr], eax
	jmp .fail
.setpos_ok:
	mov eax, 1
	ret

.fail:
	xor eax, eax
	ret
endp

; EnumWindows callback: stop when we find a visible top-level window whose title contains g_searchStr.
proc enum_cb hwnd, lParam
	mov [hwnd], rcx
	mov [lParam], rdx
	mov rax, [g_foundHwnd]
	test rax, rax
	jnz .stop

	invoke IsWindowVisible, [hwnd]
	test eax, eax
	jz .cont

	invoke GetWindowTextW, [hwnd], g_titleBuf, TITLEBUF_LEN
	test eax, eax
	jz .cont

	invoke StrStrIW, g_titleBuf, [g_searchStr]
	test rax, rax
	jz .cont

	mov rax, [hwnd]
	mov [g_foundHwnd], rax
.stop:
	xor eax, eax
	ret

.cont:
	mov eax, 1
	ret
endp

; EnumWindows callback: pick the largest visible top-level window owned by g_baseHwnd.
proc enum_cb_popup_owned hwnd, lParam
	mov [hwnd], rcx
	mov [lParam], rdx

	invoke IsWindowVisible, [hwnd]
	test eax, eax
	jz .cont

	mov rax, [hwnd]
	cmp rax, [g_baseHwnd]
	je .cont

	invoke GetWindow, [hwnd], GW_OWNER
	cmp rax, [g_baseHwnd]
	jne .cont

	invoke GetWindowRect, [hwnd], g_rect
	test eax, eax
	jz .cont

	mov eax, [g_rect+8]
	sub eax, [g_rect+0]
	jle .cont
	mov edx, [g_rect+12]
	sub edx, [g_rect+4]
	jle .cont

	movsxd rax, eax
	movsxd rdx, edx
	imul rax, rdx

	cmp rax, [g_popupBestArea]
	jle .cont
	mov [g_popupBestArea], rax
	mov rax, [hwnd]
	mov [g_popupBest], rax

.cont:
	mov eax, 1
	ret
endp

; EnumWindows callback: pick the largest visible top-level window in g_targetPid (excluding g_baseHwnd).
proc enum_cb_popup_pid hwnd, lParam
	mov [hwnd], rcx
	mov [lParam], rdx

	invoke IsWindowVisible, [hwnd]
	test eax, eax
	jz .cont

	mov rax, [hwnd]
	cmp rax, [g_baseHwnd]
	je .cont

	invoke GetWindowThreadProcessId, [hwnd], addr g_pid
	mov eax, [g_pid]
	cmp eax, [g_targetPid]
	jne .cont

	invoke GetWindowRect, [hwnd], g_rect
	test eax, eax
	jz .cont

	mov eax, [g_rect+8]
	sub eax, [g_rect+0]
	jle .cont
	mov edx, [g_rect+12]
	sub edx, [g_rect+4]
	jle .cont

	movsxd rax, eax
	movsxd rdx, edx
	imul rax, rdx

	cmp rax, [g_popupBestArea]
	jle .cont
	mov [g_popupBestArea], rax
	mov rax, [hwnd]
	mov [g_popupBest], rax

.cont:
	mov eax, 1
	ret
endp

; EnumWindows callback: list visible windows (optionally filter by title/class substring).
proc enum_cb_list uses rbx rsi rdi, hwnd, lParam
	mov [hwnd], rcx
	mov [lParam], rdx
	invoke IsWindowVisible, [hwnd]
	test eax, eax
	jz .cont

	invoke GetWindowTextW, [hwnd], g_titleBuf, TITLEBUF_LEN
	invoke GetClassNameW, [hwnd], g_classBuf, CLASSBUF_LEN
	invoke GetWindowRect, [hwnd], g_rect
	invoke GetWindowThreadProcessId, [hwnd], addr g_pid

	mov rax, [g_listFilter]
	test rax, rax
	jz .no_filter

	invoke StrStrIW, g_titleBuf, rax
	test rax, rax
	jnz .no_filter

	invoke StrStrIW, g_classBuf, [g_listFilter]
	test rax, rax
	jz .cont
.no_filter:
	invoke WideCharToMultiByte, CP_UTF8, 0, g_classBuf, -1, g_classUtf8, CLASSUTF8_LEN, 0, 0
	test eax, eax
	jnz .class_ok
	mov byte [g_classUtf8], 0
.class_ok:
	invoke WideCharToMultiByte, CP_UTF8, 0, g_titleBuf, -1, g_titleUtf8, TITLEUTF8_LEN, 0, 0
	test eax, eax
	jnz .title_ok
	mov byte [g_titleUtf8], 0
.title_ok:

	; keep output lines compact
	mov byte [g_classUtf8 + CLASS_TRUNC_AT], 0
	mov byte [g_titleUtf8 + TITLE_TRUNC_AT], 0

	; build output line: <hwndhex> pid=... rect=(l,t)-(r,b) class="..." title="..."
	lea rdi, [g_lineBuf]
	mov rcx, rdi
	mov rdx, [hwnd]
	fastcall append_hex64, rcx, rdx

	mov rsi, rax
	sub rsi, rdi ; prefix length

	cinvoke wsprintfA, rax, fmt_list_rest, [g_pid], [g_rect+0], [g_rect+4], [g_rect+8], [g_rect+12], g_classUtf8, g_titleUtf8
	add eax, esi
	mov ecx, eax
	invoke WriteFile, [g_hOut], rdi, ecx, addr g_bytesWritten, 0

.cont:
	mov eax, 1
	ret
endp

start:
	sub rsp, 8	; Win64: align stack before any calls
	invoke GetStdHandle, STD_OUTPUT_HANDLE
	mov [g_hOut], rax
	invoke GetStdHandle, STD_ERROR_HANDLE
	mov [g_hErr], rax

	invoke GetCommandLineW
	invoke CommandLineToArgvW, rax, addr g_argc
	test rax, rax
	jz .argv_fail
	mov [g_argv], rax

	mov rbx, [g_argv]

	; Optional trailing flag: --popup (targets active popup/owned dialog of the chosen window)
	mov eax, [g_argc]
	cmp eax, 2
	jl .after_popup
	mov ecx, eax
	dec ecx
	mov rcx, [rbx+rcx*8]
	invoke lstrcmpiW, rcx, flag_popup
	test eax, eax
	jnz .after_popup
	mov dword [g_usePopup], 1
	dec dword [g_argc]
.after_popup:

	mov ecx, [g_argc]
	cmp ecx, 2
	jl .usage

	mov rcx, [rbx+8] ; argv[1]
	invoke lstrcmpiW, rcx, flag_list
	test eax, eax
	jz .mode_list

	mov rcx, [rbx+8] ; argv[1]
	invoke lstrcmpiW, rcx, flag_hwnd
	test eax, eax
	jz .mode_hwnd

.mode_title:
	; argc must be 2, 4, or 6:
	;   "<title>"
	;   "<title>" <w> <h>
	;   "<title>" <w> <h> <x> <y>
	mov eax, [g_argc]
	cmp eax, 2
	je .title_no_args
	cmp eax, 4
	je .title_wh
	cmp eax, 6
	je .title_whxy
	jmp .usage

.title_no_args:
	mov dword [g_haveSize], 0
	mov dword [g_havePos], 0
	jmp .title_find

.title_wh:
	mov dword [g_haveSize], 1
	mov dword [g_havePos], 0

	mov rcx, [rbx+16] ; argv[2]
	fastcall parse_positive_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_w], eax

	mov rcx, [rbx+24] ; argv[3]
	fastcall parse_positive_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_h], eax
	jmp .title_find

.title_whxy:
	mov dword [g_haveSize], 1
	mov dword [g_havePos], 1

	mov rcx, [rbx+16] ; argv[2]
	fastcall parse_positive_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_w], eax

	mov rcx, [rbx+24] ; argv[3]
	fastcall parse_positive_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_h], eax

	mov rcx, [rbx+32] ; argv[4]
	fastcall parse_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_x], eax

	mov rcx, [rbx+40] ; argv[5]
	fastcall parse_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_y], eax

.title_find:
	mov rcx, [rbx+8] ; argv[1]
	mov [g_searchStr], rcx
	mov qword [g_foundHwnd], 0
	invoke EnumWindows, enum_cb, 0

	mov rax, [g_foundHwnd]
	test rax, rax
	jz .notfound
	mov [g_hwnd], rax
	jmp .apply

.mode_list:
	; argc must be 2 or 3
	mov eax, [g_argc]
	cmp eax, 2
	je .list_no_filter
	cmp eax, 3
	je .list_with_filter
	jmp .usage

.list_no_filter:
	mov qword [g_listFilter], 0
	jmp .list_common

.list_with_filter:
	mov rax, [rbx+16] ; argv[2]
	mov [g_listFilter], rax

.list_common:
	invoke SetConsoleOutputCP, CP_UTF8
	fastcall printA, [g_hOut], msg_list_header
	invoke EnumWindows, enum_cb_list, 0
	jmp .exit_ok

.mode_hwnd:
	; argc must be 3, 5, or 7:
	;   --hwnd <hwnd>
	;   --hwnd <hwnd> <w> <h>
	;   --hwnd <hwnd> <w> <h> <x> <y>
	mov eax, [g_argc]
	cmp eax, 3
	je .hwnd_no_args
	cmp eax, 5
	je .hwnd_wh
	cmp eax, 7
	je .hwnd_whxy
	jmp .usage

.hwnd_no_args:
	mov dword [g_haveSize], 0
	mov dword [g_havePos], 0
	jmp .hwnd_common

.hwnd_wh:
	mov dword [g_haveSize], 1
	mov dword [g_havePos], 0

	mov rcx, [rbx+24] ; argv[3]
	fastcall parse_positive_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_w], eax

	mov rcx, [rbx+32] ; argv[4]
	fastcall parse_positive_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_h], eax
	jmp .hwnd_common

.hwnd_whxy:
	mov dword [g_haveSize], 1
	mov dword [g_havePos], 1

	mov rcx, [rbx+24] ; argv[3]
	fastcall parse_positive_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_w], eax

	mov rcx, [rbx+32] ; argv[4]
	fastcall parse_positive_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_h], eax

	mov rcx, [rbx+40] ; argv[5]
	fastcall parse_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_x], eax

	mov rcx, [rbx+48] ; argv[6]
	fastcall parse_i32_w, rcx
	test edx, edx
	jz .badargs
	mov [g_y], eax

.hwnd_common:
	; hwnd argv[2]
	mov rcx, [rbx+16]
	fastcall parse_int_w, rcx
	test edx, edx
	jz .badargs
	test rax, rax
	jz .badargs
	mov [g_hwnd], rax
	invoke IsWindow, rax
	test eax, eax
	jz .badargs
	jmp .apply

.apply:
	mov rax, [g_hwnd]
	mov [g_baseHwnd], rax

	cmp dword [g_usePopup], 0
	je .apply_go

	; Prefer a visible owned dialog (largest area), then fall back to last active/enabled popup.
	mov qword [g_popupBest], 0
	mov qword [g_popupBestArea], 0
	invoke EnumWindows, enum_cb_popup_owned, 0
	mov rax, [g_popupBest]
	test rax, rax
	jz .popup_try_lastactive
	mov [g_hwnd], rax
	jmp .apply_go

.popup_try_lastactive:
	invoke GetLastActivePopup, [g_baseHwnd]
	test rax, rax
	jz .popup_try_enabledpopup
	cmp rax, [g_baseHwnd]
	je .popup_try_enabledpopup
	fastcall validate_window, rax
	test rax, rax
	jz .popup_try_enabledpopup
	mov [g_hwnd], rax
	jmp .apply_go

.popup_try_enabledpopup:
	invoke GetWindow, [g_baseHwnd], GW_ENABLEDPOPUP
	test rax, rax
	jz .popup_try_pid
	cmp rax, [g_baseHwnd]
	je .popup_try_pid
	fastcall validate_window, rax
	test rax, rax
	jz .popup_try_pid
	mov [g_hwnd], rax
	jmp .apply_go

.popup_try_pid:
	; Last resort: pick the largest visible top-level window in the same process.
	invoke GetWindowThreadProcessId, [g_baseHwnd], addr g_targetPid
	mov qword [g_popupBest], 0
	mov qword [g_popupBestArea], 0
	invoke EnumWindows, enum_cb_popup_pid, 0
	mov rax, [g_popupBest]
	test rax, rax
	jz .apply_go
	mov [g_hwnd], rax

.apply_go:
	invoke ShowWindow, [g_hwnd], SW_RESTORE
	fastcall fit_window, [g_hwnd]
	test eax, eax
	jz .resize_fail
	fastcall printA, [g_hOut], msg_ok
	jmp .exit_ok

.argv_fail:
	fastcall printA, [g_hErr], msg_argv_fail
	jmp .exit_fail

.usage:
	fastcall printA, [g_hErr], msg_usage
	jmp .exit_usage

.badargs:
	fastcall printA, [g_hErr], msg_badargs
	fastcall printA, [g_hErr], msg_usage
	jmp .exit_usage

.notfound:
	fastcall printA, [g_hErr], msg_notfound
	jmp .exit_notfound

.resize_fail:
	fastcall printA, [g_hErr], msg_resize_fail
	cinvoke wsprintfA, g_lineBuf, fmt_resize_fail_detail, [g_failStage], [g_failErr]
	fastcall printA, [g_hErr], g_lineBuf
	jmp .exit_fail

.exit_ok:
	invoke LocalFree, [g_argv]
	invoke ExitProcess, 0

.exit_usage:
	invoke LocalFree, [g_argv]
	invoke ExitProcess, 1

.exit_notfound:
	invoke LocalFree, [g_argv]
	invoke ExitProcess, 2

.exit_fail:
	invoke LocalFree, [g_argv]
	invoke ExitProcess, 3

section '.data' data readable writeable

g_hOut dq 0
g_hErr dq 0

g_argc dd 0
g_argv dq 0

g_hwnd dq 0
g_baseHwnd dq 0
g_popupBest dq 0
g_popupBestArea dq 0
g_targetPid dd 0
g_failStage dd 0
g_failErr dd 0
g_haveSize dd 0
g_havePos dd 0
g_usePopup dd 0
g_w dd 0
g_h dd 0
g_x dd 0
g_y dd 0
g_hmon dq 0
g_mi rb MONITORINFO_SIZE

g_searchStr dq 0
g_foundHwnd dq 0

g_listFilter dq 0

g_bytesWritten dd 0
g_pid dd 0

g_titleBuf rw TITLEBUF_LEN
g_classBuf rw CLASSBUF_LEN

g_titleUtf8 rb TITLEUTF8_LEN
g_classUtf8 rb CLASSUTF8_LEN
g_lineBuf rb LINEBUF_LEN

g_rect dd 0,0,0,0

flag_hwnd du '--hwnd',0
flag_list du '--list',0
flag_popup du '--popup',0

msg_ok db 'Moved/resized window to fit on-screen.',13,10,0
msg_notfound db 'No matching window found.',13,10,0
msg_badargs db 'Bad arguments.',13,10,0
msg_resize_fail db 'Failed to move/resize window (try running elevated if targeting an admin window).',13,10,0
msg_argv_fail db 'CommandLineToArgvW failed.',13,10,0
msg_usage db 'Usage:',13,10,\
	'  forceresize.exe "<title substring>" [w h [x y]] [--popup]',13,10,\
	'  forceresize.exe --hwnd <hwnd_hex> [w h [x y]] [--popup]',13,10,\
	'  forceresize.exe --list [filter]',13,10,0

msg_list_header db 'HWND (hex) pid rect class title',13,10,0

fmt_list_rest db ' pid=%u rect=(%ld,%ld)-(%ld,%ld) class="%s" title="%s"',13,10,0
fmt_resize_fail_detail db 'Details: stage=%u err=0x%08X',13,10,0

section '.idata' import data readable writeable

library kernel32,'kernel32.dll',\
	user32,'user32.dll',\
	shell32,'shell32.dll',\
	shlwapi,'shlwapi.dll'

import kernel32,\
	ExitProcess,'ExitProcess',\
	GetLastError,'GetLastError',\
	GetCommandLineW,'GetCommandLineW',\
	GetStdHandle,'GetStdHandle',\
	SetLastError,'SetLastError',\
	SetConsoleOutputCP,'SetConsoleOutputCP',\
	WideCharToMultiByte,'WideCharToMultiByte',\
	WriteFile,'WriteFile',\
	LocalFree,'LocalFree',\
	lstrcmpiW,'lstrcmpiW'

import user32,\
	EnumWindows,'EnumWindows',\
	GetLastActivePopup,'GetLastActivePopup',\
	IsWindowVisible,'IsWindowVisible',\
	GetClassNameW,'GetClassNameW',\
	GetWindow,'GetWindow',\
	GetWindowTextW,'GetWindowTextW',\
	GetWindowRect,'GetWindowRect',\
	GetWindowThreadProcessId,'GetWindowThreadProcessId',\
	MonitorFromWindow,'MonitorFromWindow',\
	GetMonitorInfoW,'GetMonitorInfoW',\
	SetWindowPos,'SetWindowPos',\
	ShowWindow,'ShowWindow',\
	wsprintfA,'wsprintfA',\
	IsWindow,'IsWindow'

import shell32,\
	CommandLineToArgvW,'CommandLineToArgvW'

import shlwapi,\
	StrStrIW,'StrStrIW'
