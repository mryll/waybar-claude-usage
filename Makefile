PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
OMARCHY_PLUGINS_DIR ?= $(HOME)/.config/omarchy/plugins

install:
	install -Dm755 claudebar $(DESTDIR)$(BINDIR)/claudebar

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/claudebar

# Omarchy shell (Quickshell) plugin. Symlinks the omarchy/ directory into the
# shell's plugin dir (run `omarchy restart shell` after editing
# plugin files — the shell does not watch through symlinks). Requires the
# claudebar binary on PATH (make install first).
install-omarchy:
	@command -v claudebar >/dev/null 2>&1 || \
		echo "warning: claudebar is not on PATH — the widget will show an explicit error until it is installed (run 'make install PREFIX=~/.local')"
	mkdir -p "$(OMARCHY_PLUGINS_DIR)"
	ln -sfT "$(abspath .)" "$(OMARCHY_PLUGINS_DIR)/mryll.claudebar"
	@echo 'Linked omarchy/ -> $(OMARCHY_PLUGINS_DIR)/mryll.claudebar'
	@echo 'Add { "id": "mryll.claudebar" } to a bar layout section in ~/.config/omarchy/shell.json'

uninstall-omarchy:
	rm -f "$(OMARCHY_PLUGINS_DIR)/mryll.claudebar"

.PHONY: install uninstall install-omarchy uninstall-omarchy
