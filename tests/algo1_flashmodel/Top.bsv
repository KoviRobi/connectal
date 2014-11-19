/* Copyright (c) 2014 Quanta Research Cambridge, Inc
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
// bsv libraries
import SpecialFIFOs::*;
import Vector::*;
import StmtFSM::*;
import FIFO::*;
import BRAM::*;
import DefaultValue::*;
import Connectable::*;

// connectal libraries
import Leds::*;
import CtrlMux::*;
import Portal::*;
import ConnectalMemory::*;
import MemTypes::*;
import MemServer::*;
import MemServerInternal::*;
import MMU::*;
import MemreadEngine::*;
import MemwriteEngine::*;
import HostInterface::*;

// generated by tool
import MMURequest::*;
import StrstrRequest::*;
import MemServerIndication::*;
import MMUIndication::*;
import StrstrIndication::*;


import NandSimNames::*;
import Strstr::*;
import AuroraCommon::*;
import FlashTop::*;
import FlashRequest::*;
import FlashIndication::*;

interface Top_Pins;
	interface Aurora_Pins#(4) aurora_fmc1;
	interface Aurora_Clock_Pins aurora_clk_fmc1;
endinterface

typedef 128 FlashDataWidth;
typedef 40  FlashAddrWidth;

//module mkConnectalTop#(HostType host) (ConnectalTop#(PhysAddrWidth,128,Empty,1));
module mkConnectalTop#(HostType host) (ConnectalTop#(PhysAddrWidth,DataBusWidth, Top_Pins,1));
	//(StdConnectalDmaTop#(PhysAddrWidth));
   
   Clock clk250 = host.doubleClock;
   Reset rst250 = host.doubleReset;
	
   // strstr algo
   StrstrIndicationProxy strstrIndicationProxy <- mkStrstrIndicationProxy(AlgoIndication);
   Strstr#(128,128) strstr <- mkStrstr(strstrIndicationProxy.ifc);
   StrstrRequestWrapper strstrRequestWrapper <- mkStrstrRequestWrapper(AlgoRequest,strstr.request);
   
   // algo mmu
   MMUIndicationProxy algoMMUIndicationProxy <- mkMMUIndicationProxy(AlgoMMUIndication);
   MMU#(PhysAddrWidth) algoMMU <- mkMMU(0, True, algoMMUIndicationProxy.ifc);
   MMURequestWrapper algoMMURequestWrapper <- mkMMURequestWrapper(AlgoMMURequest, algoMMU.request);

   // backing store mmu
   MMUIndicationProxy backingMMUIndicationProxy <- mkMMUIndicationProxy(BackingStoreMMUIndication);
   MMU#(PhysAddrWidth) backingMMU <- mkMMU(1, True, backingMMUIndicationProxy.ifc);
   MMURequestWrapper backingMMURequestWrapper <- mkMMURequestWrapper(BackingStoreMMURequest, backingMMU.request);
   
   // nand mmu
   MMUIndicationProxy nandMMUIndicationProxy <- mkMMUIndicationProxy(NandMMUIndication);
   MMU#(FlashAddrWidth) nandMMU <- mkMMU(0, False, nandMMUIndicationProxy.ifc);
   MMURequestWrapper nandMMURequestWrapper <- mkMMURequestWrapper(NandMMURequest, nandMMU.request);

   // flash top
   FlashIndicationProxy flashIndicationProxy <- mkFlashIndicationProxy(NandCfgIndication);
   FlashTop flashtop <- mkFlashTop(flashIndicationProxy.ifc, clk250, rst250);
   FlashRequestWrapper flashRequestWrapper <- mkFlashRequestWrapper(NandCfgRequest,flashtop.request);
   
   // host memory server
   MemServerIndicationProxy hostMemServerIndicationProxy <- mkMemServerIndicationProxy(HostMemServerIndication);
   let rcs = cons(strstr.config_read_client,cons(flashtop.hostMemReadClient,nil));
   let wcs = cons(flashtop.hostMemWriteClient,nil);
   MemServer#(PhysAddrWidth,128,1) hostMemServer <- mkMemServerRW(hostMemServerIndicationProxy.ifc, rcs,wcs, cons(algoMMU, cons(backingMMU,nil)));
	//MemServerRequestWrapper hostMemServerRequestWrapper <- mkMemServerRequestWrapper(HostMemServerRequest, hostMemServer.request);

   // flash memory read server
   MemServerIndicationProxy flashMemServerIndicationProxy <- mkMemServerIndicationProxy(NandMemServerIndication);
   MemServer#(FlashAddrWidth,FlashDataWidth,1) flashMemServer <- mkMemServerR(flashMemServerIndicationProxy.ifc, 
									      cons(strstr.haystack_read_client,nil),  
									      cons(nandMMU,nil));
   mkConnection(flashMemServer.masters[0], flashtop.memSlave);
   
   Vector#(12,StdPortal) portals;

   portals[0] = strstrRequestWrapper.portalIfc;
   portals[1] = strstrIndicationProxy.portalIfc; 

   portals[2] = algoMMURequestWrapper.portalIfc;
   portals[3] = algoMMUIndicationProxy.portalIfc;
   
   portals[4] = nandMMURequestWrapper.portalIfc;
   portals[5] = nandMMUIndicationProxy.portalIfc; 
   
   portals[6] = flashRequestWrapper.portalIfc;
   portals[7] = flashIndicationProxy.portalIfc;
   
   portals[8] = hostMemServerIndicationProxy.portalIfc;
   //portals[9] = hostMemServerRequestWrapper.portalIfc;
   portals[9] = flashMemServerIndicationProxy.portalIfc;
   
   portals[10] = backingMMURequestWrapper.portalIfc;
   portals[11] = backingMMUIndicationProxy.portalIfc;


   let ctrl_mux <- mkSlaveMux(portals);
   
   interface interrupt = getInterruptVector(portals);
   interface slave = ctrl_mux;
   interface masters = hostMemServer.masters;
   interface leds = default_leds;
	interface Top_Pins pins;
		interface Aurora_Pins aurora_fmc1 = flashtop.aurora_fmc1;
		interface Aurora_Clock_Pins aurora_clk_fmc1 = flashtop.aurora_clk_fmc1;
	endinterface
      
endmodule : mkConnectalTop


