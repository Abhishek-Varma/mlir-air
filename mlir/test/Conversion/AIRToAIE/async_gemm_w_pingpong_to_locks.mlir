//===- async_gemm_w_ping_pong_to_locks.mlir --------------------*- MLIR -*-===//
//
// Copyright (C) 2023, Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

// RUN: air-opt -air-to-aie="emit-while-loop=false use-objectfifo=false row-offset=3 col-offset=5 device=xcvc1902" %s | FileCheck %s

// CHECK-LABEL:   aie.device(xcvc1902) {
// CHECK:   %[[VAL_0:.*]] = aie.tile(2, 0)
// CHECK:   %[[VAL_1:.*]] = aie.tile(3, 0)
// CHECK:   %[[VAL_2:.*]] = aie.tile(5, 3)
// CHECK:   %[[VAL_3:.*]] = aie.tile(6, 3)
// CHECK:   %[[VAL_4:.*]] = aie.tile(5, 4)
// CHECK:   %[[VAL_5:.*]] = aie.tile(6, 4)
// CHECK-COUNT-6:    aie.lock(%[[VAL_2]], {{.*}}) {init = 0 : i32}
// CHECK-COUNT-6:    aie.lock(%[[VAL_3]], {{.*}}) {init = 0 : i32}
// CHECK-COUNT-6:    aie.lock(%[[VAL_4]], {{.*}}) {init = 0 : i32}
// CHECK-COUNT-6:    aie.lock(%[[VAL_5]], {{.*}}) {init = 0 : i32}
// CHECK-COUNT-5:    aie.buffer(%[[VAL_5]]) {{{.*}}} : memref<32x32xi32, 2>
// CHECK-COUNT-5:    aie.buffer(%[[VAL_4]]) {{{.*}}} : memref<32x32xi32, 2>
// CHECK-COUNT-5:    aie.buffer(%[[VAL_3]]) {{{.*}}} : memref<32x32xi32, 2>
// CHECK-COUNT-5:    aie.buffer(%[[VAL_2]]) {{{.*}}} : memref<32x32xi32, 2>
// CHECK:   aie.mem(%[[VAL_5]])
// CHECK:   aie.core(%[[VAL_5]]) {
// CHECK:     aie.use_lock({{.*}}, Acquire, 0)
// CHECK:     aie.use_lock({{.*}}, Acquire, 1)
// CHECK:     scf.for
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       linalg.matmul
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       linalg.matmul
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:     }
// CHECK-DAG: aie.use_lock({{.*}}, Release, 1)
// CHECK-DAG: aie.use_lock({{.*}}, Release, 0)
// CHECK:   } {elf_file = 
// CHECK:   aie.mem(%[[VAL_4]])
// CHECK:   aie.core(%[[VAL_4]])
// CHECK:     aie.use_lock({{.*}}, Acquire, 0)
// CHECK:     aie.use_lock({{.*}}, Acquire, 1)
// CHECK:     scf.for
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       linalg.matmul
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       linalg.matmul
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:     }
// CHECK-DAG: aie.use_lock({{.*}}, Release, 1)
// CHECK-DAG: aie.use_lock({{.*}}, Release, 0)
// CHECK:   } {elf_file = 
// CHECK:   aie.mem(%[[VAL_3]])
// CHECK:   aie.core(%[[VAL_3]])
// CHECK:     aie.use_lock({{.*}}, Acquire, 0)
// CHECK:     aie.use_lock({{.*}}, Acquire, 1)
// CHECK:     scf.for
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       linalg.matmul
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       linalg.matmul
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:     }
// CHECK-DAG: aie.use_lock({{.*}}, Release, 1)
// CHECK-DAG: aie.use_lock({{.*}}, Release, 0)
// CHECK:   } {elf_file = 
// CHECK:   aie.mem(%[[VAL_2]])
// CHECK:   aie.core(%[[VAL_2]])
// CHECK:     aie.use_lock({{.*}}, Acquire, 0)
// CHECK:     aie.use_lock({{.*}}, Acquire, 1)
// CHECK:     scf.for
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       linalg.matmul
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       aie.use_lock({{.*}}, Acquire, 1)
// CHECK:       linalg.matmul
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:       aie.use_lock({{.*}}, Release, 0)
// CHECK:     }
// CHECK-DAG: aie.use_lock({{.*}}, Release, 1)
// CHECK-DAG: aie.use_lock({{.*}}, Release, 0)
// CHECK:   } {elf_file = 

#map = affine_map<()[s0] -> (s0 * 32)>
#set = affine_set<()[s0, s1] : (s0 == 0, s1 >= 0, -s1 + 1 >= 0)>
#set1 = affine_set<()[s0, s1] : (s0 >= 0, -s0 + 1 >= 0, s1 == 0)>
module {
  air.channel @channel_5 [2, 2]
  air.channel @channel_4 [2, 2]
  air.channel @channel_3 [1, 1] {broadcast_shape = [2, 1]}
  air.channel @channel_2 [1, 1] {broadcast_shape = [2, 1]}
  air.channel @channel_1 [1, 1] {broadcast_shape = [1, 2]}
  air.channel @channel_0 [1, 1] {broadcast_shape = [1, 2]}
  func.func @matmul(%arg0: memref<64x512xi32>, %arg1: memref<512x64xi32>, %arg2: memref<64x64xi32>) {
    %c32 = arith.constant 32 : index
    %c512 = arith.constant 512 : index
    %c1 = arith.constant 1 : index
    %c64 = arith.constant 64 : index
    %c0 = arith.constant 0 : index
    %c2 = arith.constant 2 : index
    %async_token, %results = air.execute -> (memref<64x64xi32>) {
      %alloc = memref.alloc() {alignment = 64 : i64} : memref<64x64xi32>
      air.execute_terminator %alloc : memref<64x64xi32>
    }
    %async_token_0 = air.execute [%async_token] {
      memref.copy %arg2, %results : memref<64x64xi32> to memref<64x64xi32>
    }
    %0 = air.wait_all async 
    %1 = scf.for %arg3 = %c0 to %c512 step %c32 iter_args(%arg4 = %0) -> (!air.async.token) {
      %11 = air.channel.put async [%arg4]  @channel_0[] (%arg0[%c0, %arg3] [%c32, %c32] [%c512, %c1]) {id = 1 : i32} : (memref<64x512xi32>)
      scf.yield %11 : !air.async.token
    }
    %2 = air.wait_all async 
    %3 = scf.for %arg3 = %c0 to %c512 step %c32 iter_args(%arg4 = %2) -> (!air.async.token) {
      %11 = air.channel.put async [%arg4]  @channel_1[] (%arg0[%c32, %arg3] [%c32, %c32] [%c512, %c1]) {id = 2 : i32} : (memref<64x512xi32>)
      scf.yield %11 : !air.async.token
    }
    %4 = air.wait_all async 
    %5 = scf.for %arg3 = %c0 to %c512 step %c32 iter_args(%arg4 = %4) -> (!air.async.token) {
      %11 = air.channel.put async [%arg4]  @channel_2[] (%arg1[%arg3, %c0] [%c32, %c32] [%c64, %c1]) {id = 3 : i32} : (memref<512x64xi32>)
      scf.yield %11 : !air.async.token
    }
    %6 = air.wait_all async 
    %7 = scf.for %arg3 = %c0 to %c512 step %c32 iter_args(%arg4 = %6) -> (!air.async.token) {
      %11 = air.channel.put async [%arg4]  @channel_3[] (%arg1[%arg3, %c32] [%c32, %c32] [%c64, %c1]) {id = 4 : i32} : (memref<512x64xi32>)
      scf.yield %11 : !air.async.token
    }
    %8 = scf.parallel (%arg3, %arg4) = (%c0, %c0) to (%c2, %c2) step (%c1, %c1) init (%async_token_0) -> !air.async.token {
      %async_token_1, %results_2 = air.execute -> (index) {
        %12 = affine.apply #map()[%arg3]
        air.execute_terminator %12 : index
      }
      %async_token_3, %results_4 = air.execute -> (index) {
        %12 = affine.apply #map()[%arg4]
        air.execute_terminator %12 : index
      }
      %11 = air.channel.put async [%async_token_3, %async_token_1, %async_token_0]  @channel_4[%arg3, %arg4] (%results[%results_2, %results_4] [%c32, %c32] [%c64, %c1]) {id = 5 : i32} : (memref<64x64xi32>)
      scf.reduce(%11 : !air.async.token) {
      ^bb0(%arg5: !air.async.token, %arg6: !air.async.token):
        %12 = air.wait_all async [%arg5, %arg6] 
        scf.reduce.return %12 : !air.async.token
      }
    }
    %9 = scf.parallel (%arg3, %arg4) = (%c0, %c0) to (%c2, %c2) step (%c1, %c1) init (%async_token_0) -> !air.async.token {
      %async_token_1, %results_2 = air.execute -> (index) {
        %12 = affine.apply #map()[%arg3]
        air.execute_terminator %12 : index
      }
      %async_token_3, %results_4 = air.execute -> (index) {
        %12 = affine.apply #map()[%arg4]
        air.execute_terminator %12 : index
      }
      %11 = air.channel.get async [%async_token_3, %async_token_1, %async_token_0]  @channel_5[%arg3, %arg4] (%results[%results_2, %results_4] [%c32, %c32] [%c64, %c1]) {id = 6 : i32} : (memref<64x64xi32>)
      scf.reduce(%11 : !air.async.token) {
      ^bb0(%arg5: !air.async.token, %arg6: !air.async.token):
        %12 = air.wait_all async [%arg5, %arg6] 
        scf.reduce.return %12 : !air.async.token
      }
    }
    %10 = air.herd @herd_0 async [%async_token_0]  tile (%arg3, %arg4) in (%arg5=%c2, %arg6=%c2) attributes {id = 1 : i32, x_loc = 5 : i64, y_loc = 3 : i64} {
      %c64_1 = arith.constant 64 : index
      %c0_2 = arith.constant 0 : index
      %c512_3 = arith.constant 512 : index
      %11 = air.wait_all async 
      %async_token_4, %results_5 = air.execute -> (memref<32x32xi32, 2>) {
        %alloc = memref.alloc() : memref<32x32xi32, 2>
        air.execute_terminator %alloc : memref<32x32xi32, 2>
      }
      %12 = air.channel.get async [%async_token_4, %11]  @channel_4[%arg3, %arg4] (%results_5[] [] []) {id = 7 : i32} : (memref<32x32xi32, 2>)
      %async_token_6, %results_7 = air.execute [%12] -> (memref<32x32xi32, 2>) {
        %alloc = memref.alloc() : memref<32x32xi32, 2>
        air.execute_terminator %alloc : memref<32x32xi32, 2>
      }
      %async_token_8, %results_9 = air.execute [%async_token_6] -> (memref<32x32xi32, 2>) {
        %alloc = memref.alloc() : memref<32x32xi32, 2>
        air.execute_terminator %alloc : memref<32x32xi32, 2>
      }
      %async_token_10, %results_11 = air.execute [%async_token_8] -> (memref<32x32xi32, 2>) {
        %alloc = memref.alloc() : memref<32x32xi32, 2>
        air.execute_terminator %alloc : memref<32x32xi32, 2>
      }
      %async_token_12, %results_13 = air.execute [%async_token_8] -> (memref<32x32xi32, 2>) {
        %alloc = memref.alloc() : memref<32x32xi32, 2>
        air.execute_terminator %alloc : memref<32x32xi32, 2>
      }
      %13:4 = scf.for %arg7 = %c0_2 to %c512_3 step %c64_1 iter_args(%arg8 = %async_token_10, %arg9 = %async_token_12, %arg10 = %async_token_12, %arg11 = %async_token_12) -> (!air.async.token, !air.async.token, !air.async.token, !air.async.token) {
        %15 = affine.if #set()[%arg3, %arg4] -> !air.async.token {
          %20 = air.channel.get async [%arg11, %async_token_10, %arg8]  @channel_0[%arg3, %arg4] (%results_11[] [] []) {id = 8 : i32} : (memref<32x32xi32, 2>)
          affine.yield %20 : !air.async.token
        } else {
          %20 = air.channel.get async [%arg11, %async_token_10, %arg8]  @channel_1[%arg3, %arg4] (%results_11[] [] []) {id = 9 : i32} : (memref<32x32xi32, 2>)
          affine.yield %20 : !air.async.token
        }
        %16 = affine.if #set1()[%arg3, %arg4] -> !air.async.token {
          %20 = air.channel.get async [%arg11, %async_token_12, %arg8]  @channel_2[%arg3, %arg4] (%results_13[] [] []) {id = 10 : i32} : (memref<32x32xi32, 2>)
          affine.yield %20 : !air.async.token
        } else {
          %20 = air.channel.get async [%arg11, %async_token_12, %arg8]  @channel_3[%arg3, %arg4] (%results_13[] [] []) {id = 11 : i32} : (memref<32x32xi32, 2>)
          affine.yield %20 : !air.async.token
        }
        %async_token_15 = air.execute [%arg10, %16, %15] {
          linalg.matmul {cast = #linalg.type_fn<cast_signed>} ins(%results_11, %results_13 : memref<32x32xi32, 2>, memref<32x32xi32, 2>) outs(%results_5 : memref<32x32xi32, 2>)
        }
        %17 = affine.if #set()[%arg3, %arg4] -> !air.async.token {
          %20 = air.channel.get async [%16, %15, %arg9]  @channel_0[%arg3, %arg4] (%results_9[] [] []) {id = 8 : i32} : (memref<32x32xi32, 2>)
          affine.yield %20 : !air.async.token
        } else {
          %20 = air.channel.get async [%16, %15, %arg9]  @channel_1[%arg3, %arg4] (%results_9[] [] []) {id = 9 : i32} : (memref<32x32xi32, 2>)
          affine.yield %20 : !air.async.token
        }
        %18 = affine.if #set1()[%arg3, %arg4] -> !air.async.token {
          %20 = air.channel.get async [%16, %15, %arg9]  @channel_2[%arg3, %arg4] (%results_7[] [] []) {id = 10 : i32} : (memref<32x32xi32, 2>)
          affine.yield %20 : !air.async.token
        } else {
          %20 = air.channel.get async [%16, %15, %arg9]  @channel_3[%arg3, %arg4] (%results_7[] [] []) {id = 11 : i32} : (memref<32x32xi32, 2>)
          affine.yield %20 : !air.async.token
        }
        %async_token_18 = air.execute [%async_token_15, %18, %17] {
          linalg.matmul {cast = #linalg.type_fn<cast_signed>} ins(%results_9, %results_7 : memref<32x32xi32, 2>, memref<32x32xi32, 2>) outs(%results_5 : memref<32x32xi32, 2>)
        }
        %19 = air.wait_all async [%17, %18] 
        scf.yield %async_token_15, %async_token_18, %async_token_18, %19 : !air.async.token, !air.async.token, !air.async.token, !air.async.token
      }
      %14 = air.channel.put async [%13#1]  @channel_5[%arg3, %arg4] (%results_5[] [] []) {id = 12 : i32} : (memref<32x32xi32, 2>)
      %async_token_14 = air.execute [%14] {
        memref.dealloc %results_5 : memref<32x32xi32, 2>
      }
      %async_token_19 = air.execute {
        memref.dealloc %results_9 : memref<32x32xi32, 2>
      }
      %async_token_20 = air.execute {
        memref.dealloc %results_7 : memref<32x32xi32, 2>
      }
    }
    return
  }
}
