// RUN: air-opt -air-to-aie %s | FileCheck %s

func @launch(%arg0: i32) {
  %cst2 = constant 2 : index
  // CHECK: %[[TILE01:.*]] = AIE.tile(0, 1)
  // CHECK: {{.*}} = AIE.core(%[[TILE01]])  {
  // CHECK: %[[C0:.*]] = constant 0 : index
  // CHECK: %[[C1:.*]] = constant 1 : index
  // CHECK: %[[C20:.*]] = constant 2 : index
  // CHECK: %[[C21:.*]] = constant 2 : index
  // CHECK: {{.*}} = addi %[[C0]], %[[C1]] : index
  // CHECK: {{.*}} = muli %[[C20]], %[[C21]] : index
  air.launch_herd tile (%x, %y) in (%sx=%cst2, %sy=%cst2) {
    %buf = memref.alloc() : memref<1024xindex,2>
    %0 = addi %x, %y : index
    %1 = muli %sx, %sy : index
    memref.store %0, %buf[%1] : memref<1024xindex,2>
    air.herd_terminator
  }
  return
}