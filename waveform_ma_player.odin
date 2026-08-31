package waveform_editor

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"

import imgui "imgui:."
import pb "playback_buffer"
import ma "vendor:miniaudio"

SAMPLE_RATE :: 44100
waveform_editor_ma_init :: proc(app: ^App) {
	if app.state.wp.has_init do return
	app.state.wp = WaveformPlayer {
		app       = app,
		frequency = 440,
		amplitude = 0.251189, //Around -12 dBFS
	}
	dev_cfg := ma.device_config_init(.playback)
	dev_cfg.playback.format = .f32
	dev_cfg.playback.channels = 1
	dev_cfg.sampleRate = SAMPLE_RATE
	dev_cfg.dataCallback = ma_callback
	dev_cfg.noFixedSizedCallback = true
	dev_cfg.pUserData = &app.state.wp
	if ma.device_init(nil, &dev_cfg, &app.state.wp.ma_device) != ma.result.SUCCESS {
		panic("Unable to start miniaudio device")
	}
	if ma.device_start(&app.state.wp.ma_device) != ma.result.SUCCESS {
		panic("Failed to start miniaudio device")
	}
	app.state.wp.has_init = true
}
waveform_editor_ma_destroy :: proc(app: ^App) {
	ma.device_uninit(&app.state.wp.ma_device)
}
//When changing player variables, including data and num_points
wp_mutex: sync.Mutex
last_frame_count: u32
ma_callback :: proc "c" (ma_device: ^ma.device, output, input: rawptr, frame_count: u32) {
	sync.mutex_guard(&wp_mutex)
	wp := cast(^WaveformPlayer)ma_device.pUserData
	last_frame_count = frame_count
	fadd_arr: [MAX_WAVEFORM_EDITOR_WINDOWS]FloatAdderData
	thread_arr: [MAX_WAVEFORM_EDITOR_WINDOWS]^thread.Thread
	output_buffer := cast([^]f32)(output)
	num_threads: int = 0
	context = app_context
	for &we_state in wp.app.state.we[:] {
		if !we_state.is_active || !we_state.play do continue
		fadd_arr[num_threads] = {
			frame_count   = frame_count,
			we_state      = &we_state,
			wp            = wp,
			output_buffer = output_buffer,
		}
		thread_arr[num_threads] = thread.create_and_start_with_data(
			&fadd_arr[num_threads],
			float_thread_add,
		)
		num_threads += 1
	}
	we_wav_state := &wp.app.state.we_wav_state
	if sync.atomic_load_explicit(&we_wav_state.thread_state.status, .Acquire) == .Play {
		result_buf: [MAX_PLAYBACK_SAMPLES]f32
		sync.mutex_lock(&we_wav_state.thread_state.mutex)
		result := pb.pop(&we_wav_state.pb, result_buf[:frame_count])
		sync.mutex_unlock(&we_wav_state.thread_state.mutex)
		if result.status == .Ok {
			for i in 0 ..< result.num_popped {
				atomic_add_f32(&output_buffer[i], result_buf[i])
			}
			sync.atomic_store_explicit(&we_wav_state.play_cursor, result.idx, .Release)
		}
	}
	for thr in thread_arr[:num_threads] {
		thread.join(thr)
	}
	for thr in thread_arr[:num_threads] {
		thread.destroy(thr)
	}
	if osc_i <= OSC_BUF_SIZE - i32(frame_count) {
		mem.copy_non_overlapping(
			&osc_buf[osc_i],
			&output_buffer[0],
			int(size_of(f32) * frame_count),
		)
	} else {
		frames_end := OSC_BUF_SIZE - osc_i
		mem.copy_non_overlapping(
			&osc_buf[osc_i],
			&output_buffer[0],
			int(size_of(f32) * frames_end),
		)
		mem.copy_non_overlapping(
			&osc_buf[0],
			&output_buffer[frames_end],
			int(size_of(f32) * (i32(frame_count) - frames_end)),
		)
	}
	osc_i = (osc_i + i32(frame_count)) % OSC_BUF_SIZE
}
FloatAdderData :: struct {
	we_state:      ^WaveformEditorState,
	wp:            ^WaveformPlayer,
	frame_count:   u32,
	output_buffer: [^]f32,
}
float_thread_add :: proc(userdata: rawptr) {
	fadd := (^FloatAdderData)(userdata)
	num_points := u32(fadd.we_state.num_points)
	data := fadd.we_state.data[data_index(fadd.we_state.data_frame, 0):data_index(
		fadd.we_state.data_frame,
		num_points,
	)]
	step := f64(fadd.wp.frequency) * f64(num_points) / SAMPLE_RATE
	for i in 0 ..< fadd.frame_count {
		idx_f, idx_r := math.modf_f64(fadd.we_state.phase)
		idx := u32(idx_f) % num_points
		switch fadd.we_state.interp_v {
		case .None:
			atomic_add_f32(
				&fadd.output_buffer[i],
				clamp(data[idx] * fadd.wp.amplitude, -fadd.wp.amplitude, fadd.wp.amplitude),
			)
		case .Linear:
			diff := data[(idx + 1) % num_points] - data[idx]
			atomic_add_f32(
				&fadd.output_buffer[i],
				clamp(
					(data[idx] + diff * f32(idx_r)) * fadd.wp.amplitude,
					-fadd.wp.amplitude,
					fadd.wp.amplitude,
				),
			)
		case .Cubic:
			y_m1 := data[(num_points + idx - 1) % num_points]
			y0 := data[idx]
			y1 := data[(idx + 1) % num_points]
			y2 := data[(idx + 2) % num_points]
			atomic_add_f32(
				&fadd.output_buffer[i],
				clamp(
					cubic_hermite(f32(idx_r), y_m1, y0, y1, y2) * fadd.wp.amplitude,
					-fadd.wp.amplitude,
					fadd.wp.amplitude,
				),
			)
		}
		fadd.we_state.phase += step
	}
}
atomic_add_f32 :: proc(target: ^f32, value: f32) {
	for {
		old_bits := intrinsics.atomic_load_explicit(cast(^u32)target, .Relaxed)
		old_f32 := transmute(f32)old_bits
		new_f32 := old_f32 + value
		_, ok := intrinsics.atomic_compare_exchange_weak_explicit(
			cast(^u32)target,
			old_bits,
			transmute(u32)new_f32,
			.Acq_Rel,
			.Relaxed,
		)
		if ok do return
	}
}
MAX_WRITE_BUFFER_FRAMES :: 4096
OSC_BUF_SIZE :: MAX_WRITE_BUFFER_FRAMES
osc_buf: [OSC_BUF_SIZE]f32
osc_disp_buf: [OSC_BUF_SIZE]f32
osc_i: i32
osc_frame_size: i32 = 900
f_draw_oscilloscope :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	we_state := &app.state.we[win_idx]
	if imgui.BeginMenuBar() {
		if imgui.BeginMenu("View") {
			sync.mutex_lock(&wp_mutex)
			imgui.SliderInt("Frame Size", &osc_frame_size, 2, OSC_BUF_SIZE, "%d Samples")
			osc_frame_size = clamp(osc_frame_size, 2, OSC_BUF_SIZE)
			if imgui.IsItemHovered() {
				imgui.SetTooltip(
					"Shows the number of samples to view from [2,%d].\nThe sample rate for this application is %d Hz.\nCtrl + LMB to manually input",
					OSC_BUF_SIZE,
					SAMPLE_RATE,
				)
			}
			sync.mutex_unlock(&wp_mutex)
			imgui.Separator()
			help_marker(
				"Triggers anchor the graph at y-values with rising or falling slopes.\nTriggers work well if there is only one y-value that is rising/falling once per waveform\nCtrl + LMB to manually input",
			)
			imgui.Text("Triggers")
			imgui.SliderFloat("Trigger Value", &we_state.trigger_v, -1, 1)
			we_state.trigger_v = clamp(we_state.trigger_v, -1, 1)
			if imgui.IsItemHovered() {
				imgui.SetTooltip(
					"This will make the oscillator anchor at points between\n-1 and 1 based on the reading of the oscilloscope.\nUse along side Trigger Slope.",
				)
			}
			imgui.Combo(
				"Trigger Slope Type",
				cast(^i32)&we_state.trigger_slope_v,
				_TRIGGER_SLOPE_TYPE_CSTR,
			)
			if imgui.IsItemHovered() {
				imgui.SetTooltip(
					"This will make the oscillator anchor at specific slopes.\nUse along side Trigger Value.",
				)
			}
			imgui.EndMenu()
		}
		imgui.EndMenuBar()
	}
	if imgui.IsWindowFocused() {
		if imgui.IsKeyDown(.ImGuiMod_Ctrl) {
			changed := false
			lb := imgui.GetKeyData(.LeftBracket)
			rb := imgui.GetKeyData(.RightBracket)
			if lb.Down {
				sync.mutex_guard(&wp_mutex)
				osc_frame_size -= i32(math.pow_f32(1.5, lb.DownDuration))
				osc_frame_size = clamp(osc_frame_size, 2, OSC_BUF_SIZE)
				changed = true
			}
			if rb.Down {
				sync.mutex_guard(&wp_mutex)
				osc_frame_size += i32(math.pow_f32(1.5, rb.DownDuration))
				osc_frame_size = clamp(osc_frame_size, 2, OSC_BUF_SIZE)
				changed = true
			}
			if changed {
				sb := strings.builder_make()
				strings.write_string(&sb, "Window Size:\n")
				fmt.sbprintf(&sb, "%d Hz", osc_frame_size)
				strings.write_byte(&sb, 0)
				tooltip_change(app, sb, .Info, app.state.frames + 2000 / u64(app.config.mspf))
			}
		}
	}
	sync.mutex_guard(&wp_mutex)
	trigger_i := find_trigger_index(we_state.trigger_v, we_state.trigger_slope_v)
	if trigger_i <= OSC_BUF_SIZE - osc_frame_size {
		mem.copy_non_overlapping(
			&osc_disp_buf[0],
			&osc_buf[trigger_i],
			int(osc_frame_size) * size_of(f32),
		)
	} else {
		frames_end := OSC_BUF_SIZE - trigger_i
		mem.copy_non_overlapping(
			&osc_disp_buf[0],
			&osc_buf[trigger_i],
			int(frames_end) * size_of(f32),
		)
		mem.copy_non_overlapping(
			&osc_disp_buf[frames_end],
			&osc_buf[0],
			int(osc_frame_size - frames_end) * size_of(f32),
		)
	}
	imgui.PlotLines(
		"##Osc",
		&osc_disp_buf[0],
		osc_frame_size,
		0,
		nil,
		-1,
		1,
		imgui.GetContentRegionAvail(),
	)
}

find_trigger_index :: proc(value: f32, slope: TriggerSlopeType) -> i32 {
	if slope == .Disabled do return 0
	for i in 0 ..< osc_frame_size {
		idx1 := (osc_i - i - 2 + osc_frame_size * 2) % osc_frame_size
		idx2 := (osc_i - i - 1 + osc_frame_size * 2) % osc_frame_size
		#partial switch slope {
		case .Rising:
			if osc_buf[idx1] <= value && osc_buf[idx2] > value {
				return idx2
			}
		case .Falling:
			if osc_buf[idx1] >= value && osc_buf[idx2] < value {
				return idx2
			}
		}
	}
	return 0
}
