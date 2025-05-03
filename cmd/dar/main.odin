package main

import "../../../dar"
import "core:fmt"
import "core:mem"

main :: proc() {

	track := mem.Tracking_Allocator{}
	mem.tracking_allocator_init(&track, context.allocator)
	track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	context.allocator = mem.tracking_allocator(&track)
	defer {
		if len(track.allocation_map) > 0 || len(track.bad_free_array) > 0 {
			fmt.println("=======MEMORY TROUBLE=======")
		}
		for _, leak in track.allocation_map {
			fmt.printfln("%v leaked %m", leak.location, leak.size)
		}
		for bad in track.bad_free_array {
			fmt.printfln("%v bad free", bad.location)
		}
		if len(track.allocation_map) > 0 || len(track.bad_free_array) > 0 {
			fmt.println("=======MEMORY TROUBLE=======")
		}
		mem.tracking_allocator_destroy(&track) // comes after ^ o/w use after free
	}

	fn := "test.dar"
	f, err := dar.file_create(fn, true)
	if err != nil {
		fmt.printfln("err: %v", err)
		return
	}

	str := "Hello World!"
	err = dar.add_file(f, "File1", transmute([]byte)(str))
	if err != nil {
		fmt.printfln("add file err: %v", err)
	}
	str = "Hello World!Hello World!Hello World!"
	err = dar.add_file(f, "File2", transmute([]byte)(str))
	if err != nil {
		fmt.printfln("add file err: %v", err)
	}

	err = dar.file_close(f)
	if err != nil {
		fmt.printfln("close err: %v", err)
	}

	fr: ^dar.DAR_File
	fr, err = dar.file_open("test.dar")
	if err != nil {
		fmt.printfln("open err: %v", err)
	}
	fmt.printfln("%v", fr.files)

	err = dar.file_close(fr)
	if err != nil {
		fmt.printfln("close err: %v", err)
	}

}
