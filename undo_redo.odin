package waveform_editor

import "core:container/queue"
import "core:fmt"
import "core:sync"

CommandType :: enum u8 {
	Stop, //'Null-terminator' as the dequeues continues undo/redo until it reaches this type
	WEFrame, //Command.v = f32
	WEMaxFrames, //Command.v = f32
	WEDraw, //Command.v = f32 and uses Command.bf.frame
	WENumPoints, //Command.v = i32
}

CommandBF :: bit_field u32 {
	type:    CommandType | 3,
	win_idx: u16         | 2,
	idx:     u16         | 11,
	frame:   u16         | 16,
}

CommandStop :: Command{} //CommandType is Stop

CommandValue :: struct #raw_union {
	f: f32,
	i: i32,
}

Command :: struct {
	bf: CommandBF,
	v:  CommandValue,
}

UndoRedoManager :: struct {
	undo_dequeue: queue.Queue(Command),
	redo_dequeue: queue.Queue(Command),
	last_data_frame: Maybe(i32) //For waveform_math_lua.odin to not repeat same frame
}

undo_redo_manager_new :: proc(self: ^UndoRedoManager) {
	self.last_data_frame = nil
	queue.init(&self.undo_dequeue)
	queue.init(&self.redo_dequeue)
}

undo_redo_manager_undo_add_stop :: proc(self: ^UndoRedoManager) {
	self.last_data_frame = nil
	queue.push_back(&self.undo_dequeue, CommandStop)
	undo_redo_manager_remove_redo(self)
}

undo_redo_manager_remove_redo :: #force_inline proc(self: ^UndoRedoManager) {
	queue.clear(&self.redo_dequeue)
}

undo_redo_manager_remove_last :: proc(self: ^UndoRedoManager) {
	queue.pop_back_safe(&self.undo_dequeue)
}

undo_redo_manager_clear :: proc(self: ^UndoRedoManager) {
	self.last_data_frame = nil
	queue.clear(&self.undo_dequeue)
	queue.clear(&self.redo_dequeue)
}

undo_redo_manager_undo_has_no_stop :: proc(self: ^UndoRedoManager) -> bool {
	if queue.len(self.undo_dequeue) == 0 do return true
	return queue.back_ptr(&self.undo_dequeue).bf.type != .Stop
}

undo_redo_manager_undo_wedraw :: proc(
	self: ^UndoRedoManager,
	app: ^App,
	win_idx: int,
	idx: i32,
	frame: i32,
	v_override: Maybe(f32) = nil,
) {
	we_state := &app.state.we[win_idx]
	queue.push_back(
		&self.undo_dequeue,
		Command {
			bf = {type = .WEDraw, idx = u16(idx), win_idx = u16(win_idx), frame = u16(frame)},
			v = {f = v_override.? or_else we_state.data[data_index(frame, u32(idx))]},
		},
	)
}

undo_redo_manager_undo_wenumpoints :: proc(
	self: ^UndoRedoManager,
	app: ^App,
	win_idx: int,
	last_num_points: i32,
) {
	queue.push_back(
		&self.undo_dequeue,
		Command{bf = {type = .WENumPoints, win_idx = u16(win_idx)}, v = {i = last_num_points}},
	)
}

undo_redo_manager_undo_setmaxframes :: proc(
	self: ^UndoRedoManager,
	app: ^App,
	win_idx: int,
	num_frames: i32,
) {
	queue.push_back(
		&self.undo_dequeue,
		Command{bf = {type = .WEMaxFrames, win_idx = u16(win_idx)}, v = {i = num_frames}},
	)
}
undo_redo_manager_undo_data_frame :: proc(
	self: ^UndoRedoManager,
	app: ^App,
	win_idx: int,
	data_frame: i32,
) {
	if ldf, exists := self.last_data_frame.?; exists {
		if ldf == data_frame do return
	}
	self.last_data_frame = data_frame
	queue.push_back(
		&self.undo_dequeue,
		Command{bf = {type = .WEFrame, win_idx = u16(win_idx)}, v = {i = i32(data_frame)}},
	)
}

undo_redo_manager_do_undo :: proc(self: ^UndoRedoManager, app: ^App) {
	self.last_data_frame = nil
	sync.guard(&wp_mutex)
	no_cmds := true
	for queue.len(self.undo_dequeue) != 0 {
		this_cmd := queue.pop_back(&self.undo_dequeue)
		if no_cmds && this_cmd.bf.type != .Stop do queue.push_back(&self.redo_dequeue, CommandStop)
		switch this_cmd.bf.type {
		case .Stop:
			return
		case .WEDraw:
			we_state := &app.state.we[this_cmd.bf.win_idx]
			queue.push_back(
				&self.redo_dequeue,
				Command {
					bf = this_cmd.bf,
					v = {
						f = we_state.data[data_index(i32(this_cmd.bf.frame), u32(this_cmd.bf.idx))],
					},
				},
			)
			we_state.data[data_index(i32(this_cmd.bf.frame), u32(this_cmd.bf.idx))] = this_cmd.v.f
		case .WENumPoints:
			we_state := &app.state.we[this_cmd.bf.win_idx]
			queue.push_back(
				&self.redo_dequeue,
				Command{bf = this_cmd.bf, v = {i = we_state.num_points}},
			)
			we_state.num_points = this_cmd.v.i
		case .WEFrame:
			we_state := &app.state.we[this_cmd.bf.win_idx]
			queue.push_back(
				&self.redo_dequeue,
				Command{bf = this_cmd.bf, v = {i = i32(we_state.data_frame)}},
			)
			we_state.data_frame = i32(this_cmd.v.i)
		case .WEMaxFrames:
			we_state := &app.state.we[this_cmd.bf.win_idx]
			queue.push_back(
				&self.redo_dequeue,
				Command{bf = this_cmd.bf, v = {i = i32(we_state.num_frames)}},
			)
			we_state.num_frames = i32(this_cmd.v.i)
			set_frames(app, int(this_cmd.bf.win_idx), we_state.num_frames)
			we_state.data_frame = min(we_state.data_frame, we_state.num_frames - 1)
		case:
			fmt.panicf("Unimplemented enum value: '{}'", this_cmd.bf.type)
		}
		no_cmds = false
	}
}

undo_redo_manager_do_redo :: proc(self: ^UndoRedoManager, app: ^App) {
	sync.guard(&wp_mutex)
	no_cmds := true
	for queue.len(self.redo_dequeue) != 0 {
		this_cmd := queue.pop_back(&self.redo_dequeue)
		if no_cmds && this_cmd.bf.type != .Stop do queue.push_back(&self.undo_dequeue, CommandStop)
		switch this_cmd.bf.type {
		case .Stop:
			return
		case .WEDraw:
			we_state := &app.state.we[this_cmd.bf.win_idx]
			queue.push_back(
				&self.undo_dequeue,
				Command {
					bf = this_cmd.bf,
					v = {
						f = we_state.data[data_index(i32(this_cmd.bf.frame), u32(this_cmd.bf.idx))],
					},
				},
			)
			we_state.data[data_index(i32(this_cmd.bf.frame), u32(this_cmd.bf.idx))] = this_cmd.v.f
		case .WENumPoints:
			we_state := &app.state.we[this_cmd.bf.win_idx]
			queue.push_back(
				&self.undo_dequeue,
				Command{bf = this_cmd.bf, v = {i = we_state.num_points}},
			)
			we_state.num_points = this_cmd.v.i
		case .WEFrame:
			we_state := &app.state.we[this_cmd.bf.win_idx]
			queue.push_back(
				&self.undo_dequeue,
				Command{bf = this_cmd.bf, v = {i = i32(we_state.data_frame)}},
			)
			we_state.data_frame = i32(this_cmd.v.i)
		case .WEMaxFrames:
			we_state := &app.state.we[this_cmd.bf.win_idx]
			queue.push_back(
				&self.undo_dequeue,
				Command{bf = this_cmd.bf, v = {i = i32(we_state.num_frames)}},
			)
			we_state.num_frames = i32(this_cmd.v.i)
			set_frames(app, int(this_cmd.bf.win_idx), we_state.num_frames)
			we_state.data_frame = min(we_state.data_frame, we_state.num_frames - 1)
		case:
			fmt.panicf("Unimplemented enum value: '{}'", this_cmd.bf.type)
		}
		no_cmds = false
	}
}

undo_redo_manager_destroy :: proc(self: ^UndoRedoManager) {
	queue.destroy(&self.undo_dequeue)
	queue.destroy(&self.redo_dequeue)
}
