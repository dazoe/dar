package dar

import "core:bytes"
import "core:encoding/endian"
import "core:encoding/varint"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "vendor:zlib"

/*
  DAR file format will be...
  [4 byte signature] = "DAR" + version number as char '1'
  [
    [<unsigned varint> file name length in bytes]
	[<string> file name]
	[<unsigned varint> compressed file data size in bytes]
	[<unsigned varint> file size in bytes diference (add to compressed size to get true size)]
	[<x bytes> compressed file data]
  ]...
*/

DAR_Error :: enum {
	None = 0,
	File_Exists,
	File_Not_Found,
	File_Create_Error,
	File_Close_Error,
	Missing_Signature,
}

ZLIB_Error :: struct {
	code: i32,
}

Error :: union {
	DAR_Error,
	ZLIB_Error,
	varint.Error,
	io.Error,
	os.Error,
}

DAR_FileEntry :: struct {
	offset:    u64, // offset in file to file entry header
	comp_size: u64, // compressed file size
	file_size: u64, // uncompressed file size
}

DAR_File :: struct {
	f:        os.Handle,
	files:    map[string]DAR_FileEntry,
	readonly: bool,
}

file_open :: proc(filename: string) -> (file: ^DAR_File, err: Error) {
	if !os.exists(filename) {
		return nil, DAR_Error.File_Not_Found
	}
	f := os.open(filename) or_return
	{ 	// check for signature
		sig: [4]byte
		n := os.read(f, sig[:]) or_return
		if n != 4 || sig != "DAR1" {
			return nil, DAR_Error.Missing_Signature
		}
	}

	filesize := os.file_size(f) or_return

	dar := new(DAR_File)
	dar.f = f
	dar.files = make(map[string]DAR_FileEntry)
	// Read file list.
	for { 	// TODO: there is probably a better way to do this
		// <varuint file name len>
		fn_len: u128
		{
			buf := make([]byte, 1)
			defer delete(buf)
			verr := varint.Error.Buffer_Too_Small
			for off := 0; verr == varint.Error.Buffer_Too_Small; off += 1 {
				n := os.read(dar.f, buf) or_return
				fmt.printfln("n: %d", n)
				assert(n == 1)
				fn_len, _, verr = varint.decode_uleb128_byte(buf[0], off, fn_len)
			}
		}
		// <file name string>
		fn: string
		{
			buf := make([]byte, fn_len)
			n := os.read_full(dar.f, buf) or_return
			fmt.printfln("n: %d, len(buf): %d buf: %s", n, len(buf), transmute(string)(buf))
			assert(n == int(fn_len))
			fn = string(buf)
		}
		// <fdata size>
		fdata_size: u128
		{
			buf := make([]byte, 1)
			defer delete(buf)
			verr := varint.Error.Buffer_Too_Small
			for off := 0; verr == varint.Error.Buffer_Too_Small; off += 1 {
				n := os.read(dar.f, buf) or_return
				assert(n == 1)
				fdata_size, _, verr = varint.decode_uleb128_byte(buf[0], off, fdata_size)
			}
		}
		// <size - fdata size>
		fdata_diff: u128
		{
			buf := make([]byte, 1)
			defer delete(buf)
			verr := varint.Error.Buffer_Too_Small
			for off := 0; verr == varint.Error.Buffer_Too_Small; off += 1 {
				n := os.read(dar.f, buf) or_return
				assert(n == 1)
				fdata_diff, _, verr = varint.decode_uleb128_byte(buf[0], off, fdata_diff)
			}
		}
		offset := os.seek(dar.f, 0, os.SEEK_CUR) or_return
		dar.files[fn] = DAR_FileEntry {
			comp_size = u64(fdata_size),
			file_size = u64(fdata_size + fdata_diff),
			offset    = u64(offset),
		}

		// skip to the next file entry
		off := os.seek(dar.f, i64(fdata_size), os.SEEK_CUR) or_return
		if off == filesize {
			break
		}
	}
	return dar, nil
}

file_create :: proc(filename: string, overwrite: bool = false) -> (file: ^DAR_File, err: Error) {
	if !overwrite && os.exists(filename) {
		return nil, DAR_Error.File_Exists
	}
	flags := os.O_CREATE | os.O_RDWR
	if overwrite {
		flags |= os.O_TRUNC
	}
	f, oerr := os.open(filename, flags, 0o666)
	if oerr != nil {
		return nil, DAR_Error.File_Create_Error
	}
	// New file so write signature
	sig := "DAR1"
	n := os.write(f, transmute([]byte)(sig)) or_return
	assert(n == len(sig))
	df := new(DAR_File)
	df.f = f
	df.files = make(map[string]DAR_FileEntry)
	df.readonly = false
	return df, nil
}

file_close :: proc(f: ^DAR_File) -> Error {
	// no matter what we are going to clean up at the end of this funcion.
	defer {
		delete(f.files)
		f.files = nil
		free(f)
	}

	for k, _ in f.files {
		delete(k)
	}

	os.close(f.f) or_return
	return nil
}

add_file :: proc(dar: ^DAR_File, filename: string, data: []byte) -> Error {
	// <varuint name len> + <filename string>
	buf := bytes.Buffer{}
	defer bytes.buffer_destroy(&buf)
	vi: [varint.LEB128_MAX_BYTES]byte
	n := varint.encode_uleb128(vi[:], u128(len(filename))) or_return
	bytes.buffer_write(&buf, vi[:n]) or_return
	bytes.buffer_write(&buf, transmute([]byte)(filename)) or_return

	// compress data
	comp_len := zlib.compressBound(u64(len(data)))
	comp := make([]byte, comp_len)
	defer delete(comp)
	ok := zlib.compress(raw_data(comp), &comp_len, raw_data(data), u64(len(data)))
	if ok != zlib.OK {
		return ZLIB_Error{ok}
		// return DAR_Error{.ZLIB_ERROR, i32(ok)}
	}

	fdata := comp[:comp_len]
	diff := len(data) - int(comp_len)
	if diff < 0 {
		// compression increases size, store uncompressed
		fdata = data[:]
		comp_len = u64(len(data))
	}
	fmt.printfln("diff: %d", diff)

	//<varuint fdata size>
	n = varint.encode_uleb128(vi[:], u128(len(fdata))) or_return
	bytes.buffer_write(&buf, vi[:n]) or_return

	//<varuint (size - fdata size)> (also signals if we compressed the data)
	n = varint.encode_uleb128(vi[:], u128(len(data) - len(fdata))) or_return
	bytes.buffer_write(&buf, vi[:n]) or_return

	//<fdata>
	bytes.buffer_write(&buf, fdata) or_return

	// seek to the end of the file and place the data there.
	off := os.seek(dar.f, 0, os.SEEK_END) or_return
	n = os.write(dar.f, buf.buf[:]) or_return
	// add to the file list.
	filename_clone := strings.clone(filename)
	dar.files[filename_clone] = DAR_FileEntry {
		offset    = u64(off),
		comp_size = comp_len,
		file_size = u64(len(data)),
	}
	fmt.printfln("wrote %m", n)
	return nil
}

/*
read_file :: proc(f: ^DAR_File, fn: string) -> ([]byte, Error) {
	fe, ok := f.files[fn]
	if !ok {
		return nil, DAR_Error.File_Not_Found
	}
	n := os.seek(f.f, i64(fe.offset), os.SEEK_SET) or_return
	assert(n == i64(fe.offset))
	zbuf := make([]byte, fe.comp_size)
	defer delete(zbuf)
	n := os.read_full(f.f, zbuf)

	data = make([]byte, fe.file_size)
	data_len := zlib.uLongf
	zlib.uncompress(raw_data(data))


	// TODO: complete me
	return nil, DAR_Error.Missing_Signature
}
*/
