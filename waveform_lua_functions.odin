package waveform_editor

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:sync"

import fm "./fourier_model"
import lua "vendor:lua/5.4"

LUA_APP_UD_KEY: int

lua_get_app :: proc "c" (L: ^lua.State) -> ^App {
	lua.pushlightuserdata(L, &LUA_APP_UD_KEY)
	lua.rawget(L, lua.REGISTRYINDEX)
	app := cast(^App)lua.touserdata(L, -1)
	lua.pop(L, 1)
	return app
}

lua_register_functions :: proc(L: ^lua.State) {
	lua_set_window_table(L)
	lua.setglobal(L, "window")

	lua.pushcfunction(L, lua_print)
	lua.setglobal(L, "print")
	lua.createtable(L, 0, c.int(len(lua_math_functions) + len(CONSTANTS)))
	for lcf in lua_math_functions {
		lua.pushcfunction(L, lcf.ptr)
		lua.setfield(L, -2, lcf.lua_name)
	}
	CONSTANTS :: [?]struct {
		n:        lua.Number,
		lua_name: cstring,
	} {
		{math.E, "e"},
		{math.PI, "pi"},
		{math.TAU, "tau"},
		{math.F64_EPSILON, "epsilon"},
		{lua.Number(math.INF_F64), "inf"},
	}
	for c in CONSTANTS {
		lua.pushnumber(L, c.n)
		lua.setfield(L, -2, c.lua_name)
	}
	lua.setglobal(L, "wemath")

	lua.createtable(L, 0, c.int(len(lua_waveform_effects)))
	for lwe in lua_waveform_effects {
		lua.pushcfunction(L, lwe.ptr)
		lua.setfield(L, -2, lwe.lua_name)
	}
	lua.setglobal(L, "effects")

	lua.createtable(L, 0, c.int(len(lua_data_functions)))
	for ldf in lua_data_functions {
		lua.pushcfunction(L, ldf.ptr)
		lua.setfield(L, -2, ldf.lua_name)
	}
	lua.setglobal(L, "data")

	lua.createtable(L, 0, c.int(len(LuaPresetChoose)))
	lpc_name := reflect.enum_field_names(LuaPresetChoose)
	lpc_values := reflect.enum_field_values(LuaPresetChoose)
	for i in 0 ..< len(LuaPresetChoose) {
		lua.pushlstring(
			L,
			strings.unsafe_string_to_cstring(lpc_name[i]),
			c.size_t(len(lpc_name[i])),
		)
		lua.pushinteger(L, lua.Integer(lpc_values[i]))
		lua.rawset(L, -3)
	}
	lua.pushcfunction(L, lua_apply_preset)
	lua.setfield(L, -2, "apply")
	lua.setglobal(L, "presets")

	lua.createtable(L, 0, c.int(len(lua_harmonics_functions)))
	for lhf in lua_harmonics_functions {
		lua.pushcfunction(L, lhf.ptr)
		lua.setfield(L, -2, lhf.lua_name)
	}
	lua.setglobal(L, "harmonics")
	lua.pushcfunction(L, lua_map)
	lua.setglobal(L, "map")
}
lua_window__index :: proc "c" (L: ^lua.State) -> c.int {
	app := lua_get_app(L)
	#partial switch lua.Type(lua.type(L, 2)) {
	case .NUMBER:
		win_idx: int = int(lua.tointeger(L, 2))
		_lua_check_window(L, 1, app, win_idx)
		context = runtime.default_context()
		lua_set_window_table(L, c.int(win_idx))
		return 1
	case .STRING:
		key := lua.tostring(L, 2)
		lua.pushliteral(L, "idx")
		lua.rawget(L, 1)
		win_idx: int = _lua_idx_from_window_table(L, app)
		return _window__index(L, app, win_idx, key)
	case:
		return 0
	}
	unreachable()
}
//Table from lua_window_table should be at index 1
_lua_idx_from_window_table :: proc "c" (L: ^lua.State, app: ^App) -> (win_idx: int) {
	lua.pushliteral(L, "idx")
	lua.rawget(L, 1)
	#partial switch lua.Type(lua.type(L, -1)) {
	case .NIL:
		win_idx = app.state.lua_win_idx
		lua.pop(L, 1)
	case .NUMBER:
		win_idx = int(lua.tointeger(L, -1) - 1)
		lua.pop(L, 1)
	case:
		lua.L_error(L, "Unexpected type")
	}
	return
}
lua_window__newindex :: proc "c" (L: ^lua.State) -> c.int {
	app := lua_get_app(L)
	key := lua.tostring(L, 2)
	value := lua.tointeger(L, 3)
	lua.pushliteral(L, "idx")
	lua.rawget(L, 1)
	win_idx: int = _lua_idx_from_window_table(L, app)
	switch key {
	case "idx":
		lua.L_argerror(L, 2, "idx is read-only")
	case "frame":
		_lua_check_frame(L, 3, win_idx, i32(value), app)
		we_state := &app.state.we[win_idx]
		we_state.data_frame = i32(value)
	case "frames":
		if value <= 0 || value > MAX_WAVEFORM_FRAMES {
			lua.L_error(L, "Value should be between [1, %d]", MAX_WAVEFORM_FRAMES)
		}
		we_state := &app.state.we[win_idx]
		context = runtime.default_context()
		undo_redo_manager_undo_setmaxframes(&we_state.undo_redo, app, win_idx, we_state.num_frames)
		set_frames(app, win_idx, i32(value))
		we_state.num_frames = i32(value)
	case "samples":
		context = runtime.default_context()
		we_state := &app.state.we[win_idx]
		if value <= 0 || value > MAX_WAVEFORM_EDITOR_POINTS {
			lua.L_error(
				L,
				"For argument #3, samples must be set from [1, %d]",
				MAX_WAVEFORM_EDITOR_POINTS,
			)
		}
		undo_redo_manager_undo_wenumpoints(&we_state.undo_redo, app, win_idx, we_state.num_points)
		sync.mutex_guard(&wp_mutex)
		we_state.num_points = i32(value)
	}
	return 0
}
_window__index :: proc "c" (L: ^lua.State, app: ^App, win_idx: int, key: cstring) -> c.int {
	switch key {
	case "idx":
		lua.pushinteger(L, lua.Integer(win_idx + 1))
	case "frame":
		lua.pushinteger(L, lua.Integer(app.state.we[win_idx].data_frame))
	case "frames":
		lua.pushinteger(L, lua.Integer(app.state.we[win_idx].num_frames))
	case "samples":
		lua.pushinteger(L, lua.Integer(app.state.we[win_idx].num_points))
	case:
		return 0
	}
	return 1
}
lua_set_window_table :: proc "c" (L: ^lua.State, idx: c.int = -1) {
	lua.newtable(L) // [proxy]
	if idx != -1 {
		lua.pushinteger(L, lua.Integer(idx))
		lua.setfield(L, -2, "idx")
	}
	lua.newtable(L) // [proxy, mt]
	lua.pushcfunction(L, lua_window__index)
	lua.setfield(L, -2, "__index")
	lua.pushcfunction(L, lua_window__newindex)
	lua.setfield(L, -2, "__newindex")
	lua.pushboolean(L, true)
	lua.setfield(L, -2, "__metatable")
	lua.setmetatable(L, -2) // [proxy]
}

LuaCustomFunction :: struct {
	ptr:      proc "c" (L: ^lua.State) -> c.int,
	lua_name: cstring,
	desc:     cstring,
}




//odinfmt: disable
lua_math_functions :: [?]LuaCustomFunction{
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		num := lua.tonumber(L, 1)
		lua.pushnumber(L, abs(num))
		return 1
	}, lua_name = "abs"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		num := lua.tonumber(L, 1)
		lua.pushnumber(L, lua.Number(math.acos_f64(f64(num))))
		return 1
	}, lua_name = "acos"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	lua.pushnumber(L, lua.Number(math.asin_f64(f64(num))))
    	return 1
    }, lua_name = "asin"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
	num := lua.tonumber(L, 1)
		lua.pushnumber(L, lua.Number(math.atan(f64(num))))
    	return 1
    }, lua_name = "atan"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	num2 := lua.tonumber(L, 2)
		lua.pushnumber(L, lua.Number(math.atan2_f64(f64(num), f64(num2))))
    	return 1
    }, lua_name = "atan2"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
		lua.pushnumber(L, lua.Number(math.ceil(f64(num))))
    	return 1
    }, lua_name = "ceil"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := f64(lua.tonumber(L, 1))
    	num2 := i32(lua.tointeger(L, 2))
		lua.pushnumber(L, lua.Number(chebyshev_wavefold(num,num2)))
    	return 1
    }, lua_name = "chebyshev"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		if lua.Type(lua.type(L, 1)) != .NUMBER {
			lua.L_error(L,"For argument #1, a number is required")
		}
		lua.pushvalue(L, 1)
		lua.pushcclosure(L, _lua_chebyshev_closure, 1)
    	return 1
    }, lua_name = "chebyshev_cl"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	num2 := lua.tonumber(L, 2)
    	num3 := lua.tonumber(L, 3)
    	lua.pushnumber(L, clamp(num, num2, num3))
    	return 1
    }, lua_name = "clamp"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
		lua.pushnumber(L, lua.Number(math.to_degrees_f64(f64(num))))
    	return 1
    }, lua_name = "deg"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
    	x: f64 = f64(lua.tonumber(L, 1))
		n := math.round(x/2)
    	lua.pushnumber(L, lua.Number(math.pow_f64(-1, n) * (x - 2 * n)))
    	return 1
    }, lua_name = "fold"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
    	x: f64 = f64(lua.tonumber(L, 1))
		lua.pushboolean(L, x!=x)
    	return 1
    }, lua_name = "isnan"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	num2 := lua.tonumber(L, 2)
    	num3 := lua.tonumber(L, 3)
    	lua.pushnumber(L, math.lerp(num, num2, num3))
    	return 1
    }, lua_name = "lerp"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	num2 := lua.tonumber(L, 2)
		lua.pushnumber(L, lua.Number(math.log_f64(f64(num), f64(num2))))
    	return 1
    }, lua_name = "log"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	n := lua.gettop(L)
    	res: lua.Number = ---
    		res = lua.Number(math.inf_f64(-1))
    	for i in 1 ..= n {
    		res = max(res, lua.tonumber(L, i))
    	}
    	lua.pushnumber(L, res)
    	return 1
    }, lua_name = "max"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	n := lua.gettop(L)
    	res: lua.Number = ---
    		res = lua.Number(math.inf_f64(1))
    	for i in 1 ..= n {
    		res = min(res, lua.tonumber(L, i))
    	}
    	lua.pushnumber(L, res)
    	return 1
    }, lua_name = "min"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
		int_f, rem := math.modf_f64(f64(num))
		lua.pushnumber(L, lua.Number(int_f))
		lua.pushnumber(L, lua.Number(rem))
    	return 2
    }, lua_name ="modf"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
		lua.pushnumber(L, lua.Number(math.to_radians_f64(f64(num))))
    	return 1
    }, lua_name = "rad"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	num2 := lua.tonumber(L, 2)
		lua.pushnumber(L, lua.Number(math.pow_f64(f64(num), f64(num2))))
    	return 1
    }, lua_name = "pow"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	num2 := lua.tonumber(L, 2)
    	num3 := lua.tonumber(L, 3)
    	num4 := lua.tonumber(L, 4)
    	num5 := lua.tonumber(L, 5)
		lua.pushnumber(
			L,
			lua.Number(new_range(f64(num), f64(num2), f64(num3), f64(num4), f64(num5))),
		)
    	return 1
    }, lua_name = "range"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	lua.pushnumber(L, lua.Number(math.round_f64(f64(num))))
    	return 1
    }, lua_name = "round"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	lua.pushnumber(L, lua.Number(math.sign_f64(f64(num))))
    	return 1
    }, lua_name = "sgn"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	lua.pushnumber(L, lua.Number(math.sin_f64(f64(num))))
    	return 1
    }, lua_name = "sin"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	num2 := lua.tonumber(L, 2)
    	num3 := lua.tonumber(L, 3)
    	lua.pushnumber(L, math.smoothstep(num,num2,num3))
    	return 1
    }, lua_name = "smoothstep"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	lua.pushnumber(L, lua.Number(math.sqrt_f64(f64(num))))
    	return 1
    }, lua_name = "sqrt"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
    	num := lua.tonumber(L, 1)
    	lua.pushnumber(L, lua.Number(math.tan_f64(f64(num))))
    	return 1
    }, lua_name = "tan"},
}//odinfmt: enable

_lua_chebyshev_closure :: proc "c" (L: ^lua.State) -> c.int {
	n := i32(lua.tointeger(L, lua.REGISTRYINDEX - 1))
	x := f64(lua.tonumber(L, 1))
	lua.pushnumber(L, lua.Number(chebyshev_wavefold(x, n)))
	return 1
}

_lua_waveform_check_clamp_or_error :: proc "contextless" (
	L: ^lua.State,
	arg_i: c.int,
	num: $T,
	cmin: T,
	cmax: T,
) where intrinsics.type_is_numeric(T) {
	if num < cmin || num > cmax {
		lua.L_error(
			L,
			"For argument #%d, Number must be set between [%d, %d]" when intrinsics.type_is_integer(
				T,
			) else "For argument #%d, Number must be set between [%f, %f]",
			arg_i,
			cmin,
			cmax,
		)
	}
}
_lua_check_frame :: proc "contextless" (
	L: ^lua.State,
	arg_i: c.int,
	win_i: int,
	frame: i32,
	app: ^App,
) {
	num_frames := app.state.we[win_i].num_frames
	if frame < 0 || frame >= num_frames {
		lua.L_error(L, "For argument #%d, Frame must be set between [0,%d]", arg_i, num_frames - 1)
	}
}




//odinfmt: disable
lua_waveform_effects :: [?]LuaCustomFunction{
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		gain_v:f32 = f32(lua.tonumber(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, gain_v, effect_gain_clamp.min, effect_gain_clamp.max)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		effect_gain_full(app, win_i, gain_v, false)
		return 0
	}, lua_name = "gain"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		normal_v:f32 = f32(lua.tonumber(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, normal_v, effect_normalization_clamp.min, effect_normalization_clamp.max)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		effect_normalization_full(app, win_i, normal_v, false)
		return 0
	}, lua_name = "normalization"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		ch_phase_v:i32 = i32(lua.tointeger(L, 1))
		frame, win_i := _lua_check_frame_window(L, app, 1)
		we_state := &app.state.we[win_i]
		clamp := effect_change_phase_clamp(we_state)
		_lua_waveform_check_clamp_or_error(L, 1, ch_phase_v, clamp.min, clamp.max)
		_lua_check_frame(L, 1, win_i, frame, app)
		app.state.we[win_i].data_frame = frame
		effect_change_phase_full(app, win_i, ch_phase_v, false)
		return 0
	}, lua_name = "change_phase"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		comb_m_v:f32 = f32(lua.tonumber(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, comb_m_v, effect_comb_fff_clamp_m.min, effect_comb_fff_clamp_m.max)
		comb_n_v:i32 = i32(lua.tointeger(L, 2))
		_lua_waveform_check_clamp_or_error(L, 2, comb_n_v, effect_comb_fff_clamp_n.min, effect_comb_fff_clamp_n.max)
		frame, win_i := _lua_check_frame_window(L, app, 2)
		app.state.we[win_i].data_frame = frame
		effect_comb_filter_feed_forward_full(app, win_i, comb_m_v, comb_n_v, false)
		return 0
	}, lua_name = "comb_feed_forward"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 0)
		app.state.we[win_i].data_frame = frame
		effect_inversion_full(app, win_i, false)
		return 0
	}, lua_name = "inversion"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 0)
		app.state.we[win_i].data_frame = frame
		effect_fuzz_full(app, win_i, false)
		return 0
	}, lua_name = "fuzz"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		hard_clip_v:f32 = f32(lua.tonumber(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, hard_clip_v, effect_hard_clip_clamp.min, effect_hard_clip_clamp.max)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		effect_hard_clip_full(app, win_i, hard_clip_v, false)
		return 0
	}, lua_name = "hard_clip"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		soft_clip_v:f32 = f32(lua.tonumber(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, soft_clip_v, effect_soft_clip_clamp.min, effect_soft_clip_clamp.max)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		effect_soft_clip_full(app, win_i, soft_clip_v, false)
		return 0
	}, lua_name = "soft_clip"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		bitcrush_v:i32 = i32(lua.tointeger(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, bitcrush_v, effect_bit_crusher_clamp.min+1, effect_bit_crusher_clamp.max+1)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		effect_bit_crusher_full(app, win_i, WaveformBitcrush(bitcrush_v-1), false)
		return 0
	}, lua_name = "bit_crusher"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		wavefold_v:f32 = f32(lua.tonumber(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, wavefold_v, effect_triangle_folding_clamp.min, effect_triangle_folding_clamp.max)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		effect_triangle_folding_full(app, win_i, wavefold_v, false)
		return 0
	}, lua_name = "triangle_fold"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		cheb_n_v:f32 = f32(lua.tonumber(L, 1))
		frame, win_i := _lua_check_frame_window(L, app, 1)
		clamp := effect_chebyshev_folding_clamp(app.state.we[win_i].num_points)
		_lua_waveform_check_clamp_or_error(L, 1, cheb_n_v, clamp.min, clamp.max)
		app.state.we[win_i].data_frame = frame
		effect_chebyshev_folding_full(app, win_i, cheb_n_v, false)
		return 0
	}, lua_name = "chebyshev_fold"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		overtone_v:i32 = i32(lua.tointeger(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, overtone_v, effect_n_overtone_clamp.min, effect_n_overtone_clamp.max)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		effect_n_overtone_full(app, win_i, overtone_v, false)
		return 0
	}, lua_name = "n_overtone"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		n_samp_v:i32 = i32(lua.tointeger(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, n_samp_v, effect_resampling_clamp.min, effect_resampling_clamp.max)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		n_samp_interp_str: cstring = lua.tostring(L,3)
		n_samp_interp: InterpolationType = ---
		switch(n_samp_interp_str) {
		case "None":
			n_samp_interp = .None
		case "Linear":
			n_samp_interp = .Linear
		case "Cubic":
			n_samp_interp = .Cubic
		case:
			n_samp_interp = .None
		}
		effect_resampling_full(app, win_i, n_samp_v, n_samp_interp, false)
		return 0
	}, lua_name = "resampling"},
    {ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		offset_v:f32 = f32(lua.tonumber(L, 1))
		_lua_waveform_check_clamp_or_error(L, 1, offset_v, effect_offset_clamp.min, effect_offset_clamp.max)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		app.state.we[win_i].data_frame = frame
		effect_offset_full(app, win_i, offset_v, false)
		return 0
	}, lua_name = "offset"},
}//odinfmt: enable

lua_print :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	n := lua.gettop(L)
	for i in 1 ..= n {
		switch lua.Type(lua.type(L, i)) {
		case .NONE:
			fmt.print("(none)")
		case .NIL:
			fmt.print("nil")
		case .BOOLEAN:
			fmt.print(lua.toboolean(L, i))
		case .LIGHTUSERDATA:
			fmt.printf("lua.lightuserdata@{}", lua.topointer(L, i))
		case .NUMBER:
			fmt.print(lua.tonumber(L, i))
		case .STRING:
			fmt.print("\"", lua.tostring(L, i), "\"", sep = "")
		case .TABLE:
			fmt.print("lua.table{")
			lua.pushnil(L)
			for lua.next(L, i) != 0 {
				#partial switch lua.Type(lua.type(L, -2)) {
				case .BOOLEAN:
					fmt.print(lua.toboolean(L, -2))
				case .LIGHTUSERDATA:
					fmt.printf("lua.lightuserdata@{}", lua.topointer(L, -2))
				case .NUMBER:
					fmt.print("[", lua.tonumber(L, -2), "]", sep = "")
				case .STRING:
					fmt.print("\"", lua.tostring(L, -2), "\"", sep = "")
				case .TABLE:
					fmt.print("lua.table{...}")
				case .FUNCTION:
					fmt.printf("function@{}", lua.topointer(L, -2))
				case .USERDATA:
					fmt.printf("lua.userdata@{}", lua.topointer(L, -2))
				case .THREAD:
					fmt.printf("lua.thread@{}", lua.topointer(L, -2))
				}
				fmt.print(" = ")
				#partial switch lua.Type(lua.type(L, -1)) {
				case .BOOLEAN:
					fmt.print(lua.toboolean(L, -1))
				case .LIGHTUSERDATA:
					fmt.printf("lua.lightuserdata@{}", lua.topointer(L, -1))
				case .NUMBER:
					fmt.print(lua.tonumber(L, -1))
				case .STRING:
					fmt.print("\"", lua.tostring(L, -1), "\"", sep = "")
				case .TABLE:
					fmt.print("lua.table{...}")
				case .FUNCTION:
					fmt.printf("function@{}", lua.topointer(L, -1))
				case .USERDATA:
					fmt.printf("lua.userdata@{}", lua.topointer(L, -1))
				case .THREAD:
					fmt.printf("lua.thread@{}", lua.topointer(L, -1))
				}
				lua.pop(L, 1)
				fmt.print(", ")
			}
			fmt.print("}")
		case .FUNCTION:
			fmt.printf("function@{}", lua.topointer(L, i))
		case .USERDATA:
			fmt.printf("lua.userdata@{}", lua.topointer(L, i))
		case .THREAD:
			fmt.printf("lua.thread@{}", lua.topointer(L, i))
		}
		if i < n do fmt.print(" ")
	}
	fmt.println()
	return 0
}




//odinfmt: disable
lua_data_functions :: [?]LuaCustomFunction{
	{ptr=proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		win_i := app.state.lua_win_idx
		we_state := &app.state.we[win_i]
		data_frame := we_state.data_frame
		return _lua_data(L, 0, app, win_i, f32(data_frame))
	}, lua_name = "s"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		win_i := app.state.lua_win_idx
		data_frame := lua.tonumber(L, 1)
		return _lua_data(L, 1, app, win_i, f32(data_frame))
	}, lua_name = "fs"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		win_i: int = int(lua.tointeger(L, 1))
		_lua_check_window(L, 1, app, win_i)
		win_i -= 1
		data_frame := lua.tonumber(L, 2)
		return _lua_data(L, 2, app, win_i, f32(data_frame))
	}, lua_name = "wfs"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		win_i := app.state.lua_win_idx
		frame_from := i32(lua.tointeger(L, 1))
		_lua_check_frame(L, 1, win_i, frame_from, app)
		frame_to := i32(lua.tointeger(L, 2))
		_lua_check_frame(L, 2, win_i, frame_to, app)
		we_state := &app.state.we[win_i]
		if frame_from == frame_to { //Because of copy_non_overlapping
			return 0
		}
		context = runtime.default_context()
		undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_i, frame_from)
		we_state.data_frame = frame_to
		for i in 0..<we_state.num_points {
			undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_i, i, frame_to)
		}
		mem.copy_non_overlapping(
			&we_state.data[data_index(frame_to,0)],
			&we_state.data[data_index(frame_from,0)],
			int(we_state.num_points)*size_of(f32)
		)
		return 0
	}, lua_name = "copy"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		win_i := app.state.lua_win_idx
		frame_from := i32(lua.tointeger(L, 1))
		_lua_check_frame(L, 1, win_i, frame_from, app)
		frame_to := i32(lua.tointeger(L, 2))
		_lua_check_frame(L, 2, win_i, frame_to, app)
		we_state := &app.state.we[win_i]
		if frame_from == frame_to { //Because of copy_non_overlapping
			return 0
		}
		context = runtime.default_context()
		undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_i, frame_from)
		we_state.data_frame = frame_to
		for i in 0..<we_state.num_points {
			undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_i, i, frame_to)
		}
		mem.copy_non_overlapping(
			&we_state.data[data_index(frame_to,0)],
			&we_state.data[data_index(frame_from,0)],
			int(we_state.num_points)*size_of(f32)
		)
		for i in 0..<we_state.num_points {
			undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_i, i, frame_from)
			we_state.data[data_index(frame_from,u32(i))] = 0
		}
		return 0
	}, lua_name = "move"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		win_i := app.state.lua_win_idx
		frame_from := i32(lua.tointeger(L, 1))
		_lua_check_frame(L, 1, win_i, frame_from, app)
		frame_to := i32(lua.tointeger(L, 2))
		_lua_check_frame(L, 2, win_i, frame_to, app)
		we_state := &app.state.we[win_i]
		if frame_from == frame_to { //Because of copy_non_overlapping
			return 0
		}
		context = runtime.default_context()
		undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_i, frame_from)
		we_state.data_frame = frame_to
		for i in 0..<we_state.num_points {
			undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_i, i, frame_to)
			undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_i, i, frame_from)
			tmp := we_state.data[data_index(frame_from, u32(i))]
			we_state.data[data_index(frame_from, u32(i))] = we_state.data[data_index(frame_to, u32(i))]
			we_state.data[data_index(frame_to, u32(i))] = tmp
		}
		return 0
	}, lua_name = "swap"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 0)
		we_state := &app.state.we[win_i]
		context = runtime.default_context()
		undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_i, frame)
		for i in 0..<we_state.num_points {
			undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_i, i, frame)
			we_state.data[data_index(frame, u32(i))] = 0
		}
		return 0
	}, lua_name = "delete"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 0)
		we_state := &app.state.we[win_i]
		lua.createtable(L, c.int(we_state.num_points), 0)
		for i in 0..<u32(we_state.num_points) {
			lua.pushnumber(L, lua.Number(we_state.data[data_index(frame, i)]))
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		return 1
	}, lua_name = "table_r"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		if !lua.istable(L, 1) {
			lua.L_argerror(L, 1, "Argument must be a table")
		}	
		lua.pushnil(L)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		we_state := &app.state.we[win_i]
		we_state.data_frame = frame
		for lua.next(L, 1) != 0 {
			if lua.isinteger(L, -2) && lua.isnumber(L, -1) {
				context = runtime.default_context()
				undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_i, frame)
				lua_i:int = int(lua.tointeger(L, -2))
				data_f:f32 = f32(lua.tonumber(L, -1))
				if lua_i > 0|| i32(lua_i) <= we_state.num_points {
					i := lua_i - 1
					undo_redo_manager_undo_wedraw(&we_state.undo_redo, app, win_i, i32(i), frame)
					we_state.data[data_index(frame,u32(i))] = data_f
				}
			}
			lua.pop(L, 1)
		}
		return 0
	}, lua_name = "table_w"},
}//odinfmt: enable
lua_apply_preset :: proc "c" (L: ^lua.State) -> c.int {
	app := lua_get_app(L)
	preset_value := LuaPresetChoose(lua.tointeger(L, 1))
	frame, win_i := _lua_check_frame_window(L, app, 1)
	we_state := &app.state.we[win_i]
	context = runtime.default_context()
	undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_i, frame)
	we_state.data_frame = frame
	switch preset_value {
	case .empty:
		preset_empty(app, win_i, false)
	case .sine:
		preset_sine(app, win_i, false)
	case .square:
		preset_square(app, win_i, false)
	case .sawtooth:
		preset_sawtooth(app, win_i, false)
	case .triangle:
		preset_triangle(app, win_i, false)
	case .half_sine:
		preset_half_sine(app, win_i, false)
	case:
		lua.L_error(L, "At argument#1, Invalid preset enum")
	}
	return 0
}




//odinfmt: disable
lua_harmonics_functions :: [?]LuaCustomFunction{
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		context = runtime.default_context()
		frame, win_i := _lua_check_frame_window(L, app, 0)
		app.state.we[win_i].data_frame = frame
		harmonics_update_model(app, win_i)
		return 0
	}, lua_name = "update"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		context = runtime.default_context()
		frame, win_i := _lua_check_frame_window(L, app, 0)
		app.state.we[win_i].data_frame = frame
		harmonics_apply(app, win_i, false)
		return 0
	}, lua_name = "apply"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		wfm := &app.state.we_h_wfs[win_i]
		low_pass_v:f32 = f32(lua.tonumber(L, 1))
		clamp := effect_pass_clamp(wfm)
		_lua_waveform_check_clamp_or_error(L, 1, low_pass_v, clamp.min, clamp.max)
		app.state.we[win_i].data_frame = frame
		harmonics_update_model(app, win_i)
		effect_low_pass(app, win_i, low_pass_v, false)
		return 0
	}, lua_name = "low_pass"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		wfm := &app.state.we_h_wfs[win_i]
		high_pass_v:f32 = f32(lua.tonumber(L, 1))
		clamp := effect_pass_clamp(wfm)
		_lua_waveform_check_clamp_or_error(L, 1, high_pass_v, clamp.min, clamp.max)
		app.state.we[win_i].data_frame = frame
		harmonics_update_model(app, win_i)
		effect_high_pass(app, win_i, high_pass_v, false)
		return 0
	}, lua_name = "high_pass"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 0)
		app.state.we[win_i].data_frame = frame
		harmonics_update_model(app, win_i)
		effect_odd_harmonics_only(app, win_i, false)
		return 0
	}, lua_name = "only_odd"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 0)
		app.state.we[win_i].data_frame = frame
		harmonics_update_model(app, win_i)
		effect_even_harmonics_only(app, win_i, false)
		return 0
	}, lua_name = "only_even"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		wfm := &app.state.we_h_wfs[win_i]
		amp_i := lua.tointeger(L, 1)
		_lua_check_harmonic_index(L, wfm, amp_i, true)
		app.state.we[win_i].data_frame = frame
		lua.pushnumber(L, lua.Number(wfm.amp[amp_i]))
		return 1
	}, lua_name = "amplitude_r"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 2)
		wfm := &app.state.we_h_wfs[win_i]
		amp_i := lua.tointeger(L, 1)
		_lua_check_harmonic_index(L, wfm, amp_i, true)
		app.state.we[win_i].data_frame = frame
		new_value: f32 = f32(lua.tonumber(L, 2))
		wfm.amp[amp_i] = new_value
		return 0
	}, lua_name = "amplitude_w"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		wfm := &app.state.we_h_wfs[win_i]
		ph_i := lua.tointeger(L, 1)
		_lua_check_harmonic_index(L, wfm, ph_i, false)
		app.state.we[win_i].data_frame = frame
		lua.pushnumber(L, lua.Number(wfm.phase[ph_i]))
		return 1
	}, lua_name = "phase_r"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		context = runtime.default_context()
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 1)
		wfm := &app.state.we_h_wfs[win_i]
		we_state := &app.state.we[win_i]
		we_state.data_frame = frame
		ph_i := lua.tointeger(L, 1)
		_lua_check_harmonic_index(L, wfm, ph_i, false)
		new_value: f32 = f32(lua.tonumber(L, 2))
		wfm.phase[ph_i] = math.mod(new_value,(2 * math.PI))
		return 0
	}, lua_name = "phase_w"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		frame, win_i := _lua_check_frame_window(L, app, 0)
		we_state := &app.state.we[win_i]
		we_state.data_frame = frame
		wfm := &app.state.we_h_wfs[win_i]
		lua.createtable(L, c.int(wfm.n), 1)
		lua.pushstring(L, "dc")
		lua.pushnumber(L, lua.Number(wfm.amp[0]))
		lua.rawset(L, -3)
		for i in 1..=u32(wfm.n) {
			lua.createtable(L, 0, 2)
			lua.pushstring(L, "a")
			lua.pushnumber(L, lua.Number(wfm.amp[i]))
			lua.rawset(L, -3)
			lua.pushstring(L, "p")
			lua.pushnumber(L, lua.Number(wfm.phase[i]))
			lua.rawset(L, -3)
			lua.rawseti(L, -2, lua.Integer(i)) //table1[i] = table2{'a'=...,'p'=...}
		}
		return 1
	}, lua_name = "table_r"},
	{ptr = proc "c" (L: ^lua.State) -> c.int {
		app := lua_get_app(L)
		table_i :: 1
		if !lua.istable(L, table_i) {
			lua.L_error(L, "Argument #1 must be a table")
		}
		frame, win_i := _lua_check_frame_window(L, app, 1)
		we_state := &app.state.we[win_i]
		we_state.data_frame = frame
		wfm := &app.state.we_h_wfs[win_i]
		lua.pushstring(L, "dc")
		lua.rawget(L, table_i)
		if lua.isnumber(L, -1) {
			wfm.amp[0] = f32(lua.tonumber(L, -1))
		}
		lua.pop(L, 1)
		lua.pushnil(L)
		for lua.next(L, table_i) != 0 { //[table, ..., (nil or i)] -> [table, ..., i, table[i]=table2] or [table, ..., nil]
			pop_n:c.int = 1
			if lua.isinteger(L, -2) {
				if lua.istable(L, -1) {
					i := lua.tointeger(L, -2)
					if i > 0 && i <= lua.Integer(wfm.n) {
						lua.pushstring(L, "a")
						lua.rawget(L, -2) //[table, ..., i, table2, 'a' -> table2.a]
						if lua.isnumber(L, -1) {
							wfm.amp[i] = f32(lua.tonumber(L, -1))
						}
						lua.pushstring(L, "p")
						lua.rawget(L, -3) //[table, ..., i, table2, table2.a, 'p' -> table2.p]
						if lua.isnumber(L, -1) {
							wfm.phase[i] = f32(lua.tonumber(L, -1))
						} 
						pop_n = 3
					}
				}
			} //All [table, ..., i]
			lua.pop(L, pop_n)
		}
		return 0
	}, lua_name = "table_w"},
}//odinfmt: enable
_lua_check_harmonic_index :: proc "c" (
	L: ^lua.State,
	wfm: ^fm.Waveform_Model,
	amp_i: lua.Integer,
	inc_0: bool,
) {
	less_than: bool = ---
	if inc_0 do less_than = amp_i < 0
	else do less_than = amp_i < 1
	if less_than || int(amp_i) > wfm.n {
		lua.L_error(
			L,
			"At argument #1, harmonic index must be between [%d, %d] (floor(samples / 2) + 1)",
			0 if inc_0 else 1,
			wfm.n,
		)
	}
}
lua_map :: proc "c" (L: ^lua.State) -> c.int {
	table_i :: 1
	func_i :: 2
	if !lua.istable(L, table_i) {
		lua.L_argerror(L, table_i, "Argument 1 must be a table")
	}
	if !lua.isfunction(L, func_i) {
		lua.L_argerror(
			L,
			func_i,
			"Argument 2 must be a function of type f(anytype, [idx, [table]]) -> anytype|nil",
		)
	}
	lua.pushnil(L)
	for lua.next(L, table_i) != 0 { 	//[table, lfunc, (nil or i)] -> [table, lfunc, i, table[i]=v] or [table, lfunc, nil]
		if lua.isinteger(L, -2) {
			i := lua.tointeger(L, -2)
			lua.pushvalue(L, func_i)
			lua.insert(L, -2) //[table, lfunc, i, lfunc, v]
			lua.pushvalue(L, -3)
			lua.pushvalue(L, table_i) //[table, lfunc, i, lfunc, v, i, table]
			lua.call(L, 3, 1, 0) //[table, lfunc, i, new_v] or (error)
			lua.rawseti(L, table_i, i) //[table, lfunc, i]
		} else { 	//Both [table, lfunc, i]
			lua.pop(L, 1)
		}
	}
	lua.pushvalue(L, table_i)
	return 1
}
_lua_data :: proc "c" (
	L: ^lua.State,
	shift_by: c.int,
	app: ^App,
	win_i: int,
	data_frame: f32,
) -> c.int {
	context = runtime.default_context()
	we_state := &app.state.we[win_i]
	n := lua.gettop(L)
	if n <= shift_by {
		lua.L_error(L, "%d or %d arguments are required", shift_by + 1, shift_by + 2)
	} else if n == shift_by + 1 {
		data_f := lua.tonumber(L, shift_by + 1)
		_, rem := math.modf(f32(data_f))
		data_i_int: i32 = i32(pmod(f32(data_f), f32(we_state.num_points)))
		_, frame_rem := math.modf(f32(data_frame))
		data_frame_int: i32 = i32(pmod(data_frame, f32(we_state.num_frames)))
		switch {
		case rem <= math.F32_EPSILON && frame_rem <= math.F32_EPSILON:
			lua.pushnumber(
				L,
				lua.Number(app.state.we[win_i].data[data_index(data_frame_int, u32(data_i_int))]),
			)
			return 1
		case rem > math.F32_EPSILON && frame_rem <= math.F32_EPSILON:
			slope :=
				app.state.we[win_i].data[data_index(data_frame_int, u32((data_i_int + 1) % we_state.num_points))] -
				app.state.we[win_i].data[data_index(data_frame_int, u32(data_i_int))]
			lua.pushnumber(
				L,
				lua.Number(
					app.state.we[win_i].data[data_index(data_frame_int, u32(data_i_int))] +
					slope * rem,
				),
			)
			return 1
		case rem <= math.F32_EPSILON && frame_rem > math.F32_EPSILON:
			slope :=
				app.state.we[win_i].data[data_index((data_frame_int + 1) % we_state.num_frames, u32(data_i_int))] -
				app.state.we[win_i].data[data_index(data_frame_int, u32(data_i_int))]
			lua.pushnumber(
				L,
				lua.Number(
					app.state.we[win_i].data[data_index(data_frame_int, u32(data_i_int))] +
					slope * frame_rem,
				),
			)
			return 1
		case: //TODO: Check
			//Bilinear interpolation a + bx + cy + dxy, a = z_00, b = z_10 - z_00, c = z_01 - z_00, d = z_11 - z_10 - z_01 + z_00
			z00 := app.state.we[win_i].data[data_index(data_frame_int, u32(data_i_int))]
			z10 :=
				app.state.we[win_i].data[data_index(data_frame_int, u32((data_i_int + 1) % we_state.num_points))]
			z01 :=
				app.state.we[win_i].data[data_index((data_frame_int + 1) % we_state.num_frames, u32(data_i_int))]
			z11 :=
				app.state.we[win_i].data[data_index((data_frame_int + 1) % we_state.num_frames, u32((data_i_int + 1) % we_state.num_points))]
			lua.pushnumber(
				L,
				lua.Number(
					z00 +
					(z10 - z00) * rem +
					(z01 - z00) * frame_rem +
					(z11 - z10 - z01 + z00) * rem * frame_rem,
				),
			)
			return 1
		}
	} else if n >= shift_by + 2 {
		data_f := lua.tonumber(L, shift_by + 1)
		assign_f := lua.tonumber(L, shift_by + 2)
		_, rem := math.modf(f32(data_f))
		data_i_int: i32 = i32(pmod(f32(data_f), f32(we_state.num_points)))
		_, frame_rem := math.modf(f32(data_frame))
		data_frame_int: i32 = i32(pmod(data_frame, f32(we_state.num_frames)))
		if rem <= math.F32_EPSILON && frame_rem <= math.F32_EPSILON {
			undo_redo_manager_undo_data_frame(&we_state.undo_redo, app, win_i, data_frame_int)
			undo_redo_manager_undo_wedraw(
				&we_state.undo_redo,
				app,
				win_i,
				i32(data_i_int),
				data_frame_int,
			)
			app.state.we[win_i].data[data_index(data_frame_int, u32(data_i_int))] = f32(assign_f)
			return 0
		} else {
			if rem > math.F32_EPSILON {
				lua.L_argerror(L, 1, "Sample number must be an integer to be assigned")
			}
			if frame_rem > math.F32_EPSILON {
				lua.L_argerror(L, 2, "Frame and sample numbers must be integers to be assigned")
			}
		}
	}
	unreachable()
}

_lua_check_window :: proc "contextless" (L: ^lua.State, arg_i: c.int, app: ^App, win_i: int) {
	if win_i <= 0 || win_i > MAX_WAVEFORM_EDITOR_WINDOWS {
		lua.L_error(
			L,
			"Invalid window index %d at argument #%d. It must be between [1,%d]",
			win_i,
			arg_i,
			MAX_WAVEFORM_EDITOR_WINDOWS,
		)
	} else if !app.windows.waveform_editors[win_i - 1].base.is_active {
		lua.L_error(L, "Window index %d is currently disabled at argument #%d", win_i, arg_i)
	}
}

//Appends arguments for functions as f(args...), f(args...,frame), or f(args...,window,frame) where len(args) = num_args and checks frame/window numbers
_lua_check_frame_window :: proc "contextless" (
	L: ^lua.State,
	app: ^App,
	num_args: c.int,
) -> (
	frame: i32,
	win_i: int,
) {
	n := lua.gettop(L)
	switch n {
	case 0 ..< num_args:
		lua.L_error(L, "This function should have at least %d arguments", num_args)
	case num_args:
		win_i = app.state.lua_win_idx
		frame = app.state.we[win_i].data_frame
	case num_args + 1:
		win_i = app.state.lua_win_idx
		frame = i32(lua.tointeger(L, num_args + 1))
		_lua_check_frame(L, num_args + 1, win_i, frame, app)
	case:
		win_i = int(lua.tointeger(L, num_args + 1))
		_lua_check_window(L, num_args + 1, app, win_i)
		win_i -= 1
		frame = i32(lua.tointeger(L, num_args + 2))
		_lua_check_frame(L, num_args + 2, win_i, frame, app)
	}
	return
}
