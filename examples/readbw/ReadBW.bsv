// Copyright (c) 2013 Quanta Research Cambridge, Inc.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import FIFO::*;
import GetPut::*;
import AxiClientServer::*;
import PcieToAxiBridge::*;
import PortalMemory::*;
import SGList::*;

interface CoreIndication;
    method Action loadValue(Bit#(128) value, Bit#(32) cycles);
    method Action storeAddress(Bit#(64) addr);
endinterface

interface CoreRequest;
    method Action load(Bit#(64) addr, Bit#(32) length);
    method Action store(Bit#(64) addr, Bit#(64) value);

    method Action sglist(Bit#(32) off, Bit#(40) addr, Bit#(32) len);
    method Action paref(Bit#(32) addr, Bit#(32) len);
endinterface

interface ReadBWIndication;
    interface CoreIndication coreIndication;
endinterface

interface ReadBWRequest;
   interface CoreRequest coreRequest;
   interface Axi3Client#(40,128,16,12) m_axi;
   interface TlpTrace trace;
endinterface

instance PortalMemory#(CoreRequest);
endinstance
instance PortalMemory#(ReadBWRequest);
endinstance

module mkReadBWRequest#(ReadBWIndication ind)(ReadBWRequest);

    FIFO#(Bit#(40)) readAddrFifo <- mkFIFO;
    FIFO#(Bit#(4)) readLenFifo <- mkFIFO;
    FIFO#(Bit#(40)) writeAddrFifo <- mkFIFO;
    FIFO#(Bit#(128)) writeDataFifo <- mkFIFO;
    FIFO#(TimestampedTlpData) ttdFifo <- mkFIFO;

    Reg#(Bit#(5)) readBurstCount <- mkReg(0);
    FIFO#(Tuple2#(Bit#(5),Bit#(32))) readBurstCountStartTimeFifo <- mkSizedFIFO(2);

    Reg#(Bit#(32)) timer <- mkReg(0);
    rule updateTimer;
        timer <= timer + 1;
    endrule

   FIFO#(Tuple2#(Bit#(128),Bit#(32))) readDataFifo <- mkSizedFIFO(32);
   rule receivedData;
      let v = readDataFifo.first;
      readDataFifo.deq;
      ind.coreIndication.loadValue(tpl_1(v), tpl_2(v));
   endrule

    interface CoreRequest coreRequest;
        method Action load(Bit#(64) addr, Bit#(32) len);
    	    readAddrFifo.enq(truncate(addr));
	    readLenFifo.enq(truncate(len));
	endmethod: load
        method Action store(Bit#(64) addr, Bit#(64) value);
	    writeAddrFifo.enq(truncate(addr));
	    writeDataFifo.enq({value,value});
	endmethod: store
    endinterface: coreRequest

    interface Axi3Client m_axi;
	interface Axi3WriteClient write;
	   method ActionValue#(Axi3WriteRequest#(40, 12)) address();
	       writeAddrFifo.deq;
	      ind.coreIndication.storeAddress(zeroExtend(writeAddrFifo.first));
	       return Axi3WriteRequest { address: writeAddrFifo.first, burstLen: 0, id: 0 };
	   endmethod
	   method ActionValue#(Axi3WriteData#(128, 16, 12)) data();
	       writeDataFifo.deq;
	       return Axi3WriteData { data: writeDataFifo.first, byteEnable: 16'hffff, last: 1, id: 0 };
	   endmethod
	   method Action response(Axi3WriteResponse#(12) r);
	   endmethod
	endinterface: write
	interface Axi3ReadClient read;
	   method ActionValue#(Axi3ReadRequest#(40, 12)) address();
	       TimestampedTlpData ttd = unpack(0);
	       ttd.unused = 1;
	       Bit#(153) trace = 0;
	       trace[127:64] = zeroExtend(readLenFifo.first + 1);
	       trace[31:0] = readAddrFifo.first[31:0];
	       ttd.tlp = unpack(trace);
	       ttdFifo.enq(ttd);

	       readAddrFifo.deq;
	       readLenFifo.deq;
	       readBurstCountStartTimeFifo.enq(tuple2(zeroExtend(readLenFifo.first)+1, timer));
	       return Axi3ReadRequest { address: readAddrFifo.first, burstLen: readLenFifo.first, id: 0};
	   endmethod
	   method Action data(Axi3ReadResponse#(128, 12) response);

	      let rbc = readBurstCount;
	      if (rbc == 0) begin
		 rbc = tpl_1(readBurstCountStartTimeFifo.first);
	      end

	      let readStartTime = tpl_2(readBurstCountStartTimeFifo.first);
	      let latency = timer - readStartTime;

	      TimestampedTlpData ttd = unpack(0);
	      ttd.unused = 2;
	      Bit#(153) trace = 0;
	      trace[127:96] = response.data[127:96];
	      trace[95:64] = latency;
	      trace[31:0] = zeroExtend(rbc);
	      ttd.tlp = unpack(trace);
	      ttdFifo.enq(ttd);

	      if (rbc == 1) begin
	         readDataFifo.enq(tuple2(response.data, latency));
		 // this request is done, dequeue its information
		 readBurstCountStartTimeFifo.deq;
	      end

	      readBurstCount <= rbc - 1;

	   endmethod
	endinterface: read
    endinterface: m_axi
   interface TlpTrace trace;
      interface Get tlp;
	  method ActionValue#(TimestampedTlpData) get();
	     ttdFifo.deq;
	     return ttdFifo.first();
	  endmethod
      endinterface: tlp
   endinterface: trace
endmodule: mkReadBWRequest
