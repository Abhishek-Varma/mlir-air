"""
aircc - AIR compiler driver for MLIR tools
"""

import itertools
import os
import platform
import sys
import time
import subprocess
from joblib import Parallel, delayed
import tempfile

from air.mlir.passmanager import PassManager
from air.mlir.ir import Module

import air.compiler.aircc.cl_arguments as cl_arguments

def emit_wrapper(herd_name="herd", include_name="aie.inc"):
    s = """// generated, do not edit
#include "stdio.h"
#include "assert.h"
#include "air_host.h"

namespace air {
namespace herds {
"""
    s = s + f'namespace {herd_name} {{\n'
    s = s + f'#include "{include_name}"'
    s = s + """
}
}
}
"""
    s = s + f'using namespace air::herds::{herd_name};'
    s = s + """
extern "C" {
"""
    s = s + f'air_rt_aie_functions_t __airrt_{herd_name}_aie_functions {{'
    s = s + """
  .configure_cores = &mlir_aie_configure_cores,
  .configure_switchboxes = &mlir_aie_configure_switchboxes,
  .initialize_locks = &mlir_aie_initialize_locks,
  .configure_dmas = &mlir_aie_configure_dmas,
  .start_cores = &mlir_aie_start_cores
};
}
"""
    return s

def do_call(command):
    global opts
    if(opts.verbose):
        print(" ".join(command))
    ret = subprocess.call(command)
    if(ret != 0):
        print("Error encountered while running: " + " ".join(command))
        sys.exit(1)

def do_run(command):
    global opts
    if(opts.verbose):
        print(" ".join(command))
    ret = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    return ret

def run_passes(pass_pipeline, mlir_module, opts, outputfile=None):
  if opts.verbose:
    print("Running:", pass_pipeline)
  PassManager.parse(pass_pipeline).run(mlir_module)
  if outputfile:
    with open(outputfile, 'w') as g:
      g.write(str(mlir_module))

def run(mlir_module, args):
  global opts
  opts = cl_arguments.parse_args(args)
  if(opts.tmpdir):
    tmpdirname = opts.tmpdir
    try:
      os.mkdir(tmpdirname)
    except FileExistsError:
      pass
    if(opts.verbose):
      print('created temporary directory', tmpdirname)

  with mlir_module.context as ctx:
    m = Module.parse(str(mlir_module))
    air_to_aie_pass = 'air-to-aie{air-to-aie-emit-while-loop=false'
    air_to_aie_pass = air_to_aie_pass + f' air-to-aie-row-offset={opts.row_offset} air-to-aie-col-offset={opts.col_offset}'
    air_to_aie_pass = air_to_aie_pass + f' air-to-aie-output-prefix={opts.tmpdir}/' + '}'

    run_passes(air_to_aie_pass+',builtin.func(convert-linalg-to-loops)',Module.parse(str(m)),opts)

    air_to_airrt_pass = 'air-to-aie{air-to-aie-emit-while-loop=true'
    air_to_airrt_pass = air_to_airrt_pass + f' air-to-aie-row-offset={opts.row_offset} air-to-aie-col-offset={opts.col_offset}'
    air_to_airrt_pass = air_to_airrt_pass + f' air-to-aie-output-prefix={opts.tmpdir}/' + '}'

    _,air_mlir_filename = os.path.split(opts.air_mlir_file)
    air_mlir_filename = "torch.mlir"

    # make the control program as llvm dialect

    aie_ctrl_airrt = opts.tmpdir+'/airrt.'+air_mlir_filename
    pass_pipeline = air_to_airrt_pass+',convert-vector-to-llvm,air-to-std,air-lower-linalg-tensors,canonicalize,cse'
    run_passes(pass_pipeline, mlir_module, opts, aie_ctrl_airrt)

    aie_ctrl = opts.tmpdir+'/aie_ctrl.'+air_mlir_filename
    pass_pipeline = 'airrt-to-llvm,func-bufferize,builtin.func(finalizing-bufferize)'
    run_passes(pass_pipeline, mlir_module, opts, aie_ctrl)

    aie_ctrl_refback = opts.tmpdir+'/refback.'+air_mlir_filename
    pass_pipeline = 'convert-vector-to-llvm,air-to-std,air-lower-linalg-tensors,canonicalize,cse,'+ \
                    'airrt-to-llvm,canonicalize,cse'
    run_passes(pass_pipeline, Module.parse(str(m)), opts, aie_ctrl_refback)

    aie_ctrl_llvm = opts.tmpdir+'/llvm.'+air_mlir_filename
    pass_pipeline = 'lower-affine,convert-scf-to-std,convert-memref-to-llvm,convert-std-to-llvm,canonicalize,cse'
    run_passes(pass_pipeline, mlir_module, opts, aie_ctrl_llvm)

    aie_ctrl_llvm_ir = opts.tmpdir+'/'+air_mlir_filename+'.ll'
    do_call(['aie-translate', '--mlir-to-llvmir', aie_ctrl_llvm, '-o', aie_ctrl_llvm_ir])

    aie_ctrl_llvm_opt_bc = opts.tmpdir+'/'+air_mlir_filename+'.opt.bc'
    do_call(['opt', '-O3', aie_ctrl_llvm_ir, '-o', aie_ctrl_llvm_opt_bc])

    aie_ctrl_llvm_opt_ir = opts.tmpdir+'/'+air_mlir_filename+'.opt.ll'
    do_call(['llvm-dis', aie_ctrl_llvm_opt_bc, '-o', aie_ctrl_llvm_opt_ir])

    aie_ctrl_obj = opts.tmpdir+'/'+air_mlir_filename+'.o'
    do_call(['clang', '-Wno-override-module', '-fPIC', '--target=aarch64-linux-gnu', '-c', aie_ctrl_llvm_opt_ir, '-o', aie_ctrl_obj])

    t = do_run(['air-translate', '--airrt-generate-json', aie_ctrl_airrt])
    module_meta = eval(t.stdout)
    herds = [module_meta[herd]["sym_name"] for herd in module_meta]
    if opts.verbose:
      print ("Compiling herds:", herds)
    obj_files = [aie_ctrl_obj]
    for herd in herds:
      herd_file = opts.tmpdir+'/aie.'+herd+'.mlir'
      aiecc_file = opts.tmpdir+'/aiecc.'+herd+'.mlir'
      aiecc_dir = opts.tmpdir+'/'+herd
      do_call(['air-opt', herd_file, '-air-lower-linalg-tensors', '--lower-affine', '-cse', '-o', aiecc_file])
      do_call(['aiecc.py'] +
              (['-v'] if opts.verbose else []) +
              (['--sysroot', opts.sysroot] if opts.sysroot!="" else []) +
              ['--tmpdir', aiecc_dir] +
              ['--pathfinder'] +
              ['--no-xbridge', '--no-xchesscc', aiecc_file])

      inc_file = opts.tmpdir+'/'+air_mlir_filename+'.'+herd+'.inc'
      cpp_file = opts.tmpdir+'/'+air_mlir_filename+'.'+herd+'.cpp'
      obj_file = opts.tmpdir+'/'+air_mlir_filename+'.'+herd+'.o'

      do_call(['cp',aiecc_dir+'/aie_inc.cpp',inc_file])

      with open(cpp_file, 'w') as f:
        f.write(emit_wrapper(herd, inc_file))

      cmd = [opts.cc, '-std=c++11', '--target=aarch64-linux-gnu', '-g']
      if(opts.sysroot):
        cmd += ['--sysroot=%s' % opts.sysroot]
      cmd += ['-I.', f'-I{opts.sysroot}/opt/xaiengine/include']
      thispath = os.path.dirname(os.path.realpath(__file__))
      cmd += [f'-I{thispath}/../../../../runtime_lib/airhost/include']
      cmd += [f'-I{thispath}/../../../../runtime_lib']
      cmd += ['-DAIE_LIBXAIE_ENABLE', '-fPIC', '-c']
      cmd += ['-o', obj_file, cpp_file]
      do_call(cmd)

      obj_files.append(obj_file)

    lib_file = opts.tmpdir+'/'+opts.air_mlir_file+('.so' if opts.shared else '.a')
    if opts.shared:
      cmd = ['clang', '-shared', '-o', lib_file] + obj_files
    else:
      cmd = ['llvm-ar', 'rc', lib_file] + obj_files
    do_call(cmd)

    if opts.output_file:
      do_call(['cp', lib_file, opts.output_file])

def run_flow(opts):
    thispath = os.path.dirname(os.path.realpath(__file__))
    air_to_aie_pass = '-air-to-aie=air-to-aie-emit-while-loop=false'
    air_to_aie_pass = air_to_aie_pass + f' air-to-aie-row-offset={opts.row_offset} air-to-aie-col-offset={opts.col_offset}'
    air_to_aie_pass = air_to_aie_pass + f' air-to-aie-output-prefix={opts.tmpdir}/'
    
    do_call(['air-opt', opts.air_mlir_file,
             air_to_aie_pass, '-o', '/dev/null'])

    air_to_airrt_pass = '-air-to-aie=air-to-aie-emit-while-loop=false'
    air_to_airrt_pass = air_to_airrt_pass + f' air-to-aie-row-offset={opts.row_offset} air-to-aie-col-offset={opts.col_offset}'
    air_to_airrt_pass = air_to_airrt_pass + f' air-to-aie-output-prefix={opts.tmpdir}/'

    _,air_mlir_filename = os.path.split(opts.air_mlir_file)
    aie_ctrl_airrt = opts.tmpdir+'/airrt.'+air_mlir_filename
    do_call(['air-opt', opts.air_mlir_file, air_to_airrt_pass,
            '-convert-vector-to-llvm', '-air-to-std',
            '-air-lower-linalg-tensors', '-canonicalize', '-cse',
            '-o', aie_ctrl_airrt])

    aie_ctrl = opts.tmpdir+'/aie_ctrl.'+air_mlir_filename
    do_call(['air-opt', aie_ctrl_airrt,
            '-airrt-to-llvm', '-func-bufferize', '-finalizing-bufferize',
            '-o', aie_ctrl])

    aie_ctrl_llvm = opts.tmpdir+'/llvm.'+air_mlir_filename
    do_call(['air-opt', aie_ctrl,
            '-air-return-elimination','--lower-affine','--convert-scf-to-std',
            '--convert-memref-to-llvm',
            '--convert-std-to-llvm',
            '--canonicalize', '--cse',
            '-o', aie_ctrl_llvm])

    aie_ctrl_llvm_ir = opts.tmpdir+'/'+air_mlir_filename+'.ll'
    do_call(['aie-translate', '--mlir-to-llvmir', aie_ctrl_llvm, '-o', aie_ctrl_llvm_ir])

    aie_ctrl_llvm_opt_bc = opts.tmpdir+'/'+air_mlir_filename+'.opt.bc'
    do_call(['opt', '-O3', aie_ctrl_llvm_ir, '-o', aie_ctrl_llvm_opt_bc])

    aie_ctrl_llvm_opt_ir = opts.tmpdir+'/'+air_mlir_filename+'.opt.ll'
    do_call(['llvm-dis', aie_ctrl_llvm_opt_bc, '-o', aie_ctrl_llvm_opt_ir])

    aie_ctrl_obj = opts.tmpdir+'/'+air_mlir_filename+'.o'
    do_call(['clang', '-Wno-override-module', '-fPIC', '--target=aarch64-linux-gnu', '-c', aie_ctrl_llvm_opt_ir, '-o', aie_ctrl_obj])

    t = do_run(['air-translate', '--airrt-generate-json', aie_ctrl_airrt])
    module_meta = eval(t.stdout)
    herds = [module_meta[herd]["sym_name"] for herd in module_meta]
    print ("Compiling herds:", herds)
    obj_files = [aie_ctrl_obj]
    for herd in herds:
      herd_file = opts.tmpdir+'/aie.'+herd+'.mlir'
      aiecc_file = opts.tmpdir+'/aiecc.'+herd+'.mlir'
      aiecc_dir = opts.tmpdir+'/'+herd
      do_call(['air-opt', herd_file, '-air-lower-linalg-tensors', '--lower-affine', '-cse', '-o', aiecc_file])
      do_call(['aiecc.py'] +
              (['-v'] if opts.verbose else []) +
              (['--sysroot', opts.sysroot] if opts.sysroot!="" else []) +
              ['--tmpdir', aiecc_dir] +
              ['--pathfinder'] +
              ['--no-xbridge', '--no-xchesscc', aiecc_file])

      inc_file = opts.tmpdir+'/'+air_mlir_filename+'.'+herd+'.inc'
      cpp_file = opts.tmpdir+'/'+air_mlir_filename+'.'+herd+'.cpp'
      obj_file = opts.tmpdir+'/'+air_mlir_filename+'.'+herd+'.o'

      do_call(['cp',aiecc_dir+'/aie_inc.cpp',inc_file])

      with open(cpp_file, 'w') as f:
        f.write(emit_wrapper(herd, inc_file))

      cmd = [opts.cc, '-std=c++11', '--target=aarch64-linux-gnu', '-g']
      if(opts.sysroot):
        cmd += ['--sysroot=%s' % opts.sysroot]
      cmd += ['-I.', f'-I{opts.sysroot}/opt/xaiengine/include']
      cmd += [f'-I{thispath}/../../../../runtime_lib/airhost/include']
      cmd += [f'-I{thispath}/../../../../runtime_lib']
      cmd += ['-DAIE_LIBXAIE_ENABLE', '-fPIC', '-c']
      cmd += ['-o', obj_file, cpp_file]
      do_call(cmd)

      obj_files.append(obj_file)

    lib_file = opts.air_mlir_file+('.so' if opts.shared else '.a')
    if opts.shared:
      raise NotImplemented
    else:
      cmd = ['llvm-ar', 'rc', lib_file] + obj_files
    do_call(cmd)

    if opts.output_file:
      do_call(['mv', lib_file, opts.output_file])


def main():
    global opts
    opts = cl_arguments.parse_args()
    is_windows = platform.system() == 'Windows'

    if opts.shared:
      print('shared library option not implemented')
      raise NotImplemented

    if(opts.verbose):
        sys.stderr.write('\ncompiling %s\n' % opts.air_mlir_file)

    if(opts.tmpdir):
      tmpdirname = opts.tmpdir
      try:
        os.mkdir(tmpdirname)
      except FileExistsError:
        pass
      if(opts.verbose):
        print('created temporary directory', tmpdirname)

      run_flow(opts)
    else:
      with tempfile.TemporaryDirectory() as tmpdirname:
        run_flow(opts)
