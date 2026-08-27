package waveform_editor

import "core:container/handle_map"
import "core:container/queue"
import "core:fmt"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"

import "./assets"
import "./colors"
import imgui "imgui:."
import ma "vendor:miniaudio"

//data is a combined array of frames * MAX_WAVEFORM_EDITOR_POINTS
data_index :: proc "contextless" (frame: i32, idx: u32) -> u32 {
	return u32(frame) * MAX_WAVEFORM_EDITOR_POINTS + idx
}
//num_frames should also be set to frames
set_frames :: proc(app: ^App, win_idx: int, frames: i32) {
	assert(frames > 0 && frames <= MAX_WAVEFORM_FRAMES)
	we_state := &app.state.we[win_idx]
	resize(&we_state.data, int(frames * MAX_WAVEFORM_EDITOR_POINTS))
}
MAX_WAVEFORM_FRAMES :: 256
WaveformEditorState :: struct {
	data:            [dynamic]f32,
	data_frame:      i32,
	num_frames:      i32,
	undo_redo:       UndoRedoManager,
	phase:           f64,
	num_points:      i32, //1 to MAX_WAVEFORM_EDITOR_POINTS
	scale:           f32,
	edit_state:      EditState,
	read_range:      WaveformRangeType,
	last_effect_vf:  EffectPtr,
	gain_v:          f32,
	normal_v:        f32,
	comb_m_v:        f32,
	comb_n_v:        i32,
	ch_phase_v:      i32,
	hard_clip_v:     f32,
	soft_clip_v:     f32,
	wavefold_v:      f32,
	cheb_n_v:        f32,
	offset_v:        f32,
	overtone_v:      i32,
	low_pass_v:      f32,
	high_pass_v:     f32,
	h_shift_by_v:    f32,
	bitcrush_v:      WaveformBitcrush,
	interp_v:        InterpolationType,
	n_samp_interp_v: InterpolationType,
	n_samp_v:        i32,
	trigger_v:       f32,
	trigger_slope_v: TriggerSlopeType,
	amp_buf:         [64]u8,
	key_buf:         [8]u8,
	ie_text:         ImportExportText,
	is_active:       bool,
	play:            bool,
}

EditSelect :: struct {
	begin: i16,
	end:   i16,
	dt:    i16,
}
EditSelectNone :: EditSelect{-1, -1, 0}
edit_select_is_none :: #force_inline proc(es: EditSelect) -> bool {
	return es.begin == EditSelectNone.begin && es.end == EditSelectNone.end
}
EditStateUnion :: struct #raw_union {
	draw:   i32,
	select: EditSelect,
}
EditStateType :: enum {
	None, //v = none
	DrawNone, //v = none
	DrawLastX, //v = .draw
	SelectIdle, //v = EditSelect
	SelectInit, //v = EditSelect
	SelectMove, //v = EditSelect
	SelectLeft, //v = EditSelect
	SelectRight, //v = EditSelect
}
EditState :: struct {
	v:    EditStateUnion,
	type: EditStateType,
}

waveform_editor_new :: proc(app: ^App) -> (int, bool) {
	win_idx: Maybe(int)
	for we_state, idx in app.state.we {
		if we_state.is_active do continue
		win_idx = idx
		break
	}
	if _win_idx, exists := win_idx.?; exists {
		app.state.we[_win_idx] = WaveformEditorState {
			data            = make([dynamic]f32, MAX_WAVEFORM_EDITOR_POINTS),
			num_frames      = 1,
			scale           = 1,
			num_points      = 64,
			last_effect_vf  = effect_none,
			gain_v          = 0.5,
			interp_v        = .Linear,
			n_samp_interp_v = .Linear,
			n_samp_v        = 64,
			normal_v        = 1,
			comb_m_v        = 0.5,
			comb_n_v        = 32,
			hard_clip_v     = 1,
			low_pass_v      = 1,
			high_pass_v     = 1,
			bitcrush_v      = ._3B,
			soft_clip_v     = 1,
			wavefold_v      = 1,
			cheb_n_v        = 2,
			overtone_v      = 1,
			is_active       = true,
		}
		undo_redo_manager_new(&app.state.we[_win_idx].undo_redo)
		id_sb := strings.builder_make()
		fmt.sbprintf(&id_sb, "Waveform Editor %d - Untitled\x00", _win_idx + 1)
		app.windows.waveform_editors[_win_idx] = imgui_window_new(
			id_sb,
			_win_idx,
			container_f = f_waveform_editor_draw,
			destroy_f = f_waveform_editor_destroy,
			position = {{}, UDim{s = 0.5}},
			size = {UDim{s = 1}, UDim{s = 0.25}},
			flags = {.NoScrollWithMouse, .NoScrollbar, .AlwaysHorizontalScrollbar, .MenuBar},
		)
		imgui_window_add_handle(app, &app.windows.waveform_editors[_win_idx])
		harmonics_update_model(app, _win_idx)
		reset_phases(app)
		return _win_idx, true
	} else {
		tooltip_change(
			app,
			cstring("Unable to create more windows (Max limit)"),
			.Error,
			app.state.frames + 3000 / u64(app.config.mspf),
		)
		return 0, false
	}
}
//Check if .is_active is true
waveform_editor_destroy :: proc(we_state: ^WaveformEditorState) {
	undo_redo_manager_destroy(&we_state.undo_redo)
	we_state.undo_redo = {}
	delete(we_state.data)
	we_state.data = nil
}

ImportExportText :: enum {
	Import,
	Export,
}
WaveformPlayer :: struct {
	app:       ^App,
	frequency: f32,
	amplitude: f32,
	ma_device: ma.device,
	has_init:  bool,
}
_TRIGGER_SLOPE_TYPE_CSTR: cstring : "Disabled - No Anchoring\x00Rising - Anchors at positive slopes\x00Falling - Anchors at negative slopes\x00"
TriggerSlopeType :: enum i32 {
	Disabled,
	Rising,
	Falling,
}
_INTERPOLATION_TYPE_CSTR: cstring : "None\x00Linear\x00Cubic Hermite\x00"
InterpolationType :: enum i32 {
	None,
	Linear,
	Cubic,
}
_WAVEFORM_BITCRUSH_CSTR: cstring : "1-bit (2 values)\x002-bit (4 values)\x003-bit (8 values)\x004-bit (16 values)\x005-bit (32 values)\x006-bit (64 values)\x007-bit (128 values)\x008-bit (256 values)\x00"
WaveformBitcrush :: enum i32 {
	_1B,
	_2B,
	_3B,
	_4B,
	_5B,
	_6B,
	_7B,
	_8B,
}
WaveformRangeType :: enum i32 {
	F32_CLAMP,
	U8,
	I16,
}
WaveformRange := [WaveformRangeType]linalg.Vector2f32 {
	.F32_CLAMP = {-1, 1},
	.U8        = {bits.U8_MIN, bits.U8_MAX},
	.I16       = {bits.I16_MIN, bits.I16_MAX},
}

_WAVEFORM_RANGE_CSTR: cstring : "Float (-1 to 1)\x00U8 (0 to 255)\x00I16 (-32768 to 32767)\x00"

set_amplitude_buffer :: proc(app: ^App, we_state: ^WaveformEditorState) {
	dbfs: f32 = ---
	if app.state.wp.amplitude > 0.000001 {
		dbfs = 20 * math.log10(app.state.wp.amplitude)
	} else {
		dbfs = math.inf_f32(-1)
	}
	mem.zero(&we_state.amp_buf, len(we_state.amp_buf))
	fmt.bprintf(
		we_state.amp_buf[:len(we_state.amp_buf) - 1],
		"%.3f (%.2f dBFS)",
		app.state.wp.amplitude,
		dbfs,
	)
}

//Gets top-left (tl) and bottom-right (br) position of a window, cursor scroll top-left (cursor_tl), mouse position relative to tl
LineGraphProperties :: struct {
	tl, br, total_size, mouse_pos, cursor_tl: imgui.Vec2,
}
get_line_graph_prop :: proc(include_menu_bar: bool) -> LineGraphProperties {
	lgp: LineGraphProperties
	io := imgui.GetIO()
	style := imgui.GetStyle()
	size_offset := imgui.GetFrameHeight()
	if include_menu_bar do size_offset *= 2
	wp := imgui.GetWindowPos()
	lgp.tl = wp + imgui.Vec2{0, size_offset}
	lgp.br = wp + imgui.GetWindowSize()
	lgp.total_size = lgp.br - lgp.tl
	lgp.mouse_pos = io.MousePos - lgp.tl
	lgp.cursor_tl = imgui.GetCursorStartPos() - style.WindowPadding
	return lgp
}
_draw_bar :: proc(
	app: ^App,
	we_state: ^WaveformEditorState,
	draw_list: ^imgui.DrawList,
	i: i32,
	draw_tl: imgui.Vec2,
	line_graph_size: imgui.Vec2,
	bar_width_unsized: f32,
	bar_color: u32be,
	line_color: u32be,
	is_highlight: bool = false,
	override_val: Maybe(f32) = nil,
) {
	if is_highlight {
		tl := draw_tl + {bar_width_unsized * f32(i) * we_state.scale, 0} + {1, 1}
		br :=
			draw_tl + {bar_width_unsized * f32(i + 1) * we_state.scale, line_graph_size.y} - {1, 1}
		imgui.DrawList_AddRectFilled(
			draw_list,
			tl,
			br,
			transmute(u32)colors.WE_LINE_GRAPH.background_highlight,
		)
	}
	y_val := override_val.? or_else we_state.data[data_index(we_state.data_frame, u32(i))]
	zero_y := line_graph_size.y / 2
	ml := draw_tl + {0, zero_y}
	#partial switch math.classify(y_val) {
	case .Inf, .Neg_Inf, .NaN:
		warn_uv := assets.tex_atlas_uv[.Warn]
		//20 px warn image in the middle
		tl :=
			ml +
			{bar_width_unsized * we_state.scale * f32(i), 0} +
			{bar_width_unsized * we_state.scale / 2 - 10, -10}
		br :=
			ml +
			{bar_width_unsized * we_state.scale * f32(i), 0} +
			{bar_width_unsized * we_state.scale / 2 + 10, 10}
		imgui.DrawList_AddImage(
			draw_list,
			as_texture_ref(app, .tex_atlas),
			tl,
			br,
			warn_uv.tl,
			warn_uv.br,
			imgui.ColorConvertFloat4ToU32({1, 1, 0, 1}),
		)
	}
	if y_val >= 0 { 	// {1,1 because of lines in rect not showing up}
		tl :=
			ml +
			{bar_width_unsized * f32(i) * we_state.scale, -(line_graph_size.y / 2) * y_val} +
			{1, 1}
		br := ml + {bar_width_unsized * f32(i + 1) * we_state.scale, 0} - {1, 1}
		imgui.DrawList_AddRectFilled(draw_list, tl, br, transmute(u32)bar_color)
		imgui.DrawList_AddRect(draw_list, tl, br, transmute(u32)line_color)
	} else {
		tl := ml + {bar_width_unsized * f32(i) * we_state.scale, 0} + {1, 1}
		br :=
			ml +
			{bar_width_unsized * f32(i + 1) * we_state.scale, -(line_graph_size.y / 2) * y_val} -
			{1, 1}
		imgui.DrawList_AddRectFilled(draw_list, tl, br, transmute(u32)bar_color)
		imgui.DrawList_AddRect(draw_list, tl, br, transmute(u32)line_color)
	}
	if math.abs(y_val) > 1 {
		warn_uv := assets.tex_atlas_uv[.Warn]
		tl :=
			ml +
			{bar_width_unsized * we_state.scale * f32(i), 0} +
			{bar_width_unsized * we_state.scale / 2 - 10, -10}
		br :=
			ml +
			{bar_width_unsized * we_state.scale * f32(i), 0} +
			{bar_width_unsized * we_state.scale / 2 + 10, 10}
		imgui.DrawList_AddImage(
			draw_list,
			as_texture_ref(app, .tex_atlas),
			tl,
			br,
			warn_uv.tl,
			warn_uv.br,
			imgui.ColorConvertFloat4ToU32({1, 1, 0, 1}),
		)
	}
}
f_waveform_editor_draw :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	we_state := &app.state.we[win_idx]
	io := imgui.GetIO()
	style := imgui.GetStyle()
	lgp := get_line_graph_prop(true)
	image_mouse_pos := imgui.Vec2 {
		(lgp.mouse_pos.x - lgp.cursor_tl.x) / we_state.scale,
		lgp.mouse_pos.y,
	}
	line_graph_size := lgp.total_size - {0, style.ScrollbarSize}
	bar_width_unsized := line_graph_size.x / f32(we_state.num_points)
	draw_list := imgui.GetWindowDrawList()
	imgui_tl := imgui.GetCursorScreenPos() - style.WindowPadding
	imgui.DrawList_AddRectFilled(
		draw_list,
		imgui_tl,
		imgui_tl + {line_graph_size.x * we_state.scale, line_graph_size.y},
		transmute(u32)colors.WE_LINE_GRAPH.background_idle,
	)
	is_draw: bool
	is_select: bool
	#partial switch we_state.edit_state.type {
	case .DrawNone, .DrawLastX:
		is_draw = true
	case .SelectIdle, .SelectInit, .SelectMove, .SelectLeft, .SelectRight:
		is_select = true
	}
	imgui.SetCursorScreenPos(imgui_tl)
	imgui.InvisibleButton("##Plot", {lgp.total_size.x * we_state.scale, lgp.total_size.y})
	if imgui.IsWindowFocused() {
		if imgui.IsKeyPressed(.I, false) {
			new_scale := math.min(we_state.scale * 2, 128)
			if new_scale != we_state.scale {
				to_x := image_mouse_pos.x / bar_width_unsized
				from_x := to_x / 2
				we_state.scale = new_scale
				base.keep_scroll_here = imgui.Vec2 {
					imgui.GetScrollX() + (to_x - from_x) * bar_width_unsized * new_scale,
					0,
				}
			}
		}
		if imgui.IsKeyPressed(.O, false) {
			new_scale := math.max(we_state.scale / 2, 1)
			to_x := image_mouse_pos.x / bar_width_unsized
			from_x := to_x * 2
			we_state.scale = new_scale
			base.keep_scroll_here = imgui.Vec2 {
				imgui.GetScrollX() + (to_x - from_x) * bar_width_unsized * new_scale,
				0,
			}
		}
		if is_select && we_state.edit_state.type != .SelectIdle {
			if io.MousePos.x < lgp.tl.x {
				imgui.SetScrollX(imgui.GetScrollX() - bar_width_unsized * we_state.scale)
			}
			if io.MousePos.x > lgp.br.x {
				imgui.SetScrollX(imgui.GetScrollX() + bar_width_unsized * we_state.scale)
			}
		}
	}
	if imgui.IsWindowFocused() {
		_we_keybinds(base, app, we_state, win_idx, i32(image_mouse_pos.x / bar_width_unsized))
		if imgui.IsMouseClicked(.Left) {
			app.state.we_edit_v.status = .None
		}
	}
	for i in 0 ..< we_state.num_points {
		_draw_bar(
			app,
			we_state,
			draw_list,
			i,
			imgui_tl,
			line_graph_size,
			bar_width_unsized,
			colors.WE_LINE_GRAPH.bar_idle,
			colors.WE_LINE_GRAPH.line_idle,
			false,
		)
	}
	undo_add_unique :: proc(wedraw_idx_buf: ^[dynamic]i32, new_i: i32) {
		if idx, exists := slice.binary_search(wedraw_idx_buf[:], new_i); !exists do inject_at(wedraw_idx_buf, idx, new_i)
	}
	if is_select && !edit_select_is_none(we_state.edit_state.v.select) {
		for i in we_state.edit_state.v.select.begin ..< we_state.edit_state.v.select.end {
			_draw_bar(
				app,
				we_state,
				draw_list,
				i32(i),
				imgui_tl,
				line_graph_size,
				bar_width_unsized,
				colors.WE_LINE_GRAPH.bar_hovered,
				colors.WE_LINE_GRAPH.line_hovered2,
				true,
			)
		}
	}
	SELECT_PIXEL_DT :: 10
	if imgui.IsItemHovered() {
		if is_draw {
			custom_cursor(app, .Draw, {20, 20}, {0, 0})
		}
		if we_state.edit_state.type == .SelectIdle {
			if imgui.IsKeyPressed(.LeftArrow) {
				if we_state.edit_state.v.select.begin > 0 {
					we_state.edit_state.v.select.begin -= 1
					we_state.edit_state.v.select.end -= 1
				}
			}
			if imgui.IsKeyPressed(.RightArrow) {
				if i32(we_state.edit_state.v.select.end) <= we_state.num_points - 1 {
					we_state.edit_state.v.select.begin += 1
					we_state.edit_state.v.select.end += 1
				}
			}
			select_v := &we_state.edit_state.v.select
			mouse_pos_x := lgp.mouse_pos.x - lgp.cursor_tl.x
			begin_pos_x := f32(select_v.begin) * bar_width_unsized * we_state.scale
			end_pos_x := f32(select_v.end) * bar_width_unsized * we_state.scale
			if mouse_pos_x >= begin_pos_x + SELECT_PIXEL_DT &&
			   mouse_pos_x <= end_pos_x - SELECT_PIXEL_DT {
				custom_cursor(app, .LeftRight, {20, 10}, {-10, 0})
			} else if math.abs(mouse_pos_x - begin_pos_x) <= SELECT_PIXEL_DT {
				custom_cursor(app, .Left, {10, 10}, {0, 0})
			} else if math.abs(mouse_pos_x - end_pos_x) <= SELECT_PIXEL_DT {
				custom_cursor(app, .Right, {10, 10}, {0, 0})
			}
		}
		if !imgui.IsKeyDown(.ImGuiMod_Ctrl) {
			if imgui.IsMouseDown(.Left) {
				#partial switch we_state.edit_state.type {
				case .DrawNone, .DrawLastX:
					if app.state.past_data == nil {
						app.state.past_data = make([dynamic]f32, int(we_state.num_points))
						mem.copy_non_overlapping(
							&app.state.past_data[0],
							&we_state.data[data_index(we_state.data_frame, 0)],
							int(we_state.num_points) * size_of(f32),
						)
						app.state.wedraw_idx_buf = make([dynamic]i32)
					}
					get_x := clamp(
						i32(image_mouse_pos.x / bar_width_unsized),
						0,
						we_state.num_points - 1,
					)
					y_ratio := (1 - clamp(lgp.mouse_pos.y / line_graph_size.y, 0, 1))
					y_m1_to_1 := 2 * y_ratio - 1
					sync.mutex_lock(&wp_mutex)
					we_state.data[data_index(we_state.data_frame, u32(get_x))] = y_m1_to_1
					undo_add_unique(&app.state.wedraw_idx_buf, get_x)
					if we_state.edit_state.type == .DrawLastX {
						lx := we_state.edit_state.v.draw
						last_y := we_state.data[data_index(we_state.data_frame, u32(lx))]
						if i32(lx) > get_x {
							for i in get_x + 1 ..< i32(lx) {
								undo_add_unique(&app.state.wedraw_idx_buf, i)
								t := (f32(lx) - f32(i)) / (f32(lx) - f32(get_x))
								we_state.data[data_index(we_state.data_frame, u32(i))] = math.lerp(
									last_y,
									y_m1_to_1,
									t,
								)
							}
						} else if i32(lx) < get_x {
							for i in i32(lx) + 1 ..< get_x {
								undo_add_unique(&app.state.wedraw_idx_buf, i)
								t := (f32(lx) - f32(i)) / (f32(lx) - f32(get_x))
								we_state.data[data_index(we_state.data_frame, u32(i))] = math.lerp(
									last_y,
									y_m1_to_1,
									t,
								)
							}
						}
					}
					sync.mutex_unlock(&wp_mutex)
					we_state.edit_state = {
						type = .DrawLastX,
						v = {draw = i32(get_x)},
					}
					harmonics_update_model(app, win_idx)
				case .SelectIdle:
					get_x := clamp(
						i16(image_mouse_pos.x / bar_width_unsized),
						0,
						i16(we_state.num_points - 1),
					)
					select_v := &we_state.edit_state.v.select
					if edit_select_is_none(select_v^) {
						select_v^ = {
							begin = get_x,
							end   = get_x + 1,
							dt    = get_x,
						}
						we_state.edit_state.type = .SelectInit
					} else {
						mouse_pos_x := lgp.mouse_pos.x - lgp.cursor_tl.x
						begin_pos_x := f32(select_v.begin) * bar_width_unsized * we_state.scale
						end_pos_x := f32(select_v.end) * bar_width_unsized * we_state.scale
						select_v.dt = get_x - select_v.begin
						if mouse_pos_x >= begin_pos_x + SELECT_PIXEL_DT &&
						   mouse_pos_x <= end_pos_x - SELECT_PIXEL_DT {
							we_state.edit_state.type = .SelectMove
							we_state.edit_state.v.select.dt =
								get_x - we_state.edit_state.v.select.begin
						} else if math.abs(mouse_pos_x - begin_pos_x) <= SELECT_PIXEL_DT {
							we_state.edit_state.type = .SelectLeft
						} else if math.abs(mouse_pos_x - end_pos_x) <= SELECT_PIXEL_DT {
							we_state.edit_state.type = .SelectRight
						} else {
							select_v^ = {
								begin = get_x,
								end   = get_x + 1,
								dt    = get_x,
							}
							we_state.edit_state.type = .SelectInit
						}
					}
				case .SelectInit:
					custom_cursor(app, .LeftRight, {20, 10}, {-10, 0})
					get_x := clamp(
						i16(image_mouse_pos.x / bar_width_unsized),
						0,
						i16(we_state.num_points - 1),
					)
					select_v := &we_state.edit_state.v.select
					select_v.begin = clamp(get_x, 0, select_v.dt)
					select_v.end = clamp(get_x + 1, select_v.dt + 1, i16(we_state.num_points))
				case .SelectMove:
					custom_cursor(app, .LeftRight, {20, 10}, {-10, 0})
					get_x := clamp(
						i16(image_mouse_pos.x / bar_width_unsized),
						0,
						i16(we_state.num_points - 1),
					)
					select_v := &we_state.edit_state.v.select
					new_begin := i32(get_x - select_v.dt)
					old_dt := i32(select_v.end - select_v.begin)
					new_end := i32(new_begin + old_dt)
					if i32(new_end) >= we_state.num_points {
						new_end = we_state.num_points
						new_begin = we_state.num_points - old_dt
					} else if new_begin < 0 {
						new_begin = 0
						new_end = old_dt
					}
					select_v.begin = i16(new_begin)
					select_v.end = i16(new_end)
				case .SelectLeft:
					custom_cursor(app, .Left, {10, 10}, {0, 0})
					get_x := clamp(
						i16(image_mouse_pos.x / bar_width_unsized),
						0,
						i16(we_state.num_points - 1),
					)
					we_state.edit_state.v.select.begin = min(
						get_x,
						we_state.edit_state.v.select.end - 1,
					)
				case .SelectRight:
					custom_cursor(app, .Right, {10, 10}, {0, 0})
					get_x := clamp(
						i16(image_mouse_pos.x / bar_width_unsized) + 1,
						0,
						i16(we_state.num_points - 1),
					)
					we_state.edit_state.v.select.end = max(
						get_x,
						we_state.edit_state.v.select.begin + 1,
					)
				}
			} else {
				#partial switch we_state.edit_state.type {
				case .DrawLastX:
					harmonics_update_model(app, win_idx)
					we_state.edit_state.type = .DrawNone
				case .SelectInit, .SelectMove, .SelectLeft, .SelectRight:
					we_state.edit_state.type = .SelectIdle //Reset select drag state
				}
				if app.state.past_data != nil {
					undo_redo_manager_undo_add_stop(&we_state.undo_redo)
					undo_redo_manager_undo_data_frame(
						&we_state.undo_redo,
						app,
						win_idx,
						we_state.data_frame,
					)
					for idx in app.state.wedraw_idx_buf {
						undo_redo_manager_undo_wedraw(
							&we_state.undo_redo,
							app,
							win_idx,
							idx,
							we_state.data_frame,
							app.state.past_data[idx],
						)
					}
					delete(app.state.wedraw_idx_buf)
					delete(app.state.past_data)
					app.state.wedraw_idx_buf = nil
					app.state.past_data = nil
				}
			}
		} else {
			if imgui.IsMouseClicked(.Left, false) {
				#partial switch we_state.edit_state.type {
				case .None, .DrawNone, .SelectIdle:
					get_x := clamp(
						i16(image_mouse_pos.x / bar_width_unsized),
						0,
						i16(we_state.num_points - 1),
					)
					mouse_c := imgui.GetMousePos()
					app.state.we_edit_v = WeEditValue {
						status  = .SExistsFocus,
						win_idx = i16(win_idx),
						idx     = get_x,
						x       = i16(mouse_c.x),
						y       = i16(mouse_c.y),
					}
					sample_f := we_state.data[data_index(we_state.data_frame, u32(get_x))]
					temp_str := fmt.tprintf("%.10f\x00", sample_f)
					delete(app.state.we_edit_s_buf)
					app.state.we_edit_s_buf = make([dynamic]u8)
					append(&app.state.we_edit_s_buf, temp_str)
				}
			}
		}
		#partial switch we_state.edit_state.type {
		case .None, .DrawNone, .DrawLastX, .SelectIdle:
			_draw_bar(
				app,
				we_state,
				draw_list,
				i32(image_mouse_pos.x / bar_width_unsized),
				imgui_tl,
				line_graph_size,
				bar_width_unsized,
				colors.WE_LINE_GRAPH.bar_hovered,
				colors.WE_LINE_GRAPH.line_hovered2,
				true,
			)
		}
		draw_y: f32
		if is_draw {
			y_ratio := (1 - clamp(lgp.mouse_pos.y / line_graph_size.y, 0, 1))
			y_m1_to_1 := 2 * y_ratio - 1
			draw_y = y_m1_to_1
			_draw_bar(
				app,
				we_state,
				draw_list,
				i32(image_mouse_pos.x / bar_width_unsized),
				imgui_tl,
				line_graph_size,
				bar_width_unsized,
				colors.WE_LINE_GRAPH.bar_hovered2,
				colors.WE_LINE_GRAPH.line_hovered2,
				false,
				y_m1_to_1,
			)
		}
		if io.MouseWheel < 0 {
			imgui.SetScrollX(imgui.GetScrollX() + bar_width_unsized * we_state.scale)
		} else if io.MouseWheel > 0 {
			imgui.SetScrollX(imgui.GetScrollX() - bar_width_unsized * we_state.scale)
		}
		if imgui.BeginTooltip() {
			get_x := clamp(i32(image_mouse_pos.x / bar_width_unsized), 0, we_state.num_points - 1)
			y_value := we_state.data[data_index(we_state.data_frame, u32(get_x))]
			imgui.Text("f(%u) = %.10f", get_x, y_value)
			#partial switch math.classify(y_value) {
			case .Inf, .Neg_Inf, .NaN:
				imgui.Text("Warning! Infinite or NaN Values detected")
			}
			if math.abs(y_value) > 1 {
				imgui.Text("Warning! Value must be clamped to [-1, 1]")
			}
			imgui.EndTooltip()
		}
		hover_window_text: cstring = ---
		#partial switch we_state.edit_state.type {
		case .None:
			hover_window_text = "D for draw mode, S for select mode\nCtrl + LMB to edit sample's value"
		case .DrawNone:
			hover_window_text = "Ctrl + LMB to edit sample's value"
		case .SelectIdle:
			hover_window_text = `Drag to select samples, Ctrl + C to copy, Ctrl + X to cut, Delete to remove
Ctrl + V to paste at left of selection, Ctrl + Shift + V to paste at mouse cursor position
Ctrl + A to select all, Ctrl + Shift + A to deselect all
Ctrl + LMB to edit a sample's value`
		case:
			hover_window_text = ""
		}
		imgui.DrawList_AddText(
			draw_list,
			imgui_tl + {imgui.GetScrollX(), 0},
			0xffffffff,
			hover_window_text,
		)
	}
	imgui.SetCursorScreenPos(
		imgui_tl + {0, lgp.total_size.y - style.ScrollbarSize - imgui.GetTextLineHeight()},
	)
	imgui.Text("Frame #%d, Total Frames: %d", we_state.data_frame, we_state.num_frames)
	if imgui.BeginMenuBar() {
		if imgui.BeginMenu("File") {
			defer imgui.EndMenu()
			if imgui.BeginMenu("New") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Empty") do preset_empty(app, win_idx)
				if imgui.MenuItem("Sine") do preset_sine(app, win_idx)
				if imgui.MenuItem("Square") do preset_square(app, win_idx)
				if imgui.MenuItem("Sawtooth") do preset_sawtooth(app, win_idx)
				if imgui.MenuItem("Triangle") do preset_triangle(app, win_idx)
				if imgui.MenuItem("Half-Sine") do preset_half_sine(app, win_idx)
			}
			if imgui.BeginMenu("Import As...") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Text") {
					create_import_export_window(base, app, win_idx, .Import)
				}
				if imgui.MenuItem(".wav file") {
					if !app.windows.file_explorer.is_active {
						file_explorer_load_idx = win_idx
						fe_h := file_explorer_new(app, .LoadToWindow)
						base.depends_on = fe_h
						refresh_dir_or_root(app)
					} else {
						tooltip_change(
							app,
							cstring("File Explorer window already in use"),
							.Error,
							app.state.frames + 3000 / u64(app.config.mspf),
						)
					}
				}
				if imgui.MenuItem("Directory") {
					if !app.windows.file_explorer.is_active {
						file_explorer_load_idx = win_idx
						fe_h := file_explorer_new(app, .LoadFromAudioFolder)
						base.depends_on = fe_h
						refresh_dir_or_root(app)
					} else {
						tooltip_change(
							app,
							cstring("File Explorer window already in use"),
							.Error,
							app.state.frames + 3000 / u64(app.config.mspf),
						)
					}
				}
			}
			if imgui.BeginMenu("Export As...") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Text") {
					if export_check_all_samples_valid(base, app, win_idx) {
						create_import_export_window(base, app, win_idx, .Export)
					} else {
						tooltip_change(
							app,
							cstring(
								"Unable to save: Frames contain samples that are not between [-1,1] or NaN values",
							),
							.Error,
							app.state.frames + 3000 / u64(app.config.mspf),
						)
					}
				}
				if imgui.MenuItem(".wav file") {
					if !app.windows.file_explorer.is_active {
						if export_check_all_samples_valid(base, app, win_idx) {
							file_explorer_load_idx = win_idx
							fe_h := file_explorer_new(app, .SaveToAudio)
							base.depends_on = fe_h
							refresh_dir_or_root(app)
						} else {
							tooltip_change(
								app,
								cstring(
									"Unable to save: Frames contain samples that are not between [-1,1] or NaN values",
								),
								.Error,
								app.state.frames + 3000 / u64(app.config.mspf),
							)
						}
					} else {
						tooltip_change(
							app,
							cstring("File Explorer window already in use"),
							.Error,
							app.state.frames + 3000 / u64(app.config.mspf),
						)
					}
				}
				if imgui.MenuItem("Directory") {
					if !app.windows.file_explorer.is_active {
						if export_check_all_samples_valid(base, app, win_idx) {
							file_explorer_load_idx = win_idx
							fe_h := file_explorer_new(app, .SaveToAudioFolder)
							base.depends_on = fe_h
							refresh_dir_or_root(app)
						} else {
							tooltip_change(
								app,
								cstring(
									"Unable to save: Frames contain samples that are not between [-1,1] or NaN values",
								),
								.Error,
								app.state.frames + 3000 / u64(app.config.mspf),
							)
						}
					} else {
						tooltip_change(
							app,
							cstring("File Explorer window already in use"),
							.Error,
							app.state.frames + 3000 / u64(app.config.mspf),
						)
					}
				}
			}
		}
		if imgui.BeginMenu("Edit") {
			defer imgui.EndMenu()
			_we_keybinds(base, app, we_state, win_idx, i32(image_mouse_pos.x / bar_width_unsized))
			if imgui.MenuItem(
				"Undo",
				"Ctrl+Z",
				enabled = queue.len(we_state.undo_redo.undo_dequeue) != 0,
			) {
				undo_redo_manager_do_undo(&we_state.undo_redo, app)
				harmonics_update_model(app, win_idx)
			}
			if imgui.MenuItem(
				"Redo",
				"Ctrl+Shift+Z",
				enabled = queue.len(we_state.undo_redo.redo_dequeue) != 0,
			) {
				undo_redo_manager_do_redo(&we_state.undo_redo, app)
				harmonics_update_model(app, win_idx)
			}
			imgui.Separator()
			if imgui.MenuItem("Draw", "D", is_draw) {
				#partial switch we_state.edit_state.type {
				case .None, .SelectIdle:
					we_state.edit_state = {
						type = .DrawNone,
					}
				case:
					we_state.edit_state = {
						type = .None,
					}
				}
			}
			if imgui.MenuItem("Select", "S", is_select) {
				#partial switch we_state.edit_state.type {
				case .None, .DrawNone:
					we_state.edit_state = {
						type = .SelectIdle,
						v = {select = EditSelectNone},
					}
				case:
					we_state.edit_state = {
						type = .None,
					}
				}
			}
			if imgui.MenuItem("Play Waveform", "Ctrl+Space", we_state.play) {
				sync.mutex_lock(&wp_mutex)
				we_state.play = !we_state.play
				reset_phases(app)
				sync.mutex_unlock(&wp_mutex)
			}
			if imgui.MenuItem("Harmonics", "Ctrl+H", app.windows.harmonics[win_idx].is_active) {
				harmonics_window_new(base, app, win_idx)
			}
			if imgui.MenuItem("Lua", "Ctrl+L", app.windows.lua[win_idx].is_active) {
				lua_window_new(base, app, win_idx)
			}
			sync.mutex_lock(&wp_mutex)
			last_num_points := we_state.num_points //To make undo_redo_manager get the value of unedited and not first edit.
			@(static) last_num_points_undo: i32 = 0
			if imgui.SliderInt(
				"Number of samples",
				&last_num_points,
				1,
				MAX_WAVEFORM_EDITOR_POINTS,
				flags = {.ClampOnInput},
			) {
				reset_phases(app)
				if undo_redo_manager_undo_has_no_stop(&we_state.undo_redo) {
					last_num_points_undo = we_state.num_points
					undo_redo_manager_undo_add_stop(&we_state.undo_redo)
				}
			}
			we_state.num_points = last_num_points
			sync.mutex_unlock(&wp_mutex)
			if imgui.IsItemHovered() do imgui.SetTooltip("[1, 2048]\nCtrl+LMB to manually input")
			if imgui.IsItemDeactivatedAfterEdit() {
				sync.mutex_guard(&wp_mutex)
				reset_phases(app)
				harmonics_update_model(app, win_idx)
				undo_redo_manager_undo_wenumpoints(
					&we_state.undo_redo,
					app,
					win_idx,
					last_num_points_undo,
				)
			}
			last_num_frames := we_state.num_frames //To make undo_redo_manager get the value of unedited and not first edit.
			@(static) last_num_frames_undo: i32 = 1
			if imgui.SliderInt(
				"Number of frames",
				&last_num_frames,
				1,
				MAX_WAVEFORM_FRAMES,
				flags = {.ClampOnInput},
			) {
				if undo_redo_manager_undo_has_no_stop(&we_state.undo_redo) {
					last_num_frames_undo = we_state.num_frames
					undo_redo_manager_undo_add_stop(&we_state.undo_redo)
				}
			}
			if imgui.IsItemHovered() {
				imgui.SetTooltip("[1, 256]\nCtrl+LMB to manually input\n")
			}
			we_state.num_frames = last_num_frames
			if imgui.IsItemDeactivatedAfterEdit() {
				undo_redo_manager_undo_add_stop(&we_state.undo_redo)
				if we_state.data_frame >= we_state.num_frames {
					for f in we_state.num_frames ..= we_state.data_frame {
						undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, f)
						for i in 0 ..< we_state.num_points {
							undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, f)
						}
					}
					we_state.data_frame = we_state.num_frames - 1
				}
				undo_redo_manager_undo_setmaxframes(
					&we_state.undo_redo,
					app,
					win_idx,
					last_num_frames_undo,
				)
				set_frames(app, win_idx, we_state.num_frames)
			}
			if imgui.SliderInt(
				"Frame Number",
				&we_state.data_frame,
				0,
				we_state.num_frames - 1,
				flags = {.ClampOnInput},
			) {
				harmonics_update_model(app, win_idx)
			}
			if imgui.IsItemHovered() {
				imgui.BeginTooltip()
				imgui.Text("[0, (Number of frames) - 1]\nCtrl+LMB to manually input\n")
				imgui.TextColored({0.5, 0.5, 0.5, 1}, "Up")
				imgui.SameLine()
				imgui.Text("Increase Frame")
				imgui.TextColored({0.5, 0.5, 0.5, 1}, "Down")
				imgui.SameLine()
				imgui.Text("Decrease Frame")
				imgui.EndTooltip()
			}
			sync.mutex_lock(&wp_mutex)
			if imgui.SliderFloat(
				"Frequency",
				&app.state.wp.frequency,
				1,
				15000,
				"%.3f Hz",
				{.Logarithmic, .ClampOnInput},
			) {
				mem.zero(&we_state.key_buf[0], len(we_state.key_buf))
				harmonics_update_model(app, win_idx)
			}
			sync.mutex_unlock(&wp_mutex)
			if imgui.IsItemHovered() {
				imgui.BeginTooltip()
				imgui.Text("[1, 15000] Hz\nCtrl+LMB to manually input\n")
				imgui.TextColored({0.5, 0.5, 0.5, 1}, "Ctrl+[")
				imgui.SameLine()
				imgui.Text("(Increase 1 semitone)")
				imgui.TextColored({0.5, 0.5, 0.5, 1}, "Ctrl+]")
				imgui.SameLine()
				imgui.Text("(Decrease 1 semitone)")
				imgui.EndTooltip()
			}

			if imgui.InputText(
				"Octave Key",
				cstring(&we_state.key_buf[0]),
				len(we_state.key_buf),
				{.EnterReturnsTrue},
			) {
				OCState :: enum {
					Key,
					Octave,
					Ok,
					Error,
				}
				oc_state := OCState.Key
				rel_semitones: i16 = 9 //As A relative to C
				octavekey_read: for i in 0 ..< len(we_state.key_buf) {
					#partial switch oc_state {
					case .Key:
						switch we_state.key_buf[i] {
						case 'a', 'A':
							oc_state = .Octave
						case 'b', 'B':
							rel_semitones = 11
							oc_state = .Octave
						case 'c', 'C':
							rel_semitones = 0
							oc_state = .Octave
						case 'd', 'D':
							rel_semitones = 2
							oc_state = .Octave
						case 'e', 'E':
							rel_semitones = 4
							oc_state = .Octave
						case 'f', 'F':
							rel_semitones = 5
							oc_state = .Octave
						case 'g', 'G':
							rel_semitones = 7
							oc_state = .Octave
						case:
							break octavekey_read
						}
					case .Octave:
						switch we_state.key_buf[i] {
						case '+', '#':
							rel_semitones += 1
						case '-', 'b':
							rel_semitones -= 1
						case '0' ..= '9':
							octave := we_state.key_buf[i] - '0'
							rel_semitones += i16(octave * 12)
							oc_state = .Ok
						}
					case .Ok:
						if we_state.key_buf[i] != 0 {
							oc_state = .Error
							break octavekey_read
						} else do break octavekey_read
					}
					if we_state.key_buf[i] == 0 do break
				}
				if oc_state == .Ok {
					rel_semitones -= HERTZ_SEMITONES
					sync.mutex_lock(&wp_mutex)
					app.state.wp.frequency = frequency_relative_a4(i16(rel_semitones))
					sync.mutex_unlock(&wp_mutex)
				} else {
					tooltip_change(
						app,
						cstring(
							"Invalid String\nMust be the format (Key)(Accidental?)(Octave)\nAccidentals should be +/#/-/b\nOctave from 0 to 9",
						),
						.Error,
						app.state.frames + 3000 / u64(app.config.mspf),
					)
				}
				harmonics_update_model(app, win_idx)
			}
			if imgui.IsItemHovered() do imgui.SetTooltip("Change Frequency as a music key\nwith octave number from 0 to 9\nUse b/- for flats, and #/+ for sharps\nExamples: Ab3, F++5")

			set_amplitude_buffer(app, we_state)

			sync.mutex_lock(&wp_mutex)
			imgui.SliderFloat(
				"Master Gain",
				&app.state.wp.amplitude,
				0,
				1,
				cstring(&we_state.amp_buf[0]),
				{.ClampOnInput},
			)
			if imgui.IsItemHovered() {
				imgui.BeginTooltip()
				imgui.Text("[0, 1], where dBFS(v) = 20*log_10(v)\nCtrl+LMB to manually input")
				imgui.TextColored({0.5, 0.5, 0.5, 1}, "Ctrl+=")
				imgui.SameLine()
				imgui.Text("(Increase)")
				imgui.SameLine()
				imgui.TextColored({0.5, 0.5, 0.5, 1}, "Ctrl+-")
				imgui.SameLine()
				imgui.Text("(Decrease)")
				imgui.EndTooltip()
			}
			if imgui.IsItemDeactivatedAfterEdit() {
				harmonics_update_model(app, win_idx)
			}
			sync.mutex_unlock(&wp_mutex)
		}
		if imgui.BeginMenu("View") {
			imgui.Text("Read values as...")
			if imgui.Combo(
				"##Read Values as",
				cast(^i32)&we_state.read_range,
				_WAVEFORM_RANGE_CSTR,
			) {
				imgui.CloseCurrentPopup()
			}
			imgui.Separator()
			help_marker(
				"Interpolates values between sample points using the following\nNone: Interpolate using the leftmost point only\nLinear: Interpolation between the last and next point\nCubic Hermite: Interpolation using 4 points (f(x_m1), f(x0), f(x1), f(x2))\nto calculate between x0 and x1",
			)
			imgui.Text("Audio Interpolation")
			imgui.Combo("##Interpolation", cast(^i32)&we_state.interp_v, _INTERPOLATION_TYPE_CSTR)
			imgui.EndMenu()
		}
		if imgui.BeginMenu("Effects") {
			defer imgui.EndMenu()
			_we_keybinds(base, app, we_state, win_idx, i32(image_mouse_pos.x / bar_width_unsized))
			if imgui.MenuItem("Reapply Last Effect", "Ctrl+Shift+E") {
				we_state.last_effect_vf(app, win_idx)
			}
			help_marker("Sets each sample in each frame that has NaN values to 0")
			if imgui.MenuItem("NaN to 0") {
				effect_nan_to_0_full(app, win_idx)
			}
			help_marker("Multiply the samples proportionally by a factor of [0,inf]")
			if imgui.BeginMenu("Gain") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_gain(app, win_idx)
					we_state.last_effect_vf = effect_gain
				}
				imgui.DragFloat(
					"##HCThreshold",
					&we_state.gain_v,
					1,
					effect_gain_clamp.min,
					effect_gain_clamp.max,
					flags = {.ClampOnInput},
				)
				we_state.gain_v = max(we_state.gain_v, 0)
			}

			help_marker(
				"Scales the samples proportionally where\nthe max/min samples further from 0 scale to either -N or N\nValues must cross 0 for this effect to work",
			)
			if imgui.BeginMenu("Normalization") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_normalization(app, win_idx)
					we_state.last_effect_vf = effect_normalization
				}
				imgui.SliderFloat(
					"##NormalizationThreshold",
					&we_state.normal_v,
					effect_normalization_clamp.min,
					effect_normalization_clamp.max,
					flags = {.ClampOnInput},
				)
			}

			help_marker(
				"Change the horizontal position of the waveform by N samples.\nNegative N moves left and positive N moves right.",
			)
			if imgui.BeginMenu("Phase Shift") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_change_phase(app, win_idx)
					we_state.last_effect_vf = effect_change_phase
				}
				cl := effect_change_phase_clamp(we_state)
				imgui.SliderInt("N", &we_state.ch_phase_v, cl.min, cl.max, flags = {.ClampOnInput})
			}

			help_marker(
				"Adds previous samples of the waveform with factor M of time N samples to itself\nFormula: For input x[n] and output y[n]\ny[n] = x[n] + M * x_or_y[n-N]",
			)
			if imgui.BeginMenu("Comb Filter") {
				defer imgui.EndMenu()
				help_marker("For input x[n] and output y[n]\ny[n] = x[n] + M * x[n-N]")
				if imgui.MenuItem("Apply Feed-Forward") {
					effect_comb_filter_feed_forward(app, win_idx)
					we_state.last_effect_vf = effect_comb_filter_feed_forward
				}
				imgui.SliderFloat(
					"M",
					&we_state.comb_m_v,
					effect_comb_fff_clamp_m.min,
					effect_comb_fff_clamp_m.max,
					flags = {.ClampOnInput},
				)
				imgui.SliderInt(
					"N",
					&we_state.comb_n_v,
					effect_comb_fff_clamp_n.min,
					effect_comb_fff_clamp_n.max,
					flags = {.ClampOnInput},
				)
			}

			help_marker("Sets all samples as positive to negative and vice versa")
			if imgui.MenuItem("Inversion") {
				effect_inversion(app, win_idx)
				we_state.last_effect_vf = effect_inversion
			}

			help_marker("All samples reach their maximum, excluding 0")
			if imgui.MenuItem("Fuzz") {
				effect_fuzz(app, win_idx)
				we_state.last_effect_vf = effect_fuzz
			}

			help_marker(
				"Flattens samples by a threshold value of 0 to 1 above\nsuch that the all values can only reach the threshold as the max",
			)
			if imgui.BeginMenu("Hard Clip") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_hard_clip(app, win_idx)
					we_state.last_effect_vf = effect_hard_clip
				}
				imgui.SliderFloat(
					"##HCThreshold",
					&we_state.hard_clip_v,
					effect_hard_clip_clamp.min,
					effect_hard_clip_clamp.max,
					flags = {.ClampOnInput},
				)
			}

			help_marker(
				"Smoothes the samples when approaching maximum boundaries.\nHigher values approach -1 or 1 quicker.",
			)
			if imgui.BeginMenu("Soft Clip") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_soft_clip(app, win_idx)
					we_state.last_effect_vf = effect_soft_clip
				}
				imgui.DragFloat(
					"##SCThreshold",
					&we_state.soft_clip_v,
					1,
					effect_soft_clip_clamp.min,
					effect_soft_clip_clamp.max,
					flags = {.ClampOnInput},
				)
			}

			help_marker(
				"Sets all samples to limited sets of values\n(1-bit has 1 set of values for min/max,\n2-bit has 2 sets of values for min/max, etc.)",
			)
			if imgui.BeginMenu("Bitcrusher") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_bit_crusher(app, win_idx)
					we_state.last_effect_vf = effect_bit_crusher
				}
				imgui.Combo("##Set Bits", cast(^i32)&we_state.bitcrush_v, _WAVEFORM_BITCRUSH_CSTR)
			}

			help_marker(
				"Uses the formula (-1)^n * (A*x - 2*n)\nx = input sample and n = round(A*x/2).\nThe result lets the values \"fold back in itself\" between -1 and 1",
			)
			if imgui.BeginMenu("Triangle Folding") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_triangle_folding(app, win_idx)
					we_state.last_effect_vf = effect_triangle_folding
				}
				imgui.DragFloat(
					"A##WaveFolding",
					&we_state.wavefold_v,
					1,
					effect_triangle_folding_clamp.min,
					effect_triangle_folding_clamp.max,
					flags = {.ClampOnInput},
				)
			}

			help_marker(
				"For the input sample x, uses the formula\nT_n(x) = 2*x*T_{n-1}(x) - T_{n-2}(x)\nWhere T_0(x) = 1\nT_1(x) = x.\nDecimal values interpolate between polynomials",
			)
			if imgui.BeginMenu("Chebyshev Polynomial") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_chebyshev_folding(app, win_idx)
					we_state.last_effect_vf = effect_chebyshev_folding
				}
				clamp := effect_chebyshev_folding_clamp(we_state.num_points)
				imgui.DragFloat(
					"n##WaveFolding",
					&we_state.cheb_n_v,
					1,
					clamp.min,
					clamp.max,
					flags = {.ClampOnInput},
				)
			}

			help_marker(
				"Edits the samples by changing the cycle of the current waveform\nto repeat (N + 1) times by gathering the average of N + 1 points",
			)
			if imgui.BeginMenu("As N Overtone") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_n_overtone(app, win_idx)
					we_state.last_effect_vf = effect_n_overtone
				}
				imgui.SliderInt(
					"##AsNOvertone",
					&we_state.overtone_v,
					effect_n_overtone_clamp.min,
					effect_n_overtone_clamp.max,
					flags = {.ClampOnInput},
				)
				if imgui.IsItemHovered() {
					imgui.SetTooltip(
						"%d%s Overtone or %d%s Harmonic",
						we_state.overtone_v,
						cstr_th_num(we_state.overtone_v),
						we_state.overtone_v + 1,
						cstr_th_num(we_state.overtone_v + 1),
					)
				}
			}

			help_marker(
				"Change the number of samples of the current waveform to N samples\nInterpolates values between samples based on None, Linear, and Cubic Hermite interpolation\nNote: This will resample all frames and not just a specific frame",
			)
			if imgui.BeginMenu("Resampling") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_resampling(app, win_idx)
					we_state.last_effect_vf = effect_resampling
				}
				help_marker(
					"Interpolates values between sample points using the following\nNone: Interpolate using the leftmost point only\nLinear: Interpolation between the last and next point\nCubic Hermite: Interpolation using 4 points (f(x_m1), f(x0), f(x1), f(x2))\nto calculate between x0 and x1",
				)
				imgui.Text("Interpolation Type")
				imgui.Combo(
					"##Interpolation",
					cast(^i32)&we_state.n_samp_interp_v,
					_INTERPOLATION_TYPE_CSTR,
				)
				imgui.SliderInt(
					"N samples",
					&we_state.n_samp_v,
					effect_resampling_clamp.min,
					effect_resampling_clamp.max,
					flags = {.ClampOnInput},
				)
			}

			help_marker("Moves all samples vertically based on a threshold M from -1 to 1.")
			if imgui.BeginMenu("Vertical Offset") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_offset(app, win_idx)
					we_state.last_effect_vf = effect_offset
				}
				imgui.SliderFloat(
					"M",
					&we_state.offset_v,
					effect_offset_clamp.min,
					effect_offset_clamp.max,
					flags = {.ClampOnInput},
				)
			}
		}
		if imgui.BeginMenu("Help") {
			defer imgui.EndMenu()
			imgui.Text(`The waveform editor is used to draw or
process waveforms from other files such as .wav files or image files
that include oscilloscopes of an audio waveform.

Other sub windows can be used such as the Harmonics window
to edit the harmonics of a waveform and the Lua window
to edit the waveforms using Lua scripting

You can also import and export waveforms as a single .wav file combined
with all the frames, or multiple .wav files per frame in a Directory
You can also import as text as integer values. This option is created
for FamiTracker's and FamiStudio's N163 and FDS wavetable/waveform creation.

Note: To export, all sample values must be between -1 or 1 per frame and not NaN. To fix this, use
the Effects such as Hard Clip at 1.0, Normalization at 1.0, or Triangle Wavefold at 1.0
Use NaN to 0 for any NaN values`)
		}
		imgui.EndMenuBar()
	}
}

f_waveform_editor_destroy :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	app.state.we_edit_v.status = .None
	we_state := &app.state.we[win_idx]
	waveform_editor_destroy(we_state)
	we_state.is_active = false
	handle_map.remove(&app.imgui_hm, base.handle)
	strings.builder_destroy(&app.windows.waveform_editors[win_idx].id.(strings.Builder))
	harmonics_window := &app.windows.harmonics[win_idx]
	if harmonics_window.is_active {
		queue.push_back(
			&app.state.events_f,
			EventCall {
				window = harmonics_window,
				event_f = harmonics_window._destroy,
				win_idx = win_idx,
			},
		)
	}
	lua_window := &app.windows.lua[win_idx]
	if lua_window.is_active {
		queue.push_back(
			&app.state.events_f,
			EventCall{window = lua_window, event_f = lua_window._destroy, win_idx = win_idx},
		)
	}
}
export_check_all_samples_valid :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int) -> bool {
	we_state := &app.state.we[win_idx]
	for f in 0 ..< we_state.num_frames {
		for i in 0 ..< we_state.num_points {
			data_f := we_state.data[data_index(f, u32(i))]
			class_f := math.classify(data_f)
			#partial switch class_f {
			case .Inf, .Neg_Inf, .NaN:
				return false
			}
			if math.abs(data_f) > 1 {
				return false
			}
		}
	}
	return true
}

reset_phases :: proc(app: ^App) {
	for &we_state in app.state.we {
		we_state.phase = 0
	}
}

_we_keybinds :: proc(
	base: ^ImGuiWindow,
	app: ^App,
	we_state: ^WaveformEditorState,
	win_idx: int,
	get_x: i32,
) {
	if base.disabled do return
	if imgui.IsKeyPressed(.UpArrow) {
		we_state.data_frame = min(we_state.data_frame + 1, we_state.num_frames - 1)
		harmonics_update_model(app, win_idx)
	}
	if imgui.IsKeyPressed(.DownArrow) {
		we_state.data_frame = max(we_state.data_frame - 1, 0)
		harmonics_update_model(app, win_idx)
	}
	#partial switch we_state.edit_state.type {
	case .DrawLastX, .SelectInit, .SelectMove, .SelectLeft, .SelectRight:
		return
	}
	if imgui.IsKeyPressed(.D, false) {
		#partial switch we_state.edit_state.type {
		case .None, .SelectIdle:
			we_state.edit_state = {
				type = .DrawNone,
			}
		case:
			we_state.edit_state = {
				type = .None,
			}
		}
		is_drawing := we_state.edit_state.type == .DrawNone
		sb := strings.builder_make()
		strings.write_string(&sb, "Draw Mode: ")
		strings.write_string(&sb, "Enabled" if is_drawing else "Disabled")
		strings.write_byte(&sb, 0)
		tooltip_change(app, sb, .Info, app.state.frames + 2000 / u64(app.config.mspf))
	}
	if imgui.IsKeyPressed(.S, false) {
		#partial switch we_state.edit_state.type {
		case .None, .DrawNone:
			we_state.edit_state = {
				type = .SelectIdle,
				v = {select = EditSelectNone},
			}
		case:
			we_state.edit_state = {
				type = .None,
			}
		}
		is_selecting := we_state.edit_state.type == .SelectIdle
		sb := strings.builder_make()
		strings.write_string(&sb, "Select Mode: ")
		strings.write_string(&sb, "Enabled" if is_selecting else "Disabled")
		strings.write_byte(&sb, 0)
		tooltip_change(app, sb, .Info, app.state.frames + 2000 / u64(app.config.mspf))
	}
	if we_state.edit_state.type == .SelectIdle {
		select_v := &we_state.edit_state.v.select
		if imgui.IsKeyPressed(.Delete, false) {
			if !edit_select_is_none(select_v^) {
				undo_redo_manager_undo_add_stop(&we_state.undo_redo)
				undo_redo_manager_undo_data_frame(
					&we_state.undo_redo,
					app,
					win_idx,
					we_state.data_frame,
				)
				for i in select_v.begin ..< select_v.end {
					undo_redo_manager_undo_wedraw(
						&we_state.undo_redo,
						app,
						win_idx,
						i32(i),
						we_state.data_frame,
					)
					we_state.data[data_index(we_state.data_frame, u32(i))] = 0
				}
			}
		}
	}
	ctrl_down := imgui.IsKeyDown(.ImGuiMod_Ctrl)
	if ctrl_down {
		zb := imgui.GetKeyData(.Z)
		if zb.Down && zb.DownDuration == 0 {
			if imgui.IsKeyDown(.ImGuiMod_Shift) {
				undo_redo_manager_do_redo(&we_state.undo_redo, app)
				harmonics_update_model(app, win_idx)
			} else {
				undo_redo_manager_do_undo(&we_state.undo_redo, app)
				harmonics_update_model(app, win_idx)
			}
		}
		if imgui.IsKeyDown(.ImGuiMod_Ctrl) && imgui.IsKeyPressed(.E, false) {
			we_state.last_effect_vf(app, win_idx)
		}
		if imgui.IsKeyPressed(.H, false) {
			harmonics_window_new(base, app, win_idx)
		}
		if imgui.IsKeyPressed(.L, false) {
			lua_window_new(base, app, win_idx)
		}
		if imgui.IsKeyPressed(.Space, false) {
			sync.mutex_guard(&wp_mutex)
			we_state.play = !we_state.play
			reset_phases(app)
			sb := strings.builder_make()
			strings.write_string(&sb, "Playing Waveform: ")
			strings.write_string(&sb, "Activated" if we_state.play else "Deactivated")
			strings.write_byte(&sb, 0)
			tooltip_change(app, sb, .Info, app.state.frames + 2000 / u64(app.config.mspf))
		}
		select_v := &we_state.edit_state.v.select
		if we_state.edit_state.type == .SelectIdle {
			if imgui.IsKeyPressed(.C, false) {
				clear(&app.state.sample_copy_buf)
				new_len := int(select_v.end - select_v.begin)
				resize(&app.state.sample_copy_buf, new_len)
				mem.copy_non_overlapping(
					&app.state.sample_copy_buf[0],
					&we_state.data[data_index(we_state.data_frame, u32(select_v.begin))],
					new_len * size_of(f32),
				)
			}
			if imgui.IsKeyPressed(.X, false) {
				clear(&app.state.sample_copy_buf)
				new_len := int(select_v.end - select_v.begin)
				resize(&app.state.sample_copy_buf, new_len)
				mem.copy_non_overlapping(
					&app.state.sample_copy_buf[0],
					&we_state.data[data_index(we_state.data_frame, u32(select_v.begin))],
					new_len * size_of(f32),
				)
				undo_redo_manager_undo_add_stop(&we_state.undo_redo)
				undo_redo_manager_undo_data_frame(
					&we_state.undo_redo,
					app,
					win_idx,
					we_state.data_frame,
				)
				for i in select_v.begin ..< select_v.end {
					undo_redo_manager_undo_wedraw(
						&we_state.undo_redo,
						app,
						win_idx,
						i32(i),
						we_state.data_frame,
					)
					we_state.data[data_index(we_state.data_frame, u32(i))] = 0
				}
			}
			if imgui.IsKeyDown(.ImGuiMod_Shift) {
				if imgui.IsKeyPressed(.A, false) {
					we_state.edit_state.v.select = EditSelectNone
				}
				if !edit_select_is_none(we_state.edit_state.v.select) {
					if imgui.IsKeyPressed(.V, false) {
						undo_redo_manager_undo_add_stop(&we_state.undo_redo)
						undo_redo_manager_undo_data_frame(
							&we_state.undo_redo,
							app,
							win_idx,
							we_state.data_frame,
						)
						select_v.begin = i16(get_x)
						select_v.end = select_v.begin
						for we_i in 0 ..< len(app.state.sample_copy_buf) {
							copy_i := we_i + int(get_x)
							select_v.end += 1
							if copy_i >= int(we_state.num_points) do break
							undo_redo_manager_undo_wedraw(
								&we_state.undo_redo,
								app,
								win_idx,
								i32(copy_i),
								we_state.data_frame,
							)
							we_state.data[data_index(we_state.data_frame, u32(copy_i))] =
								app.state.sample_copy_buf[we_i]
						}
					}
				}
			} else {
				if imgui.IsKeyPressed(.A, false) {
					select_v.begin = 0
					select_v.end = i16(we_state.num_points)
				}
				if !edit_select_is_none(we_state.edit_state.v.select) {
					if imgui.IsKeyPressed(.V, false) {
						undo_redo_manager_undo_add_stop(&we_state.undo_redo)
						undo_redo_manager_undo_data_frame(
							&we_state.undo_redo,
							app,
							win_idx,
							we_state.data_frame,
						)
						select_v.end = select_v.begin
						for we_i in 0 ..< len(app.state.sample_copy_buf) {
							copy_i := we_i + int(select_v.begin)
							select_v.end += 1
							if copy_i >= int(we_state.num_points) do break
							undo_redo_manager_undo_wedraw(
								&we_state.undo_redo,
								app,
								win_idx,
								i32(copy_i),
								we_state.data_frame,
							)
							we_state.data[data_index(we_state.data_frame, u32(copy_i))] =
								app.state.sample_copy_buf[we_i]
						}
					}
				}
			}
		}
		changed := false
		if imgui.IsKeyPressed(.Equal) {
			sync.mutex_guard(&wp_mutex)
			app.state.wp.amplitude += 0.0125
			app.state.wp.amplitude = min(app.state.wp.amplitude, 1)
			changed = true
		}
		if imgui.IsKeyPressed(.Minus) {
			sync.mutex_guard(&wp_mutex)
			app.state.wp.amplitude -= 0.0125
			app.state.wp.amplitude = max(app.state.wp.amplitude, 0)
			changed = true
		}
		if changed {
			sb := strings.builder_make()
			set_amplitude_buffer(app, we_state)
			strings.write_string(&sb, "Master Gain:\n")
			strings.write_string(&sb, string(cstring(&we_state.amp_buf[0])))
			strings.write_byte(&sb, 0)
			tooltip_change(app, sb, .Info, app.state.frames + 3000 / u64(app.config.mspf))
		}
		changed = false
		if imgui.IsKeyPressed(.LeftBracket) {
			sync.mutex_guard(&wp_mutex)
			app.state.wp.frequency = adjust_frequency_key_step(app.state.wp.frequency, .Down)
			app.state.wp.frequency = clamp(app.state.wp.frequency, 1, 15000)
			changed = true
		}
		if imgui.IsKeyPressed(.RightBracket) {
			sync.mutex_guard(&wp_mutex)
			app.state.wp.frequency = adjust_frequency_key_step(app.state.wp.frequency, .Up)
			app.state.wp.frequency = clamp(app.state.wp.frequency, 1, 15000)
			changed = true
		}
		if changed {
			sb := strings.builder_make()
			strings.write_string(&sb, "Frequency:\n")
			fmt.sbprintf(&sb, "%.5f Hz", app.state.wp.frequency)
			sr_a4 := semitone_relative_a4(app.state.wp.frequency)
			fmt.sbprintf(
				&sb,
				"\n(~%.0f semitones %s A4)",
				math.abs(sr_a4),
				"above" if sr_a4 >= 0 else "below",
			)
			strings.write_byte(&sb, 0)
			tooltip_change(app, sb, .Info, app.state.frames + 2000 / u64(app.config.mspf))
		}
	}
}

import_min: i32 = 0
import_max: i32 = 63
import_samples: i32 = 64
import_sep: [dynamic]u8
_parse_to_data :: proc(
	app: ^App,
	we_state: ^WaveformEditorState,
	win_idx, begin_i, i: int,
	num_i: ^int,
) {
	if num_i^ == int(we_state.num_points) {
		if we_state.data_frame == MAX_WAVEFORM_FRAMES - 1 {
			return
		}
		undo_redo_manager_undo_setmaxframes(
			&we_state.undo_redo,
			app,
			win_idx,
			we_state.num_frames + 1,
		)
		set_frames(app, win_idx, we_state.num_frames + 1)
		we_state.num_frames += 1
		we_state.data_frame += 1
		num_i^ = 0
	}
	num, ok := strconv.parse_int(string(app.state.import_buf[begin_i:i]))
	assert(ok)
	num = clamp(num, int(import_min), int(import_max))
	num_float := new_range_f32(f32(num), {f32(import_min), f32(import_max)}, {-1, 1})
	undo_redo_manager_undo_wedraw(
		&we_state.undo_redo,
		app,
		win_idx,
		i32(num_i^),
		we_state.data_frame,
	)
	we_state.data[data_index(we_state.data_frame, u32(num_i^))] = num_float
	num_i^ += 1
}
create_import_export_window :: proc(
	we_base: ^ImGuiWindow,
	app: ^App,
	win_idx: int,
	ie_text: ImportExportText,
) {
	we_state := &app.state.we[win_idx]
	if !app.windows.import_text.is_active {
		we_state.ie_text = ie_text
		title: cstring = "Import Text" if ie_text == .Import else "Export Text"
		app.windows.import_text = imgui_window_new(
			title,
			win_idx,
			{{we_base.size.x.s / 4, 0}, {we_base.position.y.s + we_base.size.y.s / 4, 0}},
			{{0, 600}, {0, 220}},
			{.NoCollapse},
			container_f = f_import_export_text,
			destroy_f = f_remove_handle,
		)
		h := handle_map.add(&app.imgui_hm, ImGuiWindowHandle{window = &app.windows.import_text})
		app.windows.import_text.handle = h
		we_base.depends_on = h
	} else {
		tooltip_change(
			app,
			cstring("Window already in use by a different window"),
			.Error,
			app.state.frames + 3000 / u64(app.config.mspf),
		)
	}
}
f_import_export_text :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	we_state := &app.state.we[win_idx]
	ie_text := we_state.ie_text
	style := imgui.GetStyle()
	text_flags: imgui.InputTextFlags =
		{.WordWrap, .CallbackResize} if ie_text == .Import else {.WordWrap, .ReadOnly}
	button_cstr: cstring = "Parse Import Text" if ie_text == .Import else "Get Export Text"
	if imgui.Button(
		button_cstr,
		{imgui.GetWindowSize().x - style.WindowPadding.x - style.ItemSpacing.x, 0},
	) {
		if ie_text == .Import {
			undo_redo_manager_undo_add_stop(&we_state.undo_redo)
			undo_redo_manager_undo_wenumpoints(
				&we_state.undo_redo,
				app,
				win_idx,
				we_state.num_points,
			)
			sync.mutex_lock(&wp_mutex)
			we_state.num_points = import_samples
			sync.mutex_unlock(&wp_mutex)
			undo_redo_manager_undo_setmaxframes(&we_state.undo_redo, app, win_idx, 1)
			set_frames(app, win_idx, 1)
			we_state.num_frames = 1
			NumState :: enum {
				None,
				Negative,
				Number,
			}
			num_state: NumState = .None
			i := 0
			begin_i, num_i: int
			for app.state.import_buf[i] != 0 {
				this_ch := app.state.import_buf[i]
				switch num_state {
				case .None:
					switch this_ch {
					case '0' ..= '9':
						num_state = .Number
						begin_i = i
					case '-':
						num_state = .Negative
						begin_i = i
					}
				case .Negative:
					switch this_ch {
					case '0' ..= '9':
						num_state = .Number
					case '-':
						begin_i = i
					case:
						num_state = .None
					}
				case .Number:
					switch this_ch {
					case '0' ..= '9':
					case:
						_parse_to_data(app, we_state, win_idx, begin_i, i, &num_i)
						num_state = .None
					}
				}
				i += 1
			}
			if num_state == .Number {
				_parse_to_data(app, we_state, win_idx, begin_i, i, &num_i)
			}
			sync.mutex_guard(&wp_mutex)
			undo_redo_manager_undo_wenumpoints(
				&we_state.undo_redo,
				app,
				win_idx,
				we_state.num_points,
			)
			we_state.num_points = i32(num_i)
			undo_redo_manager_undo_data_frame(
				&we_state.undo_redo,
				app,
				win_idx,
				we_state.data_frame,
			)
			harmonics_update_model(app, win_idx)
		} else {
			delete(app.state.import_buf)
			sb := strings.builder_make()
			for f in 0 ..< we_state.num_frames {
				for i in 0 ..< we_state.num_points {
					int_f := new_range_f32(
						we_state.data[data_index(f, u32(i))],
						{-1, 1},
						{f32(import_min), f32(import_max)},
					)
					int_x := int(math.round(int_f))
					strings.write_int(&sb, int_x)
					if i != we_state.num_points - 1 {
						strings.write_bytes(&sb, import_sep[:len(import_sep) - 1])
					}
				}
				if f != we_state.num_frames - 1 {
					strings.write_bytes(&sb, import_sep[:len(import_sep) - 1])
				}
			}
			strings.write_byte(&sb, 0)
			app.state.import_buf = sb.buf //strings.Builder is a [dynamic]u8 type
		}
	}
	imgui.SetNextItemWidth(-1)
	imgui.InputTextMultiline(
		"##Integer Values",
		cstring(&app.state.import_buf[0]),
		len(app.state.import_buf),
		flags = text_flags,
		callback = input_text_resize,
		user_data = &app.state.import_buf,
	)
	if imgui.IsItemHovered() {
		if ie_text == .Import {
			imgui.SetTooltip(
				"Paste integer values here\nExample: 0,10,20,-10,-15,16 is a valid string\n12 0 13 0 14 0 is also another valid string",
			)
		} else {
			imgui.SetTooltip(
				"Copy text after pressing 'Get Export Text'. Change separator string to insert characters between numbers",
			)
		}
	}
	if imgui.IsItemDeactivatedAfterEdit() {
		input_text_shrink(&app.state.import_buf)
	}
	imgui.SetNextItemWidth(100)
	if imgui.SliderInt("Minimum Value", &import_min, bits.I16_MIN, bits.I16_MAX) {
		import_min = min(import_min, import_max - 1)
	}
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Ctrl+LMB to manually type value, [-32768, 32767] allowed")
	}
	imgui.SameLine()
	imgui.SetNextItemWidth(100)
	if imgui.SliderInt("Maximum Value", &import_max, bits.I16_MIN, bits.I16_MAX) {
		import_max = max(import_max, import_min + 1)
	}
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Ctrl+LMB to manually type value, [-32768, 32767] allowed")
	}
	if ie_text == .Import {
		help_marker("Select how many integer samples would be used per frame")
		imgui.SliderInt("Samples Per Frame", &import_samples, 1, MAX_WAVEFORM_EDITOR_POINTS)
	}
	if ie_text == .Export {
		imgui.SetNextItemWidth(100)
		imgui.InputText(
			"Separator",
			cstring(&import_sep[0]),
			len(import_sep),
			{.CallbackResize},
			input_text_resize,
			&import_sep,
		)
		if imgui.IsItemHovered() {
			imgui.SetTooltip("String to insert between number values")
		}
		if imgui.IsItemDeactivatedAfterEdit() {
			input_text_shrink(&import_sep)
		}
	}
}
