package main

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:runtime"
import "core:slice"
import "core:strings"

import win "core:sys/windows"
import "vendor:glfw"
import vk "vendor:vulkan"

import im "deps:odin-imgui"
import "deps:odin-imgui/imgui_impl_glfw"
import "deps:odin-imgui/imgui_impl_vulkan"
import vma "deps:odin-vma"

vk_check :: proc(result: vk.Result, loc := #caller_location) {
	p := context.assertion_failure_proc
	if result != .SUCCESS {
		p("vk_check failed", reflect.enum_string(result), loc)
	}
}

main :: proc() {
	when ODIN_OS == .Windows {
		// Use UTF-8 for console output (fixes emojis/unicode/utf-8 shenanigans)
		win.SetConsoleOutputCP(win.CP_UTF8)
	}
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	app := VulkanEngine {
		window_extent = {1700, 900},
	}

	if !run(&app) {
		fmt.println("App could not be initialized.")
	}
}
