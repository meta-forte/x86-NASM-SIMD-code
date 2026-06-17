# ──────────────────────────────────────────────────────────────────────────────
# Makefile — x86-64 NASM Learning Collection
#
# Usage:
#   make          build all programs in src/ → obj/ and bin/
#   make clean    remove all generated object files and binaries
#   make <name>   build a single program, e.g.  make hello_world
#
# Requirements (WSL / Linux):
#   nasm   — assembler   (sudo apt install nasm)
#   gcc    — linker      (sudo apt install gcc)
#
# Programs that declare 'global main' are linked with gcc -no-pie.
# Programs that declare 'global _start' are linked with ld.
# ──────────────────────────────────────────────────────────────────────────────

ASM      := nasm
ASMFLAGS := -f elf64

CC       := gcc
CFLAGS   := -no-pie -lm

LD       := ld

SRC_DIR  := src
OBJ_DIR  := obj
BIN_DIR  := bin

# Discover all .asm source files
SOURCES  := $(wildcard $(SRC_DIR)/*.asm)
NAMES    := $(patsubst $(SRC_DIR)/%.asm,%,$(SOURCES))
OBJECTS  := $(patsubst $(SRC_DIR)/%.asm,$(OBJ_DIR)/%.o,$(SOURCES))

.PHONY: all clean $(NAMES)

all: $(NAMES)

# Per-name convenience target
$(NAMES): %: $(BIN_DIR)/%

# ── Assemble ─────────────────────────────────────────────────────────────────
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.asm | $(OBJ_DIR)
	$(ASM) $(ASMFLAGS) $< -o $@

# ── Link: choose ld or gcc based on whether the source uses _start or main ───
define link_rule
$(BIN_DIR)/$(1): $(OBJ_DIR)/$(1).o | $(BIN_DIR)
	@if grep -q 'global main' $(SRC_DIR)/$(1).asm 2>/dev/null; then \
	    echo "[gcc] $$<"; \
	    $(CC) $$< -o $$@ $(CFLAGS); \
	else \
	    echo "[ld ] $$<"; \
	    $(LD) $$< -o $$@; \
	fi
endef

$(foreach n,$(NAMES),$(eval $(call link_rule,$(n))))

# ── Directories ──────────────────────────────────────────────────────────────
$(OBJ_DIR):
	mkdir -p $@

$(BIN_DIR):
	mkdir -p $@

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f $(OBJ_DIR)/*.o
	rm -f $(BIN_DIR)/*
	@echo "Cleaned obj/ and bin/."
