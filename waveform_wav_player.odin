package waveform_editor

import "base:intrinsics"
import "core:c"
import "core:container/handle_map"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/bits"
import "core:strings"
import "core:sync"
import "core:thread"

import imgui "imgui:."
import pb "playback_buffer"
import ma "vendor:miniaudio"
import sdl "vendor:sdl3"

MAX_PLAYBACK_SAMPLES :: 4096
PlaybackBufferImpl :: pb.PlaybackBuffer(MAX_PLAYBACK_SAMPLES, 20)
//atomic_mutex whenever pb or ma is used, atomic_load/store for u64
WEWavState :: struct {
	pb:               PlaybackBufferImpl,
	ma:               ma.decoder,
	last_window_size: [2]f32,
	wav_texture:      ^sdl.GPUTexture,
	play_cursor:      u64,
	buf_cursor:       u64,
	start_cursor:     u64,
	end_cursor:       u64,
	max_frames:       u64,
	drag_dt:          u64,
	scale:            f32,
	thread_state:     WavPlayerThreadState,
	redraw_wav:       Maybe(f32), //x-position
	drag:             WavPlayerDrag,
	interp:           InterpolationType,
	follow_cursor:    bool,
	drag_dt_neg:      bool,
}

WavPlayerPlayStatus :: enum i32 {
	Pause,
	PrePause,
	Play,
	PrePlay, //After .Pause
	PrePlay2, //After changing cursor during .Play
	Destroy,
}

WavPlayerThreadState :: struct {
	thread:     ^thread.Thread,
	mutex:      sync.Mutex,
	status:     WavPlayerPlayStatus,
	pause_cond: sync.Cond,
}

DrawWavLine :: struct {
	min: f32,
	max: f32,
}

WavPlayerDrag :: enum {
	None,
	Start,
	End,
	Drag,
}

DrawWavLine_Init: DrawWavLine : {min = 1, max = -1}

we_wav_state_new :: proc(app: ^App) -> WEWavState {
	self: WEWavState
	self.scale = 1
	file_explorer_audio_keep(&app.state.fe_audio_state, &self.ma)
	result := ma.decoder_get_length_in_pcm_frames(&self.ma, &self.max_frames)
	if result != .SUCCESS {
		log.errorf("Unable to get length of decoder: {}", result)
	}
	self.end_cursor = self.max_frames
	self.redraw_wav = 0
	context.allocator = main_allocator
	self.thread_state.thread = thread.create_and_start_with_data(app, thread_wav_player_update)
	self.interp = .Linear
	return self
}

we_wav_state_destroy :: proc(self: ^WEWavState, app: ^App) {
	if app.windows.wav_player.is_active {
		if self.wav_texture != nil {
			sdl.ReleaseGPUTexture(app.gpu, self.wav_texture)
		}
		we_wav_state := &app.state.we_wav_state

		sync.mutex_lock(&we_wav_state.thread_state.mutex)
		atomic_store_rel(&we_wav_state.thread_state.status, WavPlayerPlayStatus.Destroy)
		sync.cond_signal(&we_wav_state.thread_state.pause_cond)
		sync.mutex_unlock(&we_wav_state.thread_state.mutex)

		thread.join(we_wav_state.thread_state.thread)
		thread.destroy(we_wav_state.thread_state.thread)
		ma.decoder_uninit(&self.ma)
		self^ = {}
	}
}

wav_player_new :: proc(app: ^App) {
	assert(app.state.fe_audio_state.state == .ChooseLoadAs)
	if !app.windows.wav_player.is_active {
		app.windows.wav_player = imgui_window_new(
			".wav Player",
			0,
			container_f = f_wav_player_draw,
			destroy_f = f_wav_player_destroy,
			position = {UDim{}, UDim{s = 0.25}},
			size = {UDim{s = 1}, UDim{s = 0.25}},
			flags = {.NoScrollWithMouse, .MenuBar, .NoScrollbar, .AlwaysHorizontalScrollbar},
		)
		imgui_window_add_handle(app, &app.windows.wav_player)
	} else {
		we_wav_state_destroy(&app.state.we_wav_state, app)
	}
	app.state.we_wav_state = we_wav_state_new(app)
	app.windows.wav_player.keep_scroll_here = [2]f32{0, 0} //Try to reset scroll
}
WavAddStatus :: enum {
	Ok, //All samples in the PlaybackBuffer are filled without reaching end cursor
	WrapAgain,
	WrapAgainOk, //Rest of samples after .Ok are filled without reaching end cursor
	FillRest, //Length of buffer and end cursor is too small after .WrapAgain, repeat buffer instead
}

thread_wav_player_update :: proc(userdata: rawptr) {
	context.allocator = main_allocator //Tracking allocator not thread safe
	context.logger = log.create_console_logger(
		.Debug when ODIN_DEBUG else .Warning,
		ident = "Wav Loader Thread",
	)
	defer log.destroy_console_logger(context.logger)

	app := (^App)(userdata)
	we_wav_state := &app.state.we_wav_state
	thread_loop: for {
		state_now := atomic_load_acq(&we_wav_state.thread_state.status)
		switch state_now {
		case .PrePause:
			sync.mutex_lock(&we_wav_state.thread_state.mutex)
			pb.clear(&we_wav_state.pb)
			sync.mutex_unlock(&we_wav_state.thread_state.mutex)
			atomic_store_rel(&we_wav_state.thread_state.status, WavPlayerPlayStatus.Pause)
			fallthrough
		case .Pause:
			sync.mutex_lock(&we_wav_state.thread_state.mutex)
			for atomic_load_acq(&we_wav_state.thread_state.status) == WavPlayerPlayStatus.Pause {
				sync.cond_wait(
					&we_wav_state.thread_state.pause_cond,
					&we_wav_state.thread_state.mutex,
				)
			}
			sync.mutex_unlock(&we_wav_state.thread_state.mutex)
		case .PrePlay2:
			sync.mutex_lock(&we_wav_state.thread_state.mutex)
			pb.clear(&we_wav_state.pb)
			sync.mutex_unlock(&we_wav_state.thread_state.mutex)
			atomic_store_rel(&we_wav_state.buf_cursor, atomic_load_acq(&we_wav_state.play_cursor))
			atomic_store_rel(&we_wav_state.thread_state.status, WavPlayerPlayStatus.Play)
		case .PrePlay:
			play_c := atomic_load_acq(&we_wav_state.play_cursor)
			atomic_store_rel(&we_wav_state.buf_cursor, play_c)
			atomic_store_rel(&we_wav_state.thread_state.status, WavPlayerPlayStatus.Play)
			fallthrough
		case .Play:
			sync.mutex_guard(&we_wav_state.thread_state.mutex)
			samples_left := pb.samples_left(&we_wav_state.pb)
			if samples_left >= MAX_PLAYBACK_SAMPLES / 2 {
				wrap_around: WavAddStatus = .Ok
				end_cursor_now := atomic_load_acq(&we_wav_state.end_cursor)
				start_cursor_now := atomic_load_acq(&we_wav_state.start_cursor)
				fill_loop: for {
					buf_cursor_now := atomic_load_acq(&we_wav_state.buf_cursor)
					if buf_cursor_now >= end_cursor_now do buf_cursor_now = start_cursor_now
					if sl := end_cursor_now - buf_cursor_now; sl < samples_left {
						samples_left = sl //If buf_cursor is near end, sample only in that region, and wrap to start_cursor
						switch wrap_around {
						case .Ok:
							wrap_around = .WrapAgain
						case .WrapAgainOk:
							wrap_around = .FillRest
						case .FillRest, .WrapAgain:
							unreachable()
						}
					}
					sample_load: [MAX_PLAYBACK_SAMPLES]f32
					sample_size: u64 = 0
					result := ma.decoder_seek_to_pcm_frame(&we_wav_state.ma, buf_cursor_now)
					if result != .SUCCESS {
						log.errorf("Seek error: {}", result)
						atomic_store_rel(
							&we_wav_state.thread_state.status,
							WavPlayerPlayStatus.PrePause,
						)
						break fill_loop
					}
					result = ma.decoder_read_pcm_frames(
						&we_wav_state.ma,
						&sample_load[0],
						samples_left,
						&sample_size,
					)
					if result != .SUCCESS {
						log.errorf("Seek error: {}", result)
						atomic_store_rel(
							&we_wav_state.thread_state.status,
							WavPlayerPlayStatus.PrePause,
						)
						break fill_loop
					}
					status := pb.append(
						&we_wav_state.pb,
						sample_load[:sample_size],
						buf_cursor_now,
					)
					assert(status == .Ok)
					switch wrap_around {
					case .Ok, .WrapAgainOk:
						last_idx := pb.last_end(&we_wav_state.pb)
						atomic_store_rel(&we_wav_state.buf_cursor, last_idx)
						break fill_loop
					case .WrapAgain:
						atomic_store_rel(&we_wav_state.buf_cursor, start_cursor_now)
						wrap_around = .WrapAgainOk
						samples_left = pb.samples_left(&we_wav_state.pb)
					case .FillRest:
						samples_left = pb.samples_left(&we_wav_state.pb)
						for _ in 0 ..< samples_left / sample_size {
							status = pb.append(
								&we_wav_state.pb,
								sample_load[:sample_size],
								start_cursor_now,
							)
							assert(status == .Ok)
						}
						atomic_store_rel(&we_wav_state.buf_cursor, start_cursor_now)
						break fill_loop
					}
				}
			}
		case .Destroy:
			break thread_loop
		}
	}
}
atomic_load_acq :: proc(ptr: ^$T) -> T {
	return sync.atomic_load_explicit(ptr, .Acquire)
}
atomic_store_rel :: proc(ptr: ^$T, value: T) {
	sync.atomic_store_explicit(ptr, value, .Release)
}
_cursor_pos_f :: #force_inline proc(
	cursor: u64,
	win_tl: [2]f32,
	button_rect: [2]f32,
	we_wav_state: ^WEWavState,
) -> f32 {
	return(
		win_tl.x -
		imgui.GetScrollX() +
		f32(cursor) / f32(we_wav_state.max_frames) * button_rect.x \
	)
}
f_wav_player_draw :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	we_wav_state := &app.state.we_wav_state
	frame_size := imgui.GetFrameHeight()
	draw_list := imgui.GetWindowDrawList()
	io := imgui.GetIO()
	style := imgui.GetStyle()
	wp := imgui.GetWindowPos()
	imgui_tl := [2]f32{0, frame_size * 2}
	win_tl := wp + imgui_tl
	content_size := imgui.GetWindowSize() - imgui_tl - {0, style.ScrollbarSize}
	samples_per_window := SAMPLE_RATE * we_wav_state.scale
	button_rect := [2]f32 {
		content_size.x * f32(we_wav_state.max_frames) / samples_per_window,
		content_size.y,
	}
	if imgui.IsWindowFocused() {
		_wav_player_keybinds(base, app, win_tl, content_size)
	}
	if imgui.BeginMenuBar() {
		defer imgui.EndMenuBar()
		if imgui.BeginMenu("View") {
			defer imgui.EndMenu()
			tstate := atomic_load_acq(&we_wav_state.thread_state.status)
			if imgui.MenuItem("Play", "Space", tstate == .Play) {
				if tstate == .Pause {
					sync.mutex_lock(&we_wav_state.thread_state.mutex)
					atomic_store_rel(
						&we_wav_state.thread_state.status,
						WavPlayerPlayStatus.PrePlay,
					)
					sync.cond_signal(&we_wav_state.thread_state.pause_cond)
					sync.mutex_unlock(&we_wav_state.thread_state.mutex)
				} else if tstate == .Play {
					atomic_store_rel(
						&we_wav_state.thread_state.status,
						WavPlayerPlayStatus.PrePause,
					)
				}
			}
			if imgui.MenuItem("Follow Cursor", "F", we_wav_state.follow_cursor) {
				we_wav_state.follow_cursor = !we_wav_state.follow_cursor
			}
			imgui.Separator()
			imgui.TextDisabled("%.f Samples", SAMPLE_RATE * we_wav_state.scale)
			if imgui.MenuItem("Zoom In", "I") {
				we_wav_state.scale = max(we_wav_state.scale / 2, f32(1) / 8192)
				we_wav_state.redraw_wav = imgui.GetScrollX()
			}
			if imgui.MenuItem("Zoom Out", "O") {
				we_wav_state.scale = min(we_wav_state.scale * 2, 8192)
				we_wav_state.redraw_wav = imgui.GetScrollX()
			}
			if imgui.MenuItem("Zoom Reset", "R") {
				we_wav_state.scale = 1
				we_wav_state.redraw_wav = imgui.GetScrollX()
			}
			_wav_player_keybinds(base, app, win_tl, content_size)
		}
		if imgui.BeginMenu("Cursors") {
			defer imgui.EndMenu()
			zerop: u64 = 0
			end_m1 := atomic_load_acq(&we_wav_state.end_cursor) - 1
			imgui.SliderScalar(
				"Start Cursor",
				.U64,
				&we_wav_state.start_cursor,
				&zerop,
				&end_m1,
				"%lu",
				{.ClampOnInput},
			)
			start_p1 := atomic_load_acq(&we_wav_state.start_cursor) + 1
			imgui.SliderScalar(
				"End Cursor",
				.U64,
				&we_wav_state.end_cursor,
				&start_p1,
				&we_wav_state.max_frames,
				"%lu",
				{.ClampOnInput},
			)
			if imgui.SliderScalar(
				"Cursor",
				.U64,
				&we_wav_state.play_cursor,
				&we_wav_state.start_cursor,
				&we_wav_state.end_cursor,
				"%lu",
				{.ClampOnInput},
			) {
				atomic_store_rel(&we_wav_state.thread_state.status, WavPlayerPlayStatus.PrePlay2)
			}
		}
		if imgui.BeginMenu("Process To") {
			defer imgui.EndMenu()
			at_least_one := false
			imgui.Text("Waveform Editor Window:")
			for _win_idx in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
				window := &app.windows.waveform_editors[_win_idx]
				if window.is_active {
					we_state := &app.state.we[_win_idx]
					sb := &window.id.(strings.Builder)
					no_create: if imgui.MenuItem(cstring(&sb.buf[0])) {
						if atomic_load_acq(&we_wav_state.thread_state.status) !=
						   WavPlayerPlayStatus.Pause { 	//Because sync.Cond in .Pause
							atomic_store_rel(
								&we_wav_state.thread_state.status,
								WavPlayerPlayStatus.PrePause,
							)
							for atomic_load_acq(&we_wav_state.thread_state.status) !=
							    WavPlayerPlayStatus.Pause {
							}
						}
						sync.mutex_guard(&we_wav_state.thread_state.mutex)
						undo_redo_manager_undo_add_stop(&we_state.undo_redo)
						if app.state.import_wf_at_end {
							if we_state.num_frames == MAX_WAVEFORM_FRAMES do break no_create
							we_state.data_frame = we_state.num_frames
							undo_redo_manager_undo_setmaxframes(
								&we_state.undo_redo,
								app,
								_win_idx,
								we_state.num_frames,
							)
							set_frames(app, _win_idx, we_state.num_frames + 1)
							we_state.num_frames += 1
						}
						undo_redo_manager_undo_data_frame(
							&we_state.undo_redo,
							app,
							_win_idx,
							we_state.data_frame,
						)
						for we_i in 0 ..< we_state.num_points {
							ma_i_f := new_range(
								f64(we_i),
								0,
								f64(we_state.num_points),
								f64(we_wav_state.start_cursor),
								f64(we_wav_state.end_cursor),
							)
							ma_idx_f, ma_rem := math.modf(ma_i_f)
							ma_idx := u64(ma_idx_f)
							r: u64
							undo_redo_manager_undo_wedraw(
								&we_state.undo_redo,
								app,
								_win_idx,
								we_i,
								we_state.data_frame,
							)
							switch we_wav_state.interp {
							case .None:
								result := ma.decoder_seek_to_pcm_frame(&we_wav_state.ma, ma_idx)
								assert(result == .SUCCESS)
								result = ma.decoder_read_pcm_frames(
									&we_wav_state.ma,
									&we_state.data[data_index(we_state.data_frame, u32(we_i))],
									1,
									&r,
								)
								assert(result == .SUCCESS)
							case .Linear:
								samples: [2]f32
								for si in 0 ..< len(samples) {
									result := ma.decoder_seek_to_pcm_frame(
										&we_wav_state.ma,
										(ma_idx + u64(si)) % we_wav_state.max_frames,
									)
									assert(result == .SUCCESS)
									result = ma.decoder_read_pcm_frames(
										&we_wav_state.ma,
										&samples[si],
										1,
										&r,
									)
									assert(result == .SUCCESS)
								}
								slope := samples[1] - samples[0]
								we_state.data[data_index(we_state.data_frame, u32(we_i))] =
									samples[0] + slope * f32(ma_rem)
							case .Cubic:
								samples: [4]f32
								ma_idx_m1 :=
									(ma_idx + we_wav_state.max_frames - 1) %
									we_wav_state.max_frames
								for si in 0 ..< len(samples) {
									result := ma.decoder_seek_to_pcm_frame(
										&we_wav_state.ma,
										(ma_idx_m1 + u64(si)) % we_wav_state.max_frames,
									)
									assert(result == .SUCCESS)
									result = ma.decoder_read_pcm_frames(
										&we_wav_state.ma,
										&samples[si],
										1,
										&r,
									)
									assert(result == .SUCCESS)
								}
								we_state.data[data_index(we_state.data_frame, u32(we_i))] =
									cubic_hermite(
										f32(ma_rem),
										samples[0],
										samples[1],
										samples[2],
										samples[3],
									)
							}
						}
						if app.state.import_wf_norm {
							effect_normalization_full(app, _win_idx, 1)
						}
					}
					at_least_one = true
				}
			}
			if !at_least_one do imgui.MenuItem("(No Windows Available)", enabled = false)
			imgui.Separator()
			help_marker(
				"Interpolates values between sample points using the following\nNone: Interpolate using the leftmost point only\nLinear: Interpolation between the last and next point\nCubic Hermite: Interpolation using 4 points (f(x_m1), f(x0), f(x1), f(x2))\nto calculate between x0 and x1",
			)
			imgui.Text("Audio Interpolation")
			imgui.Combo(
				"##Interpolation",
				cast(^i32)&we_wav_state.interp,
				_INTERPOLATION_TYPE_CSTR,
			)
			imgui.Separator()
			help_marker(
				"Appends waveform data as a frame at the end and increase maximum frames by 1",
			)
			if imgui.MenuItem("Import At End", selected = app.state.import_wf_at_end) {
				app.state.import_wf_at_end = !app.state.import_wf_at_end
			}
			help_marker(
				"Normalize waveform so that its peaks reach either 1 or -1\nWaveform must cross 0 for this to work",
			)
			if imgui.MenuItem("Normalize", selected = app.state.import_wf_norm) {
				app.state.import_wf_norm = !app.state.import_wf_norm
			}
		}
		if imgui.BeginMenu("Help") {
			defer imgui.EndMenu()
			imgui.Text(
				`The .wav Player can be used to extract waveforms
from a .wav file to the waveform editor by changing the
Begin Cursor and End Cursor and selecting a waveform editor window`,
			)}
	}
	//After zoom in or out
	samples_per_window = SAMPLE_RATE * we_wav_state.scale
	button_rect = [2]f32 {
		content_size.x * f32(we_wav_state.max_frames) / samples_per_window,
		content_size.y,
	}
	imgui.SetCursorPos(imgui_tl)
	wav_pos := io.MousePos - win_tl + {imgui.GetScrollX(), 0}
	sample_i := u64(f64(wav_pos.x) / f64(button_rect.x) * f64(we_wav_state.max_frames))
	sample_len_f := f32(we_wav_state.max_frames) / button_rect.x
	imgui.InvisibleButton("LMBDrag", button_rect)
	switch we_wav_state.drag {
	case .None:
	case .Start:
		atomic_store_rel(
			&we_wav_state.start_cursor,
			clamp(sample_i, 0, atomic_load_acq(&we_wav_state.end_cursor) - 1),
		)
	case .End:
		atomic_store_rel(
			&we_wav_state.end_cursor,
			clamp(
				sample_i,
				atomic_load_acq(&we_wav_state.start_cursor) + 1,
				we_wav_state.max_frames,
			),
		)
	case .Drag:
		drag_x := io.MousePos.x - io.MousePosPrev.x
		if drag_x != 0 {
			new_start_cursor, new_end_cursor: u64
			o, o2: bool
			new_start_cursor, o = intrinsics.overflow_sub(sample_i, we_wav_state.drag_dt)
			sc := atomic_load_acq(&we_wav_state.start_cursor)
			ec := atomic_load_acq(&we_wav_state.end_cursor)
			cursor_dt := ec - sc
			if we_wav_state.drag_dt_neg || !o { 	// Not (.drag_dt_neg, o) := (F, T)
				new_end_cursor, o2 = intrinsics.overflow_add(new_start_cursor, cursor_dt)
				if !o2 {
					if new_end_cursor > we_wav_state.max_frames {
						new_end_cursor = we_wav_state.max_frames
						new_start_cursor = we_wav_state.max_frames - cursor_dt
					}
				} else {
					new_end_cursor = we_wav_state.max_frames
					new_start_cursor = we_wav_state.max_frames - cursor_dt
				}
			} else {
				new_start_cursor = 0
				new_end_cursor = cursor_dt
			}
			atomic_store_rel(&we_wav_state.start_cursor, new_start_cursor)
			atomic_store_rel(&we_wav_state.end_cursor, new_end_cursor)
		}
	}
	if imgui.IsMouseReleased(.Left) {
		we_wav_state.drag = .None
	}
	if imgui.IsItemHovered() {
		text_tl := win_tl + 2
		inst_cstr: cstring = "S + LMB: Drag start cursor - E + LMB: Drag end cursor - Shift + LMB: Drag both cursors - Q: Reset cursors\nShift + Left/Right: Shift Selection (Length of both cursors)"
		inst_cstr_v := imgui.CalcTextSize(inst_cstr) + 4
		imgui.DrawList_AddRectFilled(draw_list, text_tl, text_tl + inst_cstr_v, 0xbf000000)
		imgui.DrawList_AddText(draw_list, text_tl + 2, 0xffffffff, inst_cstr)
		if imgui.IsMouseClicked(.Left) {
			drag_e: WavPlayerDrag = .None
			if imgui.IsKeyDown(.ImGuiMod_Ctrl) {
				dt: u64 = bits.U64_MAX
				drag_e = .Start
				if sample_i > we_wav_state.start_cursor {
					dt = sample_i - we_wav_state.start_cursor
				} else {
					dt = we_wav_state.start_cursor - sample_i
				}
				if sample_i > we_wav_state.end_cursor {
					if new_dt := sample_i - we_wav_state.end_cursor; new_dt < dt {
						dt = new_dt
						drag_e = .End
					}
				} else {
					if new_dt := we_wav_state.end_cursor - sample_i; new_dt < dt {
						dt = new_dt
						drag_e = .End
					}
				}
			} else if imgui.IsKeyDown(.ImGuiMod_Shift) {
				drag_e = .Drag
				we_wav_state.drag_dt, we_wav_state.drag_dt_neg = intrinsics.overflow_sub(
					sample_i,
					we_wav_state.start_cursor,
				)
			} else {
				if imgui.IsKeyDown(.S) {
					drag_e = .Start
				} else if imgui.IsKeyDown(.E) {
					drag_e = .End
				} else {
					atomic_store_rel(&we_wav_state.play_cursor, sample_i)
					if atomic_load_acq(&we_wav_state.thread_state.status) == .Play {
						atomic_store_rel(
							&we_wav_state.thread_state.status,
							WavPlayerPlayStatus.PrePlay2,
						)
					}
				}
			}
			if drag_e != .None {
				we_wav_state.drag = drag_e
			}
		}
		if imgui.IsKeyDown(.Q) {
			atomic_store_rel(&we_wav_state.start_cursor, 0)
			atomic_store_rel(&we_wav_state.end_cursor, we_wav_state.max_frames)
		}
	}
	active_id := imgui.GetActiveID()
	if active_id != 0 {
		if active_id == imgui.GetWindowScrollbarID(imgui.GetCurrentWindow(), .X) {
			we_wav_state.redraw_wav = imgui.GetScrollX()
		}
	}
	if we_wav_state.last_window_size != imgui.GetWindowSize() {
		we_wav_state.redraw_wav = imgui.GetScrollX()
	}
	we_wav_state.last_window_size = imgui.GetWindowSize()
	play_cursor_x := _cursor_pos_f(we_wav_state.play_cursor, win_tl, button_rect, we_wav_state)
	if we_wav_state.redraw_wav == nil &&
	   we_wav_state.follow_cursor &&
	   atomic_load_acq(&we_wav_state.thread_state.status) == .Play {
		scroll_x := imgui.GetScrollX()
		pcx :=
			win_tl.x + f32(we_wav_state.play_cursor) / f32(we_wav_state.max_frames) * button_rect.x
		if pcx <= scroll_x || pcx >= scroll_x + content_size.x {
			base.keep_scroll_here = imgui.Vec2{pcx, 0}
			we_wav_state.redraw_wav = pcx
		}
	}
	no_draw: if we_wav_state.redraw_wav != nil && base.keep_scroll_here == nil {
		//Draw lines of min/max based on samples per pixel
		sx := u64(min(we_wav_state.redraw_wav.(f32), imgui.GetScrollMaxX()))
		if math.is_inf(sample_len_f) {
			we_wav_state.scale /= 2
			break no_draw
		}
		sample_len := u64(math.ceil(sample_len_f))
		sample_arr := make([dynamic]f32, int(sample_len))
		defer delete(sample_arr)
		if we_wav_state.wav_texture != nil {
			sdl.ReleaseGPUTexture(app.gpu, we_wav_state.wav_texture)
			we_wav_state.wav_texture = nil
		}
		pixel_map := make([dynamic]u32, u64(content_size.x) * u64(content_size.y))
		defer delete(pixel_map)
		img := ImageData {
			width  = c.int(content_size.x),
			height = c.int(content_size.y),
			data   = cast(^u8)raw_data(pixel_map),
		}
		if len(pixel_map) == 0 do break no_draw
		pixel_loop: for i in sx ..< sx + u64(content_size.x) {
			sample_block_start := u64(sample_len_f * f32(i))
			sync.mutex_lock(&we_wav_state.thread_state.mutex)
			result := ma.decoder_seek_to_pcm_frame(&we_wav_state.ma, sample_block_start)
			assert(result == .SUCCESS)
			sample_size: u64
			result = ma.decoder_read_pcm_frames(
				&we_wav_state.ma,
				&sample_arr[0],
				sample_len,
				&sample_size,
			)
			#partial switch result {
			case .SUCCESS:
			case .AT_END:
				sync.mutex_unlock(&we_wav_state.thread_state.mutex)
				break pixel_loop
			case:
				sync.mutex_unlock(&we_wav_state.thread_state.mutex)
				fmt.panicf("Unexpected miniaudio error: {}", result)
			}
			sync.mutex_unlock(&we_wav_state.thread_state.mutex)
			dwl := DrawWavLine_Init
			for s in sample_arr[0:sample_size] {
				dwl.max = max(dwl.max, s)
				dwl.min = min(dwl.min, s)
			}
			//Then transform to window coordinates
			dwl.min = new_range_f32(dwl.min, {-1, 1}, {content_size.y - 1, 0})
			dwl.max = new_range_f32(dwl.max, {-1, 1}, {content_size.y - 1, 0})
			tmp := dwl.min
			dwl.min = dwl.max
			dwl.max = math.min(tmp + 1, content_size.y) //To make line width always 1 if min nearly equals max
			for j in u64(dwl.min) ..< u64(dwl.max) {
				pixel_map[j * u64(content_size.x) + (i - sx)] = 0xffffffff
			}
		}
		we_wav_state.wav_texture = imgui_load_texture(app.gpu, &img)
		assert(we_wav_state.wav_texture != nil)
		we_wav_state.redraw_wav = nil
	}
	if we_wav_state.wav_texture != nil {
		imgui.DrawList_AddImage(
			draw_list,
			as_texture_ref(we_wav_state.wav_texture),
			win_tl,
			win_tl + content_size,
		)
	}
	start_cursor_x := _cursor_pos_f(we_wav_state.start_cursor, win_tl, button_rect, we_wav_state)
	imgui.DrawList_AddLineV(
		draw_list,
		start_cursor_x,
		win_tl.y,
		win_tl.y + content_size.y - 1,
		0xffff0000,
		2.0,
	)
	end_cursor_x := _cursor_pos_f(we_wav_state.end_cursor, win_tl, button_rect, we_wav_state)
	imgui.DrawList_AddLineV(
		draw_list,
		end_cursor_x,
		win_tl.y,
		win_tl.y + content_size.y - 1,
		0xff0000ff,
		2.0,
	)
	imgui.DrawList_AddLineV(
		draw_list,
		play_cursor_x,
		win_tl.y,
		win_tl.y + content_size.y - 1,
		0xff00ffff,
		2.0,
	)
}

_wav_player_keybinds :: proc(base: ^ImGuiWindow, app: ^App, win_tl, content_size: [2]f32) {
	we_wav_state := &app.state.we_wav_state
	io := imgui.GetIO()
	wav_pos := io.MousePos - win_tl + {imgui.GetScrollX(), 0}
	mw := io.MouseWheel
	samples_per_window := SAMPLE_RATE * we_wav_state.scale
	samples_rect_size := [2]f32 {
		content_size.x * f32(we_wav_state.max_frames) / samples_per_window,
		content_size.y,
	}
	to_sample_i := wav_pos.x / samples_rect_size.x * f32(we_wav_state.max_frames)
	if imgui.IsKeyDown(.ImGuiMod_Shift) {
		if imgui.IsKeyPressed(.LeftArrow) {
			old_start_cursor := atomic_load_acq(&we_wav_state.start_cursor)
			old_end_cursor := atomic_load_acq(&we_wav_state.end_cursor)
			cursor_dt := old_end_cursor - old_start_cursor
			new_start_cursor, o := intrinsics.overflow_sub(old_start_cursor, cursor_dt)
			if !o {
				atomic_store_rel(&we_wav_state.start_cursor, new_start_cursor)
				atomic_store_rel(&we_wav_state.end_cursor, old_end_cursor - cursor_dt)
				pcx :=
					win_tl.x +
					f32(we_wav_state.start_cursor) /
						f32(we_wav_state.max_frames) *
						samples_rect_size.x
				if pcx <= imgui.GetScrollX() {
					left_end := max(imgui.GetScrollX() - content_size.x, 0)
					base.keep_scroll_here = imgui.Vec2{left_end, 0}
					we_wav_state.redraw_wav = left_end
				}
			}
		}
		if imgui.IsKeyPressed(.RightArrow) {
			old_start_cursor := atomic_load_acq(&we_wav_state.start_cursor)
			old_end_cursor := atomic_load_acq(&we_wav_state.end_cursor)
			cursor_dt := old_end_cursor - old_start_cursor
			new_start_cursor := old_end_cursor
			new_end_cursor := new_start_cursor + cursor_dt
			if new_end_cursor <= we_wav_state.max_frames {
				atomic_store_rel(&we_wav_state.start_cursor, new_start_cursor)
				atomic_store_rel(&we_wav_state.end_cursor, new_end_cursor)
				pcx :=
					win_tl.x +
					f32(we_wav_state.end_cursor) /
						f32(we_wav_state.max_frames) *
						samples_rect_size.x
				right_end := imgui.GetScrollX() + content_size.x
				if pcx >= right_end {
					base.keep_scroll_here = imgui.Vec2{right_end, 0}
					we_wav_state.redraw_wav = right_end
				}
			}
		}
	}
	if imgui.IsKeyPressed(.Space, false) {
		#partial switch atomic_load_acq(&we_wav_state.thread_state.status) {
		case .Play:
			atomic_store_rel(&we_wav_state.thread_state.status, WavPlayerPlayStatus.PrePause)
		case .Pause:
			sync.mutex_lock(&we_wav_state.thread_state.mutex)
			atomic_store_rel(&we_wav_state.thread_state.status, WavPlayerPlayStatus.PrePlay)
			sync.cond_signal(&we_wav_state.thread_state.pause_cond)
			sync.mutex_unlock(&we_wav_state.thread_state.mutex)
		}
	}
	if imgui.IsKeyPressed(.F, false) {
		we_wav_state.follow_cursor = !we_wav_state.follow_cursor
	}
	if imgui.IsKeyPressed(.R, false) {
		we_wav_state.scale = 1
		we_wav_state.redraw_wav = imgui.GetScrollX()
		sb := strings.builder_make()
		strings.write_string(&sb, "Reset Zoom: ")
		fmt.sbprintf(&sb, "{} samples", SAMPLE_RATE)
		strings.write_byte(&sb, 0)
		tooltip_change(app, sb, .Info, app.state.frames + 2000 / u64(app.config.mspf))
	}
	if imgui.IsKeyPressed(.I, false) || mw > 0 {
		old_scale := we_wav_state.scale
		new_scale := max(we_wav_state.scale / 2, f32(1) / 8192)
		if new_scale != we_wav_state.scale {
			we_wav_state.scale = new_scale
			sample_i_dt := to_sample_i / 2
			srs_sample_width := samples_rect_size.x * old_scale / f32(we_wav_state.max_frames)
			sx := max(0, imgui.GetScrollX() + sample_i_dt * srs_sample_width / new_scale)
			base.keep_scroll_here = [2]f32{sx, 0}
			we_wav_state.redraw_wav = sx
			sb := strings.builder_make()
			strings.write_string(&sb, "Zoom In: ")
			fmt.sbprintf(&sb, "%.f samples", we_wav_state.scale * SAMPLE_RATE)
			strings.write_byte(&sb, 0)
			tooltip_change(app, sb, .Info, app.state.frames + 2000 / u64(app.config.mspf))
		}
	}
	if imgui.IsKeyPressed(.O, false) || mw < 0 {
		old_scale := we_wav_state.scale
		new_scale := min(we_wav_state.scale * 2, 8192)
		if new_scale != we_wav_state.scale {
			we_wav_state.scale = new_scale
			sample_i_dt := -to_sample_i
			srs_sample_width := samples_rect_size.x * old_scale / f32(we_wav_state.max_frames)
			sx := max(0, imgui.GetScrollX() + sample_i_dt * srs_sample_width / new_scale)
			base.keep_scroll_here = [2]f32{sx, 0}
			we_wav_state.redraw_wav = sx
			sb := strings.builder_make()
			strings.write_string(&sb, "Zoom Out: ")
			fmt.sbprintf(&sb, "%.f samples", we_wav_state.scale * SAMPLE_RATE)
			strings.write_byte(&sb, 0)
			tooltip_change(app, sb, .Info, app.state.frames + 2000 / u64(app.config.mspf))
		}
	}
}

f_wav_player_destroy :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	handle_map.remove(&app.imgui_hm, base.handle)
	we_wav_state_destroy(&app.state.we_wav_state, app)
	base.is_active = false
}
