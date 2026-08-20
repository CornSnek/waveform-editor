package waveform_editor

import "core:container/handle_map"
import "core:container/queue"
import "core:math"
import "core:strings"

import imgui "imgui:/"

//To make ImGui objects draw based on .scale and app window resizing.
UDim :: struct {
	s: f32, //scale (pixels relative to window)
	o: f32, //offset (pixels)
}
UDim2 :: distinct [2]UDim

//Virtual function pointer defined here. Otherwise, odin will not build/run due to pointer app: ^App
ImGuiF_1BaseP2AppP3RawP :: #type proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr)
vf_1b2a3r_none :: proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr) {}
//Static or Dynamic null-terminated title
IDTitle :: union #no_nil {
	cstring,
	strings.Builder,
}
ImGuiBase :: struct {
	//Todo: Merge ImGuiWindow with this since theres only one subclass (Window)
	id:            IDTitle,
	idx:           int,
	position:      UDim2,
	size:          UDim2,
	_draw:         ImGuiF_1BaseP2AppP3RawP,
	_destroy:      ImGuiF_1BaseP2AppP3RawP,
	_is_shown:     proc(base: ^ImGuiBase) -> bool,
	_set_is_shown: proc(base: ^ImGuiBase, show: bool),
	depends_on:    Maybe(handle_map.Handle16),
	userdata:      rawptr,
	disabled:      bool,
	is_active:     bool,
	handle:        handle_map.Handle16,
}
ImGuiBaseHandle :: struct {
	base:   ^ImGuiBase,
	handle: handle_map.Handle16,
}

ImGuiWindow :: struct {
	base:             ImGuiBase,
	flags:            imgui.WindowFlags,
	container_vf:     ImGuiF_1BaseP2AppP3RawP,
	keep_scroll_here: Maybe(imgui.Vec2),
	show:             bool,
}

imgui_window_new :: proc(
	id: IDTitle,
	win_idx: int,
	position: UDim2,
	size: UDim2,
	flags: imgui.WindowFlags = {},
	container_f: ImGuiF_1BaseP2AppP3RawP = vf_1b2a3r_none,
	destroy_f: ImGuiF_1BaseP2AppP3RawP = vf_1b2a3r_none,
	userdata: rawptr = nil,
	show: bool = true,
) -> ImGuiWindow {
	return {
		base = {
			id = id,
			idx = win_idx,
			position = position,
			size = size,
			_draw = vf_imgui_window_draw,
			_is_shown = f_im_gui_window_is_shown,
			_set_is_shown = f_im_gui_window_set_is_shown,
			_destroy = destroy_f,
			userdata = userdata,
			is_active = true,
		},
		show = show,
		flags = flags,
		container_vf = container_f,
	}
}

imgui_obj_add_handle :: proc(app: ^App, base: ^ImGuiBase) {
	h := handle_map.add(&app.imgui_hm, ImGuiBaseHandle{base = base})
	assert(h.idx != 0)
	base.handle = h
}

udim_get_vec2 :: #force_inline proc(udim: UDim2, width: f32, height: f32) -> imgui.Vec2 {
	return {udim.x.s * width + udim.x.o, udim.y.s * height + udim.y.o}
}
vf_imgui_window_draw :: proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr) {
	self := cast(^ImGuiWindow)base
	if h, exists := base.depends_on.?; exists {
		if handle_map.is_valid(&app.imgui_hm, h) {
			base.disabled = true
		} else {
			base.disabled = false
			base.depends_on = nil
		}
	}
	if self.show {
		imgui.BeginDisabled(base.disabled)
		wflags: imgui.WindowFlags =
			self.flags if app.state.rw_state == .Inactive else self.flags | {.NoResize, .NoMove, .NoCollapse}
		c_str: cstring = ---
		switch v in base.id {
		case cstring:
			c_str = v
		case strings.Builder:
			c_str = cstring(&v.buf[0])
		}
		if imgui.Begin(c_str, &self.show, wflags) {
			if scr, exists := self.keep_scroll_here.?; exists { 	//SetScroll may just revert back to old value, so keep doing it until it has been set
				x_set, y_set: bool
				if scr.x >= 0 {
					x_set = imgui.GetScrollX() == min(math.round(scr.x), imgui.GetScrollMaxX())
				} else do x_set = true
				if scr.y >= 0 {
					y_set = imgui.GetScrollY() == min(math.round(scr.y), imgui.GetScrollMaxY())
				} else do y_set = true
				if x_set && y_set {
					self.keep_scroll_here = nil
				} else {
					imgui.SetScrollX(scr.x)
					imgui.SetScrollY(scr.y)
				}
			}
			cond_flags: imgui.Cond = .Once if app.state.rw_state == .Inactive else .Always
			imgui.SetWindowPos(
				udim_get_vec2(base.position, f32(app.config.width), f32(app.config.height)),
				cond_flags,
			)
			imgui.SetWindowSize(
				udim_get_vec2(base.size, f32(app.config.width), f32(app.config.height)),
				cond_flags,
			)
			self.container_vf(base, app, win_idx, userdata)
		}
		imgui.End()
		imgui.EndDisabled()
	}
	if !self.show && base._destroy != vf_1b2a3r_none {
		queue.push_back(
			&app.state.events_f,
			EventCall{base = base, event_f = base._destroy, userdata = nil, win_idx = win_idx},
		)
	}
}

f_im_gui_window_is_shown :: proc(base: ^ImGuiBase) -> bool {
	self := cast(^ImGuiWindow)base
	return self.show
}

f_im_gui_window_set_is_shown :: proc(base: ^ImGuiBase, show: bool) {
	self := cast(^ImGuiWindow)base
	self.show = show
}

f_remove_handle :: proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr) {
	handle_map.remove(&app.imgui_hm, base.handle)
	base.is_active = false
}
