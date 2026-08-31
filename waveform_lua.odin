#+feature dynamic-literals
package waveform_editor

import "core:c"
import "core:container/handle_map"
import "core:container/queue"
import "core:fmt"
import "core:sort"
import "core:strings"

import imgui "imgui:."
import lua "vendor:lua/5.4"

LuaCustomDescMap :: map[cstring]cstring //As map[lua_full_path]desc
lua_desc_map: LuaCustomDescMap
lua_desc_keys: [dynamic]cstring
WELuaState :: struct {
	text_buf: [dynamic]u8,
}

we_lua_state_new :: proc(app: ^App) -> WELuaState {
	self: WELuaState
	self.text_buf = make([dynamic]u8, 1)
	return self
}

we_lua_state_destroy :: proc(self: ^WELuaState) {
	delete(self.text_buf)
}

lua_window_new :: proc(we_base: ^ImGuiWindow, app: ^App, win_idx: int) {
	if !app.windows.lua[win_idx].is_active {
		app.state.we_luas[win_idx] = we_lua_state_new(app)
		id_sb := strings.builder_make()
		fmt.sbprintf(&id_sb, "Lua %d\x00", win_idx + 1)
		app.windows.lua[win_idx] = imgui_window_new(
			id_sb,
			win_idx,
			{{we_base.size.x.s / 2, 0}, {we_base.position.y.s + we_base.size.y.s, 0}},
			{{we_base.size.x.s / 2, 0}, {we_base.size.y.s, 0}},
			{.MenuBar, .HorizontalScrollbar},
			container_f = f_we_lua_draw,
			destroy_f = f_we_lua_destroy,
		)
		imgui_window_add_handle(app, &app.windows.lua[win_idx])
	} else do app.windows.lua[win_idx].show = false
}

f_we_lua_draw :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	window_size := imgui.GetContentRegionAvail()
	we_lua_state := &app.state.we_luas[win_idx]
	imgui.InputTextMultiline(
		"##Lua Input",
		cstring(&we_lua_state.text_buf[0]),
		len(we_lua_state.text_buf),
		size = window_size,
		flags = {.WordWrap, .CallbackResize, .AllowTabInput},
		callback = input_text_resize,
		user_data = &we_lua_state.text_buf,
	)
	imgui.SetNextItemWidth(-1)
	we_state := &app.state.we[win_idx]
	if imgui.BeginMenuBar() {
		defer imgui.EndMenuBar()
		if imgui.BeginMenu("File") {
			defer imgui.EndMenu()
			if imgui.MenuItem("Load Script", "Ctrl+Shift+O") {
				we_lua_load_save(base, app, win_idx, .LoadLuaScript)
			}
			if imgui.MenuItem("Save Script", "Ctrl+S") {
				we_lua_load_save(base, app, win_idx, .SaveLuaScript)
			}
		}
		if imgui.BeginMenu("Edit") {
			defer imgui.EndMenu()
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
			if imgui.MenuItem("Run Lua Script", "Ctrl+R") {
				input_text_shrink(&we_lua_state.text_buf)
				we_lua_process_text(app, win_idx, we_lua_state)
			}
		}
		if imgui.BeginMenu("Window") {
			defer imgui.EndMenu()
			if imgui.MenuItem(
				"Show Output Log",
				"Ctrl+O",
				selected = app.windows.output_log.show,
			) {
				app.windows.output_log.show = !app.windows.output_log.show
			}
		}
		if imgui.BeginMenu("Help") {
			defer imgui.EndMenu()
			if imgui.MenuItem("API", "Ctrl+H") {
				we_lua_open_help(app, win_idx)
			}
		}
	}
	no_kb: if imgui.IsWindowFocused() {
		if imgui.IsKeyDown(.ImGuiMod_Ctrl) {
			if imgui.IsKeyPressed(.R) {
				input_text_shrink(&we_lua_state.text_buf)
				we_lua_process_text(app, win_idx, we_lua_state)
			}
			if imgui.IsKeyPressed(.S) {
				we_lua_load_save(base, app, win_idx, .SaveLuaScript)
			}
			if imgui.IsKeyDown(.ImGuiMod_Shift) {
				if imgui.IsKeyPressed(.O) {
					we_lua_load_save(base, app, win_idx, .LoadLuaScript)
				}
			}
		}
		if imgui.IsAnyItemActive() do break no_kb
		if imgui.IsKeyDown(.ImGuiMod_Ctrl) {
			if !imgui.IsKeyDown(.ImGuiMod_Shift) {
				if imgui.IsKeyPressed(.O) {
					app.windows.output_log.show = !app.windows.output_log.show
				}
			}
			if imgui.IsKeyPressed(.H) {
				we_lua_open_help(app, win_idx)
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
we_lua_load_save :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, fex_type: FileExplorerType) {
	assert(fex_type == .LoadLuaScript || fex_type == .SaveLuaScript)
	if !app.windows.file_explorer.is_active {
		file_explorer_load_idx = win_idx
		fe_h := file_explorer_new(app, fex_type)
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
we_lua_open_help :: proc(app: ^App, win_idx: int) {
	if lua_desc_map == nil {
		lua_desc_map = make(LuaCustomDescMap)
		lua_desc_map["window"] = LUA_WINDOW_DESC
		for lmf in lua_math_functions {
			lua_desc_map[lmf.lua_full_path] = lmf.desc
		}
		for lwe in lua_waveform_effects {
			lua_desc_map[lwe.lua_full_path] = lwe.desc
		}
		for ldf in lua_data_functions {
			lua_desc_map[ldf.lua_full_path] = ldf.desc
		}
		for laf in lua_asdr_functions {
			lua_desc_map[laf.lua_full_path] = laf.desc
		}
		lua_desc_map["presets.apply"] = LUA_APPLY_PRESET_DESC
		for lhf in lua_harmonics_functions {
			lua_desc_map[lhf.lua_full_path] = lhf.desc
		}
		lua_desc_map["presets.table"] = LUA_PRESET_TABLE_DESC
		lua_desc_map["map"] = LUA_MAP_DESC
		lua_desc_map["wemath.e"] = "2.71828182845904523536"
		lua_desc_map["wemath.pi"] = "3.14159265358979323846264338327950288"
		lua_desc_map["wemath.tau"] = "6.28318530717958647692528676655900576"
		lua_desc_map["wemath.epsilon"] = "Epsilon (64-bit) = 2.2204460492503131e-016"
		lua_desc_map["wemath.inf"] = "Positive Infinity (64-bit)"
		lua_desc_map["wemath.f32max"] = "3.402823466e+38, or biggest number for a f32 float before reaching infinity\n"
		lua_desc_keys = make([dynamic]cstring)
		for k, _ in lua_desc_map {
			append(&lua_desc_keys, k)
		}
		sort.merge_sort(lua_desc_keys[:])
	}
	if !app.windows.lua_help.is_active {
		app.windows.lua_help = imgui_window_new(
			"Lua API",
			win_idx,
			position = {{}, UDim{o = 20}},
			size = {UDim{s = 0.5}, UDim{o = -20, s = 0.5}},
			container_f = f_lua_help_draw,
			destroy_f = f_lua_help_destroy,
		)
		imgui_window_add_handle(app, &app.windows.lua_help)
		harmonics_update_model(app, win_idx)
	} else do app.windows.lua_help.show = false
}

we_lua_process_text :: proc(app: ^App, win_idx: int, we_lua_state: ^WELuaState) {
	we_state := &app.state.we[win_idx]
	wls := &app.state.we_luas[win_idx]
	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)
	lua.setwarnf(L, lua_warn_f, app)
	lua.pushlightuserdata(L, &LUA_APP_UD_KEY)
	lua.pushlightuserdata(L, app)
	lua.rawset(L, lua.REGISTRYINDEX)
	app.state.lua_win_idx = win_idx
	lua_register_functions(L)

	status: lua.Status = lua.Status(
		lua.L_loadbuffer(L, raw_data(wls.text_buf), c.size_t(len(wls.text_buf) - 1), "script.lua"),
	)
	if status != .OK {
		cstr := lua.tostring(L, -1)
		output_log_printf(&app.state.output_log, .Error, "script.lua", "{}", cstr)
		fmt.println(cstr)
		lua.pop(L, 1)
		return
	}
	for i in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
		if app.windows.waveform_editors[i].is_active {
			undo_redo_manager_undo_add_stop(&we_state.undo_redo)
		}
	}
	lua.pushcfunction(L, lua_do_traceback)
	lua.insert(L, -2) //[text_buf_lua_string, lua_do_traceback]
	status = lua.Status(lua.pcall(L, 0, lua.MULTRET, -2))
	if status != .OK {
		cstr := lua.tostring(L, -1)
		output_log_printf(&app.state.output_log, .Error, "script.lua", "{}", cstr)
		fmt.println(cstr)
		lua.pop(L, 1)
		for i in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
			if app.windows.waveform_editors[i].is_active {
				undo_redo_manager_do_undo(&we_state.undo_redo, app)
				undo_redo_manager_remove_redo(&we_state.undo_redo)
			}
		}
	} else { 	//Remove undo if none were added.
		for i in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
			if app.windows.waveform_editors[i].is_active {
				if !undo_redo_manager_undo_has_no_stop(&we_state.undo_redo) {
					undo_redo_manager_remove_last(&we_state.undo_redo)
				}
				harmonics_update_model(app, i)
			}
		}
	}
}
lua_do_traceback :: proc "c" (L: ^lua.State) -> c.int {
	msg := lua.tostring(L, 1)
	if msg != nil {
		lua.L_traceback(L, L, msg, 1)
	} else {
		lua.pushnil(L)
	}
	return 1
}
lua_warn_f :: proc "c" (userdata: rawptr, msg: rawptr, tocont: c.int) {
	app := cast(^App)userdata
	context = app_context
	assert(tocont == 0 || tocont == 1) //Not sure what causes values not 0 or 1
	if app.state.warn_buf != nil {
		if tocont == 1 {
			append(&app.state.warn_buf, ' ')
			append(&app.state.warn_buf, string(cstring(msg)))
		} else {
			append(&app.state.warn_buf, ' ')
			append(&app.state.warn_buf, string(cstring(msg)))
			append(&app.state.warn_buf, "\x00")
			cstr := cstring(&app.state.warn_buf[0])
			output_log_printf(&app.state.output_log, .Warn, "script.lua", "%s", cstr)
			fmt.printfln("Lua warning: {}", cstr)
			delete(app.state.warn_buf)
			app.state.warn_buf = nil
		}
	} else {
		app.state.warn_buf = make([dynamic]u8)
		append(&app.state.warn_buf, string(cstring(msg)))
		if tocont == 0 {
			append(&app.state.warn_buf, "\x00")
			cstr := cstring(&app.state.warn_buf[0])
			output_log_printf(&app.state.output_log, .Warn, "script.lua", "%s", cstr)
			fmt.printfln("Lua warning: {}", cstr)
			delete(app.state.warn_buf)
			app.state.warn_buf = nil
		}
	}
}

f_we_lua_destroy :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	we_lua_state_destroy(&app.state.we_luas[win_idx])
	handle_map.remove(&app.imgui_hm, base.handle)
	strings.builder_destroy(&base.id.(strings.Builder))
	base.is_active = false
}

f_lua_help_draw :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	imgui.TextWrapped("This table describes the custom lua fields defined for this script.")
	imgui.TextLinkOpenURL("Lua version is 5.4", "https://www.lua.org/manual/5.4/")
	imgui.BeginTable("##Table", 2, imgui.TableFlags_SizingFixedFit | imgui.TableFlags_Borders)
	imgui.TableSetupColumn("Lua Key", {.WidthStretch}, 1)
	imgui.TableSetupColumn("Description", {.WidthStretch}, 3)
	imgui.TableHeadersRow()
	for k in lua_desc_keys {
		imgui.TableNextRow()
		imgui.TableNextColumn()
		imgui.TextWrapped(k)
		imgui.TableNextColumn()
		imgui.TextWrapped(lua_desc_map[k])
	}
	imgui.EndTable()
}

f_lua_help_destroy :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	handle_map.remove(&app.imgui_hm, base.handle)
	base.is_active = false
}
