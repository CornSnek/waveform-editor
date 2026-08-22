package waveform_editor

import "core:container/handle_map"
import "core:container/queue"
import "core:fmt"
import "core:math"
import "core:strings"

import imgui "imgui:/"
import fm "./fourier_model"
harmonics_update_model :: proc(app: ^App, win_idx: int) {
	fm.waveform_model_destroy(&app.state.we_h_wfs[win_idx])
	we_state := &app.state.we[win_idx]
	app.state.we_h_wfs[win_idx] = fm.waveform_model_new(
		we_state.data[data_index(we_state.data_frame, 0):data_index(
			we_state.data_frame,
			u32(we_state.num_points),
		)],
		int(we_state.num_points / 2),
	)
}

f_harmonics_draw :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	we_state := &app.state.we[win_idx]
	style := imgui.GetStyle()
	lgp := get_line_graph_prop(true)
	draw_list := imgui.GetWindowDrawList()
	imgui_tl :=
		imgui.GetCursorScreenPos() +
		{0, -style.WindowPadding.y + imgui.GetTextLineHeightWithSpacing()} //Add text spacing to show harmonic number between sliders
	graph_size := lgp.total_size - {0, style.ScrollbarSize}
	imgui.SetCursorScreenPos(imgui_tl)
	h_wf_model := &app.state.we_h_wfs[win_idx]
	item_space_x := style.ItemSpacing.x
	imgui.PushStyleVarImVec2(.ItemSpacing, {})
	imgui.PushStyleVarImVec2(.FramePadding, {})
	imgui.PushStyleVarImVec2(.WindowPadding, {})
	slider_width: f32 = 50
	slider_height := graph_size.y / 2
	label_width: f32 = 125
	imgui.SetCursorScreenPos(imgui_tl + {0, slider_height / 2})
	imgui.Text("Amplitude")
	imgui.SetCursorScreenPos(imgui_tl + {label_width, 0})
	for i in 0 ..= h_wf_model.n {
		tmp_id := fmt.tprintf("##A{}\x00", i)
		imgui.VSliderFloat(
			strings.unsafe_string_to_cstring(tmp_id),
			{slider_width, slider_height},
			&h_wf_model.amp[i],
			v_min = 0,
			v_max = 1,
			format = "%.3f",
		)
		if i != h_wf_model.n do imgui.SameLine()
	}
	imgui.SetCursorScreenPos(imgui_tl + {0, 3 * slider_height / 2})
	imgui.Text("Phase (Degrees)")
	imgui.SetCursorScreenPos(imgui_tl + {label_width, slider_height})
	for i in 0 ..= h_wf_model.n {
		tmp_id := fmt.tprintf("##P{}\x00", i)
		tmp_deg := fmt.tprintf("%.1fd", math.to_degrees(h_wf_model.phase[i]))
		if i != 0 {
			imgui.VSliderFloat(
				strings.unsafe_string_to_cstring(tmp_id),
				{slider_width, slider_height},
				&h_wf_model.phase[i],
				v_min = -2 * math.PI,
				v_max = 2 * math.PI,
				format = strings.unsafe_string_to_cstring(tmp_deg),
			)
		} else {
			imgui.Dummy({slider_width, slider_height})
		}
		if i != h_wf_model.n do imgui.SameLine()
	}
	imgui.SetCursorScreenPos(lgp.tl)
	imgui.DrawList_AddRectFilled(
		draw_list,
		lgp.tl,
		lgp.tl + {graph_size.x, imgui.GetTextLineHeightWithSpacing()},
		imgui.GetColorU32ImVec4({0, 0, 0, 1}),
	)
	for i in 0 ..= h_wf_model.n {
		tmp_h: string = ---
		if i != 0 {
			tmp_h = fmt.tprintf("H{}\x00", i)
		} else {
			tmp_h = "DC Offset\x00"
		}
		text_size := imgui.CalcTextSize(strings.unsafe_string_to_cstring(tmp_h))
		imgui.DrawList_AddText(
			draw_list,
			lgp.tl +
			{
					slider_width * f32(i) +
					label_width +
					item_space_x +
					slider_width / 2 -
					text_size.x / 2 -
					imgui.GetScrollX(),
					0,
				},
			0xffffffff,
			strings.unsafe_string_to_cstring(tmp_h),
		)
	}
	imgui.PopStyleVar(3)
	if imgui.BeginMenuBar() {
		defer imgui.EndMenuBar()
		if imgui.BeginMenu("Edit") {
			defer imgui.EndMenu()
			if imgui.MenuItem("Apply Formula", "Ctrl+A") {
				harmonics_apply(app, win_idx)
				harmonics_update_model(app, win_idx)
			}
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
		}
		if imgui.BeginMenu("Effects") {
			defer imgui.EndMenu()
			help_marker(
				"Effect will try to lower harmonic amplitudes above given threshold to 0.\nFloat values between threshold is lowered partially.",
			)
			if imgui.BeginMenu("Low Pass") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_low_pass(app, win_idx, we_state.low_pass_v)
				}
				wfm := &app.state.we_h_wfs[win_idx]
				clamp := effect_pass_clamp(wfm)
				imgui.SliderFloat(
					"Threshold",
					&we_state.low_pass_v,
					clamp.min,
					clamp.max,
					flags = {.ClampOnInput},
				)
			}
			help_marker(
				"Sets harmonic amplitudes below given threshold to 0.\nFloat values between threshold is lowered partially.",
			)
			if imgui.BeginMenu("High Pass") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_high_pass(app, win_idx, we_state.high_pass_v)
				}
				wfm := &app.state.we_h_wfs[win_idx]
				clamp := effect_pass_clamp(wfm)
				imgui.SliderFloat(
					"Threshold",
					&we_state.high_pass_v,
					clamp.min,
					clamp.max,
					flags = {.ClampOnInput},
				)
			}
			help_marker(
				"Shift the harmonics by set radians or degrees",
			)
			if imgui.BeginMenu("Shift By") {
				defer imgui.EndMenu()
				if imgui.MenuItem("Apply") {
					effect_shift_harmonics(app, win_idx, we_state.h_shift_by_v)
				}
				imgui.SliderFloat(
					"Radians",
					&we_state.h_shift_by_v,
					effect_shift_harmonics_clamp.min,
					effect_shift_harmonics_clamp.max,
					flags = {.ClampOnInput},
				)
				h_shift_by_v_deg := math.to_degrees(we_state.h_shift_by_v)
				if imgui.SliderFloat(
					"Degrees",
					&h_shift_by_v_deg,
					-360,
					360,
					flags = {.ClampOnInput},
				) {
					we_state.h_shift_by_v = math.to_radians(h_shift_by_v_deg)
				}
			}
			if imgui.MenuItem("Odd Harmonics Only") {
				effect_odd_harmonics_only(app, win_idx)
			}
			if imgui.MenuItem("Even Harmonics Only") {
				effect_even_harmonics_only(app, win_idx)
			}
		}
	}
	if imgui.IsWindowFocused() {
		if imgui.IsKeyDown(.ImGuiMod_Ctrl) {
			if imgui.IsKeyPressed(.A, false) {
				harmonics_apply(app, win_idx)
				harmonics_update_model(app, win_idx)
			}
		}
		zb := imgui.GetKeyData(.Z)
		if imgui.IsKeyDown(.ImGuiMod_Shift) {
			if zb.Down && zb.DownDuration == 0 {
				undo_redo_manager_do_redo(&we_state.undo_redo, app)
				harmonics_update_model(app, win_idx)
			}
		} else {
			if zb.Down && zb.DownDuration == 0 {
				undo_redo_manager_do_undo(&we_state.undo_redo, app)
				harmonics_update_model(app, win_idx)
			}
		}
	}
}
harmonics_apply :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = fm.waveform_model_evaluate_f(
			&app.state.we_h_wfs[win_idx],
			f32(i),
			we_state.num_points,
		)
	}
}
f_harmonics_destroy :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	handle_map.remove(&app.imgui_hm, base.handle)
	strings.builder_destroy(&base.id.(strings.Builder))
	base.is_active = false
}
