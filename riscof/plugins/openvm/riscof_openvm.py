import os
import re
import shutil
import subprocess
import shlex
import logging
import random
import string
from string import Template
import sys
from pathlib import Path

import riscof.utils as utils
import riscof.constants as constants
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class openvm(pluginTemplate):
    __model__ = "openvm"
    __version__ = "1.0.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

        config = kwargs.get('config')

        # If the config node for this DUT is missing or empty. Raise an error. At minimum we need
        # the paths to the ispec and pspec files
        if config is None:
            print("Please enter input file paths in configuration.")
            raise SystemExit(1)

        # Build path to executable
        self.dut_exe = os.path.join(os.path.abspath(config['PATH']), "dut-exe")

        # Number of parallel jobs that can be spawned off by RISCOF
        # for various actions performed in later functions, specifically to run the tests in
        # parallel on the DUT executable. Can also be used in the build function if required.
        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)

        # Path to the directory where this python file is located. Collect it from the config.ini
        self.pluginpath=os.path.abspath(config['pluginpath'])

        # Collect the paths to the  riscv-config absed ISA and platform yaml files. One can choose
        # to hardcode these here itself instead of picking it from the config.ini file.
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])

        #We capture if the user would like the run the tests on the target or
        #not. If you are interested in just compiling the tests and not running
        #them on the target, then following variable should be set to False
        # Default to False since we use --no-dut-run in entrypoint.sh
        if 'target_run' in config and config['target_run']=='1':
            self.target_run = True
        else:
            self.target_run = False

    def initialise(self, suite, work_dir, archtest_env):

       # capture the working directory. Any artifacts that the DUT creates should be placed in this
       # directory. Other artifacts from the framework and the Reference plugin will also be placed
       # here itself.
       self.work_dir = work_dir

       # capture the architectural test-suite directory.
       self.suite_dir = suite

       # Note the march is not hardwired here, because it will change for each
       # test. Similarly the output elf name and compile macros will be assigned later in the
       # runTests function
       self.compile_cmd = 'riscv64-unknown-elf-gcc -march={0}\
         -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g -mno-relax\
         -Wa,-march={0}\
         -T '+self.pluginpath+'/env/link.ld\
         -I '+self.pluginpath+'/env/\
         -I ' + archtest_env + ' {1} -o {2} {3}'

       # add more utility snippets here

    def build(self, isa_yaml, platform_yaml):

      # load the isa yaml as a dictionary in python.
      ispec = utils.load_yaml(isa_yaml)['hart0']

      # capture the XLEN value by picking the max value in 'supported_xlen' field of isa yaml. This
      # will be useful in setting integer value in the compiler string (if not already hardcoded);
      self.xlen = ('64' if 64 in ispec['supported_xlen'] else '32')

      # for openvm start building the '--isa' argument. the self.isa is dutnmae specific and may not be
      # useful for all DUTs
      self.isa = 'rv' + self.xlen
      if "I" in ispec["ISA"]:
          self.isa += 'i'
      if "M" in ispec["ISA"]:
          self.isa += 'm'
      if "F" in ispec["ISA"]:
          self.isa += 'f'
      if "D" in ispec["ISA"]:
          self.isa += 'd'
      if "C" in ispec["ISA"]:
          self.isa += 'c'

      # Check if float support is needed
      self.has_float = "F" in ispec["ISA"]

      # Use ilp32f/lp64d for float tests, ilp32/lp64 otherwise
      if 64 in ispec['supported_xlen']:
          abi = 'lp64d' if self.has_float else 'lp64'
      else:
          abi = 'ilp32f' if self.has_float else 'ilp32'

      self.compile_cmd = self.compile_cmd + ' -mabi=' + abi + ' '
      if self.has_float:
          # Float library artifacts - look in binaries/ first (built by cargo-openvm)
          # Fall back to env/ for local builds
          # Note: pluginpath is /riscof/plugins/openvm in Docker
          binaries_dir = '/binaries/float-libs'
          env_dir = os.path.join(self.pluginpath, 'env')

          # float_init.S is always in env/ (it's a source file)
          float_init_path = os.path.join(env_dir, 'float_init.S')

          # Check binaries/ first, then env/
          if os.path.exists(os.path.join(binaries_dir, 'libziskfloat.a')):
              # Use artifacts from binaries/ (built by cargo-openvm)
              float_lib_path = os.path.join(binaries_dir, 'libziskfloat.a')
              logger.info(f"Float support enabled - using cargo-openvm built library from binaries/")
              logger.info(f"  Library: {float_lib_path}")

              # For binaries/ artifacts, we only have the .a file
              # The .o files are included in the .a, so we don't need them separately
              self.float_files = f' {float_init_path} {float_lib_path} -lgcc'
          elif os.path.exists(os.path.join(env_dir, 'libziskfloat.a')):
              # Use artifacts from env/ (built locally)
              float_handler_path = os.path.join(env_dir, 'float.o')
              compiler_builtins_path = os.path.join(env_dir, 'compiler_builtins.o')
              float_lib_path = os.path.join(env_dir, 'libziskfloat.a')

              # Check that all required files exist
              missing_files = []
              if not os.path.exists(float_init_path):
                  missing_files.append(float_init_path)
              if not os.path.exists(float_handler_path):
                  missing_files.append(float_handler_path)
              if not os.path.exists(compiler_builtins_path):
                  missing_files.append(compiler_builtins_path)

              if missing_files:
                  logger.error("Float extension enabled but required files are missing:")
                  for f in missing_files:
                      logger.error(f"  - {f}")
                  build_script = os.path.join(env_dir, 'build_float_lib.sh')
                  logger.error(f"\nTo build the float library, run:")
                  logger.error(f"  {build_script}")
                  raise SystemExit(1)

              logger.info(f"Float support enabled - using locally built library from env/")
              logger.info(f"  Library: {float_lib_path}")
              # Link float.o and compiler_builtins.o as separate objects (not from archive)
              # to ensure _zisk_float symbol is available for .weak references
              self.float_files = f' {float_init_path} {float_handler_path} {compiler_builtins_path} {float_lib_path}'
          else:
              logger.error("Float extension enabled but float library not found")
              logger.error("Expected library in one of:")
              logger.error(f"  - {binaries_dir}/libziskfloat.a (built by cargo-openvm)")
              logger.error(f"  - {env_dir}/libziskfloat.a (built locally)")
              logger.error("")
              logger.error("To build with cargo-openvm:")
              logger.error("  1. cargo build -p cargo-openvm")
              logger.error("  2. scripts/copy-float-libs.sh")
              logger.error("")
              logger.error("Or build locally:")
              logger.error(f"  {env_dir}/build_float_lib.sh")
              raise SystemExit(1)
      else:
          self.float_files = ''

    def runTests(self, testList):

      # Delete Makefile if it already exists.
      if os.path.exists(self.work_dir+ "/Makefile." + self.name[:-1]):
            os.remove(self.work_dir+ "/Makefile." + self.name[:-1])
      # create an instance the makeUtil class that we will use to create targets.
      make = utils.makeUtil(makefilePath=os.path.join(self.work_dir, "Makefile." + self.name[:-1]))

      # set the make command that will be used. The num_jobs parameter was set in the __init__
      # function earlier
      make.makeCommand = 'make -k -j' + self.num_jobs

      # we will iterate over each entry in the testList. Each entry node will be refered to by the
      # variable testname.
      for testname in testList:

          # for each testname we get all its fields (as described by the testList format)
          testentry = testList[testname]

          # we capture the path to the assembly file of this test
          test = testentry['test_path']

          # capture the directory where the artifacts of this test will be dumped/created. RISCOF is
          # going to look into this directory for the signature files
          test_dir = testentry['work_dir']

          # name of the elf file after compilation of the test
          elf = 'my.elf'

          # name of the signature file as per requirement of RISCOF. RISCOF expects the signature to
          # be named as DUT-<dut-name>.signature. The below variable creates an absolute path of
          # signature file.
          sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")

          # for each test there are specific compile macros that need to be enabled. The macros in
          # the testList node only contain the macros/values. For the gcc toolchain we need to
          # prefix with "-D". The following does precisely that.
          compile_macros= ' -D' + " -D".join(testentry['macros'])

          # substitute all variables in the compile command that we created in the initialize
          # function
          cmd = self.compile_cmd.format(testentry['isa'].lower(), test, elf, compile_macros)

          # Add float library files if this test needs float support
          if self.has_float and self.float_files and 'f' in testentry['isa'].lower():
              cmd = cmd + self.float_files

          # if the user wants to disable running the tests and only compile the tests, then
          # the "else" clause is executed below assigning the sim command to simple no action
          # echo statement.
          if self.target_run:
              # Run the test using cargo-openvm with the --exe flag
              # cargo-openvm is available at self.dut_exe
              # Copy config files from plugin directory
              # Ensure a signature file exists even if OpenVM panics
              cargo_toml_src = os.path.join(self.pluginpath, 'Cargo.toml')
              openvm_toml_src = os.path.join(self.pluginpath, 'openvm.toml')

              # Build the command in readable parts
              copy_cargo = 'cp {3} Cargo.toml'
              copy_config = 'cp {4} openvm.toml'
              run_test = '({0} openvm run --exe {1} --signatures {2} || echo "PANIC" > {2}) 2>&1 | tail -5 > openvm.log'

              simcmd = f'{copy_cargo} && {copy_config} && {run_test}'.format(
                  self.dut_exe, elf, sig_file, cargo_toml_src, openvm_toml_src)
          else:
              # Create dummy signature file for RISCOF when not running
              simcmd = 'echo "Tests compiled but not run (--no-dut-run)" > {0}'.format(sig_file)

          # concatenate all commands that need to be executed within a make-target.
          execute = '@cd {0}; {1}; {2};'.format(testentry['work_dir'], cmd, simcmd)

          # create a target. The makeutil will create a target with the name "TARGET<num>" where num
          # starts from 0 and increments automatically for each new target that is added
          make.add_target(execute)

      # if you would like to exit the framework once the makefile generation is complete uncomment the
      # following line. Note this will prevent any signature checking or report generation.
      #raise SystemExit

      # once the make-targets are done and the makefile has been created, run all the targets in
      # parallel using the make command set above.
      make.execute_all(self.work_dir)

      # if target runs are not required then we simply exit as this point after running all
      # the makefile targets.
      # (Removed the SystemExit since we now support target_run)
