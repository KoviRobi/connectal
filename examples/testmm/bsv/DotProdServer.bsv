// Copyright (c) 2014 Quanta Research Cambridge, Inc.

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
import FIFOF::*;
import MIMO::*;
import DefaultValue::*;
import SpecialFIFOs::*;
import Vector::*;
import BRAM::*;
import DmaVector::*;
import PortalMemory::*;
import MemTypes::*;
import MemreadEngine::*;
import MemwriteEngine::*;
import MemUtils::*;
import FloatingPoint::*;
import Pipe::*;
import FloatOps::*;
import Timer::*;
import RbmTypes::*;
import Assert::*;
import Connectable::*;
import Clocks::*;
import Gearbox::*;
import XilinxCells::*;
import HostInterface::*;

interface SharedDotProdDebug#(numeric type k);
   interface PipeOut#(Bit#(32)) macCount;
endinterface

interface SharedDotProdServer#(numeric type k);
   interface Put#(MmToken)                 aInput;
   interface Put#(MmToken)                 bInput;
   interface Vector#(k, PipeOut#(MmToken)) pipes;
   interface SharedDotProdDebug#(k) debug;
endinterface

typedef struct {
`ifdef TAGGED_TOKENS
   UInt#(32) row;
   UInt#(32) col;
`endif
   Float v;
   Bool first;
   Bool last;
} MmToken deriving (Eq,Bits);


typedef 8 UB_MulLat; // upper bound on MUL latency?
typedef 8 UB_AddLat; // upper bound on ADD latency?
	   
(* synthesize *)
module  mkSharedInterleavedDotProdServer#(UInt#(TLog#(TMul#(J,K))) label)(SharedDotProdServer#(K))
   provisos(Div#(UB_AddLat,K,gatherSz));
    
   let ub_MulLat = valueOf(UB_MulLat);
   let ub_AddLat = valueOf(UB_AddLat);
   let kk = valueOf(K);

   Bool verbose = False; //label == 0;
   
   Reg#(UInt#(20)) countReg     <- mkReg(0);

   FloatAlu mul   <- mkFloatMultiplier(defaultValue);
   FloatAlu adder <- mkFloatAdder(defaultValue);
   FIFOF#(Float) adder_buffer <- mkSizedFIFOF(valueOf(TMul#(K,gatherSz)));
   
`ifdef TAGGED_TOKENS
   FIFO#(Tuple2#(UInt#(32),UInt#(32))) tag_fifo <- mkSizedFIFO(ub_MulLat); 
   Vector#(K,Reg#(Tuple2#(UInt#(32),UInt#(32)))) tag_regs <- replicateM(mkRegU);
`endif   
   
   Reg#(Bit#(32)) cycles <- mkReg(0);
   rule countCycles;
      cycles <= cycles + 1;
   endrule

   FIFOF#(MmToken)                          afifo   <- mkFIFOF();
   PipeOut#(MmToken)                        aFunnel = toPipeOut(afifo);

   FIFOF#(MmToken)                          bfifo <- mkFIFOF();
   PipeOut#(MmToken)                        bFunnel = toPipeOut(bfifo);

   Reg#(Bit#(16)) firstCnt <- mkReg(0);
   Reg#(Bool)         gReg <- mkReg(False);
   FIFOF#(Float)     gFifo <- mkSizedFIFOF(kk);
   Reg#(Bit#(16))  lastCnt <- mkReg(0);
   Reg#(Bit#(16))gatherCnt <- mkReg(0);

   FIFOF#(Tuple2#(Bool,Bool))    flFifo <- mkSizedFIFOF(ub_MulLat);
   Vector#(K,FIFOF#(MmToken))    dotfifos <- replicateM(mkFIFOF1);
   Reg#(Bit#(TAdd#(1,TLog#(K)))) rowReg <- mkReg(0);
      
   Reg#(Bit#(32)) lastMul <- mkReg(0);
   Reg#(Bit#(32)) lastAcc <- mkReg(0);
   Reg#(Bit#(32)) lastGather <- mkReg(0);
   Reg#(Bit#(32)) macs <- mkReg(0);
   
   let gather_phase = lastCnt == fromInteger(kk);
   
   (* fire_when_enabled *)
   rule connect_adder_buffer;
      match {.acc,.*} <- adder.response.get();
      adder_buffer.enq(acc);
      macs <= macs+1;
   endrule
   
   (* fire_when_enabled *)
   rule multiply;
      lastMul <= cycles;
      let a <- toGet(aFunnel).get();
      let b <- toGet(bFunnel).get();
      flFifo.enq(tuple2(a.first,a.last));
      if (a.first != b.first) 
	 $display("****\n    Warning: a.first=%d != b.first=%d\n****", a.first, b.first);
      if (a.last != b.last) 
	 $display("****\n    Warning: a.last=%d != b.last=%d\n****", a.last, b.last);
      if (verbose) 
	 $display("%08d multiply: label=%d mulin first=%d last=%d", cycles-lastMul, label, a.first, a.last);
      mul.request.put(tuple2(a.v, b.v));
`ifdef TAGGED_TOKENS
      tag_fifo.enq(tuple2(a.row,b.col));
`endif
   endrule
   
   function Action incrementRowReg = 
      (action
	  // I have to do this check (instead of relying on wrap-around) because
	  // rowReg has an extra bit to compenseate for bsc's silly Bit#(0) handling
	  if (rowReg+1 == fromInteger(kk)) rowReg <= 0;
	  else rowReg <= rowReg+1;
       endaction);

   
   (* fire_when_enabled *)
   rule accumulate if (!gather_phase);
      incrementRowReg;
      lastAcc <= cycles;
      match {.first, .last} <- toGet(flFifo).get();
      if (verbose) $display("%08d accumulate: label=%d mulout first=%d last=%d firstCnt=%d lastCnt=%d", 
			    cycles-lastAcc, label, first, last, firstCnt, lastCnt);
      match {.resp,.*} <- mul.response.get;
      let acc = unpack(0);
      if (firstCnt == fromInteger(valueOf(TMul#(K,gatherSz))))
	 acc <- toGet(adder_buffer).get;
      else begin
	 firstCnt <= firstCnt+1;
      end
      adder.request.put(tuple2(resp,acc));
      if(last) begin
	 lastCnt <= lastCnt+1;
      end
`ifdef TAGGED_TOKENS
      let row = rowReg;
      let t <- toGet(tag_fifo).get;
      tag_regs[row] <= t;
`endif
   endrule

   
   (* fire_when_enabled *)
   rule gather if (gather_phase);
      incrementRowReg;
      lastGather <= cycles;
      let row = rowReg;
      let last_row = row == fromInteger(kk-1);
      let last_pass = gatherCnt+1 == fromInteger(valueOf(gatherSz));
      if (verbose)
	 $display("%08d gather: gather=%d row=%d last_pass=%d last_row=%d, gReg=%d", 
		  cycles-lastGather, gatherCnt, row, last_pass, last_row, gReg);
      let x <- toGet(adder_buffer).get;
      if (!last_pass) begin
	 if (last_row) begin
	    if (gReg) gatherCnt <= gatherCnt+1;
	    gReg <= !gReg;
	 end
	 if(gReg) begin
	    let y <- toGet(gFifo).get;
	    adder.request.put(tuple2(x,y));
	 end
	 else begin
	    gFifo.enq(x);
	 end
      end
      else begin
`ifdef TAGGED_TOKENS
      	 let row = tpl_1(tag_regs[row]);
      	 let col = tpl_2(tag_regs[row]);
	 dotfifos[row].enq(MmToken{row:row, col:col, v:x});
`else
	 dotfifos[row].enq(MmToken{v:x});
`endif      
	 if (last_row) begin
	    gatherCnt <= 0;
	    lastCnt <= 0;
	    firstCnt <= 0;
	 end 
      end
   endrule   

   Vector#(K,PipeOut#(MmToken)) dotpipes = map(toPipeOut, dotfifos);

   interface Put aInput;
      method Action put(MmToken a);
   	 afifo.enq(a);
	 countReg <= countReg+1;
      endmethod
   endinterface
   interface Put bInput   = toPut(bfifo);
   interface Vector pipes = dotpipes;
   interface SharedDotProdDebug debug;
      interface PipeOut  macCount = toPipeOut(macs._read);
   endinterface
endmodule : mkSharedInterleavedDotProdServer



interface MmTileDebug;
   interface PipeOut#(Bit#(32)) macCount;
endinterface

interface MmTile;
   interface Vector#(RowsPerTile, Put#(MmToken)) aInputs;
   interface Vector#(RowsPerTile, Put#(MmToken)) bInputs;
   interface Vector#(RowsPerTile, PipeOut#(Vector#(N, MmToken))) fxPipes;
   interface MmTileDebug debug;
endinterface

function Put#(a) toCountedPut(Reg#(Bit#(n)) r, Put#(a) p);
   return (interface Put#(a);
      method Action put(a v);
	 r <= r+1;
	 p.put(v);
      endmethod
      endinterface);
endfunction

(* synthesize *)
module  mkMmTile#(Clock slowClock, Reset slowReset, UInt#(TLog#(T)) tile)(MmTile);

   let rowsPerTile = valueOf(RowsPerTile);
   let kk = valueOf(K);

   Vector#(RowsPerTile, Reg#(Bit#(32))) aMmTokensPutRegs <- replicateM(mkReg(0));
   Vector#(RowsPerTile, Reg#(Bit#(32))) bMmTokensPutRegs <- replicateM(mkReg(0));
   Vector#(RowsPerTile, Reg#(Bit#(32))) aMmTokensReadRegs <- replicateM(mkReg(0));
   Vector#(RowsPerTile, Reg#(Bit#(32))) bMmTokensReadRegs <- replicateM(mkReg(0));

   Vector#(RowsPerTile, FIFOF#(MmToken))   aFifos <- replicateM(mkFIFOF);
   Vector#(RowsPerTile, PipeOut#(MmToken)) aPipes = zipWith(toCountedPipeOut, aMmTokensReadRegs, map(toPipeOut, aFifos));
   Vector#(RowsPerTile,  FIFOF#(MmToken))   bFifos <- replicateM(mkFIFOF);
   Vector#(RowsPerTile,  PipeOut#(MmToken)) bPipes = zipWith(toCountedPipeOut, bMmTokensReadRegs, map(toPipeOut, bFifos));

   function Vector#(k,PipeOut#(MmToken)) getDotProdServerPipes(SharedDotProdServer#(k) s); return s.pipes; endfunction
   Vector#(RowsPerTile, SharedDotProdServer#(K)) fxdotprods <- mapM(mkSharedInterleavedDotProdServer, map(fromInteger,genVector));
   Vector#(RowsPerTile, Vector#(K, PipeOut#(MmToken))) fxpipes = map(getDotProdServerPipes, fxdotprods);
//`define USE_MIMO_DFIFOS // this version is faster
   let fastClock <- exposeCurrentClock();
   let fastReset <- exposeCurrentReset();
`ifndef USE_MIMO_DFIFOS
   Vector#(RowsPerTile, PipeOut#(Vector#(K, MmToken))) fxPipesK <- mapM(mkJoinVector(id), fxpipes);
   Vector#(RowsPerTile, PipeOut#(MmToken)) fxPipes1MmToken <- mapM(mkFunnel1, fxPipesK);
   Vector#(RowsPerTile, PipeOut#(Vector#(1, MmToken))) fxPipes1 = map(mapPipe(replicate), fxPipes1MmToken);
`else
   MIMOConfiguration mimoCfg = defaultValue;
   Vector#(RowsPerTile, MIMO#(K,1,TAdd#(K,1),MmToken)) dfifos <- replicateM(mkMIMO(mimoCfg));
   Vector#(RowsPerTile, PipeOut#(Vector#(1, MmToken))) fxPipes1 = map(toPipeOut, dfifos);
`endif
   Vector#(RowsPerTile, Gearbox#(1, N, MmToken)) gearboxes <- replicateM(mk1toNGearbox(fastClock, fastReset, slowClock, slowReset));
   Vector#(RowsPerTile, PipeIn#(Vector#(1,MmToken))) toGearboxes = map(toPipeIn, gearboxes);
   Vector#(RowsPerTile, PipeOut#(Vector#(N, MmToken))) fromGearboxes = map(toPipeOut, gearboxes);
   mapM(uncurry(mkConnection), zip(fxPipes1, toGearboxes));
   // introduce a buffer to help vivado meet timing on vc707
   Vector#(RowsPerTile, FIFOF#(Vector#(N,MmToken)))    tokenfifos <- replicateM(mkFIFOF(clocked_by slowClock, reset_by slowReset));
   Vector#(RowsPerTile, PipeIn#(Vector#(N,MmToken))) toMmTokenFifos = map(toPipeIn, tokenfifos);
   mapM(uncurry(mkConnection), zip(fromGearboxes, toMmTokenFifos), clocked_by slowClock, reset_by slowReset);
   Vector#(RowsPerTile, PipeOut#(Vector#(N, MmToken))) fxPipesN = map(toPipeOut, tokenfifos);

   FirstLastPipe#(UInt#(MMSize)) firstLastPipe          <- mkFirstLastPipe();
   Vector#(2, PipeOut#(Tuple2#(Bool,Bool))) firstLastPipes <- mkForkVector(firstLastPipe.pipe);

   for (Integer j = 0; j < rowsPerTile; j = j + 1) begin
      //mkConnection(toGet(aPipes[j]), fxdotprods[j].aInput);
      //mkConnection(toGet(bPipes[j]), fxdotprods[j].bInput);
      (* fire_when_enabled *)
      rule connectA;
	 let x <- toGet(aPipes[j]).get;
	 fxdotprods[j].aInput.put(x);
      endrule
      (* fire_when_enabled *)
      rule connectB;
	 let x <- toGet(bPipes[j]).get;
	 fxdotprods[j].bInput.put(x);
      endrule
   end

`ifdef USE_MIMO_DFIFOS
   for (Integer j = 0; j < rowsPerTile; j = j + 1) begin
      rule dotProdValue;
	 Vector#(K,MmToken) vs;
	 for (Integer k = 0; k < kk; k = k + 1) begin
	    let v <- toGet(fxpipes[j][k]).get();
	    vs[k] = v;
	 end	    
	 dfifos[j].enq(fromInteger(kk), vs);
      endrule
   end
`endif

   function Bool fifofNotEmpty(FIFOF#(a) fifof); return fifof.notEmpty(); endfunction
   function Bit#(32) my_add(Tuple2#(Bit#(32),Bit#(32)) ab); match { .a, .b } = ab; return a+b; endfunction
   function PipeOut#(Bit#(32)) dotProdMacCount(SharedDotProdServer#(K) dotprodserver); return dotprodserver.debug.macCount; endfunction
   PipeOut#(Bit#(32)) macCountPipe <- mkReducePipes(my_add, map(dotProdMacCount, fxdotprods));

   interface Vector aInputs = zipWith(toCountedPut, aMmTokensPutRegs, map(toPut, aFifos));
   interface Vector bInputs = zipWith(toCountedPut, bMmTokensPutRegs, map(toPut, bFifos));
   interface Vector fxPipes = fxPipesN;
   interface MmTileDebug debug;
      interface PipeOut macCount = macCountPipe;
   endinterface
endmodule : mkMmTile

typedef struct {
   a xbase;
   a xlimit;
   a xstep;
   a ybase;
   a ylimit;
   a ystep;
} XYRangeConfig#(type a) deriving (Bits, FShow);

interface XYRangePipeIfc#(type a);
   interface PipeOut#(Tuple2#(a,a)) pipe;
   method Action start(XYRangeConfig#(a) cfg);
   method Action display();
endinterface

module mkXYRangePipeOut(XYRangePipeIfc#(a)) provisos (Arith#(a), Bits#(a,awidth), Eq#(a), Ord#(a));
   Reg#(a) x <- mkReg(0);
   Reg#(a) y <- mkReg(0);
   Reg#(a) xbase <- mkReg(0);
   Reg#(a) ybase <- mkReg(0);
   Reg#(a) xstep <- mkReg(0);
   Reg#(a) ystep <- mkReg(0);
   Reg#(a) xlimit <- mkReg(0);
   Reg#(a) ylimit <- mkReg(0);

   interface PipeOut pipe;
      method Tuple2#(a,a) first() if (x < xlimit && y < ylimit);
	 return tuple2(x,y);
      endmethod
      method Action deq if (x < xlimit && y < ylimit);
	 let newx = x;
	 let newy = y+ystep;
	 if (newy >= ylimit && x < xlimit) begin
	    newy = ybase;
	    newx = newx + xstep;
	 end
	 x <= newx;
	 y <= newy;
      endmethod
      method Bool notEmpty();
	 return (x < xlimit && y < ylimit);
      endmethod
   endinterface
   method Action start(XYRangeConfig#(a) cfg) if (x >= xlimit);
      //$display("XYRangePipe x=%d xlimit=%d xstep=%d y=%d ylimit=%d ystep=%d", cfg.xbase, cfg.xlimit, cfg.xstep, cfg.ybase, cfg.ylimit, cfg.ystep);
      x <= cfg.xbase;
      y <= cfg.ybase;
      xbase <= cfg.xbase;
      ybase <= cfg.ybase;
      xstep <= cfg.xstep;
      ystep <= cfg.ystep;
      xlimit <= cfg.xlimit;
      ylimit <= cfg.ylimit;
   endmethod
   method Action display();
      $display("XYRangePipe x=%d xlimit=%d y=%d ylimit=%d xstep=%d ystep=%d", x, xlimit, xstep, y, ylimit, ystep);
   endmethod
endmodule: mkXYRangePipeOut

interface RowColSource#(numeric type dsz, type a);
   interface PipeOut#(a) pipe;
   method Action start(ObjectPointer h, Bit#(ObjectOffsetSize) a, Bit#(ObjectOffsetSize) l, UInt#(32) tag);
   method ActionValue#(Bool) finish();
endinterface

module mkRowSource#(VectorSource#(TMul#(N,32),Vector#(N,Float)) vs) (RowColSource#(TMul#(N,32), Vector#(N,MmToken)));
`ifdef TAGGED_TOKENS
   Reg#(UInt#(32)) col <- mkReg(0);
   FIFOF#(UInt#(32)) tagFifo <- mkSizedFIFOF(4);
`endif
   // perhaps memreadengine could do the labeling
   Reg#(Bit#(ObjectOffsetSize)) countReg <- mkReg(0);
   FIFOF#(Bit#(ObjectOffsetSize)) cmdFifo <- mkSizedFIFOF(4);

   method Action start(ObjectPointer h, Bit#(ObjectOffsetSize) a, Bit#(ObjectOffsetSize) l, UInt#(32) tag);
`ifdef TAGGED_TOKENS
      tagFifo.enq(tag);
`endif
      vs.start(h,a,l);
      cmdFifo.enq(l);
   endmethod 
   method ActionValue#(Bool) finish;
      let rv <- vs.finish;
      return rv;
   endmethod
   interface PipeOut pipe;
      method Vector#(N,MmToken) first;
	 Vector#(N,MmToken) rv;
`ifdef TAGGED_TOKENS
	 for(Integer i = 0; i < valueOf(N); i=i+1)
	    rv[i] = MmToken{row:tagFifo.first, col:col+fromInteger(i), v:vs.pipe.first[i], first:False, last:False};
`else
	 for(Integer i = 0; i < valueOf(N); i=i+1)
	    rv[i] = MmToken{v:vs.pipe.first[i], first:False, last:False};
`endif
	 if (countReg==0)
	    rv[0].first = True;
	 if (countReg+1==cmdFifo.first)
	    rv[valueOf(N)-1].last = True;
	 return rv;
      endmethod
      method Action deq;
	 vs.pipe.deq;
	 //$display("mkRowSource count=%d first=%d last=%d", countReg, firstReg, lastReg);
	 if(countReg+1==cmdFifo.first) begin
	    countReg <= 0;
	    cmdFifo.deq;
`ifdef TAGGED_TOKENS
	    tagFifo.deq;
	    col <= 0;
`endif      
	 end
	 else begin
`ifdef TAGGED_TOKENS
	    col <= col+fromInteger(valueOf(N));
`endif
	    countReg <= countReg + 1;
	 end
      endmethod
      method Bool notEmpty;
`ifdef TAGGED_TOKENS
	 return (tagFifo.notEmpty && vs.pipe.notEmpty);
`else
	 return (vs.pipe.notEmpty);
`endif
      endmethod
   endinterface
endmodule

interface RowColSink#(numeric type dsz, type a);
   interface PipeIn#(a) pipe;
   method Action start(ObjectPointer h, Bit#(ObjectOffsetSize) a, Bit#(ObjectOffsetSize) l);
   method ActionValue#(Bool) finish();
endinterface

function PipeOut#(dtype) getRowColSourcePipe(RowColSource#(dsz,dtype) vs); return vs.pipe; endfunction
function PipeIn#(a) getRowColSinkPipe(RowColSink#(n,a) vs) = vs.pipe;
   
module mkRowColSink#(VectorSink#(TMul#(N,32),Vector#(N,Float)) vs) (RowColSink#(TMul#(N,32), Vector#(N,MmToken)));
   function Float tokenValue(MmToken v) = v.v;
   method Action start(ObjectPointer p, Bit#(ObjectOffsetSize) a, Bit#(ObjectOffsetSize) l);
      vs.start(p,a,l);
   endmethod
   method finish = vs.finish;
   interface PipeIn pipe;
      method Action enq(Vector#(N,MmToken) v);
	 vs.pipe.enq(map(tokenValue,v));
      endmethod
      method Bool notFull = vs.pipe.notFull;
   endinterface
endmodule