(*
 * Copyright (c) 2001 Stefan Kral
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 *)

open List
open Util
open GenUtil
open VSimdBasics
open K7Basics
open K7RegisterAllocationBasics
open K7Translate
open CodeletMisc
open AssignmentsToVfpinstrs


let twiddle_gen n dir =
  let _ = info "generating..." in
  let code  = Fft.twiddle_dit_gen_expr n Symmetry.no_sym Symmetry.no_sym dir in
  let code' = vect_optimize varinfo_twiddle n code in
  let (_, num_twiddle, _) = Twiddle.twiddle_policy () in

  let _ = info "generating k7vinstrs..." in
  let fnarg_inout,fnarg_iostride  = K7_MFunArg 1, K7_MFunArg 3
  and fnarg_w,fnarg_m,fnarg_idist = K7_MFunArg 2,K7_MFunArg 4,K7_MFunArg 5 in

  let (inout,inout2) = makeNewVintreg2 ()
  and (iostride8p,iostride8n,idist8p) = makeNewVintreg3 ()
  and (w, m) = makeNewVintreg2 () in

  let int_initcode = 
	loadfnargs [(fnarg_inout, inout); (fnarg_w, w); (fnarg_m, m)] @
	[
	 (inout2,     get2ndhalfcode inout iostride8p inout2 (pred (msb n)));
	 (idist8p,    [K7V_IntLoadMem(fnarg_idist, idist8p);
		       K7V_IntLoadEA(K7V_SID(idist8p,8,0), idist8p)]);
	 (iostride8p, [K7V_IntLoadMem(fnarg_iostride,iostride8p);
		       K7V_IntLoadEA(K7V_SID(iostride8p,8,0), iostride8p)]);
	 (iostride8n, [K7V_IntCpyUnaryOp(K7_ICopy, iostride8p, iostride8n);
		       K7V_IntUnaryOp(K7_INegate, iostride8n)]);
	] in
  let initcode = map (fun (d,xs) -> AddIntOnDemandCode(d,xs)) int_initcode in
  let do_split = n >= 32 in
  let io_unparser' =
	if do_split then
          ([K7V_RefInts [iostride8n]],
	   strided_complex_split2_unparser 
		(inout,inout2,1 lsl (pred (msb n)),iostride8p))
	else
	  ([], strided_complex_unparser (inout,iostride8p)) in
  let tw_unparser' = ([], unitstride_complex_unparser w) in
  let unparser = make_asm_unparser io_unparser' io_unparser' tw_unparser' in
  let k7vinstrs = 
    if do_split then
	[
	 K7V_RefInts([inout; inout2; w; iostride8p; iostride8n]);
	 K7V_IntUnaryOpMem(K7_IShlImm 3, fnarg_idist);
	 K7V_Label(".L0")
	] @
	(vsimdinstrsToK7vinstrs unparser code') @
	[
	 K7V_IntUnaryOp(K7_IAddImm((num_twiddle n) * 8), w);
	 K7V_IntBinOpMem(K7_IAdd, fnarg_idist, inout);
	 K7V_IntBinOpMem(K7_IAdd, fnarg_idist, inout2);
	 K7V_IntUnaryOpMem(K7_IDec, fnarg_m);
	 K7V_RefInts([inout; inout2; w; iostride8p; iostride8n]);
	 K7V_CondBranch(K7_BCond_NotZero, K7V_BTarget_Named ".L0")
	]
    else
	[
	 K7V_RefInts([inout; w; iostride8p; idist8p; m]);
	 K7V_Label(".L0");
	] @
	(vsimdinstrsToK7vinstrs unparser code') @
	[
	 K7V_IntUnaryOp(K7_IAddImm((num_twiddle n) * 8), w);
	 K7V_IntBinOp(K7_IAdd, idist8p, inout);
	 K7V_IntUnaryOp(K7_IDec, m);
	 K7V_RefInts([inout; w; iostride8p; idist8p; m]);
	 K7V_CondBranch(K7_BCond_NotZero, K7V_BTarget_Named ".L0")
	]
  in
    (n, dir, TWIDDLE, initcode, k7vinstrs)

