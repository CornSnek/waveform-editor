package waveform_editor

import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:strings"
import "core:time"

import imgui "imgui:."

OUTPUT_LOG_MAX_MESSAGES :: 200
OutputLog :: struct {
	buf:           [OUTPUT_LOG_MAX_MESSAGES]OutputLogMessage,
	head:          i32,
	tail:          i32,
	show_debug:    bool,
	show_info:     bool,
	show_warn:     bool,
	show_error:    bool,
	scroll_to_end: bool,
}

output_log_new :: proc() -> OutputLog {
	return {show_info = true, show_warn = true, show_error = true, scroll_to_end = true}
}
output_log_print :: proc(
	self: ^OutputLog,
	type: OutputLogMessageType,
	loc: string,
	fmt_str: string,
	args: ..any,
) {
	assert(type != .Uninit)
	next_msg := &self.buf[self.head]
	if next_msg.type != .Uninit {
		output_log_message_destroy(next_msg)
		self.tail = (self.tail + 1) % OUTPUT_LOG_MAX_MESSAGES
	}
	now := time.now()
	next_msg^ = {
		msg  = fmt.aprintf(fmt_str, ..args),
		loc  = loc,
		type = type,
	}
	_ = time.to_string_hms(now, next_msg.time[:])
	self.head = (self.head + 1) % OUTPUT_LOG_MAX_MESSAGES
}
context_log_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	app := cast(^App)data
	ol_type: OutputLogMessageType
	switch level {
	case .Debug:
		ol_type = .Debug
	case .Info:
		ol_type = .Info
	case .Warning:
		ol_type = .Warn
	case .Error, .Fatal:
		ol_type = .Error
	}
	output_log_print(&app.state.output_log, ol_type, "Log", text)
}

output_log_destroy :: proc(self: ^OutputLog) {
	for &olm in self.buf {
		if olm.type != .Uninit {
			output_log_message_destroy(&olm)
		}
	}
}

OutputLogMessageType :: enum {
	Uninit,
	Debug,
	Info,
	Warn,
	Error,
}

OutputLogMessage :: struct {
	msg:  string,
	loc:  string,
	time: [time.MIN_HMS_LEN]u8,
	type: OutputLogMessageType,
}

output_log_message_destroy :: proc(self: ^OutputLogMessage) {
	assert(self.type != .Uninit)
	delete(self.msg)
	self.msg = ""
	self.type = .Uninit
}

OutputLogTypeColor := [OutputLogMessageType]u32be {
	.Uninit = 0x00000000,
	.Debug  = 0xffffffff,
	.Info   = 0xffffffff,
	.Warn   = 0xff7f00ff,
	.Error  = 0xff0000ff,
}
f_output_log_draw :: proc(base: ^ImGuiWindow, app: ^App, win_idx: int, userdata: rawptr) {
	olstate := &app.state.output_log
	type_names := reflect.enum_field_names(OutputLogMessageType)
	next_msg_loop: for count, n := 0, olstate.tail; true; n = (n + 1) % OUTPUT_LOG_MAX_MESSAGES {
		next_msg := &olstate.buf[n]
		if next_msg.type == .Uninit do break
		#partial switch next_msg.type {
		case .Debug:
			if !olstate.show_debug do continue next_msg_loop
		case .Info:
			if !olstate.show_info do continue next_msg_loop
		case .Warn:
			if !olstate.show_warn do continue next_msg_loop
		case .Error:
			if !olstate.show_error do continue next_msg_loop
		}
		msg1 := fmt.tprintf(
			"[{}, {}][{}]\x00",
			transmute(string)next_msg.time[:],
			type_names[int(next_msg.type)],
			next_msg.loc,
		)
		msg2 := fmt.tprintf("{}\x00", next_msg.msg)
		imgui.PushTextWrapPos()
		imgui.TextColored(
			imgui.ColorConvertU32ToFloat4(transmute(u32)(OutputLogTypeColor[next_msg.type])),
			strings.unsafe_string_to_cstring(msg1),
		)
		imgui.SameLine()
		imgui.Text(strings.unsafe_string_to_cstring(msg2))
		imgui.PopTextWrapPos()
		count += 1
		if count == OUTPUT_LOG_MAX_MESSAGES do break
	}
	if olstate.scroll_to_end {
		base.keep_scroll_here = [2]f32{0, imgui.GetScrollMaxY()}
	}
	if imgui.BeginMenuBar() {
		defer imgui.EndMenuBar()
		if imgui.BeginMenu("Filter") {
			defer imgui.EndMenu()
			imgui.Checkbox("Debug", &olstate.show_debug)
			imgui.Checkbox("Info", &olstate.show_info)
			imgui.Checkbox("Warn", &olstate.show_warn)
			imgui.Checkbox("Error", &olstate.show_error)
		}
		if imgui.BeginMenu("Window") {
			defer imgui.EndMenu()
			imgui.Checkbox("Scroll to End", &olstate.scroll_to_end)
		}
	}
}
