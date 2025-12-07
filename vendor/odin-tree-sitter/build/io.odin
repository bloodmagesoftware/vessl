package ts_build

import "core:c/libc"
import "core:log"
import os "core:os/os2"
import "core:strings"

exec :: proc(command: ..string) -> bool {
	log.info(command)

	// Use libc.system() instead of os2.process_start() because os2 is experimental
	// and has broken syscalls on Linux arm64.
	cmd_str := strings.join(command, " ")
	defer delete(cmd_str)

	cmd_cstr := strings.clone_to_cstring(cmd_str)
	defer delete(cmd_cstr)

	ret := libc.system(cmd_cstr)
	if ret != 0 {
		log.warnf("process exited with status code: %v", ret)
		return false
	}

	return true
}

compile :: proc(cmd: ^[dynamic]string) -> (ok: bool) {
	// On Windows, try MSVC tools first since we use MSVC-style flags
	when ODIN_OS == .Windows {
		tries := []string{"", "cl", "cl.exe", "cc", "gcc", "clang"}
	} else {
		tries := []string{"", "cc", "cl", "cl.exe", "gcc", "clang"}
	}

	cc, eok := os.lookup_env("CC", context.temp_allocator)
	if eok {tries[0] = cc}

	inject_at(cmd, 0, "")
	for try in tries {
		cmd[0] = try
		if cmd[0] == "" do continue
		if ok = exec(..cmd[:]); ok do break
	}

	if !ok {
		log.errorf("failed to compile C code, tried: %s", strings.join(tries, ", "))
	}

	return
}

archive :: proc(cmd: ^[dynamic]string) -> (ok: bool) {
	// On Windows, try MSVC tools first since we use MSVC-style flags
	when ODIN_OS == .Windows {
		tries := []string{"", "lib", "lib.exe", "ar"}
	} else {
		tries := []string{"", "ar", "lib", "lib.exe"}
	}

	cc, eok := os.lookup_env("AR", context.temp_allocator)
	if eok {tries[0] = cc}

	inject_at(cmd, 0, "")
	for try in tries {
		cmd[0] = try
		if cmd[0] == "" do continue
		if ok = exec(..cmd[:]); ok do break
	}

	if !ok {
		log.errorf("failed to archive code into library, tried: %s", strings.join(tries, ", "))
	}

	return
}

// First implemented this using a recursive thingy, but it fucked up over symlinks.
rmrf :: proc(path: string) -> (ok: bool) {
	log.debugf("rmrf %q", path)

	err := os.remove_all(path)
	if err != nil {
		log.errorf("failed recursively deleting %q: %v", path, os.error_string(err))
		return false
	}
	return true
}

rm :: proc(path: string) -> bool {
	log.debugf("rm %q", path)

	err := os.remove(path)
	if err != nil {
		log.errorf("failed removing %q: %v", path, os.error_string(err))
		return false
	}

	return true
}

rm_dir :: rm
rm_file :: rm

cp :: proc(src, dst: string, try_it := false, rm_src := false) -> (ok: bool) {
	log.debugf("cp %q %q", src, dst)

	// Use copy_directory_all for directories, file-specific copy for files
	if os.is_dir(src) {
		err := os.copy_directory_all(dst, src)
		if err != nil {
			if try_it {
				log.infof("failed copying directory %q to %q: %v", src, dst, os.error_string(err))
			} else {
				log.errorf("failed copying directory %q to %q: %v", src, dst, os.error_string(err))
			}
			return false
		}
	} else {
		// For files, read and write manually to avoid copy_directory_all issues
		data, rerr := os.read_entire_file_from_path(src, context.allocator)
		if rerr != nil {
			if try_it {
				log.infof("failed reading file %q: %v", src, os.error_string(rerr))
			} else {
				log.errorf("failed reading file %q: %v", src, os.error_string(rerr))
			}
			return false
		}
		defer delete(data)

		werr := os.write_entire_file_from_bytes(dst, data)
		if werr != nil {
			if try_it {
				log.infof("failed writing file %q: %v", dst, os.error_string(werr))
			} else {
				log.errorf("failed writing file %q: %v", dst, os.error_string(werr))
			}
			return false
		}
	}

	if rm_src {
		if os.is_dir(src) {
			return rmrf(src)
		}

		return rm(src)
	}

	return true
}

cp_file :: cp
