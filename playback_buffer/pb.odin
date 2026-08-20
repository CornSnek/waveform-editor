package playback_buffer

import "core:log"
import "core:mem"
import "core:testing"


FrameRange :: struct {
	start:  u64,
	end:    u64,
	repeat: u64,
}

frame_range_equal :: #force_inline proc(lhs: ^FrameRange, rhs: ^FrameRange) -> bool {
	return lhs.start == rhs.start && lhs.end == rhs.end
}

frame_range_length :: #force_inline proc(fr: ^FrameRange) -> u64 {
	return (fr.end - fr.start) * fr.repeat
}
//Usage:
//
//Push f32 slices with indices (consecutive and increasing for each f32)
//
//Pop f32 slices and return the last index
PlaybackBuffer :: struct($SN: u64, $RN: int) where SN > 0,
	RN > 0 {
	samp_buf:   [SN]f32,
	range_buf:  [RN]FrameRange,
	samp_head:  u64,
	samp_tail:  u64,
	samp_size:  u64,
	range_head: int,
	range_tail: int,
	range_size: int,
}

AppendStatus :: enum {
	Ok,
	Empty,
	SampleBufferFull,
	RangeBufferFull,
}

sample_max_size :: #force_inline proc(self: PlaybackBuffer($SN, $RN)) -> u64 {
	return SN
}
range_max_size :: #force_inline proc(self: PlaybackBuffer($SN, $RN)) -> int {
	return RN
}
samples_left :: #force_inline proc(self: ^PlaybackBuffer($SN, $RN)) -> u64 {
	return SN - self.samp_size
}

@(private = "file")
_append_range :: proc(self: ^PlaybackBuffer($SN, $RN), new_fr: FrameRange) -> bool {
	if self.range_size == RN do return false
	self.range_buf[self.range_head] = new_fr
	self.range_head = (self.range_head + 1) %% RN
	self.range_size += 1
	return true
}

//Fold whenever
//1) last_fr has equal range as new_fr
//2) new_fr range can be connected if last_fr repeat == 1
//3) repeat >= 1 means new_fr has range start changed while repeat is -= 1
//
//Boolean checks if Range can be inserted
@(private = "file")
_add_and_fold_ranges :: proc(self: ^PlaybackBuffer($SN, $RN), new_fr: FrameRange) -> bool {
	assert(new_fr.start <= new_fr.end && new_fr.repeat == 1)
	this_fr := new_fr
	for self.range_size != 0 {
		last_i := (RN + self.range_head - 1) % RN
		last_fr := &self.range_buf[last_i]
		if frame_range_equal(last_fr, &this_fr) {
			last_fr.repeat += 1
			this_fr = last_fr^
			self.range_head = last_i
			self.range_size -= 1
			continue
		}
		if last_fr.end == this_fr.start {
			if last_fr.repeat == 1 {
				last_fr.end = this_fr.end
				this_fr = last_fr^
				self.range_head = last_i
				self.range_size -= 1
				continue
			} else {
				last_fr.repeat -= 1
				this_fr.start = last_fr.start
				return _append_range(self, this_fr)
			}
		}
		break
	}
	return _append_range(self, this_fr)
}

@(require_results)
append :: proc(self: ^PlaybackBuffer($SN, $RN), src: []f32, start: u64) -> AppendStatus {
	src_len := u64(len(src))
	if src_len == 0 {
		return .Empty
	}
	if self.samp_size + src_len > SN {
		return .SampleBufferFull
	}
	if !_add_and_fold_ranges(self, {start = start, end = start + u64(src_len), repeat = 1}) {
		return .RangeBufferFull
	}

	first_chunk_len := min(src_len, SN - self.samp_head)
	mem.copy_non_overlapping(
		&self.samp_buf[self.samp_head],
		&src[0],
		size_of(f32) * int(first_chunk_len),
	)
	if first_chunk_len < src_len {
		second_chunk_len := src_len - first_chunk_len
		mem.copy_non_overlapping(
			&self.samp_buf[0],
			&src[first_chunk_len],
			size_of(f32) * int(second_chunk_len),
		)
	}
	self.samp_head = (self.samp_head + src_len) %% SN
	self.samp_size += src_len
	return .Ok
}

PopStatus :: enum {
	Ok, //idx and num_popped used
	Empty,
	Less, //idx and num_popped used
}

PopResult :: struct {
	idx:        u64,
	num_popped: u64,
	status:     PopStatus,
}

@(require_results)
pop :: proc(self: ^PlaybackBuffer($SN, $RN), dst: []f32) -> PopResult {
	dst_len := u64(len(dst))
	if self.samp_size == 0 {
		return {status = .Empty}
	}
	first_chunk_len := min(dst_len, SN - self.samp_tail, self.samp_size)
	mem.copy_non_overlapping(
		&dst[0],
		&self.samp_buf[self.samp_tail],
		size_of(f32) * int(first_chunk_len),
	)
	rest_size := min(dst_len, self.samp_size)
	if first_chunk_len < rest_size {
		second_chunk_len := rest_size - first_chunk_len
		mem.copy_non_overlapping(
			&dst[first_chunk_len],
			&self.samp_buf[0],
			size_of(f32) * int(second_chunk_len),
		)
	}
	if self.samp_size < dst_len {
		self.samp_tail = (self.samp_tail + self.samp_size) %% SN
		old_samp_size := self.samp_size
		self.samp_size = 0
		return {
			status = .Less,
			idx = _get_index(self, u64(old_samp_size)),
			num_popped = old_samp_size,
		}
	} else {
		self.samp_size -= dst_len
		self.samp_tail = (self.samp_tail + dst_len) %% SN
		return {status = .Ok, idx = _get_index(self, u64(dst_len)), num_popped = dst_len}
	}
}

@(private = "file")
_get_index :: proc(self: ^PlaybackBuffer($SN, $RN), dst_len: u64) -> u64 {
	len_left := dst_len
	for {
		assert(len_left != 0)
		fr := &self.range_buf[self.range_tail]
		fr_len := frame_range_length(fr)
		if len_left > fr_len {
			len_left -= fr_len
			assert(self.range_size > 0)
			self.range_size -= 1
			self.range_tail = (self.range_tail + 1) %% RN
		} else if len_left < fr_len {
			fr_once_len := fr.end - fr.start
			mult := len_left / fr_once_len
			len_left = len_left %% fr_once_len
			if len_left == 0 { 	//Divided evenly, subtract repeat
				fr.repeat -= mult
				return fr.end - 1
			} else if fr.repeat == mult + 1 { 	//Don't add leftover range, use the same pointer
				fr.repeat = 1
				fr.start += len_left
				return fr.start - 1
			} else { 	//Add leftover range if fr.repeat is 2 or greater
				fr.repeat -= mult + 1
				assert(self.range_size != RN)
				self.range_size += 1
				self.range_tail = (RN + self.range_tail - 1) % RN
				self.range_buf[self.range_tail] = {
					start  = fr.start + len_left,
					end    = fr.end,
					repeat = 1,
				}
				return fr.start + len_left - 1
			}
		} else {
			assert(self.range_size > 0)
			self.range_size -= 1
			self.range_tail = (self.range_tail + 1) %% RN
			return fr.end - 1
		}
	}
}

LAST_IDX_NONE: u64 : 0xffffffffffffffff
//Returns LAST_IDX_NONE if empty
last_end :: proc(self: ^PlaybackBuffer($SN, $RN)) -> u64 {
	if self.samp_size == 0 do return LAST_IDX_NONE
	fr_head := &self.range_buf[(RN + self.range_head - 1) % RN]
	return fr_head.end
}

clear :: proc(self: ^PlaybackBuffer($SN, $RN)) {
	self.samp_head = 0
	self.samp_tail = 0
	self.samp_size = 0
	self.range_head = 0
	self.range_tail = 0
	self.range_size = 0
}

@(test)
test_pop :: proc(t: ^testing.T) {
	pb := PlaybackBuffer(10, 10){}
	v := [?]f32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
	_ = append(&pb, v[:], 5)
	v_copy: [5]f32
	res := pop(&pb, v_copy[:])
	log.info(pb, res, v_copy)
	v_copy2: [10]f32
	res = pop(&pb, v_copy2[:])
	log.info(pb, res, v_copy2)
	res = pop(&pb, v_copy2[:])
	log.info(pb, res, v_copy2)
	log.info(last_end(&pb) == LAST_IDX_NONE)
}
@(test)
test_get_index :: proc(t: ^testing.T) {
	RN :: 5
	pb := PlaybackBuffer(15, RN){}
	for _ in 0 ..< 5 {
		_add_and_fold_ranges(&pb, {start = 41, end = 46, repeat = 1})
	}
	testing.expect_value(t, pb.range_size, 1)
	testing.expect_value(t, _get_index(&pb, 25), 45)
	testing.expect_value(t, pb.range_size, 0)
	clear(&pb)
	for leftover_adj in 1 ..= 5 {
		leftover_adj := u64(leftover_adj)
		expect_v := [?]u64{53, 52, 51, 53, 52, 51}
		for dst_len in 1 ..= 5 * 3 + 3 * 4 {
			for _ in 0 ..< 3 {
				_add_and_fold_ranges(&pb, {start = 46, end = 51, repeat = 1})
			}
			for _ in 0 ..< 4 {
				_add_and_fold_ranges(&pb, {start = 51, end = 54, repeat = 1})
			}
			idx := _get_index(&pb, u64(dst_len))
			if dst_len <= 5 * 3 {
				idx_pred := [?]u64{46, 47, 48, 49, 50}
				pred_i := (dst_len - 1) % 5
				testing.expect_value(t, idx, idx_pred[pred_i])
			} else {
				idx_pred := [?]u64{51, 52, 53}
				pred_i := (dst_len - 15 - 1) % 3
				testing.expect_value(t, idx, idx_pred[pred_i])
			}
			leftover := 5 * 3 + 3 * 4 - u64(dst_len)
			if leftover > leftover_adj { 	//Last 6 values should be 51 52 53 51 52 53
				testing.expect_value(
					t,
					_get_index(&pb, leftover - leftover_adj),
					expect_v[leftover_adj],
				)
				testing.expect_value(t, _get_index(&pb, leftover_adj), 53)
				testing.expect_value(t, pb.range_size, 0)
			}
			clear(&pb)
		}
	}
}
@(test)
test_append_range_folding :: proc(t: ^testing.T) {
	RN :: 3
	pb := PlaybackBuffer(15, RN){}
	v := [?]f32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}

	testing.expect_value(t, append(&pb, v[:2], 0), AppendStatus.Ok)
	fr_m1 := pb.range_buf[(RN + pb.range_head - 1) % RN]
	testing.expect_value(t, fr_m1, FrameRange{start = 0, end = 2, repeat = 1})
	testing.expect_value(t, pb.range_size, 1)
	//Connect ranges
	testing.expect_value(t, append(&pb, v[:3], 2), AppendStatus.Ok)
	fr_m1 = pb.range_buf[(RN + pb.range_head - 1) % RN]
	testing.expect_value(t, fr_m1, FrameRange{start = 0, end = 5, repeat = 1})
	testing.expect_value(t, pb.range_size, 1)

	testing.expect_value(t, append(&pb, v[:3], 0), AppendStatus.Ok)
	fr_m2 := pb.range_buf[(RN + pb.range_head - 2) % RN]
	fr_m1 = pb.range_buf[(RN + pb.range_head - 1) % RN]
	testing.expect_value(t, fr_m2, FrameRange{start = 0, end = 5, repeat = 1})
	testing.expect_value(t, fr_m1, FrameRange{start = 0, end = 3, repeat = 1})
	testing.expect_value(t, pb.range_size, 2)
	//Connect ranges + add repeat by 1
	testing.expect_value(t, append(&pb, v[:2], 3), AppendStatus.Ok)
	fr_m1 = pb.range_buf[(RN + pb.range_head - 1) % RN]
	testing.expect_value(t, fr_m1, FrameRange{start = 0, end = 5, repeat = 2})
	testing.expect_value(t, pb.range_size, 1)
	//repeat by -1 and connect ranges
	testing.expect_value(t, append(&pb, v[:2], 5), AppendStatus.Ok)
	fr_m2 = pb.range_buf[(RN + pb.range_head - 2) % RN]
	fr_m1 = pb.range_buf[(RN + pb.range_head - 1) % RN]
	testing.expect_value(t, fr_m2, FrameRange{start = 0, end = 5, repeat = 1})
	testing.expect_value(t, fr_m1, FrameRange{start = 0, end = 7, repeat = 1})
	testing.expect_value(t, pb.range_size, 2)
}
@(test)
test_append_slices :: proc(t: ^testing.T) {
	pb := PlaybackBuffer(10, 1){}
	v := [?]f32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
	testing.expect_value(t, append(&pb, v[:], 0), AppendStatus.Ok)
	testing.expect_value(t, append(&pb, v[:], 0), AppendStatus.SampleBufferFull)
	clear(&pb)
	testing.expect_value(t, append(&pb, v[:3], 0), AppendStatus.Ok)
	testing.expect_value(t, append(&pb, v[:3], 0), AppendStatus.Ok)
	testing.expect_value(t, append(&pb, v[:3], 0), AppendStatus.Ok)
	testing.expect_value(t, append(&pb, v[:1], 0), AppendStatus.RangeBufferFull)
}
