INSTALL_DIR := /usr/local/bin
SCRIPT_DIR  := $(shell pwd)
TARGET      := $(INSTALL_DIR)/gpustack

.PHONY: help install uninstall check

help:
	@echo ""
	@echo "  Usage: make <target>"
	@echo ""
	@echo "  Targets:"
	@echo "    install     Symlink ./gpustack to $(INSTALL_DIR)/gpustack"
	@echo "    uninstall   Remove the symlink from $(INSTALL_DIR)"
	@echo "    check       Verify the CLI is callable and print version"
	@echo ""
	@echo "  Or run directly without installing:"
	@echo "    ./gpustack --help"
	@echo ""

install:
	@echo "==> Symlinking gpustack to $(TARGET)"
	@chmod +x "$(SCRIPT_DIR)/gpustack"
	@ln -sf "$(SCRIPT_DIR)/gpustack" "$(TARGET)"
	@echo "    Done. Run: gpustack --help"

uninstall:
	@if [ -L "$(TARGET)" ]; then \
		rm "$(TARGET)"; \
		echo "==> Removed $(TARGET)"; \
	else \
		echo "==> $(TARGET) not found — nothing to remove"; \
	fi

check:
	@gpustack --version