#+feature dynamic-literals
package waveform_editor
import "base:intrinsics"
import "base:runtime"
import "core:strconv"

import "core:container/handle_map"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import ma "vendor:miniaudio"
import sdl "vendor:sdl3"

import "./colors"
import fm "./fourier_model"
import imgui "imgui:/"
import imgui_sdl3 "imgui:/imgui_impl_sdl3"
import imgui_sdlgpu3 "imgui:/imgui_impl_sdlgpu3"

app_context: runtime.Context
log_fn :: proc "c" (
	userdata: rawptr,
	category: sdl.LogCategory,
	priority: sdl.LogPriority,
	message: cstring,
) {
	context = app_context
	switch priority {
	case .DEBUG, .VERBOSE, .TRACE:
		log.debugf("[SDL, %v, %v]: %s", category, priority, message)
	case .INFO:
		log.infof("[SDL, %v, %v]: %s", category, priority, message)
	case .WARN:
		log.warnf("[SDL, %v, %v]: %s", category, priority, message)
	case .ERROR, .CRITICAL, .INVALID:
		log.errorf("[SDL, %v, %v]: %s", category, priority, message)
	}
	when ODIN_DEBUG do fmt.printfln("[SDL, %v, %v]: %s", category, priority, message)
}

AppConfig :: struct {
	width:         i32,
	height:        i32,
	display_scale: f32,
	mspf:          u32,
}

CloseState :: enum {
	No,
	Prompt,
	Yes,
}

ResizeWindowsState :: enum {
	Inactive,
	Active,
	ActiveAlways,
}

EventCall :: struct {
	window:     ^ImGuiWindow,
	event_f:  ImGuiF_1BaseP2AppP3RawP,
	win_idx:  int,
	userdata: rawptr,
}

TOOLTIP_BUF_MAX_LEN :: 256
MAX_WAVEFORM_EDITOR_POINTS :: 2048
MAX_WAVEFORM_EDITOR_WINDOWS :: 4
WeEditSampleStatus :: enum {
	None,
	ExistsFocus,
	Exists,
}
WeEditSample :: struct {
	win_idx: i16,
	idx:     i16,
	x:       i16,
	y:       i16,
	status:  WeEditSampleStatus,
}
AppState :: struct {
	events_f:            queue.Queue(EventCall),
	frames:              u64,
	render_frame_count:  u64,
	tick_acc:            u64,
	last_tick:           u64,
	lua_win_idx:         int,
	we_edit_s:           WeEditSample,
	output_log:          OutputLog,
	we_edit_s_buf:       [dynamic]u8,
	we_overwrite_lua:    FileExplorerSaveLuaOverwrite,
	import_buf:          [dynamic]u8,
	fe_choose_buf:       [dynamic]u8,
	warn_buf:            [dynamic]u8,
	past_data:           [dynamic]f32,
	sample_copy_buf:     [dynamic]f32,
	wedraw_idx_buf:      [dynamic]i32,
	we:                  [MAX_WAVEFORM_EDITOR_WINDOWS]WaveformEditorState,
	we_h_wfs:            [MAX_WAVEFORM_EDITOR_WINDOWS]fm.Waveform_Model,
	we_luas:             [MAX_WAVEFORM_EDITOR_WINDOWS]WELuaState,
	we_img:              WEImageState,
	we_wav_state:        WEWavState,
	fe_audio_state:      FileExplorerAudio,
	fe_audiomulti_state: FileExplorerAudioMulti,
	wp:                  WaveformPlayer,
	path_files:          PathFiles,
	close_state:         CloseState,
	rw_state:            ResizeWindowsState,
	tooltip:             ToolTip,
	import_wf_at_end:    bool,
	import_wf_norm:      bool,
}
ToolTipContainer :: union {
	cstring,
	strings.Builder, //String will deallocate when changing tooltip
}
ToolTipType :: enum {
	Info,
	Error,
}
ToolTip :: struct {
	type:        ToolTipType,
	expires:     bool,
	until_frame: u64,
	container:   ToolTipContainer,
}

tooltip_change :: proc(
	tt: ^ToolTip,
	container: ToolTipContainer,
	type: ToolTipType,
	expire_frames: Maybe(u64) = nil,
) {
	tt.until_frame, tt.expires = expire_frames.?
	tt.type = type
	#partial switch &c in tt.container {
	case strings.Builder:
		strings.builder_destroy(&c)
	}
	tt.container = container
}

ImGuiWindows :: struct {
	file_explorer:    ImGuiWindow,
	image:            ImGuiWindow,
	wav_player:       ImGuiWindow,
	oscilloscope:     ImGuiWindow,
	output_log:       ImGuiWindow,
	import_text:      ImGuiWindow,
	waveform_editors: [MAX_WAVEFORM_EDITOR_WINDOWS]ImGuiWindow,
	lua:              [MAX_WAVEFORM_EDITOR_WINDOWS]ImGuiWindow,
	harmonics:        [MAX_WAVEFORM_EDITOR_WINDOWS]ImGuiWindow,
}

ColorsButton :: struct {
	idle:    imgui.Vec4,
	hovered: imgui.Vec4,
	active:  imgui.Vec4,
}

ImGuiHM :: handle_map.Dynamic_Handle_Map(ImGuiWindowHandle, handle_map.Handle16)
App :: struct {
	config:   AppConfig,
	state:    AppState,
	window:   ^sdl.Window,
	gpu:      ^sdl.GPUDevice,
	sc:       ^sdl.GPUTexture,
	imgui_hm: ImGuiHM,
	windows:  ImGuiWindows,
	textures: [TextureNames]^sdl.GPUTexture,
}

app_reset_windows :: proc(app: ^App) {
	app.state.rw_state = .Active
	tooltip_change(
		&app.state.tooltip,
		cstring("All windows size and positions are resetted"),
		.Info,
		app.state.frames + 3000 / u64(app.config.mspf),
	)
}
app_lock_windows :: proc(app: ^App) {
	switch app.state.rw_state {
	case .ActiveAlways:
		app.state.rw_state = .Inactive
		tooltip_change(
			&app.state.tooltip,
			cstring("All windows size and positions are now unlocked"),
			.Info,
			app.state.frames + 3000 / u64(app.config.mspf),
		)
	case .Inactive, .Active:
		app.state.rw_state = .ActiveAlways
		tooltip_change(
			&app.state.tooltip,
			cstring("All windows size and positions are now resetted and locked"),
			.Info,
			app.state.frames + 3000 / u64(app.config.mspf),
		)
	}
}

app_destroy :: proc(app: ^App) {
	output_log_destroy(&app.state.output_log)
	file_explorer_save_lua_overwrite_destroy(&app.state.we_overwrite_lua)
	for tn in TextureNames {
		sdl.ReleaseGPUTexture(app.gpu, app.textures[tn])
	}
	we_image_state_destroy(&app.state.we_img, app)
	we_wav_state_destroy(&app.state.we_wav_state, app)
	file_explorer_audio_destroy(&app.state.fe_audio_state)
	file_explorer_audiomulti_destroy(&app.state.fe_audiomulti_state)
	delete(app.state.sample_copy_buf)
	delete(app.state.import_buf)
	delete(app.state.we_edit_s_buf)
	delete(app.state.fe_choose_buf)
	for &wfm in app.state.we_h_wfs {
		fm.waveform_model_destroy(&wfm)
	}
	for idx in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
		we_state := &app.state.we[idx]
		if we_state.is_active {
			f_waveform_editor_destroy(&app.windows.waveform_editors[idx], app, idx, nil)
		}
	}
	for ec in queue.pop_front_safe(&app.state.events_f) { 	//Delete other windows from active waveform editors
		ec.event_f(ec.window, app, ec.win_idx, ec.userdata)
	}
	#partial switch &s in app.state.tooltip.container {
	case strings.Builder:
		strings.builder_destroy(&s)
	}
	queue.destroy(&app.state.events_f)
	path_files_destroy(&app.state.path_files)
	sdl.DestroyGPUDevice(app.gpu)
	sdl.DestroyWindow(app.window)
}
main_allocator: mem.Allocator
main :: proc() {
	main_allocator = context.allocator
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintfln("=== %v allocation(s) not freed ===", len(track.allocation_map))
			}
			for _, entry in track.allocation_map {
				fmt.eprintf("%v bytes @ %v\n", entry.size, entry.location)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}
	app: App
	context.logger = runtime.Logger {
		data         = &app,
		lowest_level = .Debug when ODIN_DEBUG else .Info,
		procedure    = context_log_proc,
	}
	app_context = context

	assert(sdl.Init({.VIDEO}))
	defer sdl.Quit()

	display_scale := sdl.GetDisplayContentScale(sdl.GetPrimaryDisplay())
	init_path_dir()
	app = App {
		state = {
			path_files = path_files_new(get_path_dir()) or_else panic("Unable to Allocate"),
			last_tick = sdl.GetTicks(),
			we_edit_s_buf = make([dynamic]u8, 1),
			import_buf = make([dynamic]u8, 1),
			fe_choose_buf = make([dynamic]u8, 1),
			sample_copy_buf = make([dynamic]f32),
			output_log = output_log_new(),
		},
		config = {
			width         = i32(1280 * display_scale),
			height        = i32(800 * display_scale),
			display_scale = display_scale,
			mspf          = 1000 /
			60, //60 FPS
		},
		windows = {
			oscilloscope = imgui_window_new(
				"Oscilloscope",
				0,
				container_f = f_draw_oscilloscope,
				position = {{s = 0.5}, UDim{o = 20}},
				size = {UDim{s = 0.5}, UDim{s = 0.25, o = -20}},
				flags = {.NoCollapse, .MenuBar},
			),
			output_log = imgui_window_new(
				"Output Log",
				0,
				container_f = f_output_log_draw,
				position = {{s = 0.5}, UDim{s = 0.25}},
				size = {UDim{s = 0.5}, UDim{s = 0.25}},
				flags = {.NoCollapse, .MenuBar},
				show = false,
			),
		},
	}
	defer app_destroy(&app)
	import_sep = [dynamic]u8{',', ' ', 0}
	defer delete(import_sep)
	waveform_editor_ma_init(&app)
	defer waveform_editor_ma_destroy(&app)
	if e := queue.init(&app.state.events_f); e != nil {
		panic("Unable to allocate")
	}

	handle_map.dynamic_init(&app.imgui_hm, context.allocator)
	defer handle_map.dynamic_destroy(&app.imgui_hm)
	imgui_window_add_handle(&app, &app.windows.oscilloscope)
	imgui_window_add_handle(&app, &app.windows.output_log)

	sdl.SetLogOutputFunction(log_fn, nil)
	when ODIN_DEBUG {
		sdl.SetLogPriorities(.TRACE)
	}
	wprops := sdl.CreateProperties()
	assert(wprops != 0)
	defer sdl.DestroyProperties(wprops)
	//odinfmt: disable
	assert(sdl.SetStringProperty(wprops,sdl.PROP_WINDOW_CREATE_TITLE_STRING,"Waveform Editor"))
	assert(sdl.SetNumberProperty(wprops,sdl.PROP_WINDOW_CREATE_WIDTH_NUMBER,i64(app.config.width)))
	assert(sdl.SetNumberProperty(wprops,sdl.PROP_WINDOW_CREATE_HEIGHT_NUMBER,i64(app.config.height)))
	assert(sdl.SetNumberProperty(wprops,sdl.PROP_WINDOW_CREATE_X_NUMBER,i64(sdl.WINDOWPOS_CENTERED)))
	assert(sdl.SetNumberProperty(wprops,sdl.PROP_WINDOW_CREATE_Y_NUMBER,i64(sdl.WINDOWPOS_CENTERED)))
	assert(sdl.SetBooleanProperty(wprops,sdl.PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN,true))
	assert(sdl.SetBooleanProperty(wprops,sdl.PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN,true))
	//odinfmt: enable

	app.window = sdl.CreateWindowWithProperties(wprops)
	assert(app.window != nil)

	app.gpu = sdl.CreateGPUDevice({.SPIRV, .DXIL, .MSL, .METALLIB}, ODIN_DEBUG, nil)
	assert(app.gpu != nil)

	ctx := imgui.CreateContext()
	defer imgui.DestroyContext(ctx)
	imgui.GetIO().IniFilename = nil

	for tn in TextureNames {
		img_d := load_from_memory(TexturePaths[tn])
		assert(img_d.data != nil)
		defer free_image(&img_d)
		app.textures[tn] = imgui_load_texture(app.gpu, &img_d)
		assert(app.textures[tn] != nil)
	}

	im_io := imgui.GetIO()
	im_io.ConfigFlags += {.NavEnableKeyboard}
	im_style := imgui.GetStyle()
	imgui.Style_ScaleAllSizes(im_style, app.config.display_scale)
	im_style.FontScaleDpi = app.config.display_scale
	im_io.ConfigDpiScaleFonts = true

	assert(imgui_sdl3.InitForSDLGPU(app.window))
	defer imgui_sdl3.Shutdown()

	assert(sdl.ClaimWindowForGPUDevice(app.gpu, app.window))
	assert(
		imgui_sdlgpu3.Init(
			&imgui_sdlgpu3.InitInfo {
				Device = app.gpu,
				ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(app.gpu, app.window),
				MSAASamples = ._1,
				SwapchainComposition = .SDR,
				PresentMode = .VSYNC,
			},
		),
	)
	defer imgui_sdlgpu3.Shutdown()

	for app.state.close_state != .Yes {
		next_tick := sdl.GetTicks()
		tick_diff := next_tick - app.state.last_tick
		app.state.last_tick = next_tick
		app.state.tick_acc = sdl.min(app.state.tick_acc + tick_diff, u64(15 * app.config.mspf))
		app.state.render_frame_count = 0
		for app.state.tick_acc >= u64(app.config.mspf) {
			e: sdl.Event = ---
			for sdl.PollEvent(&e) {
				#partial switch e.type {
				case .QUIT:
					if app.state.close_state == .No do app.state.close_state = .Prompt
				case .WINDOW_RESIZED:
					app.config.width = e.window.data1
					app.config.height = e.window.data2
				}
				imgui_sdl3.ProcessEvent(&e)
			}

			if app.state.tooltip.expires {
				#partial switch &s in app.state.tooltip.container {
				case cstring:
					if app.state.frames > app.state.tooltip.until_frame {
						app.state.tooltip.container = nil
						app.state.tooltip.expires = false
					}
				case strings.Builder:
					if app.state.frames > app.state.tooltip.until_frame {
						strings.builder_destroy(&s)
						app.state.tooltip.container = nil
						app.state.tooltip.expires = false
					}
				}
			}

			for ec in queue.pop_front_safe(&app.state.events_f) {
				ec.event_f(ec.window, &app, ec.win_idx, ec.userdata)
			}

			app.state.frames += 1
			app.state.render_frame_count += 1
			app.state.tick_acc -= u64(app.config.mspf)
		}

		imgui_sdlgpu3.NewFrame()
		imgui_sdl3.NewFrame()
		imgui.NewFrame()

		if imgui.BeginMainMenuBar() {
			if imgui.BeginMenu("File") {
				if imgui.MenuItem("New Waveform") {
					waveform_editor_new(&app)
				}
				if imgui.MenuItem("Load File") {
					if !app.windows.file_explorer.is_active {
						file_explorer_new(&app, .Load)
						refresh_dir_or_root(&app)
					} else {
						tooltip_change(
							&app.state.tooltip,
							cstring("File Explorer window already in use"),
							.Error,
							app.state.frames + 3000 / u64(app.config.mspf),
						)
					}
				}
				if imgui.MenuItem("Exit") {
					app.state.close_state = .Prompt
				}
				imgui.EndMenu()
			}
			if imgui.BeginMenu("Window") {
				it := handle_map.iterator_make(&app.imgui_hm)
				for bh, _ in handle_map.iterate(&it) {
					_, dep := bh.window.depends_on.?
					c_str: cstring = ---
					switch v in bh.window.id {
					case cstring:
						c_str = v
					case strings.Builder:
						c_str = cstring(&v.buf[0])
					}
					if imgui.MenuItem(c_str, selected = bh.window.show, enabled = !dep && !bh.window.disabled) do bh.window.show = !bh.window.show
				}
				imgui.Separator()
				if imgui.MenuItem("Reset All Windows", "Ctrl+Shift+R") {
					app_reset_windows(&app)
				}
				if imgui.MenuItem(
					"Reset and Lock All Windows" if app.state.rw_state != .ActiveAlways else "Unlock All Window Positions",
					"Ctrl+Shift+L",
					app.state.rw_state == .ActiveAlways,
				) {
					app_lock_windows(&app)
				}
				if imgui.MenuItem("Show Output Log", selected = app.windows.output_log.show) {
					app.windows.output_log.show = !app.windows.output_log.show
				}
				imgui.EndMenu()
			}
			imgui.EndMainMenuBar()
		}

		ctrl_down := imgui.IsKeyDown(.ImGuiMod_Ctrl)
		shift_down := imgui.IsKeyDown(.ImGuiMod_Shift)
		if ctrl_down && shift_down {
			if imgui.IsKeyPressed(.R, false) do app_reset_windows(&app)
			if imgui.IsKeyPressed(.L, false) do app_lock_windows(&app)
		}

		#partial switch app.state.fe_audio_state.state {
		case .ChooseLoadAs:
			if imgui.Begin("Load Audio To", nil, {.NoResize, .AlwaysAutoResize}) {
				if imgui.Button("Waveform Editor") {
					app.state.fe_audio_state.state = .ChooseLoadAsWavExport
				}
				imgui.SameLine()
				if imgui.Button("Audio Player") {
					wav_player_new(&app)
					app.windows.file_explorer.show = false
				}
				imgui.SameLine()
				imgui.PushStyleColor(.Button, transmute(u32)(colors.RED_BUTTON.idle))
				imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.RED_BUTTON.hovered))
				imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.RED_BUTTON.active))
				if imgui.Button("Cancel") {
					file_explorer_audio_destroy(&app.state.fe_audio_state)
					app.windows.file_explorer.disabled = false
				}
				imgui.PopStyleColor(3)
				imgui.End()
			}
		case .ChooseLoadAsWavExport:
			if imgui.Begin("Waveform Editor Properties", nil, {.NoResize, .AlwaysAutoResize}) {
				help_marker("Number of samples for each waveform")
				imgui.SliderInt(
					"Number of samples",
					&app.state.fe_audio_state.prop.num_samples,
					1,
					MAX_WAVEFORM_EDITOR_POINTS,
					flags = {.ClampOnInput},
				)
				help_marker("Parser will stop at this maximum number of frames or less")
				imgui.SliderInt(
					"Maximum number of Frames",
					&app.state.fe_audio_state.prop.num_frames,
					1,
					MAX_WAVEFORM_FRAMES,
					flags = {.ClampOnInput},
				)
				no_window: if imgui.Button("Apply") {
					we_idx: int = ---
					assert(file_explorer_type != .SaveToAudio)
					if file_explorer_type == .Load {
						we_idx = waveform_editor_new(&app) or_break no_window
					} else if file_explorer_type == .LoadToWindow {
						we_idx = file_explorer_load_idx
						undo_redo_manager_clear(&app.state.we[we_idx].undo_redo)
					}
					we_state := &app.state.we[we_idx]
					if !app.windows.waveform_editors[we_idx].is_active do break no_window
					id_sb := &app.windows.waveform_editors[we_idx].id.(strings.Builder)
					strings.builder_reset(id_sb)
					fmt.sbprintf(
						id_sb,
						"Waveform Editor %d - %s\x00",
						we_idx + 1,
						app.state.fe_audio_state.file_str,
					)
					we_state.num_points = app.state.fe_audio_state.prop.num_samples
					set_frames(&app, we_idx, 1)
					we_state.data_frame = 0
					we_state.num_frames = 1
					read_loop: for _ in 0 ..< app.state.fe_audio_state.prop.num_frames {
						frame_buf: [MAX_WAVEFORM_EDITOR_POINTS]f32
						frames_read: u64
						result := ma.decoder_read_pcm_frames(
							&app.state.fe_audio_state.audio_ma,
							&frame_buf[0],
							u64(app.state.fe_audio_state.prop.num_samples),
							&frames_read,
						)
						#partial switch result {
						case .SUCCESS:
							if we_state.data_frame != 0 {
								set_frames(&app, we_idx, we_state.num_frames + 1)
								we_state.num_frames += 1
							}
							mem.copy_non_overlapping(
								&we_state.data[data_index(we_state.data_frame, 0)],
								&frame_buf[0],
								int(frames_read) * size_of(f32),
							)
							we_state.data_frame += 1
						case .AT_END:
							break read_loop
						case:
							log.errorf("Unable to read audio file: %v", result)
							break read_loop
						}
					}
					we_state.data_frame = max(we_state.data_frame - 1, 0)
					file_explorer_audio_destroy(&app.state.fe_audio_state)
					app.windows.file_explorer.show = false
				}
				imgui.PushStyleColor(.Button, transmute(u32)(colors.RED_BUTTON.idle))
				imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.RED_BUTTON.hovered))
				imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.RED_BUTTON.active))
				imgui.SameLine()
				if imgui.Button("Cancel") {
					app.state.fe_audio_state.state = .ChooseLoadAs
				}
				imgui.PopStyleColor(3)
				imgui.End()
			}
		case .SaveAs:
			file_str := app.state.fe_audio_state.file_str
			if !os.exists(file_str) {
				file_explorer_write_wav_file(&app, file_str)
				app.windows.file_explorer.show = false
				id_sb := &app.windows.waveform_editors[file_explorer_load_idx].id.(strings.Builder)
				strings.builder_reset(id_sb)
				fmt.sbprintf(
					id_sb,
					"Waveform Editor %d - %s\x00",
					file_explorer_load_idx + 1,
					file_str,
				)
				file_explorer_audio_destroy(&app.state.fe_audio_state)
				break
			}
			app.state.fe_audio_state.state = .SaveAsOverwrite
			fallthrough
		case .SaveAsOverwrite:
			if !app.windows.waveform_editors[file_explorer_load_idx].is_active {
				file_explorer_audio_destroy(&app.state.fe_audio_state)
				break
			}
			file_str := app.state.fe_audio_state.file_str
			if imgui.Begin("Overwrite", nil, {.NoResize, .AlwaysAutoResize}) {
				defer imgui.End()
				imgui.Text("Overwrite to file '%s'?", file_str)
				if imgui.Button("Yes") {
					file_explorer_write_wav_file(&app, file_str)
					app.windows.file_explorer.show = false
					id_sb := &app.windows.waveform_editors[file_explorer_load_idx].id.(strings.Builder)
					strings.builder_reset(id_sb)
					fmt.sbprintf(
						id_sb,
						"Waveform Editor %d - %s\x00",
						file_explorer_load_idx + 1,
						file_str,
					)
					file_explorer_audio_destroy(&app.state.fe_audio_state)
					break
				}
				imgui.SameLine()
				imgui.PushStyleColor(.Button, transmute(u32)(colors.RED_BUTTON.idle))
				imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.RED_BUTTON.hovered))
				imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.RED_BUTTON.active))
				if imgui.Button("No") {
					file_explorer_audio_destroy(&app.state.fe_audio_state)
					app.windows.file_explorer.disabled = false
				}
				imgui.PopStyleColor(3)
			}
		}
		#partial switch app.state.fe_audiomulti_state.state {
		case .Save:
			feams := &app.state.fe_audiomulti_state
			assert(os.exists(feams.file_dir))
			f, err := os.open(feams.file_dir)
			if err != nil {
				log.errorf("Unable to save to directory '{}': {}", feams.file_dir, err)
				file_explorer_audiomulti_destroy(feams)
				break
			}
			defer os.close(f)
			fi_arr: []os.File_Info
			fi_arr, err = os.read_dir(f, 1, context.allocator)
			if err != nil {
				log.errorf("Unable to save to directory '{}': {}", feams.file_dir, err)
				file_explorer_audiomulti_destroy(feams)
				break
			}
			os.file_info_slice_delete(fi_arr, context.allocator)
			if len(fi_arr) == 0 {
				we_state := &app.state.we[file_explorer_load_idx]
				for i in 0 ..< we_state.num_frames {
					file_explorer_write_wav_file_frame(&app, feams.file_dir, i)
				}
				file_explorer_audiomulti_destroy(feams)
				app.windows.file_explorer.show = false
			} else {
				feams.state = .CheckOverwrite
				break
			}
		case .CheckOverwrite:
			if imgui.Begin("Overwrite", nil, {.NoResize, .AlwaysAutoResize}) {
				feams := &app.state.fe_audiomulti_state
				defer imgui.End()
				imgui.Text("Overwrite .wav files in '%s'?", feams.file_dir)
				if imgui.Button("Yes") {
					we_state := &app.state.we[file_explorer_load_idx]
					for i in 0 ..< we_state.num_frames {
						old_wav_file := fmt.tprintf(
							FILE_EXPLORER_WRITE_WAV_MULTI_STR,
							feams.file_dir,
							i,
						)
						os.remove(old_wav_file)
						file_explorer_write_wav_file_frame(&app, feams.file_dir, i)
					}
					file_explorer_audiomulti_destroy(feams)
					app.windows.file_explorer.show = false
				}
				imgui.SameLine()
				imgui.PushStyleColor(.Button, transmute(u32)(colors.RED_BUTTON.idle))
				imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.RED_BUTTON.hovered))
				imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.RED_BUTTON.active))
				if imgui.Button("No") {
					file_explorer_audio_destroy(&app.state.fe_audio_state)
					app.windows.file_explorer.disabled = false
				}
				imgui.PopStyleColor(3)
			}
		}

		if app.state.we_overwrite_lua.active {
			if imgui.Begin(
				"Overwrite File",
				nil,
				{.NoMove, .NoResize, .NoCollapse, .AlwaysAutoResize},
			) {
				defer imgui.End()
				we_overwrite_lua := &app.state.we_overwrite_lua
				str := fmt.tprintf("Overwrite file '{}'?\x00", we_overwrite_lua.path)
				imgui.Text(strings.unsafe_string_to_cstring(str))
				if imgui.Button("Yes") {
					fex_save_lua_file(&app, we_overwrite_lua.path, we_overwrite_lua.win_idx)
					app.windows.file_explorer.show = false
					file_explorer_save_lua_overwrite_destroy(we_overwrite_lua)
				}
				imgui.SameLine()
				imgui.PushStyleColor(.Button, transmute(u32)(colors.RED_BUTTON.idle))
				imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.RED_BUTTON.hovered))
				imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.RED_BUTTON.active))
				if imgui.Button("No") {
					file_explorer_save_lua_overwrite_destroy(we_overwrite_lua)
					app.windows.file_explorer.disabled = false
				}
				imgui.PopStyleColor(3)
			}
		}

		if app.state.we_edit_s.status != .None {
			edit_s := &app.state.we_edit_s
			if imgui.Begin("Edit Sample##WE", nil, {.NoMove, .NoResize, .NoCollapse}) {
				imgui.SetWindowPos({f32(edit_s.x), f32(edit_s.y)})
				imgui.SetWindowSize({140, 55})
				we_state := &app.state.we[edit_s.win_idx]
				if edit_s.status == .ExistsFocus do imgui.SetKeyboardFocusHere()
				if imgui.InputText(
					"##Float Value",
					cstring(&app.state.we_edit_s_buf[0]),
					len(app.state.we_edit_s_buf),
					{.CallbackResize, .CallbackCharFilter, .EnterReturnsTrue},
					float_text_resize,
					&app.state.we_edit_s_buf,
				) {
					f_value, _ := strconv.parse_f32(string(cstring(&app.state.we_edit_s_buf[0])))
					undo_redo_manager_undo_add_stop(&we_state.undo_redo)
					undo_redo_manager_undo_data_frame(
						&we_state.undo_redo,
						&app,
						int(edit_s.win_idx),
						we_state.data_frame,
					)
					undo_redo_manager_undo_wedraw(
						&we_state.undo_redo,
						&app,
						int(edit_s.win_idx),
						i32(edit_s.idx),
						we_state.data_frame,
					)
					we_state.data[data_index(we_state.data_frame, u32(edit_s.idx))] = clamp(
						f_value,
						-1,
						1,
					)
					edit_s.status = .None
				}
				if !imgui.IsWindowFocused() {
					f_value, _ := strconv.parse_f32(string(cstring(&app.state.we_edit_s_buf[0])))
					undo_redo_manager_undo_add_stop(&we_state.undo_redo)
					undo_redo_manager_undo_data_frame(
						&we_state.undo_redo,
						&app,
						int(edit_s.win_idx),
						we_state.data_frame,
					)
					undo_redo_manager_undo_wedraw(
						&we_state.undo_redo,
						&app,
						int(edit_s.win_idx),
						i32(edit_s.idx),
						we_state.data_frame,
					)
					we_state.data[data_index(we_state.data_frame, u32(edit_s.idx))] = clamp(
						f_value,
						-1,
						1,
					)
					edit_s.status = .None
				}
				if imgui.IsKeyPressed(.Escape, false) {
					edit_s.status = .None
				}
				if edit_s.status != .None do edit_s.status = .Exists
				imgui.End()
			}
		}

		it := handle_map.iterator_make(&app.imgui_hm)
		for bh, _ in handle_map.iterate(&it) {
			bh.window->_draw(&app, bh.window.idx, bh.window.userdata)
		}
		if app.state.rw_state == .Active {
			app.state.rw_state = .Inactive
		}

		if app.state.tooltip.container != nil {
			imgui.BeginTooltip()
			#partial switch app.state.tooltip.type {
			case .Error:
				imgui.TextColored({1, 0.5, 0.5, 1}, "Error: ")
				imgui.SameLine()
			}
			#partial switch &s in app.state.tooltip.container {
			case cstring:
				imgui.Text(s)
			case strings.Builder:
				imgui.Text(cstring(&s.buf[0]))
			}
			imgui.EndTooltip()
		}

		if app.state.close_state == .Prompt {
			imgui.OpenPopup("Exiting Program")
		}
		if imgui.BeginPopupModal("Exiting Program", nil, {.NoResize, .NoMove}) {
			imgui.SetWindowPos(
				udim_get_vec2(
					UDim2{UDim{s = 0.5, o = -270 / 2}, UDim{s = 0.5, o = -80 / 2}},
					f32(app.config.width),
					f32(app.config.height),
				),
			)
			imgui.SetWindowSize(
				udim_get_vec2(
					UDim2{UDim{o = 270}, UDim{o = 80}},
					f32(app.config.width),
					f32(app.config.height),
				),
			)
			imgui.Text("Are you sure you want to quit?")
			imgui.Separator()
			imgui.PushStyleColor(.Button, transmute(u32)(colors.RED_BUTTON.idle))
			imgui.PushStyleColor(.ButtonHovered, transmute(u32)(colors.RED_BUTTON.hovered))
			imgui.PushStyleColor(.ButtonActive, transmute(u32)(colors.RED_BUTTON.active))
			if imgui.Button("Exit", {120, 0}) {
				app.state.close_state = .Yes
				imgui.CloseCurrentPopup()
			}
			imgui.PopStyleColor(3)
			imgui.SameLine()
			if imgui.Button("Cancel", size = {120, 0}) {
				app.state.close_state = .No
				imgui.CloseCurrentPopup()
			}
			imgui.EndPopup()
		}

		imgui.Render()
		draw_data := imgui.GetDrawData()

		cmd_buf := sdl.AcquireGPUCommandBuffer(app.gpu)
		assert(sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buf, app.window, &app.sc, nil, nil))

		if app.sc != nil {
			imgui_sdlgpu3.PrepareDrawData(draw_data, cmd_buf)
			render_pass := sdl.BeginGPURenderPass(
				cmd_buf,
				&sdl.GPUColorTargetInfo {
					texture = app.sc,
					clear_color = {0.125, 0.125, 0.375, 1},
					load_op = .CLEAR,
					store_op = .STORE,
				},
				1,
				nil,
			)
			imgui_sdlgpu3.RenderDrawData(draw_data, cmd_buf, render_pass, nil)
			sdl.EndGPURenderPass(render_pass)
		}
		assert(sdl.SubmitGPUCommandBuffer(cmd_buf))
		free_all(context.temp_allocator)
	}
	assert(sdl.WaitForGPUIdle(app.gpu))
}

help_marker :: proc(fmt: cstring, args: ..any) {
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.BeginTooltip()
		imgui.Text(fmt, args)
		imgui.EndTooltip()
	}
	imgui.SameLine()
}

input_text_resize :: proc "c" (data: ^imgui.InputTextCallbackData) -> i32 {
	if .CallbackResize in data.Flags {
		context = app_context
		dyn_arr := cast(^[dynamic]u8)data.UserData
		if cap(dyn_arr) < int(data.BufSize) {
			new_cap := cap(dyn_arr)
			for new_cap < int(data.BufSize) do new_cap *= 2
			err := resize(dyn_arr, new_cap)
			if err != .None do return 1
			data.Buf = cstring(&dyn_arr[0])
		}
	}
	return 0
}

float_text_resize :: proc "c" (data: ^imgui.InputTextCallbackData) -> i32 {
	if .CallbackCharFilter in data.Flags {
		switch data.EventChar {
		case '0' ..= '9', '.', '-':
			return 0
		case:
			return 1
		}
	}
	return input_text_resize(data)
}

//Remove extra 0s excluding +1 for c-string
input_text_shrink :: #force_inline proc(arr: ^[dynamic]u8) {
	resize_len := len(cstring(&arr[0])) + 1
	shrink(arr, resize_len)
}

pmod :: proc "contextless" (a, n: $T) -> T where intrinsics.type_is_float(T) {
	return math.mod(math.mod(a, n) + n, n)
}
