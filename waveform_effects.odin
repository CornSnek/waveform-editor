package waveform_editor
//Shared with waveform_editor.odin and waveform_lua_functions.odin
import "core:c"
import "core:math"
import "core:mem"
import "core:sync"

import fm "./fourier_model"
import lua "vendor:lua/5.4"

EffectPtr :: #type proc(app: ^App, win_idx: int)
effect_none :: proc(_: ^App, _: int) {}

//Presets

LuaPresetChoose :: enum lua.Integer {
	empty,
	sine,
	pulse_1_8th,
	pulse_1_4th,
	square,
	sawtooth,
	triangle,
	half_sine,
}

preset_empty :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = 0
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

preset_sine :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = math.sin_f32(
			2 * math.PI * f32(i) / f32(we_state.num_points),
		)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

preset_pulse_1_8th :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = f32(
			i32(i >= we_state.num_points / 8) * -2 + 1,
		)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

preset_pulse_1_4th :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = f32(
			i32(i >= we_state.num_points / 4) * -2 + 1,
		)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

preset_square :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = f32(
			i32(i >= we_state.num_points / 2) * -2 + 1,
		)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

preset_sawtooth :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		n := f32(i) / f32(we_state.num_points) + 0.5
		we_state.data[data_index(we_state.data_frame, u32(i))] = 2 * (n - math.floor(n)) - 1
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

preset_triangle :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		n := f32(i) / f32(we_state.num_points) + 0.25
		we_state.data[data_index(we_state.data_frame, u32(i))] =
			1 - 4 * math.abs(n - math.floor(n) - 0.5)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

preset_half_sine :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = new_range_f32(
			math.sin_f32(math.PI * f32(i) / f32(we_state.num_points)),
			{0, 1},
			{-1, 1},
		)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

lua_preset_table :: proc "c" (L: ^lua.State) -> c.int {
	app := lua_get_app(L)
	preset_value := LuaPresetChoose(lua.tointeger(L, 1))
	table_len := lua.tointeger(L, 2)
	lua.createtable(L, c.int(table_len), 0)
	switch preset_value {
	case .empty:
		for i in 0 ..< table_len {
			lua.pushnumber(L, 0)
			lua.rawseti(L, -2, i + 1)
		}
	case .sine:
		for i in 0 ..< table_len {
			lua.pushnumber(L, lua.Number(math.sin_f64(2 * math.PI * f64(i) / f64(table_len))))
			lua.rawseti(L, -2, i + 1)
		}
	case .pulse_1_4th:
		for i in 0 ..< table_len {
			lua.pushnumber(L, lua.Number(i64(i >= table_len / 4) * -2 + 1))
			lua.rawseti(L, -2, i + 1)
		}
	case .square:
		for i in 0 ..< table_len {
			lua.pushnumber(L, lua.Number(i64(i >= table_len / 2) * -2 + 1))
			lua.rawseti(L, -2, i + 1)
		}
	case .pulse_1_8th:
		for i in 0 ..< table_len {
			lua.pushnumber(L, lua.Number(i64(i >= table_len / 8) * -2 + 1))
			lua.rawseti(L, -2, i + 1)
		}
	case .sawtooth:
		for i in 0 ..< table_len {
			n := f64(i) / f64(table_len) + 0.5
			lua.pushnumber(L, lua.Number(2 * (n - math.floor(n)) - 1))
			lua.rawseti(L, -2, i + 1)
		}
	case .triangle:
		for i in 0 ..< table_len {
			n := f64(i) / f64(table_len) + 0.25
			lua.pushnumber(L, lua.Number(1 - 4 * math.abs(n - math.floor(n) - 0.5)))
			lua.rawseti(L, -2, i + 1)
		}
	case .half_sine:
		for i in 0 ..< table_len {
			lua.pushnumber(
				L,
				lua.Number(
					f64(new_range(math.sin_f64(math.PI * f64(i) / f64(table_len)), 0, 1, -1, 1)),
				),
			)
			lua.rawseti(L, -2, i + 1)
		}
	case:
		lua.L_error(L, "At argument#1, Invalid preset enum")
	}
	return 1
}
LUA_PRESET_TABLE_DESC :: `f(i:int, n:int) -> t:table
Returns a table that contains values of a preset waveform of length n,
where the preset names are in the table presets and contain the i value.
Use 'print(presets)' to check the values.`

//Effects

EffectClampInt :: struct {
	min: i32,
	max: i32,
}
EffectClampFloat :: struct {
	min: f32,
	max: f32,
}

effect_nan_to_0_full :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for f in 0 ..< we_state.num_frames {
		for i in 0 ..< we_state.num_points {
			data_f := we_state.data[data_index(f, u32(i))]
			if data_f != data_f {
				undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, f)
				we_state.data[data_index(f, u32(i))] = 0
			}
		}
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_gain_clamp :: EffectClampFloat{-math.INF_F32, math.INF_F32}
effect_gain :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_gain_full(app, win_idx, we_state.gain_v)
}
effect_gain_full :: proc(app: ^App, win_idx: int, gain_v: f32, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	sync.mutex_guard(&wp_mutex)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] *= gain_v
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_normalization_clamp :: EffectClampFloat{0, 1}
effect_normalization :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_normalization_full(app, win_idx, we_state.normal_v)
}
effect_normalization_full :: proc(app: ^App, win_idx: int, normal_v: f32, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	max_sample, min_sample: f32
	for i in 0 ..< we_state.num_points {
		max_sample = max(max_sample, we_state.data[data_index(we_state.data_frame, u32(i))])
		min_sample = min(min_sample, we_state.data[data_index(we_state.data_frame, u32(i))])
	}
	if max_sample > 0 && min_sample < 0 { 	//Must cross 0 boundary
		sync.mutex_guard(&wp_mutex)
		scale_factor: f32 = 1
		if math.abs(max_sample) > math.abs(min_sample) {
			scale_factor = f32(normal_v) / max_sample
		} else {
			scale_factor = -f32(normal_v) / min_sample
		}
		if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
		undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
		for i in 0 ..< we_state.num_points {
			undo_redo_manager_undo_wedraw(
				&we_state.undo_redo,
				app,
				win_idx,
				i,
				we_state.data_frame,
			)
			we_state.data[data_index(we_state.data_frame, u32(i))] = clamp(
				we_state.data[data_index(we_state.data_frame, u32(i))] * scale_factor,
				-1,
				1,
			)
		}
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_change_phase_clamp :: proc(we_state: ^WaveformEditorState) -> EffectClampInt {
	return {-we_state.num_points + 1, we_state.num_points - 1}
}
effect_change_phase :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_change_phase_full(app, win_idx, we_state.ch_phase_v)
}
effect_change_phase_full :: proc(app: ^App, win_idx: int, ch_phase_v: i32, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	assert(app.state.past_data == nil)
	app.state.past_data = make([dynamic]f32, int(we_state.num_points))
	defer {
		delete(app.state.past_data)
		app.state.past_data = nil
	}
	mem.copy_non_overlapping(
		&app.state.past_data[0],
		&we_state.data[data_index(we_state.data_frame, 0)],
		int(we_state.num_points) * size_of(f32),
	)
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		phase_i := (i - ch_phase_v) % we_state.num_points
		if phase_i < 0 do phase_i += we_state.num_points
		we_state.data[data_index(we_state.data_frame, u32(i))] = app.state.past_data[phase_i]
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_comb_fff_clamp_m :: EffectClampFloat{-1, 1}
effect_comb_fff_clamp_n :: EffectClampInt{1, 2048}
effect_comb_filter_feed_forward :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_comb_filter_feed_forward_full(app, win_idx, we_state.comb_m_v, we_state.comb_n_v)
}
effect_comb_filter_feed_forward_full :: proc(
	app: ^App,
	win_idx: int,
	comb_m_v: f32,
	comb_n_v: i32,
	add_stop: bool = true,
) {
	we_state := &app.state.we[win_idx]
	assert(app.state.past_data == nil)
	app.state.past_data = make([dynamic]f32, int(we_state.num_points))
	defer {
		delete(app.state.past_data)
		app.state.past_data = nil
	}
	mem.copy_non_overlapping(
		&app.state.past_data[0],
		&we_state.data[data_index(we_state.data_frame, u32(0))],
		int(we_state.num_points) * size_of(f32),
	)
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		delay_i := (i - comb_n_v) % we_state.num_points
		if delay_i < 0 do delay_i += we_state.num_points
		we_state.data[data_index(we_state.data_frame, u32(i))] =
			we_state.data[data_index(we_state.data_frame, u32(i))] +
			comb_m_v * app.state.past_data[delay_i]
	}
	if add_stop do harmonics_update_model(app, win_idx)
} //, add_stop: bool = true
effect_inversion :: proc(app: ^App, win_idx: int) {
	effect_inversion_full(app, win_idx)
}
effect_inversion_full :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = -we_state.data[data_index(we_state.data_frame, u32(i))]
	}
	if add_stop do harmonics_update_model(app, win_idx)
}
effect_fuzz :: proc(app: ^App, win_idx: int) {
	effect_fuzz_full(app, win_idx)
}
effect_fuzz_full :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = math.sign(
			we_state.data[data_index(we_state.data_frame, u32(i))],
		)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_hard_clip_clamp :: EffectClampFloat{0, 1}
effect_hard_clip :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_hard_clip_full(app, win_idx, we_state.hard_clip_v)
}
effect_hard_clip_full :: proc(app: ^App, win_idx: int, hard_clip_v: f32, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		sign := math.sign(we_state.data[data_index(we_state.data_frame, u32(i))])
		if math.abs(we_state.data[data_index(we_state.data_frame, u32(i))]) > hard_clip_v {
			undo_redo_manager_undo_wedraw(
				&we_state.undo_redo,
				app,
				win_idx,
				i,
				we_state.data_frame,
			)
			we_state.data[data_index(we_state.data_frame, u32(i))] = hard_clip_v * sign
		}
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_soft_clip_clamp :: EffectClampFloat{0, math.INF_F32}
effect_soft_clip :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_soft_clip_full(app, win_idx, we_state.soft_clip_v)
}
effect_soft_clip_full :: proc(app: ^App, win_idx: int, soft_clip_v: f32, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = math.tanh(
			soft_clip_v * we_state.data[data_index(we_state.data_frame, u32(i))],
		)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_bit_crusher_clamp :: EffectClampInt{i32(WaveformBitcrush._1B), i32(WaveformBitcrush._8B)}
effect_bit_crusher :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_bit_crusher_full(app, win_idx, we_state.bitcrush_v)
}
effect_bit_crusher_full :: proc(
	app: ^App,
	win_idx: int,
	bitcrush_v: WaveformBitcrush,
	add_stop: bool = true,
) {
	we_state := &app.state.we[win_idx]
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		bits: i32 = i32(bitcrush_v)
		pow_v := math.pow(2, f32(bits))
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = math.clamp(
			(math.floor(we_state.data[data_index(we_state.data_frame, u32(i))] * pow_v) + 0.5) /
			(pow_v - 0.5),
			-1,
			1,
		)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_triangle_folding_clamp :: EffectClampFloat{1, math.F32_MAX}
effect_triangle_folding :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_triangle_folding_full(app, win_idx, we_state.wavefold_v)
}
effect_triangle_folding_full :: proc(
	app: ^App,
	win_idx: int,
	wavefold_v: f32,
	add_stop: bool = true,
) {
	we_state := &app.state.we[win_idx]
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		x := we_state.data[data_index(we_state.data_frame, u32(i))] * wavefold_v
		rhx := math.round(x / 2)
		we_state.data[data_index(we_state.data_frame, u32(i))] =
			math.pow_f32(-1, rhx) * (x - 2 * rhx)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}
effect_chebyshev_folding_clamp :: proc(num_points: i32) -> EffectClampFloat {
	return {min = 0, max = f32(num_points / 2)}
}
effect_chebyshev_folding :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_chebyshev_folding_full(app, win_idx, we_state.cheb_n_v)
}
effect_chebyshev_folding_full :: proc(
	app: ^App,
	win_idx: int,
	cheb_n_v: f32,
	add_stop: bool = true,
) {
	we_state := &app.state.we[win_idx]
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		data_f := we_state.data[data_index(we_state.data_frame, u32(i))]
		int_f, rem := math.modf(cheb_n_v)
		cheb_n_int := i32(int_f)
		slope :=
			chebyshev_wavefold(data_f, cheb_n_int + 1) - chebyshev_wavefold(data_f, cheb_n_int)
		cheb_res := clamp(chebyshev_wavefold(data_f, cheb_n_int) + slope * rem, -1, 1)
		we_state.data[data_index(we_state.data_frame, u32(i))] = cheb_res
	}
	if add_stop do harmonics_update_model(app, win_idx)
}
effect_n_overtone_clamp :: EffectClampInt{1, MAX_WAVEFORM_EDITOR_POINTS}
effect_n_overtone :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_n_overtone_full(app, win_idx, we_state.overtone_v)
}
effect_n_overtone_full :: proc(app: ^App, win_idx: int, overtone_v: i32, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	samples_copy := make([dynamic]f32, int(we_state.num_points))
	defer delete(samples_copy)
	copy(
		samples_copy[:],
		we_state.data[data_index(we_state.data_frame, u32(0)):data_index(
			we_state.data_frame,
			u32(u32(we_state.num_points)),
		)],
	)
	avg_len := overtone_v + 1
	sync.mutex_guard(&wp_mutex)
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		sample_i := (i * avg_len + we_state.num_points - avg_len / 2) % we_state.num_points
		sum: f32 = 0
		for j in 0 ..< avg_len {
			sum += samples_copy[(sample_i + j) % we_state.num_points]
		}
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] = sum / f32(avg_len)
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_resampling_clamp :: EffectClampInt{1, MAX_WAVEFORM_EDITOR_POINTS}
effect_resampling :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_resampling_full(app, win_idx, we_state.n_samp_v, we_state.n_samp_interp_v)
}
effect_resampling_full :: proc(
	app: ^App,
	win_idx: int,
	n_samp_v: i32,
	n_samp_interp_v: InterpolationType,
	add_stop: bool = true,
) {
	we_state := &app.state.we[win_idx]
	assert(app.state.past_data == nil)
	app.state.past_data = make([dynamic]f32, int(we_state.num_points))
	defer {
		delete(app.state.past_data)
		app.state.past_data = nil
	}
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_wenumpoints(&we_state.undo_redo, app, win_idx, we_state.num_points)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	old_len := we_state.num_points
	we_state.num_points = n_samp_v
	for f in 0 ..< we_state.num_frames {
		mem.copy_non_overlapping(
			&app.state.past_data[0],
			&we_state.data[data_index(f, u32(0))],
			int(old_len) * size_of(f32),
		)
		for i in 0 ..< n_samp_v {
			undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, f)
			x_f := f32(i) * f32(old_len) / f32(n_samp_v) //[0,new_len) to [0,old_len)
			x_intf, x_rem := math.modf(x_f)
			x_int := i32(x_intf)
			switch n_samp_interp_v {
			case .None:
				we_state.data[data_index(f, u32(i))] = app.state.past_data[x_int]
			case .Linear:
				slope := app.state.past_data[(x_int + 1) % old_len] - app.state.past_data[x_int]
				we_state.data[data_index(f, u32(i))] = app.state.past_data[x_int] + slope * x_rem
			case .Cubic:
				y_m1 := app.state.past_data[(old_len + x_int - 1) % old_len]
				y0 := app.state.past_data[x_int]
				y1 := app.state.past_data[(x_int + 1) % old_len]
				y2 := app.state.past_data[(x_int + 2) % old_len]
				we_state.data[data_index(f, u32(i))] = cubic_hermite(f32(x_rem), y_m1, y0, y1, y2)
			}
		}
		if old_len > n_samp_v {
			for i in n_samp_v ..< old_len {
				undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, f)
				we_state.data[data_index(f, u32(i))] = 0
			}
		}
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_offset_clamp :: EffectClampFloat{-1, 1}
effect_offset :: proc(app: ^App, win_idx: int) {
	we_state := &app.state.we[win_idx]
	effect_offset_full(app, win_idx, we_state.offset_v)
}
effect_offset_full :: proc(app: ^App, win_idx: int, offset_v: f32, add_stop: bool = true) {
	we_state := &app.state.we[win_idx]
	if add_stop do undo_redo_manager_undo_add_stop(&we_state.undo_redo)
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_idx, we_state.data_frame)
	for i in 0 ..< we_state.num_points {
		undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_idx, i, we_state.data_frame)
		we_state.data[data_index(we_state.data_frame, u32(i))] += offset_v
	}
	if add_stop do harmonics_update_model(app, win_idx)
}

//Harmonics effects

//For both low/high
effect_pass_clamp :: proc(wfm: ^fm.Waveform_Model) -> EffectClampFloat {
	return {min = 1, max = f32(wfm.n)}
}
effect_low_pass :: proc(app: ^App, win_idx: int, low_pass_v: f32, add_stop: bool = true) {
	wfm := &app.state.we_h_wfs[win_idx]
	i: int = wfm.n
	for {
		if f32(i) > low_pass_v {
			wfm.amp[i] = 0
		} else if f32(i) == low_pass_v {
			break
		} else {
			wfm.amp[i] *= low_pass_v - f32(i)
			break
		}
		i -= 1
	}
	harmonics_apply(app, win_idx, add_stop)
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_high_pass :: proc(app: ^App, win_idx: int, high_pass_v: f32, add_stop: bool = true) {
	wfm := &app.state.we_h_wfs[win_idx]
	for i in 1 ..= wfm.n {
		if f32(i) < high_pass_v {
			wfm.amp[i] = 0
		} else if f32(i) == high_pass_v {
			break
		} else {
			wfm.amp[i] *= 1 + f32(i) - high_pass_v
			break
		}
	}
	harmonics_apply(app, win_idx, add_stop)
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_odd_harmonics_only :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	wfm := &app.state.we_h_wfs[win_idx]
	i: int = 2
	for i <= wfm.n {
		wfm.amp[i] = 0
		i += 2
	}
	harmonics_apply(app, win_idx, add_stop)
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_even_harmonics_only :: proc(app: ^App, win_idx: int, add_stop: bool = true) {
	wfm := &app.state.we_h_wfs[win_idx]
	i: int = 1
	for i <= wfm.n {
		wfm.amp[i] = 0
		i += 2
	}
	harmonics_apply(app, win_idx, add_stop)
	if add_stop do harmonics_update_model(app, win_idx)
}

effect_shift_harmonics_clamp :: EffectClampFloat{-math.PI * 2, math.PI * 2}
effect_shift_harmonics :: proc(app: ^App, win_idx: int, h_shift_by: f32, add_stop: bool = true) {
	wfm := &app.state.we_h_wfs[win_idx]
	for i in 1 ..= wfm.n {
		wfm.phase[i] = pmod(wfm.phase[i] + h_shift_by * f32(i), math.PI * 2)
	}
	harmonics_apply(app, win_idx, add_stop)
	if add_stop do harmonics_update_model(app, win_idx)
}
