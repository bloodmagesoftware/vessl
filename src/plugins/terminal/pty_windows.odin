#+build windows
package terminal

// Windows ConPTY implementation
// Uses the modern CreatePseudoConsole API for proper ANSI sequence handling

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/windows"

// ConPTY types
HPCON :: windows.HANDLE
COORD :: struct {
	X: windows.SHORT,
	Y: windows.SHORT,
}

// Process information
STARTUPINFOEXW :: struct {
	StartupInfo:     windows.STARTUPINFOW,
	lpAttributeList: rawptr,
}

// ConPTY flags
PSEUDOCONSOLE_INHERIT_CURSOR :: 0x1

// Extended startup info flag
EXTENDED_STARTUPINFO_PRESENT :: 0x00080000

// Attribute list size
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016

// Foreign imports for kernel32
foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "stdcall")
foreign kernel32 {
	// ConPTY functions (Windows 10 1809+)
	CreatePseudoConsole :: proc(size: COORD, hInput: windows.HANDLE, hOutput: windows.HANDLE, dwFlags: windows.DWORD, phPC: ^HPCON) -> windows.HRESULT ---

	ResizePseudoConsole :: proc(hPC: HPCON, size: COORD) -> windows.HRESULT ---

	ClosePseudoConsole :: proc(hPC: HPCON) ---

	// Process attribute list
	InitializeProcThreadAttributeList :: proc(lpAttributeList: rawptr, dwAttributeCount: windows.DWORD, dwFlags: windows.DWORD, lpSize: ^c.size_t) -> windows.BOOL ---

	UpdateProcThreadAttribute :: proc(lpAttributeList: rawptr, dwFlags: windows.DWORD, Attribute: windows.DWORD_PTR, lpValue: rawptr, cbSize: c.size_t, lpPreviousValue: rawptr, lpReturnSize: ^c.size_t) -> windows.BOOL ---

	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
}

// PTY handle for Windows
PTYHandle :: struct {
	hPC:              HPCON, // Pseudo console handle
	hProcess:         windows.HANDLE, // Child process handle
	hThread:          windows.HANDLE, // Child thread handle
	hPipeIn:          windows.HANDLE, // Pipe for reading from PTY
	hPipeOut:         windows.HANDLE, // Pipe for writing to PTY
	hPipeInWrite:     windows.HANDLE, // Write end of input pipe (for ConPTY)
	hPipeOutRead:     windows.HANDLE, // Read end of output pipe (for ConPTY)
	attributeList:    rawptr, // Process attribute list
	attributeListBuf: []u8, // Buffer for attribute list
}

// Invalid handle value
INVALID_HANDLE :: windows.HANDLE(~uintptr(0))

// Get the default shell for Windows
get_default_shell :: proc() -> string {
	// Try COMSPEC environment variable
	comspec := os.get_env("COMSPEC")
	if len(comspec) > 0 {
		return comspec
	}

	// Check for PowerShell
	pwsh := os.get_env("SystemRoot")
	if len(pwsh) > 0 {
		ps_path := fmt.tprintf("%s\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", pwsh)
		if os.exists(ps_path) {
			return ps_path
		}
	}

	// Default to cmd.exe
	return "cmd.exe"
}

// Spawn a new PTY with ConPTY
spawn_pty :: proc(shell: string, rows, cols: int) -> (handle: PTYHandle, ok: bool) {
	handle = PTYHandle {
		hPC      = nil,
		hProcess = INVALID_HANDLE,
		hThread  = INVALID_HANDLE,
		hPipeIn  = INVALID_HANDLE,
		hPipeOut = INVALID_HANDLE,
	}

	// Create pipes for PTY communication
	// The ConPTY sits between these pipes and the child process

	// Input pipe: we write -> ConPTY reads
	hPipeInRead: windows.HANDLE
	hPipeInWrite: windows.HANDLE
	if windows.CreatePipe(&hPipeInRead, &hPipeInWrite, nil, 0) == windows.FALSE {
		fmt.eprintln("[pty_windows] Failed to create input pipe")
		return handle, false
	}

	// Output pipe: ConPTY writes -> we read
	hPipeOutRead: windows.HANDLE
	hPipeOutWrite: windows.HANDLE
	if windows.CreatePipe(&hPipeOutRead, &hPipeOutWrite, nil, 0) == windows.FALSE {
		fmt.eprintln("[pty_windows] Failed to create output pipe")
		windows.CloseHandle(hPipeInRead)
		windows.CloseHandle(hPipeInWrite)
		return handle, false
	}

	// Create pseudo console
	size := COORD {
		X = windows.SHORT(cols),
		Y = windows.SHORT(rows),
	}

	hPC: HPCON
	hr := CreatePseudoConsole(size, hPipeInRead, hPipeOutWrite, 0, &hPC)
	if hr < 0 {
		fmt.eprintf("[pty_windows] CreatePseudoConsole failed: 0x%08X\n", hr)
		windows.CloseHandle(hPipeInRead)
		windows.CloseHandle(hPipeInWrite)
		windows.CloseHandle(hPipeOutRead)
		windows.CloseHandle(hPipeOutWrite)
		return handle, false
	}

	// Close the ends that ConPTY owns now
	windows.CloseHandle(hPipeInRead)
	windows.CloseHandle(hPipeOutWrite)

	// Initialize process attribute list for ConPTY
	listSize: c.size_t = 0
	InitializeProcThreadAttributeList(nil, 1, 0, &listSize)

	attributeListBuf := make([]u8, listSize)
	attributeList := rawptr(raw_data(attributeListBuf))

	if InitializeProcThreadAttributeList(attributeList, 1, 0, &listSize) == windows.FALSE {
		fmt.eprintln("[pty_windows] InitializeProcThreadAttributeList failed")
		ClosePseudoConsole(hPC)
		windows.CloseHandle(hPipeInWrite)
		windows.CloseHandle(hPipeOutRead)
		delete(attributeListBuf)
		return handle, false
	}

	// Add pseudo console attribute
	if UpdateProcThreadAttribute(
		   attributeList,
		   0,
		   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		   hPC,
		   size_of(HPCON),
		   nil,
		   nil,
	   ) ==
	   windows.FALSE {
		fmt.eprintln("[pty_windows] UpdateProcThreadAttribute failed")
		DeleteProcThreadAttributeList(attributeList)
		ClosePseudoConsole(hPC)
		windows.CloseHandle(hPipeInWrite)
		windows.CloseHandle(hPipeOutRead)
		delete(attributeListBuf)
		return handle, false
	}

	// Create process with extended startup info
	startupInfo := STARTUPINFOEXW {
		StartupInfo = windows.STARTUPINFOW{cb = size_of(STARTUPINFOEXW)},
		lpAttributeList = attributeList,
	}

	processInfo: windows.PROCESS_INFORMATION

	// Convert shell path to wide string
	shell_wide := windows.utf8_to_wstring(shell)

	// Create the process
	if windows.CreateProcessW(
		   nil, // lpApplicationName
		   shell_wide, // lpCommandLine
		   nil, // lpProcessAttributes
		   nil, // lpThreadAttributes
		   windows.FALSE, // bInheritHandles
		   EXTENDED_STARTUPINFO_PRESENT, // dwCreationFlags
		   nil, // lpEnvironment
		   nil, // lpCurrentDirectory
		   &startupInfo.StartupInfo, // lpStartupInfo
		   &processInfo, // lpProcessInformation
	   ) == windows.FALSE {
		fmt.eprintln("[pty_windows] CreateProcessW failed")
		DeleteProcThreadAttributeList(attributeList)
		ClosePseudoConsole(hPC)
		windows.CloseHandle(hPipeInWrite)
		windows.CloseHandle(hPipeOutRead)
		delete(attributeListBuf)
		return handle, false
	}

	// Fill in handle
	handle.hPC = hPC
	handle.hProcess = processInfo.hProcess
	handle.hThread = processInfo.hThread
	handle.hPipeIn = hPipeOutRead // We read from output
	handle.hPipeOut = hPipeInWrite // We write to input
	handle.attributeList = attributeList
	handle.attributeListBuf = attributeListBuf

	fmt.printf("[pty_windows] Spawned ConPTY process: %d\n", processInfo.dwProcessId)
	return handle, true
}

// Read from PTY (non-blocking)
read_pty :: proc(handle: PTYHandle, buffer: []u8) -> int {
	if handle.hPipeIn == INVALID_HANDLE do return 0
	if len(buffer) == 0 do return 0

	// Check if data is available
	bytesAvailable: windows.DWORD
	if windows.PeekNamedPipe(handle.hPipeIn, nil, 0, nil, &bytesAvailable, nil) == windows.FALSE {
		return 0
	}

	if bytesAvailable == 0 {
		return 0
	}

	// Read available data
	bytesToRead := min(windows.DWORD(len(buffer)), bytesAvailable)
	bytesRead: windows.DWORD

	if windows.ReadFile(handle.hPipeIn, raw_data(buffer), bytesToRead, &bytesRead, nil) ==
	   windows.FALSE {
		return 0
	}

	return int(bytesRead)
}

// Write to PTY
write_pty :: proc(handle: PTYHandle, data: []u8) -> int {
	if handle.hPipeOut == INVALID_HANDLE do return 0
	if len(data) == 0 do return 0

	bytesWritten: windows.DWORD
	if windows.WriteFile(
		   handle.hPipeOut,
		   raw_data(data),
		   windows.DWORD(len(data)),
		   &bytesWritten,
		   nil,
	   ) ==
	   windows.FALSE {
		return 0
	}

	return int(bytesWritten)
}

// Resize PTY
resize_pty :: proc(handle: PTYHandle, rows, cols: int) {
	if handle.hPC == nil do return

	size := COORD {
		X = windows.SHORT(cols),
		Y = windows.SHORT(rows),
	}

	ResizePseudoConsole(handle.hPC, size)
}

// Close PTY and terminate process
close_pty :: proc(handle: PTYHandle) {
	// Terminate process if still running
	if handle.hProcess != INVALID_HANDLE {
		windows.TerminateProcess(handle.hProcess, 0)
		windows.CloseHandle(handle.hProcess)
	}

	if handle.hThread != INVALID_HANDLE {
		windows.CloseHandle(handle.hThread)
	}

	// Close pseudo console
	if handle.hPC != nil {
		ClosePseudoConsole(handle.hPC)
	}

	// Cleanup attribute list
	if handle.attributeList != nil {
		DeleteProcThreadAttributeList(handle.attributeList)
	}

	if handle.attributeListBuf != nil {
		delete(handle.attributeListBuf)
	}

	// Close pipes
	if handle.hPipeIn != INVALID_HANDLE {
		windows.CloseHandle(handle.hPipeIn)
	}

	if handle.hPipeOut != INVALID_HANDLE {
		windows.CloseHandle(handle.hPipeOut)
	}

	fmt.println("[pty_windows] ConPTY closed")
}
