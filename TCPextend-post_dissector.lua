-- A Wireshark LUA script to display some additional TCP information.
-- This is a post-dissector script which adds a new tree to the Wireshark view, _TCP extended info_.
--
-- All statistics, except ACK related (delta & ack_sz), are referenced to a single node, usually the sender, and displayed on both sent and received packets.
-- bif:		bytes in flight. This will normally equal the built-in tcp.analysis.bytes_in_flight, however it is 
-- 			also displayed on the ACK packets.
-- max_tx:	maximum size packet the server can send, equal to the client's receive window minus the server's bytes in flight.
-- bsp:		bytes sent since the last push flag.
-- pba:		number of packets between this ACK and the packet it ACKs (equal to the builtin frame.number minus tcp.analysis.acks_frame)
-- 			TODO: this should be count of how many data packets were received, it is currently everything, even non-TCP.
-- delta:	time since the previous packet was transmitted. Unlike the builtin time delta which is relative to the previous displayed packet,
--			this is relative to the previous packet from the matching sender.
-- ack_sz:	size of the segment(s) this ACK is ACKing
-- ip_inc:	incremental value of the IP ID field, ie how much bigger (or smaller) than the previous packet. Useful for spotting out of order packets
--			in situations where the IP ID increments by 1 each packet. If Large Segment Offload is running on the server then expect to see frequent
--			large negative values.
--
-- Chris Gadd
-- https://github.com/gaddman/wireshark-tcpextend
-- v1.1-20150826
--
-- Known limitiations:
-- PBA counts all packets, not just TCP packets

-- declare some fields to be read
local f_tcp_len = Field.new("tcp.len")
local f_tcp_ack = Field.new("tcp.ack")
local f_tcp_push = Field.new("tcp.flags.push")
local f_tcp_seq = Field.new("tcp.seq")
local f_tcp_stream = Field.new("tcp.stream")
local f_tcp_win = Field.new("tcp.window_size")
local f_tcp_src = Field.new("tcp.srcport")
local f_tcp_dst = Field.new("tcp.dstport")
local f_tcp_ack_frm = Field.new("tcp.analysis.acks_frame")
local f_ip_id = Field.new("ip.id")

-- declare (pseudo) protocol
local p_TCPextend = Proto("TCPextend","Extended TCP information")
-- create the fields for this "protocol". These probably shouldn't all be 32 bit integers.
local F_bif = ProtoField.int32("TCPextend.bif","Bytes in Flight")
local F_max_tx = ProtoField.int32("TCPextend.max_tx","Max tx bytes")
local F_bsp = ProtoField.int32("TCPextend.bsp","Bytes since PSH")
local F_pba = ProtoField.int32("TCPextend.pba","Packets before ACK")
local F_delta = ProtoField.relative_time("TCPextend.delta","Time delta")
local F_ack_sz = ProtoField.int32("TCPextend.ack_sz","Size of segment ACKd")
local F_ip_inc = ProtoField.int32("TCPextend.ip_inc","IP ID increment")
-- add the fields to the protocol
p_TCPextend.fields = {F_bif, F_max_tx, F_bsp, F_pba, F_ack_sz, F_delta, F_ip_inc}
-- variables to persist across all packets
local tcpextend_stats = {}

local function reset_stats()
	-- clear stats for a new dissection
	tcpextend_stats = {}	-- declared already outside this function
	-- define/clear variables per stream
	tcpextend_stats.client_time = {}	-- timestamp for this frame
	tcpextend_stats.server_time = {}
	tcpextend_stats.client_port = {}	-- tcp port
	tcpextend_stats.server_port = {}
	tcpextend_stats.client_win = {}		-- window size
	tcpextend_stats.server_win = {}
	tcpextend_stats.client_bsp = {}		-- bytes since push
	tcpextend_stats.server_bsp = {}
	tcpextend_stats.client_pseq = {}	-- sequence number at last push flag (at end of packet, ie tcp.seq + tcp.len - 1)
	tcpextend_stats.server_pseq = {}
	tcpextend_stats.client_ack = {}		-- last ACK value
	tcpextend_stats.server_ack = {}
	tcpextend_stats.client_seq = {}		-- last SEQ value (actually SEQ+LEN-1)
	tcpextend_stats.server_seq = {}
	tcpextend_stats.client_id = {}		-- IP id
	tcpextend_stats.server_id = {}
	-- define/clear variables per stream
	tcpextend_stats.bif = {}
	tcpextend_stats.bsp = {}
	tcpextend_stats.txb = {}
	tcpextend_stats.pba = {}
	tcpextend_stats.delta = {}
	tcpextend_stats.acksz = {}
	tcpextend_stats.ipinc = {}
end

function p_TCPextend.init()
	reset_stats()
end
   
-- function to "postdissect" each frame
function p_TCPextend.dissector(extend,pinfo,tree)

	local tcp_len = f_tcp_len()
	if tcp_len then    -- seems like it should filter out TCP traffic. Maybe there's a way like taps to register the dissector with a filter?
		tcp_len = tcp_len.value
		local pkt_no = pinfo.number -- warning, this will become a large array (of 32bit integers) if lots of packets
		local frame_time = pinfo.rel_ts
		local tcp_stream = f_tcp_stream().value
		local tcp_ack = f_tcp_ack().value
		local tcp_lseq = f_tcp_seq().value + tcp_len - 1
		local tcp_push = f_tcp_push().value
		local tcp_win = f_tcp_win().value
		local tcp_srcport = f_tcp_src().value
		local tcp_dstport = f_tcp_dst().value
		local ip_id = f_ip_id().value

		if not pinfo.visited then
	
			-- set initial values if this stream not seen before            
			if not tcpextend_stats.client_port[tcp_stream] then
				tcpextend_stats.client_port[tcp_stream] = tcp_srcport  -- assuming first packet we see is client to server
				tcpextend_stats.server_port[tcp_stream] = tcp_dstport
				tcpextend_stats.client_win[tcp_stream] = 0
				tcpextend_stats.server_win[tcp_stream] = 0
				tcpextend_stats.client_bsp[tcp_stream] = 0
				tcpextend_stats.server_bsp[tcp_stream] = 0
				tcpextend_stats.client_pseq[tcp_stream] = 0
				tcpextend_stats.server_pseq[tcp_stream] = 0
				tcpextend_stats.client_ack[tcp_stream] = 0
				tcpextend_stats.server_ack[tcp_stream] = 0
				tcpextend_stats.client_seq[tcp_stream] = 0
				tcpextend_stats.server_seq[tcp_stream] = 0
				tcpextend_stats.client_id[tcp_stream] = 0
				tcpextend_stats.server_id[tcp_stream] = 0
				tcpextend_stats.client_time[tcp_stream] = 0
				tcpextend_stats.server_time[tcp_stream] = 0
			end
			-- declare variables local to this packet
			local cbsp = 0
			local sbsp = 0
			local cbif = 0
			local sbif = 0
			local ctxb = 0
			local stxb = 0
			local cdelta = 0
			local sdelta = 0
			local cacksz = 0
			local sacksz = 0
			
			-- calculate depending on which direction this packet is going
			if tcp_srcport == tcpextend_stats.server_port[tcp_stream] then
				-- from server
				-- calculate time since last packet from this endpoint, and store as NStime (seconds,nanoseconds)
				sdelta = frame_time - tcpextend_stats.server_time[tcp_stream]
				local secs, frac = math.modf(sdelta)
				tcpextend_stats.delta[pkt_no] = NSTime(secs, math.modf(frac * 10^9))
				-- set current, and then calculate new bytes since last push
				sbsp = tcp_lseq - tcpextend_stats.server_pseq[tcp_stream]
				cbsp = tcpextend_stats.client_bsp[tcp_stream]
				if tcp_push == true then
					tcpextend_stats.server_bsp[tcp_stream] = 0
					tcpextend_stats.server_pseq[tcp_stream] = tcp_lseq
				else
					-- rather than just add the length, calculate from seq in case we have OOO or retransmitted pkts
					tcpextend_stats.server_bsp[tcp_stream] = tcp_lseq - tcpextend_stats.server_pseq[tcp_stream]
				end
                -- acksz = current ACK - previous ACK
                tcpextend_stats.acksz[pkt_no] = tcp_ack - tcpextend_stats.server_ack[tcp_stream]
				-- txb = receive window - _current_ BiF
				stxb = tcpextend_stats.client_win[tcp_stream] - (tcpextend_stats.server_seq[tcp_stream] - tcpextend_stats.client_ack[tcp_stream] + 1)
				ctxb = tcpextend_stats.server_win[tcp_stream] - (tcpextend_stats.client_seq[tcp_stream] - tcpextend_stats.server_ack[tcp_stream] + 1)
                -- ipinc = how much bigger is this IP ID than previous packet
				if tcpextend_stats.server_id[tcp_stream]>0 then
					-- not the first packet
					tcpextend_stats.ipinc[pkt_no] = ip_id - tcpextend_stats.server_id[tcp_stream]
				end
				-- set/calculate new persistent values
				tcpextend_stats.server_time[tcp_stream] = frame_time
				tcpextend_stats.server_seq[tcp_stream] = tcp_lseq
				tcpextend_stats.server_ack[tcp_stream] = tcp_ack
				tcpextend_stats.server_win[tcp_stream] = tcp_win
				tcpextend_stats.server_id[tcp_stream] = ip_id
			elseif tcp_srcport == tcpextend_stats.client_port[tcp_stream] then
				-- from client
				-- calculate time since last packet from this endpoint, and store as NStime (seconds,nanoseconds)
				cdelta = frame_time - tcpextend_stats.client_time[tcp_stream]
				local secs, frac = math.modf(cdelta)
				tcpextend_stats.delta[pkt_no] = NSTime(secs, math.modf(frac * 10^9))
				-- set current, and then calculate new bytes since last push
				cbsp = tcp_lseq - tcpextend_stats.client_pseq[tcp_stream]
				sbsp = tcpextend_stats.server_bsp[tcp_stream]
				if tcp_push == true then
					tcpextend_stats.client_bsp[tcp_stream] = 0
					tcpextend_stats.client_pseq[tcp_stream] = tcp_lseq
				else
					-- rather than just add the length, calculate from seq in case we have OOO or retransmitted pkts
					tcpextend_stats.client_bsp[tcp_stream] = tcp_lseq - tcpextend_stats.client_pseq[tcp_stream]
				end
                -- acksz = current ACK - previous ACK
                tcpextend_stats.acksz[pkt_no] = tcp_ack - tcpextend_stats.client_ack[tcp_stream]
				-- txb = receive window - _current_ BiF
				ctxb = tcpextend_stats.server_win[tcp_stream] - (tcpextend_stats.client_seq[tcp_stream] - tcpextend_stats.server_ack[tcp_stream] + 1)
				stxb = tcpextend_stats.client_win[tcp_stream] - (tcpextend_stats.server_seq[tcp_stream] - tcpextend_stats.client_ack[tcp_stream] + 1)
                -- ipinc = how much bigger is this IP ID than previous packet
				if tcpextend_stats.client_id[tcp_stream]>0 then
					-- not the first packet
					tcpextend_stats.ipinc[pkt_no] = ip_id - tcpextend_stats.client_id[tcp_stream]
				end
				-- set/calculate new persistent values
				tcpextend_stats.client_time[tcp_stream] = frame_time
				tcpextend_stats.client_seq[tcp_stream] = tcp_lseq
				tcpextend_stats.client_ack[tcp_stream] = tcp_ack
				tcpextend_stats.client_win[tcp_stream] = tcp_win
				tcpextend_stats.client_id[tcp_stream] = ip_id
			end			
			
			-- calculate new bytes in flight
			cbif = tcpextend_stats.client_seq[tcp_stream] - tcpextend_stats.server_ack[tcp_stream] + 1
			sbif = tcpextend_stats.server_seq[tcp_stream] - tcpextend_stats.client_ack[tcp_stream] + 1
			
			-- try to guess which node is the sender, and display some stats based on that
			-- the '=' comparison in case they're both 0 favours download traffic
			if sbif >= cbif then
				-- server is sending data in this stream
				tcpextend_stats.bif[pkt_no] = sbif
				tcpextend_stats.bsp[pkt_no] = sbsp
				tcpextend_stats.txb[pkt_no] = stxb
			else
				-- client is sending data in this stream
				tcpextend_stats.bif[pkt_no] = cbif
				tcpextend_stats.bsp[pkt_no] = cbsp
				tcpextend_stats.txb[pkt_no] = ctxb
			end
			
            -- f_tcp_ack_frm not always available, even if an ACK. If so then pba will be null and not added to the tree
			-- TODO: calculate from SEQ/ACK instead of using Wireshark's builtin tcp.analysis.acks_frame
			tcpextend_stats.pba[pkt_no] = pkt_no - f_tcp_ack_frm().value

		end	-- if packet not visited

		-- packet processed, output to tree
		local subtree = tree:add(p_TCPextend,"TCP extended info")
		subtree:add(F_delta,tcpextend_stats.delta[pkt_no]):set_generated()
		subtree:add(F_bsp,tcpextend_stats.bsp[pkt_no]):set_generated()
		subtree:add(F_bif,tcpextend_stats.bif[pkt_no]):set_generated()
		subtree:add(F_max_tx,tcpextend_stats.txb[pkt_no]):set_generated()
		if tcpextend_stats.pba[pkt_no] then
			subtree:add(F_pba,tcpextend_stats.pba[pkt_no]):set_generated()
		end
		if tcp_ack then
			subtree:add(F_ack_sz,tcpextend_stats.acksz[pkt_no]):set_generated()
		end
		if tcpextend_stats.ipinc[pkt_no] then
			ip_id = subtree:add(F_ip_inc,tcpextend_stats.ipinc[pkt_no]):set_generated()
			if (tcpextend_stats.ipinc[pkt_no]>1) or (tcpextend_stats.ipinc[pkt_no]<0) then -- this may be a bad assumption
				ip_id:add_expert_info(PI_SEQUENCE,PI_WARN,"This packet may be out of order")
			end
		end
	end	-- if a TCP packet
end

-- register protocol as a postdissector
register_postdissector(p_TCPextend)
