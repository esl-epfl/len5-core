#############################
# ----- CONFIGURATION ----- #
#############################

# General configuration
MAKE			?= make
BUILD_DIR		?= build

# Hardware floating point support
HARD_FLOAT		?= 1

# Target application
PROJECT			?= hello_world
LINKER 			?= linker/len5-sim.ld
SRCS 			:= $(shell find applications/$(PROJECT) -type f -name '*.c' -o -name '*.S')
OBJS 			:= $(filter %.o,\
				   $(patsubst %.c,$(BUILD_DIR)/%.o,$(SRCS))\
				   $(patsubst %.S,$(BUILD_DIR)/%.o,$(SRCS)))
INCS 			:= $(shell find applications/$(PROJECT) -type f -name '*.h')
INC_DIRS 		:= $(sort $(dir $(INCS)))

###  RISC-V C toolchain
# TODO: REMOVE -mstrict-align ONCE UNALIGNED ACCESS IS SUPPORTED
RISCV_EXE_PREFIX           	?= riscv64-unknown-elf
GCC_VERSION					:= $(shell $(RISCV_EXE_PREFIX)-gcc -dumpversion)
ifeq ($(HARD_FLOAT), 1)
ISA_STRING					?= rv64imd
ABI_STRING					?= lp64d
else
ISA_STRING					?= rv64im
ABI_STRING					?= lp64
endif
ifeq ($(shell expr $(GCC_VERSION) \>= 12), 1)
ISA_STRING				:= $(ISA_STRING)zicsr
endif
COPT						?= -O2
CDEFS						?= # SPIKE_CHECK if using Spike
CFLAGS			:= -march=$(ISA_STRING) \
				   -mabi=$(ABI_STRING) \
				   -mstrict-align \
				   -nostartfiles \
				   -flto \
				   -ffunction-sections \
				   -fdata-sections \
				   -fno-builtin \
				   $(COPT) \
				   -Wall
LDFLAGS_PRE		:= -T $(LINKER) \
				   -static
LDFLAGS_POST	:= -Wl,-Map,$(BUILD_DIR)/main.map \
				   -Wl,--gc-sections \
				   -specs=nano.specs \
				   -lm

# LEN5 software support
LIB_SRCS		:= $(wildcard device/crt/*.S) \
				   $(wildcard device/runtime/*.c device/runtime/*.S) \
				   $(wildcard device/base/**.c device/base/**.S)
LIB_INCS		:= $(wildcard device/base/*.h device/base/freestanding/*.h device/runtime/*.h)
INC_DIRS     	+= $(sort $(dir $(LIB_INCS)))
LIB_OBJS		:= $(filter %.o,\
				   $(patsubst %.S,$(BUILD_DIR)/%.o,$(LIB_SRCS))\
				   $(patsubst %.s,$(BUILD_DIR)/%.o,$(LIB_SRCS))\
				   $(patsubst %.c,$(BUILD_DIR)/%.o,$(LIB_SRCS)))

# Include directories
INC_DIRS_GCC 	+= $(addprefix -I ,$(INC_DIRS))

# Export all the variables to sub-makefiles
export

#######################
# ----- TARGETS ----- #
#######################

# Software build
# --------------
# Application build
.PHONY: app
app: $(BUILD_DIR)/main.hex $(BUILD_DIR)/main.disasm $(BUILD_DIR)/main.elf
.PHONY: benchmark
benchmark: $(LIB_OBJS) 
	$(MAKE) -B -C benchmarks $(SUITE) BENCHMARK=$(BENCHMARK) SUITE=$(SUITE)

$(BUILD_DIR)/main.%: $(BUILD_DIR)/applications/$(PROJECT)/main.%
	cp $< $@

# ASCII .hex firmware
$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf
	$(RISCV_EXE_PREFIX)-objcopy -O verilog $< $@

# Disassembly
$(BUILD_DIR)/%.disasm: $(BUILD_DIR)/%.elf
	$(RISCV_EXE_PREFIX)-objdump -D $< > $@

# Stripped binary firmware
$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	$(RISCV_EXE_PREFIX)-objcopy -O binary $< $@

# Linked executable firmware
$(BUILD_DIR)/%.elf: $(OBJS) $(LIB_OBJS)
	echo $(LIB_OBJS)
	$(RISCV_EXE_PREFIX)-gcc $(CFLAGS) $(LDFLAGS_PRE) $(INC_DIRS_GCC) $^ $(LDFLAGS_POST) -o $@

# Implicit compilation rules
$(BUILD_DIR)/%.o: ./%.c | $(BUILD_DIR)/applications/$(PROJECT)/
	@mkdir -p $(@D)
	$(RISCV_EXE_PREFIX)-gcc $(CFLAGS) $(CDEFS) $(INC_DIRS_GCC) -c $< -o $@
$(BUILD_DIR)/%.o: ./%.S | $(BUILD_DIR)/applications/$(PROJECT)/
	@mkdir -p $(@D)
	$(RISCV_EXE_PREFIX)-gcc $(CFLAGS) $(CDEFS) $(INC_DIRS_GCC) -c $< -o $@

# Utils
# -----
# Create new directories
%/:
	mkdir -p $@

# Print variables
.PHONY: .print
.print:
	@echo "RISCV:        $(RISCV)"
	@echo "ISA_STRING:   $(ISA_STRING)"
	@echo "ABI_STRING:   $(ABI_STRING)"
	@echo "PROJECT:      $(PROJECT)"
	@echo "SRCS:         $(SRCS)"
	@echo "OBJS:         $(OBJS)"
	@echo "INCS:         $(INCS)"
	@echo "INC_DIRS:     $(INC_DIRS)"
	@echo "LIB_SRCS:     $(LIB_SRCS)"
	@echo "LIB_OBJS:     $(LIB_OBJS)"
	@echo "LIB_INCS:     $(LIB_INCS)"
	@echo "CFLAGS:       $(CFLAGS)"
	@echo "LDFLAGS_PRE:  $(LDFLAGS_PRE)"
	@echo "LDFLAGS_POST: $(LDFLAGS_POST)"

# Clean-up
.PHONY: clean
clean:
	$(RM) -r $(BUILD_DIR)/*/*.elf
	$(RM) -r $(BUILD_DIR)/*/*.o
	$(RM) -r $(BUILD_DIR)/*/*.bin
	$(RM) -r $(BUILD_DIR)/*/*.hex
	$(RM) -r $(BUILD_DIR)/*/*.dis
	$(RM) -r $(BUILD_DIR)/*/*.map
	$(RM) -r $(BUILD_DIR)/*/*.dump
