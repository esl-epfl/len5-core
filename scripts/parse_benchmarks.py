import argparse
import multiprocessing
import sys
import getopt
import os
import subprocess
import time
from typing import List, Dict
import csv

def get_benchmarks(benchmarks_dir) -> List[str]:
    """Reads the files present in the benchmarks directory."""
    
    if not os.path.exists(benchmarks_dir):
        print(f"Error: {benchmarks_dir} does not exist")
        sys.exit(2)
    else:
        benchmarks =  os.listdir(benchmarks_dir) 
        
        return benchmarks

def get_report_start(stdout) -> int:
    # Find the start of the execution report

    start_string = "Program exit with code: "
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0 # Return 0 if the line is not found
    return start_index

def parse_status(stdout) -> int:
    # Find the line containing "Instructions: "

    start_string = "Program exit with code: "

    start_index = stdout.find(start_string)
    if start_index == -1:
        return 1  # Return 0 if the line is not found

    # Extract the substring containing the number of instructions
    start_index += len(start_string)
    end_index = stdout.find("(", start_index)
    instructions_str = stdout[start_index:end_index].strip(' ')
    
    # Convert the extracted substring to an integer and return it
    try:
        instructions = int(instructions_str, 16)
        return instructions
    except ValueError:
        return 1  # Return 0 if conversion fails

def parse_retired_instructions(stdout) -> int:
    # Find the line containing "retired instructions:: "
    start_string = "retired instructions:"
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of instructions
    start_index += len(start_string)
    end_index = stdout.find("\n", start_index)
    instructions_str = stdout[start_index:end_index].strip(' ')
    # Convert the extracted substring to an integer and return it
    try:
        instructions = int(instructions_str)
        return instructions
    except ValueError:
        return 0  # Return 0 if conversion fails

def parse_cycles(stdout) -> int:
    # Find the line containing "total CPU cycles: "
    start_string = "total CPU cycles: "
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of cycles
    start_index += len(start_string)
    end_index = stdout.find("\n", start_index)
    cycles_str = stdout[start_index:end_index].strip(' ')

    # Convert the extracted substring to an integer and return it
    try:
        cycles = int(cycles_str)
        return cycles
    except ValueError:
        return 0  # Return 0 if conversion fails

def parse_jumps(stdout) -> int:
    # Find the line containing "- jumps: "
    start_string = "- jumps: "
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of cycles
    start_index += len(start_string)
    end_index = stdout.find("(", start_index)
    cycles_str = stdout[start_index:end_index].strip(' ')

    # Convert the extracted substring to an integer and return it
    try:
        cycles = int(cycles_str)
        return cycles
    except ValueError:
        return 0  # Return 0 if conversion fails

def parse_branches(stdout) -> int:
    # Find the line containing "- branches:"
    start_string = "- branches:"
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of cycles
    start_index += len(start_string)
    end_index = stdout.find("(", start_index)
    cycles_str = stdout[start_index:end_index].strip(' ')

    # Convert the extracted substring to an integer and return it
    try:
        cycles = int(cycles_str)
        return cycles
    except ValueError:
        return 0  # Return 0 if conversion fails
    
def parse_loads(stdout) -> int:
    # Find the line containing "- loads:"
    start_string = "- loads:"
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of cycles
    start_index += len(start_string)
    end_index = stdout.find("(", start_index)
    cycles_str = stdout[start_index:end_index].strip(' ')

    # Convert the extracted substring to an integer and return it
    try:
        cycles = int(cycles_str)
        return cycles
    except ValueError:
        return 0  # Return 0 if conversion fails

def parse_stores(stdout) -> int:
    # Find the line containing "- stores:"
    start_string = "- stores:"
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of cycles
    start_index += len(start_string)
    end_index = stdout.find("(", start_index)
    cycles_str = stdout[start_index:end_index].strip(' ')

    # Convert the extracted substring to an integer and return it
    try:
        cycles = int(cycles_str)
        return cycles
    except ValueError:
        return 0  # Return 0 if conversion fails

def parse_inst_fetches(stdout) -> int:
    # Find the line containing "- instruction fetches:"
    start_string = "- instruction fetches:"
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of cycles
    start_index += len(start_string)
    end_index = stdout.find("(", start_index)
    cycles_str = stdout[start_index:end_index].strip(' ')

    # Convert the extracted substring to an integer and return it
    try:
        cycles = int(cycles_str)
        return cycles
    except ValueError:
        return 0  # Return 0 if conversion fails

def parse_writes(stdout) -> int:
    # Find the line containing "- write requests: "
    start_string = "- write requests: "
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of cycles
    start_index += len(start_string)
    end_index = stdout.find("(", start_index)
    cycles_str = stdout[start_index:end_index].strip(' ')

    # Convert the extracted substring to an integer and return it
    try:
        cycles = int(cycles_str)
        return cycles
    except ValueError:
        return 0  # Return 0 if conversion fails

def parse_reads(stdout) -> int:
    # Find the line containing "- read requests:"
    start_string = "- read requests:"
    start_index = stdout.find(start_string)
    if start_index == -1:
        return 0  # Return 0 if the line is not found

    # Extract the substring containing the number of cycles
    start_index += len(start_string)
    end_index = stdout.find("(", start_index)
    cycles_str = stdout[start_index:end_index].strip(' ')

    # Convert the extracted substring to an integer and return it
    try:
        cycles = int(cycles_str)
        return cycles
    except ValueError:
        return 0  # Return 0 if conversion fails

def init_table() -> Dict[str, Dict]:
    """Initializes a dictionary to store the results of the benchmarks."""
    table = {}

    return table

def update_table(table, benchmark, output_log):
    """Updates the table with the results of a benchmark."""
    if benchmark not in table:
        table[benchmark] = {}
    
    table[benchmark]["status"] = (parse_status(output_log)==0)
    table[benchmark]["instructions"] = parse_retired_instructions(output_log)
    table[benchmark]["cycles"] = parse_cycles(output_log)
    if table[benchmark]["cycles"]!=0:
        table[benchmark]["ipc"] = table[benchmark]["instructions"]/table[benchmark]["cycles"]
    else:
        table[benchmark]["ipc"] = 0
    table[benchmark]["jumps"] = parse_jumps(output_log)
    table[benchmark]["branches"] = parse_branches(output_log)
    table[benchmark]["branch/jump"] = table[benchmark]["jumps"] + table[benchmark]["branches"]
    table[benchmark]["loads"] = parse_loads(output_log)
    table[benchmark]["stores"] = parse_stores(output_log)
    table[benchmark]["load/store"] = table[benchmark]["loads"] + table[benchmark]["stores"]
    table[benchmark]["instr_fetches"] = parse_inst_fetches(output_log)
    table[benchmark]["read_req"] = parse_reads(output_log)
    table[benchmark]["write_req"] = parse_writes(output_log)
    table[benchmark]["memory_req"] = table[benchmark]["instr_fetches"] + table[benchmark]["write_req"] + table[benchmark]["read_req"]

    return table

def print_table_to_file_csv(table, path):
    """Prints the table to a file."""
    output_dir = os.path.join(path, "output")
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    output_file = os.path.join(output_dir, "benchmarks.csv")

    with open(output_file, "w") as file:
        file.write(f"Benchmark,Status,Instructions,Cycles,IPC,Jumps,Branches,Branch/Jump Instructions,Loads,Stores,Load/Store Instructions,Instruction fetches,Write Requests,Read Requests,Memory Requests\n")
        for benchmark, results in table.items():
            file.write(f"{benchmark[:-4]},")
            file.write(f"{results['status']},")
            file.write(f"{results['instructions']},")
            file.write(f"{results['cycles']},")
            file.write(f"{results['ipc'] : .2f},")
            file.write(f"{results['jumps']},")
            file.write(f"{results['branches']},")
            file.write(f"{results['branch/jump']},")
            file.write(f"{results['loads']},")
            file.write(f"{results['stores']},")
            file.write(f"{results['load/store']},")
            file.write(f"{results['instr_fetches']},")
            file.write(f"{results['read_req']},")
            file.write(f"{results['write_req']},")
            file.write(f"{results['memory_req']}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Benchmark runner for LEN5")
    parser.add_argument("-s",
                        help="Benchmark suite name")
    parser.add_argument("-p", 
                        help="Path to the run library")

    args = parser.parse_args()
    
    if (not args.s):
        print("Usage: python parse_benchmarks.py -s <suite>")
        sys.exit(2)
    else:
        SUITE = args.s

    if (not args.p):
        print("Usage: python parse_benchmarks.py -p <path>")
        sys.exit(2)
    else:
        PATH = args.p

    #create stats table
    stats = init_table()

    #get path of the run dir
    cwd = os.getcwd()
    benchmarks_dir = os.path.join(cwd, PATH, 'logs/sim')
    BENCH_WHITE_LISTE = ['cubic', 'nbody', 'nettle-sha256', 'st', 'ud']
    print("Benchmark summary:")
    #get benchmarks
    benchmarks = get_benchmarks(benchmarks_dir)
    correctly_ex = 0
    for i, b in enumerate(benchmarks):
        with open(os.path.join(benchmarks_dir, b)) as f:
            output_log = f.read()
            start_report = get_report_start(output_log)
            output_log = output_log[start_report:]
            stats = update_table(stats, b, output_log)
        if stats[b]["status"]:
            print(f"{i+1:4d}) {b[:-4]:15}: \033[92mSUCCESS\033[00m (IPC={stats[b]['ipc'] : .2f})")
            correctly_ex += 1
        else:
            print(f"{i:4d}) {b[:-4]:15}: \033[91mFAILURE\033[00m (IPC={stats[b]['ipc'] : .2f})")

    print(f"Correctly executed testbenches {correctly_ex} out of {len(stats)}.")
    
    if not all([s["status"] for b, s in stats.items() if b[:-4] not in BENCH_WHITE_LISTE]):
        print("\033[91mFailed tests: ",end='')
        benchmarks_fail = ""
        for b, s in stats.items():
            if b[:-4] not in BENCH_WHITE_LISTE and not s["status"]:
                benchmarks_fail = benchmarks_fail+', '+b[:-4]
        benchmarks_fail = benchmarks_fail[2:] + ".\033[00m"
        print(benchmarks_fail)
        sys.exit(1)

    print(f"Saving the csv report to {PATH}/output.")
    print_table_to_file_csv(stats, PATH)
