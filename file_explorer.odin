package waveform_editor

import "base:intrinsics"
import "core:container/handle_map"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import imgui "imgui:/"
import "./assets"
import "./colors"
import ma "vendor:miniaudio"

FILES_ALLOWED: []string : []string { 	//Sorted so that binary_search will work
	".astc",
	".bmp",
	".dds",
	".gif",
	".hdr",
	".jpg",
	".ktx",
	".lua",
	".pgm",
	".ppm",
	".pbm",
	".pic",
	".pkm",
	".png",
	".psd",
	".wav",
}

AUDIO_ALLOWED: []string : []string{".wav"} //This is the only one that works for miniaudio

MAX_PATH_LEN :: 4096
path_buf: [MAX_PATH_LEN]u8
edit_path_buf: [MAX_PATH_LEN]u8

init_path_dir :: proc() {
	mem.zero(&path_buf[0], MAX_PATH_LEN)
	full_path, err1 := os.get_executable_path(context.allocator)
	if err1 != nil {
		panic("Unable to get path")
	}
	defer delete(full_path)
	dir, _ := filepath.split(full_path)

	assert(copy_from_string(path_buf[:], dir) < MAX_PATH_LEN)
	revert_edit_path()
}
get_path_dir :: #force_inline proc() -> string {
	return string(cstring(&path_buf[0]))
}
get_path_dir_cstr :: #force_inline proc() -> cstring {
	return cstring(&path_buf[0])
}
get_edit_path_dir :: #force_inline proc() -> string {
	return string(cstring(&edit_path_buf[0]))
}
revert_edit_path :: #force_inline proc() {
	copy_from_string(edit_path_buf[:], string(path_buf[:]))
}
confirm_edit_path :: #force_inline proc() {
	copy_from_string(path_buf[:], string(edit_path_buf[:]))
}

PathFiles :: struct {
	dir_f:      ^os.File,
	file_infos: []os.File_Info,
	file_pfds:  [dynamic]PathFilesData,
}

PathFilesType :: enum {
	Back,
	Directory,
	Image,
	Audio,
	Lua,
}

PathFilesData :: struct {
	type: PathFilesType,
	sb:   strings.Builder,
}

path_files_new :: proc(use_path: string) -> (PathFiles, bool) {
	success := false
	dir_f, err := os.open(use_path)
	if err != nil do return {}, false
	defer if !success do os.close(dir_f)
	files: []os.File_Info = ---
	files, err = os.read_dir(dir_f, -1, context.allocator)
	if err != nil do return {}, false
	defer if !success do os.file_info_slice_delete(files, context.allocator)

	file_pfds: [dynamic]PathFilesData = {}
	sb_back := strings.builder_make(context.allocator) or_else panic("Unable to allocate")
	strings.write_string(&sb_back, "..")
	strings.write_byte(&sb_back, 0)
	append_elem(&file_pfds, PathFilesData{type = .Back, sb = sb_back})
	for &f in files {
		ext := filepath.ext(f.name)
		is_dir := f.type == .Directory
		if is_dir {
			_path_files_write(&f, &file_pfds, .Directory)
		} else if _, allowed := slice.binary_search(FILES_ALLOWED, ext); allowed {
			if _, is_audio := slice.binary_search(AUDIO_ALLOWED, ext); is_audio {
				_path_files_write(&f, &file_pfds, .Audio)
			} else if ext == ".lua" {
				_path_files_write(&f, &file_pfds, .Lua)
			} else {
				_path_files_write(&f, &file_pfds, .Image)
			}
		}
	}
	success = true
	slice.sort_by(file_pfds[:], proc(lhs, rhs: PathFilesData) -> bool {
		if lhs.type != rhs.type {
			return lhs.type < rhs.type
		} else {
			return cstring(&lhs.sb.buf[0]) < cstring(&rhs.sb.buf[0])
		}
	})
	return {dir_f = dir_f, file_infos = files, file_pfds = file_pfds}, true
}
_path_files_write :: proc(
	f: ^os.File_Info,
	file_pfds: ^[dynamic]PathFilesData,
	type: PathFilesType,
) {
	sb := strings.builder_make(context.allocator) or_else panic("Unable to allocate")
	strings.write_string(&sb, f.name)
	strings.write_byte(&sb, 0)
	append_elem(file_pfds, PathFilesData{type = type, sb = sb})
}

path_files_destroy :: proc(pf: ^PathFiles) {
	for &pfd in pf.file_pfds {
		strings.builder_destroy(&pfd.sb)
	}
	delete(pf.file_pfds)
	os.file_info_slice_delete(pf.file_infos, context.allocator)
	os.close(pf.dir_f)
}

FileExplorerAudioState :: enum {
	None,
	ChooseLoadAs,
	ChooseLoadAsWavExport,
	SaveAs,
	SaveAsOverwrite,
	ReadError,
}

FileExplorerAudio :: struct {
	state:    FileExplorerAudioState,
	audio_ma: ma.decoder,
	file_str: string,
	prop:     FileExplorerAudioWavProperties,
}

FileExplorerAudioWavProperties :: struct {
	num_frames:  i32,
	num_samples: i32,
}

file_explorer_audio_new :: proc(self: ^FileExplorerAudio, audio_file_str: string) {
	assert(self.state == .None || self.state == .ReadError)
	self^ = {
		prop = {num_frames = 256, num_samples = 64},
	}
	dconfig := ma.decoder_config_init(.f32, 1, 44100)
	result := ma.decoder_init_file(
		strings.unsafe_string_to_cstring(audio_file_str),
		&dconfig,
		&self.audio_ma,
	)
	if result == .SUCCESS {
		self.state = .ChooseLoadAs
		self.file_str = audio_file_str
	} else {
		log.errorf("Unable to load audio file '%s': %v", audio_file_str, result)
		self.state = .ReadError
		delete(audio_file_str)
	}
}

file_explorer_audio_keep :: proc(self: ^FileExplorerAudio, move: ^ma.decoder) {
	assert(self.state == .ChooseLoadAs)
	move^ = self.audio_ma
	self.audio_ma = {}
	delete(self.file_str)
	self.state = .None
}

file_explorer_audio_destroy :: proc(self: ^FileExplorerAudio) {
	switch self.state {
	case .ChooseLoadAs, .ChooseLoadAsWavExport:
		ma.decoder_uninit(&self.audio_ma)
		self.audio_ma = {}
		delete(self.file_str)
		self.state = .None
	case .SaveAs, .SaveAsOverwrite:
		delete(self.file_str)
		self.state = .None
	case .None, .ReadError:
	}
}

FileExplorerAudioMultiState :: enum {
	None,
	Save,
	CheckOverwrite,
}

FileExplorerAudioMulti :: struct {
	state:    FileExplorerAudioMultiState,
	file_dir: string,
}

file_explorer_audiomulti_destroy :: proc(self: ^FileExplorerAudioMulti) {
	switch self.state {
	case .Save, .CheckOverwrite:
		delete(self.file_dir)
		self.state = .None
	case .None:
	}
}

FileExplorerSaveLuaOverwrite :: struct {
	path:    string,
	win_idx: int,
	active:  bool,
}
file_explorer_save_lua_overwrite_destroy :: proc(self: ^FileExplorerSaveLuaOverwrite) {
	if self.active {
		delete(self.path)
		self^ = {}
	}
}

FileExplorerType :: enum {
	Load,
	LoadLuaScript,
	LoadToWindow,
	LoadFromAudioFolder,
	SaveToAudio,
	SaveToAudioFolder,
	SaveLuaScript,
}
FEButtonCStr: [FileExplorerType]cstring = {
	.Load                = "Load File",
	.LoadLuaScript       = "Load Script",
	.LoadToWindow        = "Load File",
	.LoadFromAudioFolder = "Load Audio from Folder",
	.SaveToAudio         = "Save .wav",
	.SaveToAudioFolder   = "Save Audio to Folder",
	.SaveLuaScript       = "Save Script",
}

file_explorer_new :: proc(app: ^App, fe_type: FileExplorerType) -> handle_map.Handle16 {
	file_explorer_type = fe_type
	app.windows.file_explorer = imgui_window_new(
		"File Explorer",
		0,
		container_f = f_file_explorer_draw,
		destroy_f = f_file_explorer_destroy,
		position = {{}, UDim{o = 20}},
		size = {UDim{s = 0.5}, UDim{o = -20, s = 0.5}},
		flags = {.NoScrollbar, .AlwaysVerticalScrollbar},
	)
	imgui_window_add_handle(app, &app.windows.file_explorer)
	return app.windows.file_explorer.handle
}

fe_new_folder_buf: [dynamic]u8
file_explorer_type: FileExplorerType = .Load
file_explorer_load_idx: int //.LoadToWindow, .SaveToAudio, .LoadFromAudioFolder, .SaveToAudioFolder
f_file_explorer_draw :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	style := imgui.GetStyle()
	draw_list := imgui.GetWindowDrawList()
	frame_height := imgui.GetFrameHeight()
	window_size := imgui.GetWindowSize()
	wp := imgui.GetWindowPos()
	tl := wp
	br := wp + imgui.GetWindowSize()
	button_size := imgui.Vec2 {
		window_size.x - imgui.GetStyle().WindowPadding.x * 2,
		imgui.GetFontSize() + imgui.GetStyle().FramePadding.y * 2,
	}
	pd_tl := tl + {0, frame_height}
	pd_br := tl + {0, frame_height} + button_size + {imgui.GetStyle().WindowPadding.x, 20}
	imgui.Dummy(pd_br - pd_tl - {0, imgui.GetStyle().ItemSpacing.y * 2})
	button_loop: for &f in app.state.path_files.file_pfds {
		switch file_explorer_type {
		case .SaveToAudio:
			if f.type == .Image do continue button_loop
			if f.type == .Lua do continue button_loop
		case .SaveToAudioFolder, .LoadFromAudioFolder:
			#partial switch f.type {
			case .Lua, .Image:
				continue button_loop
			}
		case .LoadLuaScript, .SaveLuaScript:
			if f.type == .Image do continue button_loop
			if f.type == .Audio do continue button_loop
		case .Load, .LoadToWindow:
			if f.type == .Lua do continue button_loop
		}
		switch f.type {
		case .Back:
			imgui.PushStyleColor(.Button, transmute(u32)(colors.RED_BUTTON.idle))
			imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.RED_BUTTON.hovered))
			imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.RED_BUTTON.active))
		case .Image, .Audio, .Lua:
			imgui.PushStyleColor(.Button, transmute(u32)(colors.GREEN_BUTTON.idle))
			imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.GREEN_BUTTON.hovered))
			imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.GREEN_BUTTON.active))
		case .Directory:
		}
		defer switch f.type {
		case .Back, .Image, .Audio, .Lua:
			imgui.PopStyleColor(3)
		case .Directory:
		}
		no_button_cb: if imgui.Button(cstring(&f.sb.buf[0]), button_size) {
			ec := EventCall {
				window     = base,
				userdata = &f.sb.buf[0],
			}
			switch f.type {
			case .Back:
				ec.event_f = f_fex_back_dir
			case .Directory:
				ec.event_f = f_fex_dir
			case .Image:
				ec.event_f = f_fex_image
			case .Audio:
				#partial switch file_explorer_type {
				case .LoadFromAudioFolder, .SaveToAudioFolder:
					tooltip_change(
						&app.state.tooltip,
						cstring("Please choose a directory to load/save the .wav files"),
						.Error,
						app.state.frames + 3000 / u64(app.config.mspf),
					)
					break no_button_cb
				case:
				}
				ec.event_f = f_fex_audio
			case .Lua:
				ec.event_f = f_fex_lua
			}
			queue.push_back(&app.state.events_f, ec)
		}
	}
	if imgui.ImageButton(
		"New Folder",
		as_texture_ref(app, TextureNames.tex_atlas),
		button_size.yy,
		assets.tex_atlas_uv[.FolderAdd].tl,
		assets.tex_atlas_uv[.FolderAdd].br,
	) {
		if fe_new_folder_buf == nil {
			fe_new_folder_buf = make([dynamic]u8, 1)
		}
	}
	if fe_new_folder_buf != nil {
		imgui.SameLine()
		imgui.InputText(
			"##New Folder Name",
			cstring(&fe_new_folder_buf[0]),
			len(fe_new_folder_buf),
			{.CallbackResize},
			input_text_resize,
			&fe_new_folder_buf,
		)
		if imgui.IsItemDeactivatedAfterEdit() {
			input_text_shrink(&fe_new_folder_buf)
			nf_str := string(cstring(&fe_new_folder_buf[0]))
			if nf_str != "" {
				defer {
					delete(fe_new_folder_buf)
					fe_new_folder_buf = nil
				}
				nf_abs_str := fmt.tprintf("%s/%s", get_path_dir(), nf_str)
				if !os.exists(nf_abs_str) {
					err := os.make_directory(nf_abs_str)
					if err == nil {
						refresh_dir_or_root(app)
					} else {
						log.errorf("Unable to create directory '{}': {}", nf_abs_str, err)
					}
				}
			}
		}
		imgui.SameLine()
		imgui.PushStyleColor(.Button, transmute(u32)(colors.RED_BUTTON.idle))
		imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.RED_BUTTON.hovered))
		imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.RED_BUTTON.active))
		if imgui.Button("Cancel") {
			delete(fe_new_folder_buf)
			fe_new_folder_buf = nil
		}
		imgui.PopStyleColor(3)
	}
	if imgui.IsItemHovered() {
		imgui.SetTooltip("New Folder")
	}

	choose_file_height: f32 = 50
	choose_file_tl := imgui.Vec2{tl.x, max(br.y - choose_file_height, tl.y)}
	choose_file_dummy_size :=
		br - choose_file_tl - {0, style.ScrollbarSize + style.ScrollbarPadding}
	imgui.Dummy(choose_file_dummy_size)
	imgui.DrawList_AddRectFilled(draw_list, pd_tl, pd_br, (0xdf000000))
	imgui.SetCursorPos(
		{style.WindowPadding.x, style.WindowPadding.y + frame_height + imgui.GetScrollY()},
	)
	ChooseButtonSize :: 150
	imgui.SetNextItemWidth(-ChooseButtonSize)
	imgui.BeginChild("Path Directory", {br.x - tl.x, pd_br.y - pd_tl.y})
	if imgui.InputText(
		"Path Directory",
		cstring(&edit_path_buf[0]),
		MAX_PATH_LEN,
		{.EnterReturnsTrue},
	) {
		new_abs_dir, e := filepath.abs(get_edit_path_dir())
		if e == nil {
			defer delete(new_abs_dir)
			mem.zero(&edit_path_buf[0], MAX_PATH_LEN)
			assert(copy_from_string(edit_path_buf[:], new_abs_dir) < MAX_PATH_LEN)
		}
		new_pf, ok := path_files_new(get_edit_path_dir())
		if ok {
			path_files_destroy(&app.state.path_files)
			app.state.path_files = new_pf
			confirm_edit_path()
		} else {
			tooltip_change(
				&app.state.tooltip,
				cstring("Invalid directory"),
				.Error,
				app.state.frames + 3000 / u64(app.config.mspf),
			)
			revert_edit_path()
		}
	}
	imgui.EndChild()
	imgui.DrawList_AddRectFilled(draw_list, choose_file_tl, br, 0xdf000000)
	imgui.SetCursorPos(
		{
			style.WindowPadding.x,
			style.WindowPadding.y + window_size.y - choose_file_height + imgui.GetScrollY(),
		},
	)
	imgui.BeginChild("Overlay", choose_file_dummy_size, {})
	imgui.SetNextItemWidth(
		-ChooseButtonSize - style.ScrollbarSize - style.ScrollbarPadding - style.ItemSpacing.x,
	)
	imgui.InputText(
		"##LoadSaveFile",
		cstring(&app.state.fe_choose_buf[0]),
		len(app.state.fe_choose_buf),
		{.CallbackResize},
		input_text_resize,
		&app.state.fe_choose_buf,
	)
	if imgui.IsItemDeactivatedAfterEdit() {
		input_text_shrink(&app.state.fe_choose_buf)
	}
	if file_explorer_type == .SaveToAudio {
		if imgui.IsItemHovered() {
			imgui.SetTooltip(".wav file only")
		}
	}
	if file_explorer_type == .SaveToAudioFolder {
		if imgui.IsItemHovered() {
			imgui.SetTooltip(
				"Select directory to save audio data\nThis will write .wav files frames numbered as the format '%03d.wav'",
			)
		}
	}
	imgui.SameLine()
	if imgui.Button(FEButtonCStr[file_explorer_type], {ChooseButtonSize, 0}) {
		if app.state.fe_choose_buf[0] != 0 {
			fe_choose_str := string(app.state.fe_choose_buf[:len(app.state.fe_choose_buf) - 1])
			for i in 0 ..< len(app.state.path_files.file_pfds) {
				pfd := &app.state.path_files.file_pfds[i]
				pfd_str := string(pfd.sb.buf[:len(pfd.sb.buf) - 1])
				if pfd_str == fe_choose_str {
					switch pfd.type {
					case .Directory:
						#partial switch file_explorer_type {
						case .LoadFromAudioFolder:
							queue.push_back(
								&app.state.events_f,
								EventCall {
									window = base,
									userdata = &pfd.sb.buf[0],
									event_f = f_fex_load_audio_dir,
								},
							)
							mem.zero(&app.state.fe_choose_buf[0], len(app.state.fe_choose_buf))
						case .SaveToAudioFolder:
							queue.push_back(
								&app.state.events_f,
								EventCall {
									window = base,
									userdata = &pfd.sb.buf[0],
									event_f = f_fex_save_audio_dir,
								},
							)
							mem.zero(&app.state.fe_choose_buf[0], len(app.state.fe_choose_buf))
						case:
							queue.push_back(
								&app.state.events_f,
								EventCall {
									window = base,
									userdata = &pfd.sb.buf[0],
									event_f = f_fex_dir,
								},
							)
							mem.zero(&app.state.fe_choose_buf[0], len(app.state.fe_choose_buf))
						}
					case .Image:
						#partial switch file_explorer_type {
						case .Load:
							queue.push_back(
								&app.state.events_f,
								EventCall {
									window = base,
									userdata = &pfd.sb.buf[0],
									event_f = f_fex_image,
								},
							)
							mem.zero(&app.state.fe_choose_buf[0], len(app.state.fe_choose_buf))
						}
					case .Audio:
						#partial switch file_explorer_type {
						case .LoadLuaScript, .SaveLuaScript:
						case .LoadFromAudioFolder, .SaveToAudioFolder:
							tooltip_change(
								&app.state.tooltip,
								cstring("Please choose a directory to load/save the .wav files"),
								.Error,
								app.state.frames + 3000 / u64(app.config.mspf),
							)
						case:
							queue.push_back(
								&app.state.events_f,
								EventCall {
									window = base,
									userdata = &pfd.sb.buf[0],
									event_f = f_fex_audio,
								},
							)
							mem.zero(&app.state.fe_choose_buf[0], len(app.state.fe_choose_buf))
						}
					case .Lua:
						#partial switch file_explorer_type {
						case .LoadLuaScript, .SaveLuaScript:
							queue.push_back(
								&app.state.events_f,
								EventCall {
									window = base,
									userdata = &pfd.sb.buf[0],
									event_f = f_fex_lua,
								},
							)
							mem.zero(&app.state.fe_choose_buf[0], len(app.state.fe_choose_buf))
						}
					case .Back:
					}
				}
			}
			#partial switch file_explorer_type {
			case .SaveToAudio:
				ext := filepath.ext(string(cstring(&app.state.fe_choose_buf[0])))
				if _, is_audio := slice.binary_search(AUDIO_ALLOWED, ext); is_audio {
					queue.push_back(
						&app.state.events_f,
						EventCall {
							window = base,
							userdata = &app.state.fe_choose_buf[0],
							event_f = f_fex_audio,
						},
					)
				}
			case .LoadLuaScript, .SaveLuaScript:
				ext := filepath.ext(string(cstring(&app.state.fe_choose_buf[0])))
				if ext == ".lua" {
					queue.push_back(
						&app.state.events_f,
						EventCall {
							window = base,
							userdata = &app.state.fe_choose_buf[0],
							event_f = f_fex_lua,
						},
					)
				}
			}
		} else { 	//Save to current directory if empty
			#partial switch file_explorer_type {
			case .LoadFromAudioFolder:
				queue.push_back(
					&app.state.events_f,
					EventCall {
						window = base,
						userdata = &app.state.fe_choose_buf[0],
						event_f = f_fex_load_audio_dir,
					},
				)
			case .SaveToAudioFolder:
				queue.push_back(
					&app.state.events_f,
					EventCall {
						window = base,
						userdata = &app.state.fe_choose_buf[0],
						event_f = f_fex_save_audio_dir,
					},
				)
			}
		}
	}
	imgui.EndChild()
}

f_file_explorer_destroy :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	handle_map.remove(&app.imgui_hm, base.handle)
	base.is_active = false
	if fe_new_folder_buf != nil {
		delete(fe_new_folder_buf)
	}
}

f_fex_back_dir :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	revert_edit_path() //In case buffer was edited
	parent := filepath.dir(string(get_path_dir()))
	mem.zero(&edit_path_buf[len(parent)], len(edit_path_buf) - len(parent))
	refresh_dir_or_root(app)
}
//Directory '/' will not have a back button.
f_fex_dir :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	mem.zero(&edit_path_buf[0], MAX_PATH_LEN)
	not_root := get_path_dir() != filepath.dir(get_path_dir())
	dir_cstr := cstring(cast(^u8)userdata)
	new_dir_str := fmt.aprintf(
		"%s%s%s",
		get_path_dir_cstr(),
		os.Path_Separator_String if not_root else "",
		dir_cstr,
	)
	defer delete(new_dir_str)
	copy_from_string(edit_path_buf[:], new_dir_str)
	refresh_dir_or_root(app)
	base.keep_scroll_here = imgui.Vec2{0, 0}
}
f_fex_save_audio_dir :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	assert(file_explorer_type == .SaveToAudioFolder)
	revert_edit_path() //In case buffer was edited
	not_root := get_path_dir() != filepath.dir(get_path_dir())
	dir_cstr := cstring(cast(^u8)userdata)
	full_dir_str := fmt.aprintf(
		"%s%s%s",
		get_path_dir_cstr(),
		os.Path_Separator_String if not_root else "",
		dir_cstr,
	)
	app.state.fe_audiomulti_state = FileExplorerAudioMulti {
		file_dir = full_dir_str,
		state    = .Save,
	}
	base.disabled = true
}
f_fex_load_audio_dir :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	assert(file_explorer_type == .LoadFromAudioFolder)
	defer base.show = false
	revert_edit_path() //In case buffer was edited
	not_root := get_path_dir() != filepath.dir(get_path_dir())
	dir_cstr := cstring(cast(^u8)userdata)
	full_dir_str := fmt.tprintf(
		"%s%s%s",
		get_path_dir_cstr(),
		os.Path_Separator_String if not_root else "",
		dir_cstr,
	)
	we_state := &app.state.we[file_explorer_load_idx]
	sync.mutex_guard(&wp_mutex)
	we_state.num_points = MAX_WAVEFORM_EDITOR_POINTS
	sync.mutex_unlock(&wp_mutex)
	set_read_samples: u64 = MAX_WAVEFORM_EDITOR_POINTS
	for frame in 0 ..< MAX_WAVEFORM_FRAMES {
		wav_file := fmt.tprintf(FILE_EXPLORER_WRITE_WAV_MULTI_STR, full_dir_str, frame)
		dma: ma.decoder
		dconfig := ma.decoder_config_init(.f32, 1, 44100)
		result := ma.decoder_init_file(strings.unsafe_string_to_cstring(wav_file), &dconfig, &dma)
		if result == .SUCCESS {
			if frame != 0 {
				we_state.data_frame = we_state.num_frames
				set_frames(app, file_explorer_load_idx, we_state.num_frames + 1)
				we_state.num_frames += 1
			} else {
				we_state.data_frame = 0
			}
		} else {
			log.infof(
				"Loaded {} .wav files as frames ({} samples)",
				we_state.num_frames,
				we_state.num_points,
			)
			break
		}
		defer ma.decoder_uninit(&dma)
		samples_read: u64
		result = ma.decoder_read_pcm_frames(
			&dma,
			&we_state.data[data_index(i32(frame), 0)],
			set_read_samples,
			&samples_read,
		)
		if samples_read < u64(we_state.num_points) {
			sync.mutex_guard(&wp_mutex)
			we_state.num_points = max(i32(samples_read), 1)
		}
		set_read_samples = samples_read
	}
}
refresh_dir_or_root :: proc(app: ^App) {
	new_pf, ok := path_files_new(get_edit_path_dir())
	if !ok { 	//Go to root if new directory path fails for any reason.
		root := filepath.abs("/") or_else panic("Unable to allocate")
		defer delete(root)
		mem.zero(&edit_path_buf[0], MAX_PATH_LEN)
		copy_from_string(edit_path_buf[:], root)
		new_pf = path_files_new(get_edit_path_dir()) or_else panic("Unable to allocate")
	}
	path_files_destroy(&app.state.path_files)
	app.state.path_files = new_pf
	confirm_edit_path()
}
f_fex_image :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	revert_edit_path() //In case buffer was edited
	we_image_new(app)
	file_cstr := cstring(cast(^u8)userdata)
	if app.state.we_img.pixels.data != nil {
		we_image_state_destroy(&app.state.we_img, app)
	}
	file_str_full := fmt.tprintf("%s/%s\x00", get_path_dir(), file_cstr)
	success: bool = ---
	app.state.we_img, success = we_image_state_new(
		app,
		strings.unsafe_string_to_cstring(file_str_full),
	)
	if !success do app.windows.image.show = false
}
f_fex_audio :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	revert_edit_path() //In case buffer was edited
	file_str := string(cstring(cast(^u8)userdata))
	if file_explorer_type != .SaveToAudio {
		file_explorer_audio_new(
			&app.state.fe_audio_state,
			fmt.aprintf("%s/%s\x00", get_path_dir(), file_str),
		)
		base.disabled = true
	} else {
		app.state.fe_audio_state.state = .SaveAs
		app.state.fe_audio_state.file_str = fmt.aprintf("%s/%s\x00", get_path_dir(), file_str)
		base.disabled = true
	}
}
f_fex_lua :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	revert_edit_path() //In case buffer was edited
	file := string(cstring(cast(^u8)userdata))
	assert(app.windows.lua[win_idx].is_active)
	if file_explorer_type == .LoadLuaScript {
		base.show = false
		abs_file := fmt.tprintf("%s/%s", get_path_dir(), file)
		file_str, err := os.read_entire_file(abs_file, context.allocator)
		if err != nil {
			log.errorf("Unable to open file '{}': {}", abs_file, err)
			return
		}
		defer delete(file_str)
		we_lua_state := &app.state.we_luas[win_idx]
		resize(&we_lua_state.text_buf, len(file_str) + 1) //+1 to null terminate
		mem.copy_non_overlapping(&we_lua_state.text_buf[0], &file_str[0], len(file_str))
		we_lua_state.text_buf[len(file_str)] = 0
	} else if file_explorer_type == .SaveLuaScript {
		abs_file := fmt.aprintf("%s/%s", get_path_dir(), file)
		delete_str: bool
		defer if delete_str do delete(abs_file)
		we_lua_state := &app.state.we_luas[win_idx]
		input_text_shrink(&we_lua_state.text_buf)
		if !os.exists(abs_file) {
			defer base.show = false
			delete_str = true
			fex_save_lua_file(app, abs_file, win_idx)
		} else {
			delete_str = false
			app.state.we_overwrite_lua = {
				active  = true,
				path    = abs_file,
				win_idx = win_idx,
			}
			base.disabled = true
		}
	}
}
fex_save_lua_file :: proc(app: ^App, file: string, win_idx: int) {
	we_lua_state := &app.state.we_luas[win_idx]
	err := os.write_entire_file(file, we_lua_state.text_buf[:len(we_lua_state.text_buf) - 1])
	if err != nil {
		log.errorf("Unable to save to file '{}': {}", file, err)
	}
}
//file_str should be null-terminated
file_explorer_write_wav_file :: proc(app: ^App, file_str: string) {
	assert(file_str[len(file_str) - 1] == 0)
	ext := filepath.ext(file_str[:len(file_str) - 1]) //Remove null-terminator
	assert(ext == ".wav")
	encoder: ma.encoder
	econfig := ma.encoder_config_init(.wav, .f32, 1, 44100)
	result := ma.encoder_init_file(strings.unsafe_string_to_cstring(file_str), &econfig, &encoder)
	if result != .SUCCESS {
		log.errorf("Unable to write to '%s': %v", file_str, result)
		return
	}
	defer ma.encoder_uninit(&encoder)
	we_state := &app.state.we[file_explorer_load_idx]
	written: u64
	for frame in 0 ..< we_state.num_frames {
		result = ma.encoder_write_pcm_frames(
			&encoder,
			&we_state.data[data_index(frame, 0)],
			u64(we_state.num_points),
			&written,
		)
		if result != .SUCCESS {
			log.errorf("Unable to write to '%s': %v", file_str, result)
			return
		}
	}
}

FILE_EXPLORER_WRITE_WAV_MULTI_STR :: "%s/%03d.wav\x00"
file_explorer_write_wav_file_frame :: proc(app: ^App, file_dir: string, frame: i32) {
	assert(os.is_dir(file_dir))
	wav_file := fmt.tprintf(FILE_EXPLORER_WRITE_WAV_MULTI_STR, file_dir, frame)
	encoder: ma.encoder
	econfig := ma.encoder_config_init(.wav, .f32, 1, 44100)
	result := ma.encoder_init_file(strings.unsafe_string_to_cstring(wav_file), &econfig, &encoder)
	if result != .SUCCESS {
		log.errorf("Unable to write to '%s': %v", wav_file, result)
		return
	}
	defer ma.encoder_uninit(&encoder)
	we_state := &app.state.we[file_explorer_load_idx]
	written: u64
	result = ma.encoder_write_pcm_frames(
		&encoder,
		&we_state.data[data_index(frame, 0)],
		u64(we_state.num_points),
		&written,
	)
	if result != .SUCCESS {
		log.errorf("Unable to write to '%s': %v", wav_file, result)
	}
}
