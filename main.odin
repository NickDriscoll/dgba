package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:sys/info"
import "core:thread"
import win32 "core:sys/windows"

import vkw "desktop_vulkan_wrapper"

MAX_THREADS :: 64
PER_THREAD_HEAP :: 1 * 1024 * 1024
WINDOW_TITLE :: "DGBA"

ThreadParameters :: struct {
    thread_idx: u32,
    heap: mem.Arena,
}

parallel_main :: proc(data: rawptr) {
    thread_parameters := (^ThreadParameters)(data)
    thread_id := thread_parameters.thread_idx

    sb: strings.Builder
    strings.builder_init(&sb)

    // Initialize thread's logger
    logfile: os.Handle
    {
        filename := fmt.sbprintf(&sb, "thread%v.log", thread_id)
        defer strings.builder_reset(&sb)
        file, err := os.open(filename, os.O_CREATE | os.O_WRONLY)
        if err != nil {
            log.errorf("Error opening thread %v logger: %v", thread_id, err)
        }
        logfile = file
    }
    context.logger = log.create_file_logger(logfile, .Info)
    defer log.destroy_file_logger(context.logger)

    log.infof("It looks like my thread_idx == %v", thread_id)

    // Create Windows window on only one thread!
    if thread_id == 0 {
        log.info("Starting to create Windows window.")
        instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))
        assert(instance != nil, "Failed to fetch current instance")
        class_name : cstring16 = "Windows Window"

        cls := win32.WNDCLASSW {
            lpfnWndProc = win_proc,
            lpszClassName = class_name,
            hInstance = instance,
        }

        class := win32.RegisterClassW(&cls)
        assert(class != 0, "Class creation failed")

        hwnd := win32.CreateWindowW(class_name,
            WINDOW_TITLE,
            win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,
            100, 100, 1280, 720,
            nil, nil, instance, nil)

        assert(hwnd != nil, "Window creation Failed")
        msg: win32.MSG

        for	win32.GetMessageW(&msg, nil, 0, 0) > 0 {
            win32.TranslateMessage(&msg)
            win32.DispatchMessageW(&msg)
        }
    }
}

win_proc :: proc "stdcall" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	switch(msg) {
	case win32.WM_DESTROY:
		win32.PostQuitMessage(0)
	}

	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

main :: proc() {
    // --- Minimal amount of startup code before thread dispatch ---
    context.allocator = runtime.heap_allocator()
    context.logger = log.create_console_logger(.Info)
    log.info("Let's get it")

    cpu := info.cpu

    thread_params: [MAX_THREADS]ThreadParameters // Each entry is received by one parallel_main() call
    threads: [MAX_THREADS]^thread.Thread         // Handles for each spawned thread

    // Spawn one thread per physical CPU core
    for thread_idx in 0..<cpu.physical_cores { // @TODO: Should this be cpu.logical_cores?
        tp := &thread_params[thread_idx]
        tp.thread_idx = u32(thread_idx)

        // Initialize per-thread context
        ctxt := context
        thread_heap_memory, err := mem.alloc_bytes(PER_THREAD_HEAP)
        if err != nil {
            log.errorf("Error allocating thread %v heap: %v", thread_idx, err)
        }
        mem.arena_init(&tp.heap, thread_heap_memory)
        ctxt.allocator = mem.arena_allocator(&tp.heap)

        threads[thread_idx] = thread.create_and_start_with_data(
            &thread_params[thread_idx],
            parallel_main,
            ctxt
        )
    }

    // Main thread immediately joins on all spawned threads
    log.info("Waiting on spawned threads... (tail individual thread logs for more info)")
    for thread_idx in 0..<cpu.physical_cores {
        thread.join(threads[thread_idx])
    }

    log.info("Exiting main()")
}
