//
// Copyright (C) 2014 Jeff Bush
// 
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
// 
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
// 
// You should have received a copy of the GNU Library General Public
// License along with this library; if not, write to the
// Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
// Boston, MA  02110-1301, USA.
//

`include "defines.v"

//
// Track pending L1 misses.  Detect and consolidate multiple faults for the same address.
// Wake threads when loads are satisfied.
//

module l1_miss_queue(
	input                                   clk,
	input                                   reset,

	// Enqueue request
	input                                   enqueue_en,
	input scalar_t                          enqueue_addr,
	input                                   enqueue_is_store,
	input thread_idx_t                      enqueue_thread_idx,

	// Dequeue request
	output logic                            dequeue_ready,
	input                                   dequeue_en,
	output scalar_t                         dequeue_addr,
	output logic                            dequeue_is_store,    

	// From ring controller: check for sent requests.
	input                                   snoop_en,
	input scalar_t                          snoop_addr,
	output logic                            snoop_request_pending,
	output l1_miss_entry_idx_t              snoop_pending_entry,
	output pending_miss_state_t             snoop_state,
	                                        
	// Wake
	input                                   wake_en,
	input l1_miss_entry_idx_t               wake_entry,
	output logic [`THREADS_PER_CORE - 1:0]  wake_oh);

	struct packed {
		logic valid;
		logic[`THREADS_PER_CORE - 1:0] waiting_threads;
		scalar_t address;
		pending_miss_state_t state;
	} pending_entries[`THREADS_PER_CORE];
	
	logic[`THREADS_PER_CORE - 1:0] collided_miss_oh;
	logic[`THREADS_PER_CORE - 1:0] miss_thread_oh;
	logic request_unique;
	logic[`THREADS_PER_CORE - 1:0] send_grant_oh;
	logic[`THREADS_PER_CORE - 1:0] arbiter_request;
	logic[`THREADS_PER_CORE - 1:0] snoop_lookup_oh;
	thread_idx_t send_grant_idx;
	logic snoop_write;
	
	index_to_one_hot #(.NUM_SIGNALS(`THREADS_PER_CORE)) convert_thread(
		.index(enqueue_thread_idx),
		.one_hot(miss_thread_oh));
		
	arbiter #(.NUM_ENTRIES(`THREADS_PER_CORE)) send_arbiter(
		.request(arbiter_request),
		.update_lru(1'b1),
		.grant_oh(send_grant_oh),
		.*);

	one_hot_to_index #(.NUM_SIGNALS(`THREADS_PER_CORE)) convert_send_idx(
		.index(send_grant_idx),
		.one_hot(send_grant_oh));

	assign dequeue_ready = |arbiter_request;
	assign dequeue_addr = pending_entries[send_grant_idx].address;
	assign dequeue_is_store = pending_entries[send_grant_idx].state == PM_WRITE_PENDING;
	
	assign request_unique = !(|collided_miss_oh);
	assign snoop_request_pending = |snoop_lookup_oh;
	assign snoop_write = pending_entries[snoop_pending_entry].state == PM_WRITE_PENDING
		|| pending_entries[snoop_pending_entry].state == PM_WRITE_SENT;
	
	one_hot_to_index #(.NUM_SIGNALS(`THREADS_PER_CORE)) convert_snoop_pending_entry(
		.index(snoop_pending_entry),
		.one_hot(snoop_lookup_oh));

	assign wake_oh = wake_en ? pending_entries[wake_entry].waiting_threads : 0;

	genvar wait_entry;
	generate
		for (wait_entry = 0; wait_entry < `THREADS_PER_CORE; wait_entry++)
		begin
			assign collided_miss_oh[wait_entry] = pending_entries[wait_entry].valid 
				&& pending_entries[wait_entry].address == enqueue_addr;
			assign arbiter_request[wait_entry] = pending_entries[wait_entry].valid
				&& (pending_entries[wait_entry].state == PM_READ_PENDING 
				|| pending_entries[wait_entry].state == PM_WRITE_PENDING);

			always_ff @(posedge clk, posedge reset)
			begin
				if (reset)
				begin
					pending_entries[wait_entry] <= 0;
					snoop_lookup_oh[wait_entry] <= 0;
				end
				else
				begin
					snoop_lookup_oh[wait_entry] <= pending_entries[wait_entry].valid
						&& pending_entries[wait_entry].address == snoop_addr;

					if (enqueue_en && collided_miss_oh[wait_entry])
					begin
						// Miss is already pending. Wait for it.
						// XXX handle case where a pending read request should be promoted to a write
						// invalidate...
						pending_entries[wait_entry].waiting_threads <= pending_entries[wait_entry].waiting_threads
							| miss_thread_oh;
	
						// Upper level 'almost_miss' logic prevents triggering a miss in the same
						// cycle it is satisfied.
						assert(!(wake_en && wake_entry == wait_entry));
						
						if ((pending_entries[wait_entry].state == PM_READ_PENDING
							|| pending_entries[wait_entry].state == PM_READ_SENT)
							&& enqueue_is_store)
						begin
							$display("need to promote request to write");
							$finish;
						end
						
						if (dequeue_en && send_grant_oh[wait_entry])
						begin
							if (pending_entries[wait_entry].state == PM_WRITE_PENDING)
								pending_entries[wait_entry].state <= PM_WRITE_SENT;
							else if (pending_entries[wait_entry].state == PM_READ_PENDING)
								pending_entries[wait_entry].state <= PM_READ_SENT;
						end
					end
					else if (enqueue_en && miss_thread_oh[wait_entry] && request_unique)
					begin
						assert(!pending_entries[wait_entry].valid);
						assert(!(wake_en && wake_entry == wait_entry));
					
						// This miss was not pending, record it now.
						pending_entries[wait_entry].waiting_threads <= miss_thread_oh;
						pending_entries[wait_entry].valid <= 1;
						pending_entries[wait_entry].address <= enqueue_addr;
						pending_entries[wait_entry].state <= enqueue_is_store ? PM_WRITE_PENDING
							: PM_READ_PENDING;
					end
					else if (dequeue_en && send_grant_oh[wait_entry])
					begin
						assert(!(wake_en && wake_entry == wait_entry));
					
						if (pending_entries[wait_entry].state == PM_WRITE_PENDING)
							pending_entries[wait_entry].state <= PM_WRITE_SENT;
						else if (pending_entries[wait_entry].state == PM_READ_PENDING)
							pending_entries[wait_entry].state <= PM_READ_SENT;
					end
					else if (wake_en && wake_entry == wait_entry)
					begin
						assert(pending_entries[wait_entry].valid);
						pending_entries[wait_entry].valid <= 0;
					end
				end
			end
		end
	endgenerate
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:


