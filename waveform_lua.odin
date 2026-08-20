#+feature dynamic-literals
package waveform_editor

import "base:runtime"
import "core:c"
import "core:container/handle_map"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:strings"

import imgui "../../shared/odin-imgui/"
import lua "vendor:lua/5.4"


WELuaState :: struct {
	text_buf: [dynamic]u8,
	L:        ^lua.State,
}

we_lua_state_new :: proc(app: ^App) -> WELuaState {
	self: WELuaState
	self.text_buf = make([dynamic]u8, 1)
	return self
}

we_lua_state_destroy :: proc(self: ^WELuaState) {
	delete(self.text_buf)
}

f_we_lua_draw :: proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr) {
	self := cast(^ImGuiWindow)base
	imgui.SetNextItemWidth(-1)
	we_lua_state := &app.state.we_luas[win_idx]
	imgui.InputTextMultiline(
		"##Lua Input",
		cstring(&we_lua_state.text_buf[0]),
		len(we_lua_state.text_buf),
		flags = {.WordWrap, .CallbackResize, .AllowTabInput},
		callback = input_text_resize,
		user_data = &we_lua_state.text_buf,
	)
	imgui.SetNextItemWidth(-1)
	if imgui.Button("Process Lua Script") {
		input_text_shrink(&we_lua_state.text_buf)
		we_lua_process_text(app, win_idx, we_lua_state)
	}
	we_state := &app.state.we[win_idx]
	if imgui.BeginMenuBar() {
		defer imgui.EndMenuBar()
		if imgui.BeginMenu("File") {
			defer imgui.EndMenu()
			if imgui.MenuItem("Load Script") {
				if !app.windows.file_explorer.base.is_active {
					file_explorer_load_idx = win_idx
					fe_h := file_explorer_new(app, .LoadLuaScript)
					self.base.depends_on = fe_h
					refresh_dir_or_root(app)
				} else {
					tooltip_change(
						&app.state.tooltip,
						cstring("File Explorer window already in use"),
						.Error,
						app.state.frames + 3000 / u64(app.config.mspf),
					)
				}
			}
			if imgui.MenuItem("Save Script") {
				if !app.windows.file_explorer.base.is_active {
					file_explorer_load_idx = win_idx
					fe_h := file_explorer_new(app, .SaveLuaScript)
					self.base.depends_on = fe_h
					refresh_dir_or_root(app)
				} else {
					tooltip_change(
						&app.state.tooltip,
						cstring("File Explorer window already in use"),
						.Error,
						app.state.frames + 3000 / u64(app.config.mspf),
					)
				}
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
		}
	}
	no_kb: if imgui.IsWindowFocused() {
		if imgui.IsAnyItemActive() do break no_kb
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

we_lua_process_text :: proc(app: ^App, win_idx: int, we_lua_state: ^WELuaState) {
	we_state := &app.state.we[win_idx]
	wls := &app.state.we_luas[win_idx]
	wls.L = lua.L_newstate()
	defer lua.close(wls.L)
	lua.L_openlibs(wls.L)
	lua.setwarnf(wls.L, lua_warn_f, app)
	lua.pushlightuserdata(wls.L, &LUA_APP_UD_KEY)
	lua.pushlightuserdata(wls.L, app)
	lua.rawset(wls.L, lua.REGISTRYINDEX)
	app.state.lua_win_idx = win_idx
	lua_register_functions(wls.L)

	status: lua.Status = lua.Status(
		lua.L_loadbuffer(
			wls.L,
			raw_data(wls.text_buf),
			c.size_t(len(wls.text_buf) - 1),
			"script.lua",
		),
	)
	if status != .OK {
		log.error("Load error:", lua.tostring(wls.L, -1))
		lua.pop(wls.L, 1)
		return
	}
	for i in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
		if app.windows.waveform_editors[i].base.is_active {
			undo_redo_manager_undo_add_stop(&we_state.undo_redo)
		}
	}
	lua.pushcfunction(wls.L, lua_do_traceback)
	lua.insert(wls.L, -2) //[text_buf_lua_string, lua_do_traceback]
	status = lua.Status(lua.pcall(wls.L, 0, lua.MULTRET, -2))
	if status != .OK {
		log.error(lua.tostring(wls.L, -1))
		lua.pop(wls.L, 1)
		for i in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
			if app.windows.waveform_editors[i].base.is_active {
				undo_redo_manager_do_undo(&we_state.undo_redo, app)
				undo_redo_manager_remove_redo(&we_state.undo_redo)
			}
		}
	} else { 	//Remove undo if none were added.
		for i in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
			if app.windows.waveform_editors[i].base.is_active {
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
	context = runtime.default_context()
	fmt.println(b32(tocont))
	L := app.state.we_luas[app.state.lua_win_idx].L
	if app.state.warn_buf != nil {
		if tocont == 1 {
			append(&app.state.warn_buf, ' ')
			append(&app.state.warn_buf, string(cstring(msg)))
		} else {
			append(&app.state.warn_buf, ' ')
			append(&app.state.warn_buf, string(cstring(msg)))
			append(&app.state.warn_buf, "\x00")
			lua.pushcfunction(L, lua_print)
			lua.pushstring(L, cstring(&app.state.warn_buf[0]))
			lua.call(L, 1, 0)
			delete(app.state.warn_buf)
			app.state.warn_buf = nil
		}
	} else {
		app.state.warn_buf = make([dynamic]u8)
		append(&app.state.warn_buf, "script.Lua warning: ")
		append(&app.state.warn_buf, string(cstring(msg)))
		if tocont == 0 {
			append(&app.state.warn_buf, "\x00")
			lua.pushcfunction(L, lua_print)
			lua.pushstring(L, cstring(&app.state.warn_buf[0]))
			lua.call(L, 1, 0)
			delete(app.state.warn_buf)
			app.state.warn_buf = nil
		}
	}
}

f_we_lua_destroy :: proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr) {
	we_lua_state_destroy(&app.state.we_luas[win_idx])
	handle_map.remove(&app.imgui_hm, base.handle)
	strings.builder_destroy(&base.id.(strings.Builder))
	base.is_active = false
}
