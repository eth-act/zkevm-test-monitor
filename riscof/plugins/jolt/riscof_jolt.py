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

import riscof.utils as utils
import riscof.constants as constants
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class jolt(pluginTemplate):
    __model__ = "jolt"
    __version__ = "1.0.0"
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        
        config = kwargs.get('config')
        
        # If the config node for this DUT is missing or empty, raise an error
        if config is None:
            print("Please enter input file paths in configuration.")
            raise SystemExit(1)
        
        # Build path to executable
        self.dut_exe = os.path.join(os.path.abspath(config['PATH']), "dut-exe")
        
        # Number of parallel jobs for running tests
        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)
        
        # Path to the plugin directory
        self.pluginpath = os.path.abspath(config['pluginpath'])
        
        # Paths to ISA and platform specs
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])
        
        # Capture if the user wants to run tests or just compile
        # Default to True since entrypoint.sh now runs tests
        if 'target_run' in config and config['target_run']=='0':
            self.target_run = False
        else:
            self.target_run = True
        
        # Verify jolt-emu exists and is executable when target_run is enabled
        if self.target_run:
            if not os.path.isfile(self.dut_exe):
                logger.error(f"jolt-emu not found at {self.dut_exe}")
                raise SystemExit(1)
            if not os.access(self.dut_exe, os.X_OK):
                logger.error(f"jolt-emu at {self.dut_exe} is not executable")
                raise SystemExit(1)
    
    def initialise(self, suite, work_dir, archtest_env):
        # Capture the working directory for artifacts
        self.work_dir = work_dir
        
        # Capture the architectural test-suite directory
        self.suite_dir = suite
        
        # Capture test environment for includes
        self.archtest_env = archtest_env
        
        # Standard GCC compilation command
        self.compile_cmd = 'riscv64-unknown-elf-gcc -march={0} \
            -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g\
            -T '+self.pluginpath+'/env/link.ld\
            -I '+self.pluginpath+'/env/\
            -I ' + archtest_env
    
    def build(self, isa_yaml, platform_yaml):
        # Load the ISA yaml as a dictionary
        ispec = utils.load_yaml(isa_yaml)['hart0']
        
        # Capture XLEN value
        self.xlen = ('64' if 64 in ispec['supported_xlen'] else '32')
        
        # Build ISA string for jolt (simplified since Jolt supports RV32IM)
        self.isa = 'rv' + self.xlen
        if "I" in ispec["ISA"]:
            self.isa += 'i'
        if "M" in ispec["ISA"]:
            self.isa += 'm'
        
        # Set ABI based on XLEN
        abi = 'lp64' if 64 in ispec['supported_xlen'] else 'ilp32'
        self.compile_cmd = self.compile_cmd + ' -mabi=' + abi + ' {1} -o {2} {3}'
    
    def runTests(self, testList):
        # Delete existing Makefile if it exists
        makefile_path = os.path.join(self.work_dir, "Makefile." + self.name[:-1])
        if os.path.exists(makefile_path):
            os.remove(makefile_path)
        
        # Create an instance of makeUtil for parallel execution
        make = utils.makeUtil(makefilePath=makefile_path)
        
        # Set the make command with parallel jobs
        make.makeCommand = 'make -k -j' + self.num_jobs
        
        # Iterate over each test in the test list
        for testname in testList:
            # Get test entry details
            testentry = testList[testname]
            
            # Path to the assembly file
            test = testentry['test_path']
            
            # Directory for test artifacts
            test_dir = testentry['work_dir']
            
            # Name of the compiled ELF
            elf = 'my.elf'
            
            # Path to signature file (RISCOF expects DUT-<name>.signature)
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
            
            # Compile macros with -D prefix for gcc
            compile_macros = ' -D' + " -D".join(testentry['macros'])
            
            # Substitute variables in compile command
            # Format: {0}=march, {1}=xlen, {1}=input_test, {2}=output_elf, {3}=compile_macros
            cmd = self.compile_cmd.format(testentry['isa'].lower(), test, elf, compile_macros)
            
            # Set up simulation/execution command based on target_run
            if self.target_run:
                # Run jolt-emu with signature extraction
                # Ensure a signature file exists even if Jolt panics
                simcmd = '({0} {1} --signature {2} --signature-granularity 4 || echo "PANIC" > {2}) > jolt.log 2>&1'.format(
                    self.dut_exe, elf, sig_file)
            else:
                # Create dummy signature when not running tests
                simcmd = 'echo "# Test compiled but not executed (target_run=0)" > {0}'.format(sig_file)
            
            # Create the complete command to execute in the make target
            execute = '@cd {0}; {1}; {2}'.format(test_dir, cmd, simcmd)
            
            # Add target to makefile
            make.add_target(execute)
        
        # Execute all targets in parallel using make
        make.execute_all(self.work_dir)
        
        # If target_run is enabled, verify signatures were created
        if self.target_run:
            for testname in testList:
                testentry = testList[testname]
                test_dir = testentry['work_dir']
                sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
                
                if not os.path.exists(sig_file):
                    logger.warning(f"Signature file not generated for {testname}")
                    # Check log for debugging
                    log_path = os.path.join(test_dir, 'jolt.log')
                    if os.path.exists(log_path):
                        with open(log_path, 'r') as f:
                            logger.debug(f"jolt-emu output for {testname}: {f.read()}")