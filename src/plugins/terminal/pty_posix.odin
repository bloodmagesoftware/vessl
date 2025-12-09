#+build linux, darwin
package terminal

// POSIX PTY implementation using forkpty
// Works on Linux and macOS

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

// Foreign imports for PTY and system functions
when ODIN_OS == .Darwin {
	foreign import util_lib "system:System.B"
	foreign import libc "system:System.B"
} else when ODIN_OS == .Linux {
	foreign import util_lib "system:util"
	foreign import libc "system:c"
}

// Terminal size structure
Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

// ioctl request codes
when ODIN_OS == .Darwin {
	TIOCSWINSZ :: 0x80087467 // Set window size
	TIOCGWINSZ :: 0x40087468 // Get window size
} else {
	TIOCSWINSZ :: 0x5414 // Set window size on Linux
	TIOCGWINSZ :: 0x5413 // Get window size on Linux
}

// File control flags
O_NONBLOCK :: 0x0004 when ODIN_OS == .Darwin else 0x0800
F_GETFL :: 3
F_SETFL :: 4

@(default_calling_convention = "c")
foreign util_lib {
	// Fork a new process with a pseudo-terminal
	forkpty :: proc(amaster: ^c.int, name: [^]c.char, termp: rawptr, winp: ^Winsize) -> c.int ---
}

@(default_calling_convention = "c")
foreign libc {
	// Standard process/file operations
	execvp :: proc(file: cstring, argv: [^]cstring) -> c.int ---
	close :: proc(fd: c.int) -> c.int ---
	read :: proc(fd: c.int, buf: [^]u8, count: c.size_t) -> c.ssize_t ---
	write :: proc(fd: c.int, buf: [^]u8, count: c.size_t) -> c.ssize_t ---
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	fcntl :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..any) -> c.int ---
	waitpid :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
	kill :: proc(pid: c.int, sig: c.int) -> c.int ---
	_exit :: proc(status: c.int) ---
	setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
}

// Signals
SIGTERM :: 15
SIGKILL :: 9
WNOHANG :: 1

// PTY handle for POSIX systems
PTYHandle :: struct {
	master_fd: c.int, // Master side of PTY
	child_pid: c.int, // Child process ID
}

// Get the default shell for the current user
get_default_shell :: proc() -> string {
	// Try SHELL environment variable first
	shell_env := os.get_env("SHELL")
	if len(shell_env) > 0 {
		return shell_env
	}

	// Default shells by platform
	when ODIN_OS == .Darwin {
		return "/bin/zsh"
	} else {
		return "/bin/bash"
	}
}

// Spawn a new PTY with the given shell
spawn_pty :: proc(shell: string, rows, cols: int) -> (handle: PTYHandle, ok: bool) {
	handle = PTYHandle {
		master_fd = -1,
		child_pid = -1,
	}

	// Set up window size
	ws := Winsize {
		ws_row = c.ushort(rows),
		ws_col = c.ushort(cols),
	}

	// Fork with PTY
	master_fd: c.int
	pid := forkpty(&master_fd, nil, nil, &ws)

	if pid < 0 {
		fmt.eprintln("[pty_posix] forkpty failed")
		return handle, false
	}

	if pid == 0 {
		// Child process - exec the shell
		shell_cstr := strings.clone_to_cstring(shell)

		// Set up argv
		argv: [2]cstring = {shell_cstr, nil}

		// Set environment variables for proper terminal behavior
		setenv("TERM", "xterm-256color", 1)
		setenv("COLORTERM", "truecolor", 1)

		// Execute shell
		execvp(shell_cstr, raw_data(argv[:]))

		// If exec fails, exit
		fmt.eprintln("[pty_posix] execvp failed")
		_exit(1)
	}

	// Parent process
	handle.master_fd = master_fd
	handle.child_pid = pid

	// Set master fd to non-blocking
	flags := fcntl(master_fd, F_GETFL)
	if flags != -1 {
		fcntl(master_fd, F_SETFL, flags | O_NONBLOCK)
	}

	fmt.printf("[pty_posix] Spawned PTY: master_fd=%d, child_pid=%d\n", master_fd, pid)
	return handle, true
}

// Read from PTY (non-blocking)
read_pty :: proc(handle: PTYHandle, buffer: []u8) -> int {
	if handle.master_fd < 0 do return 0
	if len(buffer) == 0 do return 0

	bytes_read := read(handle.master_fd, raw_data(buffer), c.size_t(len(buffer)))

	if bytes_read < 0 {
		// EAGAIN/EWOULDBLOCK means no data available (non-blocking)
		return 0
	}

	return int(bytes_read)
}

// Write to PTY
write_pty :: proc(handle: PTYHandle, data: []u8) -> int {
	if handle.master_fd < 0 do return 0
	if len(data) == 0 do return 0

	bytes_written := write(handle.master_fd, raw_data(data), c.size_t(len(data)))

	if bytes_written < 0 {
		return 0
	}

	return int(bytes_written)
}

// Resize PTY
resize_pty :: proc(handle: PTYHandle, rows, cols: int) {
	if handle.master_fd < 0 do return

	ws := Winsize {
		ws_row = c.ushort(rows),
		ws_col = c.ushort(cols),
	}

	ioctl(handle.master_fd, TIOCSWINSZ, &ws)
}

// Close PTY and terminate child process
close_pty :: proc(handle: PTYHandle) {
	if handle.child_pid > 0 {
		// Send SIGTERM first
		kill(handle.child_pid, SIGTERM)

		// Wait briefly for process to exit
		status: c.int
		result := waitpid(handle.child_pid, &status, WNOHANG)

		if result == 0 {
			// Process still running, send SIGKILL
			kill(handle.child_pid, SIGKILL)
			waitpid(handle.child_pid, &status, 0)
		}
	}

	if handle.master_fd >= 0 {
		close(handle.master_fd)
	}

	fmt.println("[pty_posix] PTY closed")
}
