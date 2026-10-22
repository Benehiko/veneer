const std = @import("std");
const windows = std.os.windows;
const env_names = @import("env.zig");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const exe = env.get(env_names.game_exe) orelse {
        std.debug.print("veneer-inject: {s} is not set\n", .{env_names.game_exe});
        return error.NoGame;
    };
    const args = env.get(env_names.game_args) orelse "";
    const dlls = env.get(env_names.dlls) orelse "";

    var cmd_utf8: [32 * 1024]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_utf8, "\"{s}\"{s}{s}", .{ exe, if (args.len > 0) " " else "", args });

    const proc = spawnSuspended(exe, cmd) catch |err| {
        std.debug.print("veneer-inject: could not start {s}: {s}\n", .{ exe, @errorName(err) });
        return err;
    };

    var it = std.mem.tokenizeScalar(u8, dlls, ';');
    while (it.next()) |dll| {
        injectDll(proc.process, dll) catch |err| {
            std.debug.print("veneer-inject: loading {s} failed: {s}; the game runs without it\n", .{ dll, @errorName(err) });
            continue;
        };
        std.debug.print("veneer-inject: loaded {s}\n", .{dll});
    }

    if (ResumeThread(proc.thread) == ~@as(windows.DWORD, 0)) return error.ResumeFailed;
    _ = WaitForSingleObject(proc.process, INFINITE);
    var code: windows.DWORD = 0;
    _ = GetExitCodeProcess(proc.process, &code);
    _ = CloseHandle(proc.thread);
    _ = CloseHandle(proc.process);
    std.debug.print("veneer-inject: game exited with code {d}\n", .{code});
    if (code != 0) std.process.exit(@truncate(code));
}

const Spawned = struct {
    process: windows.HANDLE,
    thread: windows.HANDLE,
};

const CREATE_SUSPENDED: windows.DWORD = 0x00000004;
const INFINITE: windows.DWORD = 0xFFFFFFFF;
const MEM_COMMIT: windows.DWORD = 0x1000;
const MEM_RESERVE: windows.DWORD = 0x2000;
const MEM_RELEASE: windows.DWORD = 0x8000;
const PAGE_READWRITE: windows.DWORD = 0x04;

const STARTUPINFOW = extern struct {
    cb: windows.DWORD,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: windows.DWORD,
    dwY: windows.DWORD,
    dwXSize: windows.DWORD,
    dwYSize: windows.DWORD,
    dwXCountChars: windows.DWORD,
    dwYCountChars: windows.DWORD,
    dwFillAttribute: windows.DWORD,
    dwFlags: windows.DWORD,
    wShowWindow: windows.WORD,
    cbReserved2: windows.WORD,
    lpReserved2: ?*u8,
    hStdInput: ?windows.HANDLE,
    hStdOutput: ?windows.HANDLE,
    hStdError: ?windows.HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: windows.DWORD,
    dwThreadId: windows.DWORD,
};

fn spawnSuspended(exe: []const u8, cmd: []const u8) !Spawned {
    var exe_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const wexe = try utf8ToWideZ(&exe_buf, exe);
    var cmd_buf: [32 * 1024]u16 = undefined;
    const wcmd = try utf8ToWideZ(&cmd_buf, cmd);

    var si = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    var pi = std.mem.zeroes(PROCESS_INFORMATION);
    if (CreateProcessW(wexe.ptr, wcmd.ptr, null, null, windows.BOOL.TRUE, CREATE_SUSPENDED, null, null, &si, &pi) == .FALSE) {
        return error.CreateProcessFailed;
    }
    return .{ .process = pi.hProcess, .thread = pi.hThread };
}

fn injectDll(process: windows.HANDLE, dll_path: []const u8) !void {
    var wide_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const wide = try utf8ToWideZ(&wide_buf, dll_path);
    const bytes = (wide.len + 1) * 2;

    const remote = VirtualAllocEx(process, null, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse
        return error.VirtualAllocFailed;
    defer _ = VirtualFreeEx(process, remote, 0, MEM_RELEASE);

    if (WriteProcessMemory(process, remote, @ptrCast(wide.ptr), bytes, null) == .FALSE)
        return error.WriteMemoryFailed;

    const kernel32 = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse return error.NoKernel32;
    const load_library = GetProcAddress(kernel32, "LoadLibraryW") orelse return error.NoLoadLibrary;

    const thread = CreateRemoteThread(process, null, 0, @ptrCast(load_library), remote, 0, null) orelse
        return error.RemoteThreadFailed;
    defer _ = CloseHandle(thread);
    if (WaitForSingleObject(thread, INFINITE) != 0) return error.RemoteThreadWaitFailed;
    var module: windows.DWORD = 0;
    _ = GetExitCodeThread(thread, &module);
    if (module == 0) return error.LoadLibraryFailed;
}

fn utf8ToWideZ(buf: []u16, s: []const u8) ![:0]u16 {
    const n = try std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s);
    buf[n] = 0;
    return buf[0..n :0];
}

extern "kernel32" fn GetModuleHandleW(lpModuleName: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: windows.BOOL,
    dwCreationFlags: windows.DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(.winapi) windows.DWORD;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetExitCodeThread(hThread: windows.HANDLE, lpExitCode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn VirtualAllocEx(hProcess: windows.HANDLE, lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: windows.DWORD, flProtect: windows.DWORD) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFreeEx(hProcess: windows.HANDLE, lpAddress: *anyopaque, dwSize: usize, dwFreeType: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteProcessMemory(hProcess: windows.HANDLE, lpBaseAddress: *anyopaque, lpBuffer: *const anyopaque, nSize: usize, lpNumberOfBytesWritten: ?*usize) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateRemoteThread(hProcess: windows.HANDLE, lpThreadAttributes: ?*anyopaque, dwStackSize: usize, lpStartAddress: *const anyopaque, lpParameter: ?*anyopaque, dwCreationFlags: windows.DWORD, lpThreadId: ?*windows.DWORD) callconv(.winapi) ?windows.HANDLE;
