# run.py -*- Python -*-
#
# Copyright (C) 2024, Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT

import numpy as np
from ml_dtypes import bfloat16
import pyxrt as xrt

in_size = out_size = 128 * 128

in_size_bytes = in_size * 2
out_size_bytes = out_size * 2

with open("air.insts.bin", "rb") as f:
    instr_data = f.read()
    instr_v = np.frombuffer(instr_data, dtype=np.uint32)

opts_xclbin = "air.xclbin"
opts_kernel = "MLIR_AIE"

device = xrt.device(0)
xclbin = xrt.xclbin(opts_xclbin)
kernels = xclbin.get_kernels()
try:
    xkernel = [k for k in kernels if opts_kernel in k.get_name()][0]
except:
    print(f"Kernel '{opts_kernel}' not found in '{opts_xclbin}'")
    exit(-1)

device.register_xclbin(xclbin)
context = xrt.hw_context(device, xclbin.get_uuid())
kernel = xrt.kernel(context, xkernel.get_name())

bo_instr = xrt.bo(device, len(instr_v) * 4, xrt.bo.cacheable, kernel.group_id(1))
bo_a = xrt.bo(device, in_size_bytes, xrt.bo.host_only, kernel.group_id(3))
bo_b = xrt.bo(device, in_size_bytes, xrt.bo.host_only, kernel.group_id(4))
bo_c = xrt.bo(device, out_size_bytes, xrt.bo.host_only, kernel.group_id(5))

bo_instr.write(instr_v, 0)
bo_instr.sync(xrt.xclBOSyncDirection.XCL_BO_SYNC_BO_TO_DEVICE)

input_a = np.random.rand(in_size).astype(bfloat16)
bo_a.write(input_a.view(np.int16), 0)
bo_a.sync(xrt.xclBOSyncDirection.XCL_BO_SYNC_BO_TO_DEVICE)

input_b = np.random.rand(in_size).astype(bfloat16)
bo_b.write(input_b.view(np.int16), 0)
bo_b.sync(xrt.xclBOSyncDirection.XCL_BO_SYNC_BO_TO_DEVICE)

opcode = 3
h = kernel(opcode, bo_instr, len(instr_v), bo_a, bo_b, bo_c)
h.wait()

bo_c.sync(xrt.xclBOSyncDirection.XCL_BO_SYNC_BO_FROM_DEVICE)
output_buffer = bo_c.read(out_size_bytes, 0).view(bfloat16)
print("input:", input_a)
print("input:", input_b)
print("output:", output_buffer)

ref = input_a + input_b
print("ref:", ref)

err = 0
for i in range(0, len(ref)):
    if not np.allclose(output_buffer[i], ref[i], 0.01):
        print(i, output_buffer[i], "!=", ref[i])
        err = err + 1
if not err:
    print("PASS!")
    exit(0)
else:
    print("failed.")
    exit(-1)
